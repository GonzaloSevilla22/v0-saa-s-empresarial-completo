# Exploración: v3-rbac-multirole y su cluster de prerequisitos de autorización

> **Tipo:** Exploración (modo thinking — sin implementación). Governance **CRÍTICO** (auth/RLS): esta sesión es solo análisis, no se escribió código ni se aplicó ninguna migración.
> **Fecha:** 2026-07-30
> **Proyecto:** ALIADATA / EmprendeSmart (EIE) — Supabase prod `gxdhpxvdjjkmxhdkkwyb` (verificado read-only vía MCP)
> **Contexto:** Modelo V3 §5 (RBAC multi-rol), siguiente change del roadmap tras `v3-api-standards` ✅. Bloqueado por 3 hallazgos de la auditoría 2026-07-07 (H-05/H-06/H-07 en la numeración consolidada de `CHANGES.md`).
> **Scope:** Verificar el estado real de los 3 bloqueantes contra prod, mapear el cluster de 5 changes (4 satélites + el pivot), comparar Opción A vs B de `v31-tenancy-pool-rls`, bosquejar el diseño del pivot y la matriz rol×transición, y listar las decisiones que necesita el PO.

---

## 0. Nota sobre numeración de hallazgos (fuente de confusión real)

La numeración `H-01..H-34` de `CHANGES.md` es una **renumeración consolidada** hecha después de fusionar los hallazgos crudos de los 10 archivos `audit/*.md` (103 hallazgos → 34 consolidados). La numeración local *dentro* de cada archivo de auditoría **no coincide** con la global. Mapeo verificado para este cluster:

| Global (`CHANGES.md`) | Local (`audit/*.md`) | Archivo | Título |
|---|---|---|---|
| **H-05** (tenancy-pool-rls) | H1 | `audit/arquitectura.md` | JWT-passthrough roto: `postgres` BYPASSRLS + GUC de sesión sobre pooler transaction-mode |
| **H-06** (fix-auth-shape-500) | H3 | `audit/codigo-backend.md` | 3 endpoints en 500 por shape inválido del dict `auth` |
| **H-07** (authz-token-hook) | H-05 (¡mismo número, archivo distinto!) | `audit/seguridad.md` | Hook `custom_access_token_hook` no habilitado |

El brief de esta tarea pedía leer "H-05/H-06/H-07 en `audit/seguridad.md`" — ese archivo solo contiene el H-07 global (bajo su propio H-05 local); los otros dos viven en `arquitectura.md` y `codigo-backend.md`. Los tres están leídos y verificados abajo. Vale la pena que `v31-docs-refresh` (H-22) unifique la numeración en algún punto — hoy solo `CHANGES.md` tiene la tabla de mapeo completa.

---

## 1. Estado actual verificado (evidencia empírica, 2026-07-30)

### H-05 (global) — Pool BYPASSRLS — **CONFIRMADO, sin cambios desde la auditoría**

```sql
SELECT rolname, rolbypassrls, rolsuper FROM pg_roles
WHERE rolname IN ('postgres','authenticator','authenticated','service_role','anon');
```

| rolname | rolbypassrls | rolsuper |
|---|---|---|
| postgres | **true** | false |
| service_role | true | false |
| authenticator | false | false |
| authenticated | false | false |
| anon | false | false |

El backend conecta con `postgres` (`backend/core/database.py:19-24`, `DATABASE_URL` sin rol dedicado) → **RLS 100% inerte para el backend**, confirmado igual que en la auditoría. Además verifiqué el mecanismo exacto del bug: `get_db_conn` (`backend/core/database.py:42-61`) hace `set_config('app.jwt_claims', $1, false)` con **`is_local=false`** (scope de **sesión**, no de transacción) y **nunca abre una transacción explícita** (`BEGIN`) antes de ejecutarlo. Bajo Supavisor en *transaction mode*, cada statement fuera de un bloque `BEGIN...COMMIT` puede aterrizar en una conexión física de servidor distinta — el `set_config` de sesión puede quedar en la conexión A mientras la query de negocio corre en la B, donde `auth.uid()`/claims son NULL o (peor) pertenecen a otro request reciclado. Esto es consistente con el bug abierto K5 (compras 500 intermitente) y confirma que el fix no es solo "quitar BYPASSRLS", sino también **envolver el request en una transacción explícita con `SET LOCAL`** — dos problemas acoplados, no uno.

### H-06 (global) — Shape falso del fixture de auth — **CONFIRMADO, código sin tocar**

Shape real (`backend/core/auth.py:63-67`, `get_current_user`):
```python
return {"user_id": payload["sub"], "role": app_role, "plan": app_plan}
```

Shape del fixture de test (`backend/tests/conftest.py:16-17`):
```python
{"sub": TEST_USER_ID, "role": "authenticated", ...}
```

