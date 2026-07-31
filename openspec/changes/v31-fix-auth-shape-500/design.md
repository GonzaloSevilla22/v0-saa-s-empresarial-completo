## Context

`get_current_user` (`backend/core/auth.py`) es el único punto donde el backend Python traduce un JWT de Supabase a un contexto de aplicación. Devuelve hoy:

```python
return {"user_id": payload["sub"], "role": app_role, "plan": app_plan}
```

y está anotado como `-> dict`. Sin forma declarada, cada consumidor "adivina" las claves. Tres lo adivinaron mal:

| Archivo | Línea | Expresión actual | Efecto |
|---|---|---|---|
| `backend/routers/quotes.py` | 60 | `created_by=auth.get("sub", "")` | `""` como `created_by` de `quotes` (columna uuid) |
| `backend/routers/customer_accounts.py` | 61 | `account_id = auth.get("account_id") or auth.get("sub", "")` | `""` como `account_id` del tenant |
| `backend/routers/supplier_accounts.py` | 61 | idem | idem |

Los otros diez lectores (`backend/core/guards.py:32`, `backend/routers/payments.py:45`, y los services de `clients`, `client_addresses`, `expenses`, `products`, `purchases`, `sales`) ya usan `auth["user_id"]` y funcionan.

**Por qué la suite no lo vio.** El fixture de `backend/tests/conftest.py` no fabrica un contexto falso: fabrica un **JWT** falso (`make_token()` con `sub`/`role="authenticated"`) y deja correr a `get_current_user` de verdad. Por eso `auth["user_id"]` funciona en tests. Lo que falla es `auth.get("sub", "")`, que devuelve `""` — y como los repositorios están mockeados en esos tests, el `""` nunca llega a asyncpg y nadie lo observa. La ceguera no está en el fixture del token: está en que **ningún test afirma qué argumento recibe el repositorio**, y en que el contrato no es un tipo que `mypy`/una aserción puedan comparar.

Restricciones vigentes del proyecto:
- Arquitectura de 3 capas obligatoria (routers = validación + DI; nada de lógica de negocio en el router).
- El rol de aplicación **no viaja en el JWT hoy** (`custom_access_token_hook` deshabilitado en prod, H-07): `app_role` siempre cae al fallback `"user"` y `app_plan` al default `"pro"`. Este change **no** cambia eso.
- `backend/core/deps.py::get_account_id` ya es la fuente canónica del tenant y ya se usa en `list_quotes`, `create_quote` y varios endpoints de los mismos routers.

## Goals / Non-Goals

**Goals:**
- Un contrato **declarado y verificable** para el contexto de autenticación, de modo que una divergencia entre lo que produce `get_current_user` y lo que los consumidores esperan falle en CI, no en producción.
- Los 3 endpoints de H-06 dejan de emitir `""` donde va un UUID.
- Tests que observen el valor propagado al repositorio, para que un futuro `""` sea imposible de ocultar.
- Dejar el terreno listo para que los tests de RBAC de los changes siguientes no nazcan ciegos.

**Non-Goals:**
- **No** se habilita el `custom_access_token_hook` ni se toca cómo se resuelve `role`/`plan` — eso es `v31-authz-token-hook` (CRÍTICO, con sign-off propio).
- **No** se toca `require_role`/`require_plan` en su semántica (siguen siendo efectivamente no-op mientras el rol no viaje en el JWT). Solo cambian sus anotaciones de tipo.
- **No** se toca el pool ni el JWT-passthrough (`v31-tenancy-pool-rls`).
- **No** se introduce el pivot de roles ni la matriz rol×transición (`v3-rbac-multirole`).
- **No** se agrega `mypy` al pipeline de CI: el tipo se usa como documentación ejecutable y como base de la aserción de contrato, no como gate estático nuevo.

## Decisions

### D1 — `TypedDict` (total) en vez de `dataclass`/`Pydantic model`

`AuthContext` se declara como `typing.TypedDict` total:

```python
class AuthContext(TypedDict):
    user_id: str
    role: str
    plan: str
```

**Por qué `TypedDict` y no otra cosa:** es el único de los tres que **no cambia el objeto en runtime**. `get_current_user` sigue devolviendo un `dict` literal; los ~13 consumidores actuales (`auth["user_id"]`, `auth.get("role")`) siguen funcionando sin tocarlos. Un `dataclass` o un `BaseModel` obligaría a migrar todos los accesos a atributo en el mismo PR, convirtiendo un fix de 3 líneas en un refactor transversal del backend — exactamente el tipo de "big bang" que este cluster está tratando de evitar.

**Alternativas descartadas:**
- *Pydantic `BaseModel`*: valida en runtime, pero el payload ya viene validado por la verificación de firma; agregaría costo por request en el camino más caliente del backend a cambio de nada, y rompería los ~13 accesos por índice.
- *Dejar `dict` y solo arreglar las 3 líneas*: arregla el síntoma y deja la causa. El próximo consumidor vuelve a adivinar. El objetivo declarado del change es que los tests de los siguientes 3 changes no hereden la ceguera.

`total=True` (el default) es deliberado: las tres claves están **siempre** presentes — `user_id` viene de `payload["sub"]` (obligatorio en cualquier JWT de Supabase), y `role`/`plan` tienen fallback incondicional. No hay clave opcional que justifique `NotRequired`.

### D2 — El test de contrato compara claves producidas contra claves declaradas

El test anti-deriva no verifica "el fixture es correcto"; verifica que **`AuthContext` y la salida real de `get_current_user` no puedan divergir**:

```
claves(get_current_user(token_válido)) == AuthContext.__annotations__.keys()
```

Es una sola aserción y cubre las cuatro derivas posibles: agregar una clave al retorno sin declararla, declararla sin producirla, renombrarla en un lado, y quitarla de uno solo. Cuando `v31-authz-token-hook` agregue o cambie claims, este test es el que obliga a actualizar el tipo en el mismo PR.

**Por qué no basta con `mypy`:** `mypy` sobre un `TypedDict` no detecta que el *diccionario literal construido en runtime* diverja si alguien lo arma dinámicamente, y hoy no hay gate de `mypy` en CI. La aserción es más barata y corre en la suite que ya existe.

**Por qué esto NO es una aserción trivial:** no afirma un tipo ni una tautología — ejecuta `get_current_user` de punta a punta (decodifica un JWT real de test) y compara el resultado observado contra la declaración. Falla hoy mismo si se le agrega una clave al retorno.

### D3 — El tenant sale de `get_account_id`, no del contexto de auth

En `customer_accounts.py` y `supplier_accounts.py` la corrección **no** es cambiar `auth.get("sub","")` por `auth["user_id"]`: eso propagaría el id de *usuario* como id de *cuenta*, un bug peor (silencioso en vez de ruidoso). El `account_id` se inyecta con `Depends(get_account_id)`, el mismo resolver que ya usan `list_customer_movements`, `list_quotes` y compañía. El endpoint pasa de resolver tenancy a mano a declararla como dependencia — que además es lo que pide la regla de 3 capas (routers = validación + DI).

Efecto colateral buscado: cuando `v3-rbac-multirole` haga determinística la resolución de cuenta activa (`get_account_id` hoy no tiene `ORDER BY`, M-ARQ-04), estos dos endpoints heredan el fix gratis en vez de quedar con su propia lógica divergente.

### D4 — Delta de spec como `ADDED` sobre `backend-auth`, no `MODIFIED`

`openspec/specs/backend-auth/spec.md` está escrita en el formato legacy `### REQ-BA-NN:` (es una de solo dos specs del repo que quedaron así) y **no tiene ningún header `### Requirement:`**. Un bloque `## MODIFIED Requirements` no tendría a qué hacer match al archivar, y perdería contenido en silencio — el "common pitfall" que advierte el propio instructivo de OpenSpec.