`sub` en vez de `user_id`, y `role="authenticated"` (el rol de Postgres, no el rol de app). Cualquier código que lea `auth["user_id"]` con este fixture recibe `KeyError`/`None`, pero como los routers rotos (`quotes.py:60`, `customer_accounts.py:61`, `supplier_accounts.py:61`) usan `.get("sub","")` en vez de `auth["user_id"]`, el fixture les da un `""` con el que sí "pasan" — el test verifica el código roto contra un doble roto, ambos se cancelan y el 500 real en prod queda invisible. Sigue así hoy.

### H-07 (global) — Hook de rol deshabilitado en prod — **CONFIRMADO, con un matiz importante sobre `config.toml`**

```sql
SELECT count(*) total_users, count(*) FILTER (WHERE raw_app_meta_data ? 'role') with_role_claim
FROM auth.users;
-- {"total_users": 34, "with_role_claim": 0}

SELECT proname, prosecdef FROM pg_proc WHERE proname ILIKE '%custom_access%';
-- {"proname": "custom_access_token_hook", "prosecdef": false}
```

El hook existe en DB (función real, no un stub), pero **0 de 34 usuarios** tienen `app_metadata.role`. **34, no 29** — la cuenta de usuarios creció desde la auditoría del 07-07 (crecimiento orgánico de ~3 semanas); el hallazgo no cambia en sustancia, pero el "blast radius" de activar el hook hoy es 5 usuarios más grande que lo documentado.

**Matiz sobre `supabase/config.toml:270-272`:**
```toml
[auth.hook.custom_access_token]
enabled = true
uri = "pg-functions://postgres/public/custom_access_token_hook"
```
El archivo local dice `enabled = true`, **no `false`** como decía el brief de esta tarea. Pero esto **no contradice** el hallazgo: el comentario en el propio archivo (líneas 267-269) aclara que `config.toml` solo controla el entorno **local** (`supabase start`); en **producción**, el toggle vive en el Dashboard de Supabase Auth (Authentication → Hooks → Customize Access Token), gestionado completamente aparte del repo. La query empírica (`with_role_claim=0` sobre 34 usuarios reales) es la prueba que importa, y confirma que el toggle de prod está apagado — el `enabled=true` de `config.toml` es dev-only y no se puede usar como evidencia de nada en prod. Vale la pena que el que ejecute `v31-authz-token-hook` no confunda "ya está en `enabled=true` en el repo" con "ya está activo en prod": son dos superficies de configuración completamente distintas y desincronizadas hoy.

### Estado del pivot de roles — más simple de lo que documenta la ficha

```sql
SELECT role, count(*) FROM account_members GROUP BY role;
-- {"role": "owner", "count": 34}

SELECT pg_get_constraintdef(oid) FROM pg_constraint
WHERE conrelid = 'account_members'::regclass AND contype = 'c';
-- CHECK (role = ANY (ARRAY['owner','admin','member']))
```

El CHECK confirma exactamente lo que dice `CHANGES.md` (`20260606010000_roles_internos.sql`). Pero el dato nuevo es que **el 100% de las 34 cuentas tiene rol `owner`** — cero `admin`, cero `member`, pese a que la migración C-06 habilitó esos valores hace meses. Esto **reduce el riesgo de la migración de compatibilidad** del pivot (no hay que preservar semántica de `admin`/`member` real en prod, porque no existen instancias) — pero **no reduce el riesgo de habilitar el hook** (H-07), que sigue siendo el problema real: sin importar qué tan simple sea el dato hoy, el rol no llega al JWT.

### Matriz FSM existente (`document_status_transitions`) — verificada, 18 filas, todas `allowed_role = NULL`

Confirmado el estado "inerte pero listo" que documenta `v3-document-status-history`. Las 18 transiciones reales (6 `document_type`) son la base concreta sobre la que diseñar RN-A4 — ver §5.

### Verificación adicional no pedida explícitamente pero relevante

`cost_centers` sigue con **0 filas** en prod (verificado ahora, igual que en la auditoría del 07-07) — el criterio de aceptación (a) del scope de `v3-rbac-multirole` ("`cost_centers` deja de dar 403 universal") sigue siendo un problema real y activo, no histórico.

### Veredicto sobre la ficha de `CHANGES.md`

**La ficha tenía razón en todo lo sustantivo.** Los tres bloqueantes duros (H-05/H-06/H-07 global) están confirmados sin remediar. El único ajuste es el matiz de `config.toml` (dev vs prod) y el conteo de usuarios (29→34). Nada invalida el bloqueo — si acaso, lo refuerza: más usuarios reales = más blast radius al tocar auth.

---

## 2. El cluster: mapa de los 5 changes