Por eso el delta usa `## ADDED Requirements` con requisitos nuevos en formato canónico. `REQ-BA-02` (que documenta `{"user_id", "role"}`, sin `plan`, y afirma que `role` cae a `"authenticated"` cuando en el código cae a `"user"`) queda **superado** por el requisito nuevo; normalizar el resto del archivo legacy es trabajo de `v31-docs-refresh` (H-22) y se anota como tal, no se hace acá para no mezclar un refactor documental con un fix de producción.

### D5 — Alcance de la adopción del tipo: firmas, no reescritura

Se anota `AuthContext` en: el retorno de `get_current_user`, los parámetros de `backend/core/guards.py` (`require_role`, `require_plan`, `require_platform_admin`) y los de los tres routers/services tocados. **No** se hace un barrido de los ~20 archivos de services que declaran `auth: dict` — cambiar esas firmas no arregla ningún bug, ensucia el diff del fix y compite por atención en la revisión. Los que queden en `dict` siguen siendo compatibles (un `TypedDict` *es* un `dict`). La adopción restante es oportunista, cuando cada archivo se toque por otro motivo.

### D6 — La auditoría del shape se cierra con evidencia, no con confianza

El barrido `auth.get(` / `auth[` sobre `backend/` (excluyendo `.venv`) ya está hecho y da exactamente 3 lectores rotos y 10 correctos; los 3 rotos son los de H-06. La tarea de auditoría del change re-ejecuta ese barrido **después** del fix y exige 0 lectores de claves fuera de `AuthContext`, dejando la evidencia en el PR. Es lo que convierte "creemos que eran 3" en "verificamos que quedan 0".

## Risks / Trade-offs

- **[El fix de `account_id` cambia el comportamiento observable de 2 endpoints que hoy fallan]** → Hoy devuelven 500 (o, si `""` fuese aceptado, 404 por cuenta inexistente): no hay cliente que dependa del comportamiento actual porque no hay comportamiento actual. Aun así, los tests nuevos fijan el contrato esperado (el `account_id` del resolver llega al repositorio) antes de tocar el código, y el frontend de cuentas corrientes se verifica manualmente en el apply.

- **[`TypedDict` no valida en runtime]** → Es la trade-off aceptada a cambio de no romper los 13 accesos existentes (D1). La red de seguridad es el test de contrato de D2, que sí corre en runtime y sí falla ante una divergencia real.

- **[Alguien podría escribir un test futuro que mockee `get_current_user` con un dict a mano y vuelva a divergir]** → El test de D2 no lo impide (mockear el dependency es legítimo), pero el `TypedDict` da el objeto de referencia contra el cual construir esos dobles, y el requisito de spec lo declara explícitamente: los dobles de test derivan del contrato declarado. Es una mitigación por convención + tipo, no un candado — se acepta.

- **[Scope creep hacia `v31-authz-token-hook`]** → Al tocar `auth.py` es tentador "aprovechar" y arreglar también el fallback de rol o el `search_path` del hook. Está explícitamente fuera (Non-Goals): ese archivo es dominio CRÍTICO y su cambio necesita sign-off del PO. Este change solo agrega una declaración de tipo sobre el retorno existente, sin alterar cómo se computa ningún valor.

## Migration Plan

No hay migración de datos ni de esquema — no se toca SQL.

Despliegue: al mergear a main, GitHub Actions despliega el backend en Render (el frontend en Vercel no cambia). No hay `db push` porque no hay migraciones nuevas.

**Rollback**: `git revert` del PR. No hay estado persistente que limpiar ni migración que revertir — el rollback devuelve exactamente el estado actual (los 3 endpoints vuelven a 500).

**Verificación post-merge**: ejercitar los 3 endpoints contra el backend desplegado con un usuario real y confirmar 2xx en vez de 500.

## Open Questions

Ninguna que requiera decisión del PO. La secuencia del cluster, la exclusión de la matriz rol×transición y la ubicación del gancho maker-checker ya están firmadas (sign-off 2026-07-30) y este change las respeta.