```
                              ┌─────────────────────────────┐
                              │  v31-fix-auth-shape-500 (H-06)│
                              │  Governance: MEDIO            │
                              │  Esfuerzo: S                  │
                              │  Implementable YA (sin sign-off)│
                              └───────────────┬───────────────┘
                                              │ arregla el fixture ANTES de
                                              │ escribir tests de la matriz rol×transición
                                              ▼
┌────────────────────────────┐   ┌─────────────────────────────┐   ┌──────────────────────────────┐
│ v31-authz-token-hook (H-07) │   │ v31-tenancy-pool-rls (H-05)  │   │ v31-fsm-status-triggers (H-17)│
│ Governance: CRÍTICO (auth)  │   │ Governance: CRÍTICO (aislam.)│   │ Governance: MEDIO             │
│ Esfuerzo: M                 │   │ Esfuerzo: L                  │   │ Esfuerzo: S                   │
│ Habilitar hook en Dashboard │   │ Decisión Opción A vs B       │   │ Trigger BEFORE UPDATE que     │
│ + verificar claim en JWT    │   │ (sign-off PO obligatorio)    │   │ enforce RN-A4 en DB            │
│ de ≥1 usuario de prueba     │   │                              │   │                                │
└──────────────┬───────────────┘   └───────────────┬──────────────┘   └───────────────┬────────────────┘
               │                                    │                                  │
               │  "el rol tiene que llegar al JWT"  │ "is_account_writer/current_      │ "sin esto RN-A4 es
               │  antes de que migrar el pivot       │  account_ids tienen que volver   │  evadible por UPDATE
               │  cambie algo en prod                │  a ser reales (Opción A) o el    │  directo vía PostgREST"
               │                                     │  filtro manual tiene que ser      │
               │                                     │  auditado repo por repo (Opción B)│
               └────────────────────┬────────────────┴──────────────────┬───────────────┘
                                    │                                   │
                                    ▼                                   ▼
                     ┌───────────────────────────────────────────────────────────────┐
                     │                  v3-rbac-multirole (V3 §5)                      │
                     │  Governance: CRÍTICO — el sign-off del PO cubre EN LA PRÁCTICA   │
                     │  3 changes: este + authz-token-hook + la decisión de tenancy-pool │
                     │  Esfuerzo: L (pivot + migrar 66 call sites de require_role +     │
                     │  matriz rol×transición + UI)                                     │
                     └───────────────────────────────────────────────────────────────┘
```

### Qué hace cada uno, tamaño real (verificado, no solo estimado)

| Change | Qué hace | Gate real | Esfuerzo verificado |
|---|---|---|---|
| **`v31-fix-auth-shape-500`** | Corrige 3 endpoints en 500 (`quotes.py:60`, `customer_accounts.py:61`, `supplier_accounts.py:61`) que leen `auth.get("sub","")` en vez de `auth["user_id"]`; arregla el fixture `conftest.py:16-17` al shape real `{user_id, role, plan}`. | Ninguno — implementable directo, gobernanza MEDIO. | S (3 líneas de código + 1 fixture + smoke E2E). Sin este fix, cualquier test nuevo de RBAC hereda la ceguera. |
| **`v31-authz-token-hook`** | Habilita el hook en el **Dashboard de Supabase Auth de prod** (no en `config.toml`, que ya dice `enabled=true` mas no aplica); fuerza re-login (o espera a expiración de sesión) para que los 34 usuarios reciban `app_metadata.role`; verifica con ≥1 usuario de prueba que el claim viaja. Corrige `search_path` mutable del hook (H-06 local de `seguridad.md`, `function_search_path_mutable`) de paso — es la función auth-crítica más sensible de las 8 con el advisor abierto. | **Prerequisito real** — sin esto, migrar el pivot y reescribir `require_role` no cambia nada observable en prod. | M — el toggle es trivial, pero verificar 34 usuarios + invalidación de sesión + `search_path` fix + tests de regresión de los guards actuales (`require_role` deja de ser no-op) es trabajo real. |
| **`v31-tenancy-pool-rls`** | Decisión de plataforma + implementación: Opción A (rol de app sin BYPASSRLS + `SET LOCAL` transaccional + policies) u Opción B (barrido manual de `account_id` en 24 repositories). Ver §3. | **Decisión con sign-off PO** antes de tocar `is_account_writer`/`current_account_ids`. | L — el mayor de los 4 satélites, independientemente de la opción elegida (ver detalle en §3). |
| **`v31-fsm-status-triggers`** | Trigger `BEFORE UPDATE` en `quotes`, `sales_orders`, `fiscal_documents` que valida la transición contra `document_status_transitions` a nivel DB — hoy la única barrera es que los RPCs "bien portados" llamen a `record_status_transition`, pero un `UPDATE` directo vía PostgREST (posible hoy porque las policies de escritura existen para esas tablas) se salta la FSM completa. | Ninguno propio — implementable directo, gobernanza MEDIO. Pero **secuenciar antes** de activar `allowed_role` en RN-A4, o la matriz rol×transición queda "de papel". | S — la lógica de validación ya existe (`is_valid_transition()`), el trigger es una envoltura fina. |
| **`v3-rbac-multirole`** | El pivot en sí: `account_member_roles`, catálogo cerrado de 8 roles, `expires_at`, migrar 66 call sites de `require_role` (`backend/services/*.py`, verificado por grep) a leer el pivot, poblar `allowed_role` en las 18 filas de `document_status_transitions`, UI `/organizacion/roles`. | Bloqueado por los 3 anteriores (ver dependencias duras). | L — 66 call sites + pivot + UI + matriz rol×transición + migración de compatibilidad (trivial dado que 34/34 cuentas son `owner`). |

### Orden recomendado (no es solo el orden "natural" del roadmap — está ajustado a costo/riesgo real)

1. **`v31-fix-auth-shape-500`** (S, sin gate) — se puede hacer HOY, desbloquea que los tests de los siguientes 3 no mientan.
2. **`v31-fsm-status-triggers`** (S, sin gate) — independiente de auth, cierra un hueco real (RN-A4 evadible) que no vale la pena dejar abierto mientras se resuelve lo demás.
3. **`v31-authz-token-hook`** (M, CRÍTICO — sign-off) — en paralelo con el análisis/diseño de #4; es el que menos ambigüedad de diseño tiene (activar un toggle + verificar), así que puede cerrar primero.
4. **`v31-tenancy-pool-rls`** (L, CRÍTICO — sign-off, la decisión más cara) — el cuello de botella real del cluster; ver §3 para el análisis completo.
5. **`v3-rbac-multirole`** (L) — solo después de que 1-4 estén cerrados (o al menos #3 y #4 con sign-off explícito), porque su forma exacta depende de la decisión de #4 (ver "Migrar `require_role`..." en el scope de la ficha).

---

## 3. Opción A vs Opción B (`v31-tenancy-pool-rls`)

### Los números concretos de este codebase

- **24 archivos de repository** reales (`backend/repositories/*_repository.py`, excluyendo 7 archivos de test que matchean el mismo glob).
- **49 archivos de migración** referencian `is_account_writer`/`current_account_ids` — las policies RLS **ya existen y están correctamente escritas** (auditoría: 0 tablas con `relrowsecurity=false`), porque las usa el camino híbrido browser→Supabase-directo (PostgREST) que sí respeta RLS hoy. Esto es clave: **Opción A no requiere escribir políticas nuevas**, solo hacer que el backend deje de ignorarlas.
- **66 call sites** de `require_role(auth, [...])` en `backend/services/*.py` — relevante para el scope de `v3-rbac-multirole`, no de este change, pero dimensiona cuánto testeo de regresión hace falta el día que el rol deje de ser no-op.
- El código real de `get_db_conn` (`backend/core/database.py:42-61`) confirma el mecanismo exacto del bug — ver §1.

### Opción A — Rol de app sin `BYPASSRLS` + policies + `SET LOCAL` transaccional

**Qué implica en este codebase concretamente:**
1. Crear un rol Postgres nuevo (ej. `app_backend`) sin `BYPASSRLS`, dueño de nada, con los mismos GRANTs que hoy tiene implícitamente `postgres` sobre las tablas de negocio.
2. Cambiar `DATABASE_URL` para conectar como ese rol (vía `authenticator` + `SET ROLE`, o credenciales directas si Supabase lo permite).
3. **El cambio real y no trivial**: reestructurar `get_db_conn` para que **cada request abra una transacción explícita** (`BEGIN`) antes de hacer `SET LOCAL role = ...` + `SET LOCAL request.jwt.claims = ...` (con `is_local=true`, no el `set_config(...,false)` actual), ejecute las queries de negocio, y haga `COMMIT`/`ROLLBACK` al final. Esto es un cambio de patrón en **todos** los endpoints que usan `Depends(get_db_conn)` — no es un toggle de config, es tocar el ciclo de vida de la conexión en el punto más caliente del backend.
4. **La memoria del proyecto dice "SET ROLE no funciona con pgBouncer transaction mode" (nota de C-17)** — esto es cierto para `SET ROLE` plano (session-scoped, sobrevive al fin de la transacción y puede filtrarse al siguiente cliente que reutilice la conexión física). **No es cierto para `SET LOCAL ROLE`** (transaction-scoped, se deshace automáticamente en `COMMIT`/`ROLLBACK`, es exactamente el patrón que usa PostgREST internamente contra Supavisor en transaction mode). El error del pasado probablemente vino de usar la variante sin `LOCAL`. Esto hay que verificarlo con una prueba de carga concurrente real antes de confiar en la recomendación (ver Riesgos, §7) — pero el patrón en sí es el correcto y documentado por Supabase para poolers en transaction mode.
5. Alternativa dentro de la misma Opción A: migrar `DATABASE_URL` al **session pooler** (puerto 5432 en vez de 6543), donde una conexión de servidor queda pineada al cliente durante toda su vida y `SET ROLE` (sin LOCAL) sí es seguro — pero esto reduce el techo de conexiones concurrentes (session pooler tiene un límite de conexiones físicas mucho más bajo que transaction mode), lo cual es una preocupación real dado el objetivo comercial de crecer en junio 2026.

**Costo**: no es "escribir policies" (ya existen) — es **reestructurar el ciclo de vida de conexión/transacción en el backend completo** + probar bajo concurrencia real. Esfuerzo L, con riesgo de regresión alto si no se prueba a fondo (un bug aquí puede causar fail-open cross-tenant, el peor escenario posible).

**Beneficio**: RLS vuelve a ser una **defensa real en profundidad**. Si mañana un repository tiene un bug y olvida el filtro `account_id`, la policy lo frena igual. Esto es exactamente lo que DEC-13/KB-08 ya afirman que existe — Opción A los hace ciertos en vez de aspiracionales.

### Opción B — Barrido manual de `account_id` en los 24 repositories

**Qué implica:**
1. Auditar los 24 archivos `*_repository.py` uno por uno: todo método que haga un acceso "by-id" (`WHERE id = $1`, sin `account_id` en el filtro) es candidato a IDOR cross-tenant si el ID se puede adivinar/enumerar. La auditoría (`arquitectura.md` H1) ya identificó gaps concretos: quotes, sales-orders, settings de org, cajas, cuentas corrientes.
2. Agregar `AND account_id = $N` (o el equivalente `current_account_ids()`) a cada query afectada, con tests de aislamiento por repository (dos cuentas, un ID conocido de la otra, verificar 404/403).
3. `BaseRepository` (ya tiene `soft_delete()` y paginación desde changes anteriores) podría ganar un helper que fuerce el filtro por convención — mitiga (no elimina) el riesgo de que un repository nuevo lo olvide.

**Costo**: 24 repositories × auditoría + fix + test de aislamiento. Repetitivo pero de bajo riesgo por archivo — cada fix es aislado, no hay un "big bang" de cambiar el ciclo de vida de conexión. Esfuerzo estimado M-L (menos incierto que A, pero no trivial: 24 archivos con revisión cuidadosa cada uno, más los tests de aislamiento nuevos).

**Beneficio**: no toca la infraestructura de conexión/pooling (menor riesgo de romper todo el backend de una vez). Es incremental — se puede hacer repository por repository, con PRs chicos y reversibles.

**El problema estructural de Opción B**: no es "defensa en profundidad", es **la única defensa**. Un repository nuevo (o uno de los 24 con un bug no detectado) vuelve a abrir el mismo agujero que la auditoría encontró. No hay red de seguridad si la aplicación falla — que es exactamente lo que DEC-13/KB-08 prometen que Postgres provee y hoy no provee.

### Comparación directa

| | Opción A (rol + policies + SET LOCAL) | Opción B (barrido manual) |
|---|---|---|
| Requiere escribir policies nuevas | No (49 archivos ya las tienen) | N/A |
| Requiere tocar el ciclo de vida de conexión | Sí — todos los endpoints | No |
| Riesgo de regresión "big bang" | Alto (un bug afecta TODO el backend) | Bajo (cada repo es independiente) |
| Riesgo residual si hay un bug futuro | Bajo (RLS frena igual) | **Alto** (sin red — IDOR directo) |
| Esfuerzo | L, con incertidumbre técnica (pgBouncer) | M-L, mecánico pero extenso (24 archivos) |
| Compatible con crecer conexiones (junio 2026) | Sí si se queda en transaction mode + SET LOCAL; No si se cae a session pooler | Sí (no toca pooling) |
| Alinea con lo que DEC-13/KB-08 ya documentan | Sí — los hace ciertos | No — hay que reescribir la decisión documentada |

### Mi recomendación

**Opción A, con `SET LOCAL` transaccional (no session pooler)** — pero como una migración en dos pasos, no un big bang:

1. **Paso 1 (bajo riesgo, hazlo ya, sin esperar sign-off)**: cambiar `get_db_conn` para envolver el request en una transacción explícita con `SET LOCAL` (`is_local=true`) en vez del `set_config(...,false)` actual — **sin cambiar de rol todavía**. Esto arregla el bug de fondo del K5 (compras 500 intermitente) independientemente de BYPASSRLS, porque el problema de "el claim aterriza en la conexión física equivocada" existe con o sin BYPASSRLS.
2. **Paso 2 (el que necesita sign-off)**: una vez que el patrón `SET LOCAL` esté probado en prod bajo carga real (unos días de observación), crear el rol sin BYPASSRLS y cortar. En este punto el cambio es "solo" cambiar el rol de conexión — el ciclo de vida transaccional ya está probado.

Opción B es la alternativa razonable si el equipo decide que el riesgo de tocar el ciclo de vida de conexión en producción (con usuarios reales y dinero real) es inaceptable en este momento — es más lenta pero cada paso es reversible de forma aislada. Si el PO prioriza velocidad de mitigación sobre elegancia arquitectónica, B es defendible. Pero mi recomendación de fondo es A-en-dos-pasos porque **B dejaría a Aliadata exactamente en el estado que DEC-13/KB-08 dicen que NO está** — documentación mintiendo sobre la arquitectura, otra vez, solo que esta vez a propósito.

---

## 4. Diseño propuesto del pivot `account_member_roles` (bosquejado, NO aplicado)

```sql
-- BOSQUEJO — NO EJECUTAR. Solo para discusión de diseño.

CREATE TABLE public.account_member_roles (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id    uuid NOT NULL REFERENCES public.account_members(id) ON DELETE CASCADE,
  role         text NOT NULL CHECK (role IN (
                 'OWNER','ADMIN','SELLER','CASHIER','STOCK',
                 'PURCHASES','ACCOUNTANT','VIEWER'
               )),
  assigned_by  uuid REFERENCES auth.users(id),
  assigned_at  timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz,              -- NULL = permanente
  -- M-SEC-13 (maker-checker): gancho de datos, sin lógica todavía
  requires_second_approval boolean NOT NULL DEFAULT false,
  UNIQUE (member_id, role)               -- un miembro no puede tener el mismo rol dos veces
);

CREATE INDEX idx_account_member_roles_member ON account_member_roles(member_id);
CREATE INDEX idx_account_member_roles_active
  ON account_member_roles(member_id, role)
  WHERE expires_at IS NULL OR expires_at > now();  -- NO es IMMUTABLE, ver nota abajo

-- NOTA DE DISEÑO: el índice parcial con `now()` no es válido en Postgres (predicado no
-- inmutable). La resolución de "roles activos" tiene que ser una función/vista, no un
-- índice parcial. P.ej.:
CREATE OR REPLACE FUNCTION public.member_active_roles(p_member_id uuid)
RETURNS text[] LANGUAGE sql STABLE AS $$
  SELECT array_agg(role) FROM account_member_roles
  WHERE member_id = p_member_id AND (expires_at IS NULL OR expires_at > now());
$$;
```

**Compat con roles legacy**: migración de datos trivial dado el hallazgo de §1 — las 34 filas de `account_members` son 100% `role='owner'`. El backfill es:
```sql
INSERT INTO account_member_roles (member_id, role, assigned_at)
SELECT id, 'OWNER', created_at FROM account_members;  -- 34 filas, sin ambigüedad
```
No hace falta decidir qué hacer con `admin`/`member` reales porque no existen instancias en prod — la ficha de `CHANGES.md` documenta esto como riesgo abierto, pero empíricamente el riesgo es cero hoy. (Ojo: esto puede cambiar entre ahora y cuando se ejecute el change, si alguien invita un `member` en el ínterin — re-verificar el conteo justo antes de aplicar.)

**`account_members.role` legacy**: no se dropea en el mismo change (patrón ya usado en `v3-soft-delete-policy` con `is_active`/`deleted_at` — coexistencia, no reemplazo inmediato). Se puede sincronizar por trigger (`account_members.role` refleja el rol "primario" del pivot) o dejarlo congelado como snapshot histórico hasta un change de limpieza posterior — decisión de diseño, no crítica.

**Estrategia de cache/invalidación (M-ARQ-04)**: la ficha señala que `deps.py:get_account_id` no tiene `ORDER BY` — verificado, es literalmente:
```python
"SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1"
```
sin `ORDER BY`, no determinístico con multi-membresía (hoy 0 usuarios tienen 2+ cuentas, así que el bug es latente pero real). Dos decisiones ligadas:
- **Si no se cachea** (recomendado para el primer corte): cada request re-lee el pivot por request — el vencimiento de `expires_at` se resuelve con latencia máxima de 1 request, sin lógica de invalidación que mantener. Redis ya está provisionado (`backend/core/redis_client.py`) pero con **0 usos reales** hoy — no hay que inventar infraestructura de invalidación de cache el mismo change que introduce el pivot.
- **Si se cachea** (para cuando el volumen lo justifique): invalidar en `rpc_change_member_role`/nuevo RPC de asignación de rol, más un TTL corto como red de seguridad para el caso `expires_at` (un rol que vence a mitad de una sesión cacheada).

**Gancho `requires_second_approval`** (M-SEC-13): incluido en el DDL bosquejado arriba con default `false` y sin lógica de enforcement — exactamente lo que pide el roadmap ("dejarlo en el mismo DDL si el costo marginal es bajo, evita una segunda migración destructiva"). Costo marginal aquí es una columna boolean — bajo.

---

## 5. Matriz rol × transición FSM (RN-A4) — bosquejada sobre las 18 transiciones reales

Verificado en prod: 6 `document_type`, 18 filas, todas `allowed_role = NULL` hoy. Bosquejo de asignación (a validar con el PO, especialmente para `quote`/`sales_order` donde el caso de uso real de un SELLER importa):

| document_type | from → to | Rol(es) propuestos | Razonamiento |
|---|---|---|---|
| `quote` | `NULL → draft` | SELLER, ADMIN, OWNER | crear presupuesto es tarea de venta |
| `quote` | `draft → sent` | SELLER, ADMIN, OWNER | enviar al cliente |
| `quote` | `draft/sent → accepted` | SELLER, ADMIN, OWNER | cierre de venta |
| `quote` | `draft/sent → expired` | sistema (cron) — sin actor humano, `allowed_role NULL` se mantiene | expiración automática, no una acción de usuario |
| `quote` | `draft/sent → rejected` | SELLER, ADMIN, OWNER | registrar rechazo del cliente |
| `sales_order` | `NULL → draft` | SELLER, CASHIER, ADMIN, OWNER | el POS lo puede iniciar un cajero |
| `sales_order` | `draft → confirmed` | **CASHIER**, SELLER, ADMIN, OWNER | RN-A4 explícita del roadmap: "CASHIER cobra" — este es el punto donde efectivamente confirma/cobra |
| `cash_session` | `NULL → open` | CASHIER, ADMIN, OWNER | abrir caja es tarea de cajero |
| `cash_session` | `open → closed` | CASHIER, ADMIN, OWNER | cerrar/arqueo — mismo rol que abre |
| `reconciliation_session` | `NULL → open` / `open → closed` | ACCOUNTANT, ADMIN, OWNER | conciliación bancaria es tarea contable |
| `fiscal_document` | `NULL → pending_cae` | sistema (relay CAE) | no es una acción de usuario, es el backend emitiendo |
| `fiscal_document` | `pending_cae → authorized/rejected` | sistema (webhook AFIP/relay) | idem — no debería tener `allowed_role` humano |
| `stock_transfer` | `NULL → completed` | **STOCK**, ADMIN, OWNER | RN-A4 explícita: "STOCK ajusta con motivo pero no confirma compras" — transferencias de stock son su dominio |

**Casos que la ficha señala explícitamente y que esta tabla debe respetar**: "`CASHIER` cobra pero no anula" — hoy no hay una transición de `sales_order` hacia un estado de anulación en el catálogo (`sales_order` solo tiene `draft→confirmed`, verificado, es terminal). Cuando exista una transición de anulación (probablemente ligada a `v31-sales-delete-rpc-reversal`, H-10), esa fila deberá **excluir** a `CASHIER` explícitamente. "`STOCK` ajusta con motivo pero no confirma compras" — hoy `purchases` no tiene FSM en `document_status_transitions` en absoluto (no está en el seed de 6 tipos), así que esta regla queda sin dónde aplicarse hasta que compras entre al patrón FSM — anotarlo como gap conocido, no bloqueante para este change.

**Transiciones de sistema (`fiscal_document`, `quote→expired`)**: no deberían llevar rol humano — son operaciones de cron/webhook. Si `record_status_transition` valida `allowed_role` contra el actor, hace falta un actor "sistema" explícito (o eximir esas filas del chequeo) para no romper el relay CAE.

---

## 6. Decisiones que necesita el PO

1. **Opción A vs Opción B para `v31-tenancy-pool-rls`** (§3).
   - Opciones: (A) rol sin BYPASSRLS + `SET LOCAL` transaccional en dos pasos; (B) barrido manual de 24 repositories.
   - **Recomendación: A**, ejecutado en dos pasos (primero `SET LOCAL` sin cambiar de rol, después el corte de rol) — reduce el riesgo del "big bang" sin resignar la defensa en profundidad que B no puede dar.

2. **Gating por plan de roles funcionales** — ¿roles funcionales (SELLER/CASHIER/STOCK/PURCHASES/ACCOUNTANT) solo en planes `avanzado`/`pro`, como ya promete `knowledge-base/03_actores_y_roles.md` ("Roles internos: ❌/❌/Básicos/Avanzados")?
   - Opciones: (a) gating estricto por plan igual que la tabla comercial; (b) todos los roles disponibles en todos los planes, el gating comercial es solo de cantidad de usuarios (ya existe vía `plan_limits.max_users`); (c) gating parcial — catálogo completo disponible pero `expires_at`/roles temporales solo en planes pagos.
   - **Sin recomendación fuerte de mi parte** — es una decisión comercial (M-ARQ-03 la marca como "requisito comercial del plan PRO"), no técnica. Pero cualquiera que sea la respuesta, debe registrarse ANTES de escribir código porque cambia el scope del `require_plan` que hoy es dead code (H-05 local de `arquitectura.md`/H2: "definido y jamás invocado").

3. **Orden de ejecución del cluster** (§2).
   - **Recomendación**: `v31-fix-auth-shape-500` + `v31-fsm-status-triggers` primero (sin gate, esfuerzo S) → `v31-authz-token-hook` en paralelo con el diseño de `v31-tenancy-pool-rls` (ambos CRÍTICO, ambos necesitan sign-off) → `v3-rbac-multirole` al final.

4. **Maker-checker (`requires_second_approval`, M-SEC-13) — ¿en el DDL ahora o en un change posterior?**
   - Opciones: (a) solo la columna boolean ahora (sin lógica), enforcement real en un change posterior dedicado; (b) omitir la columna, agregarla cuando exista el change real (evita "especular" con schema).
   - **Recomendación: (a)** — el roadmap mismo lo pide explícitamente ("evita una segunda migración destructiva sobre la misma tabla") y el costo marginal es una columna con default `false`, no lógica.

5. **Catálogo de roles: ¿OK tal cual (`OWNER/ADMIN/SELLER/CASHIER/STOCK/PURCHASES/ACCOUNTANT/VIEWER`) o ajustes?**
   - El modelo V3 §5 y `M-ARQ-03` ya lo fijan; no encontré evidencia en el código o en pedidos de usuarios reales que sugiera un rol adicional o distinto. Pregunta abierta solo por si el PO tiene señales de campo (ej. un rol "CONTADOR EXTERNO" distinto de `ACCOUNTANT` con expiración obligatoria) que no estén en la documentación.
   - **Recomendación: aprobar tal cual.**

6. **(Implícita, vale la pena que el PO la vea explícita) — ¿Ejecutar el "Paso 1" de la Opción A (fix de `SET LOCAL`, sin cambio de rol) ya, como parte de `v31-tenancy-pool-rls`, o esperar al sign-off completo?**
   - El Paso 1 no cambia el modelo de seguridad (BYPASSRLS sigue activo) pero sí toca el ciclo de vida de conexión en producción — la línea de gobernanza CRÍTICO del proyecto pide sign-off para cualquier cambio en este dominio, aunque sea "solo" un fix de bug (K5).
   - **Recomendación**: tratarlo como parte del mismo sign-off de `v31-tenancy-pool-rls`, no como un fix aparte "de bajo riesgo" — es tentador separarlo porque arregla un bug real (K5) rápido, pero toca el mismo código crítico y merece la misma revisión.

---

## 7. Riesgos

- **Auth con usuarios reales en prod (34 cuentas, no un entorno de test).** Cualquier fix de `v31-authz-token-hook` fuerza (o espera) re-login — comunicar antes de activar, aunque sea una migración transparente para el usuario.
- **`v31-tenancy-pool-rls` Opción A es el riesgo técnico más alto de todo el cluster.** Un error en el manejo de `SET LOCAL`/transacciones bajo el pooler puede causar fail-open cross-tenant (un usuario viendo datos de otra cuenta) — el peor escenario posible para un ERP con dinero real. Mitigación: probar primero el Paso 1 (SET LOCAL sin cambio de rol) bajo carga concurrente real antes de tocar BYPASSRLS.
- **Rollback plan por change**:
  - `v31-fix-auth-shape-500`: trivial — revert del PR, sin estado persistente que limpiar.
  - `v31-fsm-status-triggers`: `DROP TRIGGER` — reversible sin pérdida de datos (el trigger solo valida, no escribe).
  - `v31-authz-token-hook`: deshabilitar el hook en el Dashboard revierte al estado actual (rol siempre `'user'` en el JWT) — pero usuarios que ya cerraron/reabrieron sesión con el claim nuevo lo pierden en su próximo refresh, no hay estado roto, solo pérdida de la mejora.
  - `v31-tenancy-pool-rls`: el más delicado — revertir el rol de conexión a `postgres` (BYPASSRLS) es instantáneo y seguro (vuelve al estado actual, no peor); revertir el patrón `SET LOCAL`/transaccional del Paso 1 es un `git revert` de código, sin migración de datos de por medio.
  - `v3-rbac-multirole`: el pivot es aditivo (`account_members.role` no se dropea) — rollback es dejar de leer el pivot en `require_role` y volver a leer `account_members.role`, sin perder datos (las filas del pivot quedan huérfanas pero inertes).
- **Efecto dominó si se salta el orden**: activar `v31-authz-token-hook` sin haber resuelto `v31-tenancy-pool-rls` no es peligroso en sí (el rol llega al JWT, pero el backend lo sigue ignorando porque el pool bypasea RLS) — es simplemente inútil hasta que ambos estén cerrados, tal como documenta la ficha ("no cambia nada en prod"). El riesgo real de saltar el orden es únicamente `v3-rbac-multirole` antes de sus prerequisitos: ahí sí se estaría escribiendo enforcement de roles que no se puede confiar (RLS inerte + rol no en el JWT = todo el pivot es decorativo, exactamente el error que la auditoría encontró en el diseño original).

---

## Resumen

**Lo que la exploración confirma**: los 3 bloqueantes duros de la ficha de `CHANGES.md` (H-05/H-06/H-07 global) están verificados empíricamente contra prod, sin remediar, sin cambios sustantivos desde la auditoría del 07-07 — solo el crecimiento natural de usuarios (29→34) y un matiz sobre `config.toml` (dev-only, no evidencia de estado de prod). El cluster de 5 changes tiene un orden claro que no es puramente el del roadmap: los 2 satélites sin gate (`fix-auth-shape-500`, `fsm-status-triggers`) se pueden ejecutar ya; los 2 CRÍTICOS (`authz-token-hook`, `tenancy-pool-rls`) necesitan sign-off y pueden avanzar en paralelo; `v3-rbac-multirole` va al final. La decisión más cara y con más incertidumbre técnica es Opción A vs B de `tenancy-pool-rls` — mi recomendación es A en dos pasos, aprovechando que las policies RLS (49 archivos de migración) ya existen y están bien escritas, así que el trabajo real no es "escribir seguridad nueva" sino "dejar de ignorar la que ya existe".
