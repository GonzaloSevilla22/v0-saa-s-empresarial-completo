## Context

`custom_access_token_hook` es la función que Supabase Auth invoca **en cada emisión de token** (login y refresh) para inyectar claims propios en el JWT. En Aliadata existe desde `supabase/migrations/20260800000004_auth_jwt_role_hook.sql` (aplicada en prod) y está **dormida**: la propia migración lo dice en su cabecera ("⚠️ DORMIDO POR DEFECTO"), y la evidencia de prod lo confirma — 0 de 34 usuarios con claim de rol.

Estado verificado en prod (`gxdhpxvdjjkmxhdkkwyb`, read-only vía MCP, 2026-07-31):

| Dato | Valor |
|---|---|
| `auth.users` | 34 · **0** con `raw_app_meta_data ? 'role'` |
| `profiles.role` | 33 `user` · **1** `admin` |
| `account_members.role` | 34 `owner` · 0 `admin` · 0 `member` |
| Usuarios con 2+ membresías | **0** |
| `accounts.billing_plan` | 8 `gratis` · 24 `avanzado` · 2 `pro` |
| Cuentas con trial vigente | **5** |
| Productos vivos: máx. en una cuenta `gratis` | **123** (límite del plan: 100) |
| `cost_centers` | **0 filas** |
| GRANTs de `supabase_auth_admin` | `profiles` sí (desde la migración del hook) · `account_members` **ninguno** · `accounts` **ninguno** |

La función hoy copia `profiles.role → app_metadata.role`, corre `STABLE` **sin `SECURITY DEFINER`** (`prosecdef = false`, verificado) y **sin `SET search_path`** — el advisor `function_search_path_mutable` está abierto sobre ella. Que no sea DEFINER es correcto: se ejecuta como `supabase_auth_admin`, y la migración le dio explícitamente `GRANT SELECT` sobre `profiles` más una policy `auth_admin_can_read_roles`. Cualquier tabla nueva que el hook lea necesita el mismo tratamiento.

**El hecho estructural que domina este diseño**: en este codebase conviven **dos espacios de nombres de rol** que ningún documento previo separa explícitamente.

| | Rol de **plataforma** | Rol de **tenant** |
|---|---|---|
| Fuente | `profiles.role` | `account_members.role` |
| Valores | `user`, `admin` | `owner`, `admin`, `member` |
| Prod | 33 / 1 | 34 / 0 / 0 |
| Significa | "¿es staff de Aliadata?" | "¿qué puede hacer dentro de su empresa?" |
| Quién lo consume | `require_platform_admin` (lee la DB) y **56** `require_role(auth, ["user","admin"])` | **3** `require_role(auth, ["owner","admin"])` en `cost_centers` · las policies RLS vía `is_account_writer` |

Los 56 guards de `["user","admin"]` sólo pasan hoy porque el fallback de `get_current_user` es literalmente `"user"`. El valor "correcto" y el valor "accidental" coinciden — por eso nadie notó la mezcla. **`admin` es homónimo en ambos espacios y significa cosas distintas.**

Restricciones vigentes del proyecto que acotan el diseño:
- El toggle de producción **no vive en el repo**. `supabase/config.toml:270-272` dice `enabled = true` pero sólo aplica a `supabase start`. El CI/CD (merge → `db push`) **no** puede activarlo.
- Governance CRÍTICO: auth de 34 usuarios reales con dinero real.
- `AuthContext` ya es un `TypedDict` verificado por un test anti-deriva (`v31-fix-auth-shape-500`, PR #308): agregar una clave obliga a actualizar el contrato, por diseño.
- El hook está blindado con `EXCEPTION WHEN OTHERS → claims intactos`: un fallo nunca debe romper un login.

## Goals / Non-Goals

**Goals:**
- Que el rol de tenant y el plan **lleguen al JWT** y el backend los use, sin romper los 56 guards que hablan el otro espacio de nombres.
- Cerrar el criterio (a) de la ficha: `cost_centers` deja de dar 403 universal.
- Cerrar el criterio (b): el gating por plan deja de ser fail-open.
- Dejar el hook **listo y probado** para que la activación sea un acto único, reversible y verificable del PO.
- Dejar escrito el contrato de claims para que `v3-rbac-multirole` lo extienda sin re-litigar la forma.

**Non-Goals:**
- **No** se introduce el pivot `account_member_roles` ni el catálogo de 8 roles funcionales — eso es `v3-rbac-multirole`.
- **No** se migran los 56 call sites de `require_role` a roles funcionales. Este change los deja donde están, ahora por razón explícita y no por accidente.
- **No** se toca el pool, `SET LOCAL`, `BYPASSRLS` ni las policies RLS — eso es `v31-tenancy-pool-rls`, que corre en paralelo.
- **No** se migran los helpers RLS (`is_account_writer`, `current_account_ids`) a leer nada nuevo.
- **No** se activa el hook desde el agente ni desde CI. La activación es del PO.
- **No** se fabrican credenciales ni se inicia sesión como ningún usuario real para verificar.

## Decisions

### D1 — Tres claims con espacios de nombres separados; `role` no cambia de significado

El hook emite bajo `app_metadata`:

| Claim | Fuente | Valores | Consumidor |
|---|---|---|---|
| `role` | `profiles.role` | `user` \| `admin` | los 56 `require_role(["user","admin"])` + `require_platform_admin` |
| `account_role` | `account_members.role` de la cuenta activa | `owner` \| `admin` \| `member` | `require_account_role` (nuevo) — hoy sólo `cost_centers` |
| `plan` | plan efectivo de la cuenta activa | `gratis` \| `inicial` \| `avanzado` \| `pro` | `products.create_product`, futuro gating de roles funcionales |

**Por qué `role` se queda con el rol de plataforma.** Es la única asignación que hace que activar el toggle sea un **no-op de autorización** para lo que hoy funciona: 33 usuarios reciben `role="user"` (idéntico al fallback actual) y 1 recibe `role="admin"` (que también pasa los 56 guards y además arregla `require_platform_admin` sin pegarle a la base). Cero cambios de resultado en 62 de los 65 call sites, con evidencia numérica, no con esperanza.

**Alternativa descartada — `role` = rol de tenant** (lo que sugería el plan original de la tarea). Inyectaría `"owner"` en un claim que 56 guards comparan contra `["user","admin"]`: **403 en casi todo el backend, para las 34 cuentas, en el instante de activar el toggle.** Es un fallo catastrófico, silencioso hasta el deploy, e imposible de detectar con los tests actuales porque el fixture emite un JWT sin `app_metadata`.

**Alternativa descartada — renombrar/normalizar los espacios** (`owner → user`, o migrar los 56 call sites a roles de tenant en este change). Es exactamente el trabajo de `v3-rbac-multirole` (66 call sites + pivot + matriz rol×transición). Meterlo acá convierte un change M en un L crítico y acopla dos sign-offs distintos.

**Alternativa descartada — un solo claim con prefijo** (`role = "platform:admin"` / `"tenant:owner"`). Rompe los 56 guards igual, y obliga a parsear strings en el punto más caliente del backend.

### D2 — `account_role` es singular hoy, y el contrato dice cómo deja de serlo

`account_members.role` es una columna singular con `CHECK (role IN ('owner','admin','member'))`. El claim la refleja tal cual. Cuando `v3-rbac-multirole` introduzca el pivot `account_member_roles`, el hook emitirá **`account_roles`** — array de los roles **activos** (respetando `expires_at`) — y `account_role` quedará como compat derivado (el rol de mayor precedencia) hasta que no queden tokens viejos.

Esto se escribe acá, en el spec de `authz-token-claims`, y **no** se implementa acá. El motivo de dejarlo explícito: es la pregunta que va a reaparecer en el propose de `v3-rbac-multirole`, y la respuesta correcta (agregar una clave nueva, no cambiar la forma de una existente) es la misma lección que D1 acaba de pagar.

### D3 — El claim `plan` lleva el plan **efectivo**, computado por `get_effective_plan` (resuelto por el PO, 2026-07-31)

> **Amendment 2026-07-31 (sign-off del PO).** OQ-1 queda resuelta: el claim `plan` emite el plan efectivo a través de una función canónica de la base, `public.get_effective_plan(account_id)`, que **introduce el change `billing-pro-trial`**. Esta sección reemplaza la redacción anterior, que dejaba el enforcement como pregunta abierta.

El hook **no reimplementa** la regla del plan efectivo: llama a `public.get_effective_plan(p_account_id uuid)`, cuya precedencia es:

```
exención de cortesía vigente → 'pro'
trial vigente                → trial_plan
si no                        → billing_plan
sin información suficiente   → 'gratis'   (fail-closed)
```

**Por qué una función y no la regla inline en el hook.** La regla del plan efectivo ya existe en prosa (spec de `plan-gating`) y en TypeScript (`frontend/lib/plan-utils.ts`). Escribirla por tercera vez dentro del `jsonb_build_object` del hook la vuelve imposible de verificar: quedaría replicada en el punto más difícil de testear del sistema (emisión de tokens) y sin nada contra qué contrastarla. Con la función canónica hay **una** definición normativa, y `billing-pro-trial` incluye una prueba de paridad que cruza la implementación SQL contra el espejo TypeScript.

**Efecto colateral que simplifica D5.** `get_effective_plan` se define `SECURITY DEFINER`, así que al hook **le alcanza con `GRANT EXECUTE` sobre la función** — ya no necesita `GRANT SELECT` + policy de lectura sobre `accounts` para `supabase_auth_admin`. Menos objetos nuevos en un camino cuyo modo de fallo es el silencio (D5): un permiso faltante sobre una sola función es más fácil de detectar que sobre una tabla más una policy.

**Dependencia dura de secuencia**: `billing-pro-trial` **debe estar mergeado antes** de aplicar este change. Sin `get_effective_plan` en la base, la migración del hook no puede completarse. Se registra en las tareas del grupo 1 y en la ficha de secuencia del cluster.

**Por qué el enforcement dejó de ser una pregunta abierta.** El sign-off del 2026-07-31 le da a **todas** las cuentas 30 días de plan PRO al activarse `billing-pro-trial`. Consecuencia directa sobre este change: **en el momento de encender el toggle del hook, ninguna cuenta ve un límite reducido** — las 34 están en trial PRO o exentas, así que el claim `plan` emite `'pro'` para todas y el enforcement real empieza a morder 30 días después, no en el instante del corte. La cuenta con 123 productos que motivaba OQ-1 conserva sus 123 (política de **excedente tolerado**: se bloquea crear, nunca se borra), y recibe un aviso por la campana. El riesgo que OQ-1 pedía cuantificar quedó desactivado por el diseño de la feature, no diferido.

**Fail-closed, no fail-open.** El default `"pro"` de `get_current_user` se conserva **sólo** mientras haya tokens sin claim en circulación (ver D6), y el spec de `plan-gating` establece que la ausencia de información de plan NOT SHALL resolverse concediendo el plan más alto. La eliminación definitiva del default optimista queda ligada al cierre de la ventana de transición.

### D4 — La cuenta activa se resuelve con un orden determinístico, igual en el hook y en el backend

`backend/core/deps.py::get_account_id` hace hoy:

```sql
SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1
```

Sin `ORDER BY`, el resultado es no determinístico bajo multi-membresía. Si el hook eligiera una cuenta y `get_account_id` otra, el `account_role`/`plan` del token describirían **una cuenta distinta** de aquella sobre la que el request opera — una falla de autorización sutil y difícil de diagnosticar.

Decisión: ambos lados usan el mismo criterio explícito (`ORDER BY created_at, id LIMIT 1` — la membresía más antigua, determinística por el desempate con la PK). Hoy el riesgo es **latente** (0 usuarios con 2+ membresías) y por eso el fix es barato ahora; `v3-rbac-multirole` lo vuelve alcanzable al introducir invitaciones multi-rol.

**Alternativa descartada — un selector de cuenta activa explícito** (claim `account_id` elegido por el usuario, tipo "cambiar de organización"). Es una feature de producto, no un fix; requiere UI y un endpoint de switch. **Resuelto por el PO el 2026-07-31 (OQ-3): se diseña en `v3-rbac-multirole`**, que es el change que introduce la multi-membresía real y por lo tanto el primero donde el selector tiene algo que seleccionar. Acá no se implementa.

**Nota deliberada**: este change **no** agrega `account_id` como claim. Un `account_id` en el token que se desincronice del resolver es peor que no tenerlo, y `get_account_id` ya es la fuente canónica del tenant desde `v31-fix-auth-shape-500`. El claim de cuenta se evalúa cuando exista el selector explícito (OQ-3).

### D5 — El hook lee dos tablas nuevas: hay que darle acceso, y el blindaje deja de ser opcional

`supabase_auth_admin` **no tiene ningún grant** sobre `account_members` ni `accounts` (verificado). Sin `GRANT SELECT` + policy permisiva de SELECT para ese rol, las lecturas nuevas fallan; y como el hook está envuelto en `EXCEPTION WHEN OTHERS`, **fallarían en silencio**: el login funcionaría y los claims saldrían vacíos. El síntoma sería idéntico al de hoy y la causa, invisible.

Por eso el diseño trata el blindaje como una red que **no debe ocultar errores de configuración**:
- La migración agrega `GRANT SELECT` + policy `auth_admin_can_read_*` para `supabase_auth_admin` sobre `account_members`, siguiendo el patrón exacto que la migración original usó para `profiles`. **Sobre `accounts` ya no hace falta** (amendment 2026-07-31): el plan llega vía `GRANT EXECUTE` sobre `get_effective_plan`, que es `SECURITY DEFINER` (D3).
- El `EXCEPTION WHEN OTHERS` se conserva (nunca romper un login) pero **loguea** vía `RAISE WARNING` con el `SQLSTATE`, de modo que un permiso faltante deje rastro en los logs de Postgres en vez de degradar mudo.
- Un **gate de verificación dentro de la propia migración** ejecuta el hook contra un usuario real de la base y falla el `db push` si el resultado no trae las tres claves. Es el patrón de gates que el proyecto ya usa en sus migraciones, y convierte "el hook devuelve claims vacíos" en un error de deploy en vez de un misterio de producción.
- `SET search_path = public, pg_temp` se agrega en la misma redefinición (cierra el advisor `function_search_path_mutable` sobre la función auth-crítica más sensible del proyecto — nunca sobre una función DEFINER, pero igual de deseable acá porque corre con la identidad de `supabase_auth_admin`).

La migración es `CREATE OR REPLACE` sobre la **misma firma** `(jsonb)` — no aplica la lección C3 del proyecto (el `42725` por overload duplicado ocurre al *agregar un parámetro*; acá la firma no cambia). Igual se verifica que quede **una sola** definición.

### D6 — Transición: el backend prefiere el claim y cae a la base, nunca a un valor permisivo

Los JWT vigentes al momento de activar el toggle **no tienen los claims** y siguen siendo válidos hasta su refresh (~1 h) o hasta re-login. Durante esa ventana conviven dos poblaciones de tokens.

Regla de resolución para el rol de tenant:

1. Si `app_metadata.account_role` está presente → se usa.
2. Si no → se resuelve contra la base (`account_members` de la cuenta activa) dentro del guard.
3. Si no hay membresía → **denegar**. Nunca un default permisivo.

Se implementa como `require_account_role(conn, auth, allowed)` — asíncrono porque puede tocar la base. **No es un patrón nuevo**: `require_platform_admin` ya hace exactamente esto (lee `profiles.role` de la DB porque el rol no viaja en el token). La diferencia es que acá la lectura es el *fallback*, no el camino principal, y desaparece sola cuando la ventana se cierra.

Coste: una query extra por request **sólo** en los endpoints que piden rol de tenant (hoy 3, todos de `cost_centers`) y **sólo** para tokens viejos. No se toca el camino caliente.

Para `plan`, el fallback es el default actual (`"pro"`) mientras dure la ventana, con la nota explícita en el spec de que es un valor de transición y no la política definitiva (D3).

**Alternativa descartada — forzar el re-login de los 34 usuarios** (revocar sesiones al activar). Convierte una migración transparente en una interrupción visible para usuarios reales, a cambio de acortar una ventana de una hora. No vale la pena.

### D7 — La activación en producción es una tarea MANUAL del PO, con instrucciones exactas y un camino alternativo documentado

El toggle vive en **Supabase Dashboard → Authentication → Hooks (Beta) → Customize Access Token**, seleccionando la función Postgres `public.custom_access_token_hook`. Esa superficie está **fuera del repo, fuera de CI/CD y fuera del alcance del agente**.

Sobre la vía programática (investigado, no asumido):
- Existe el endpoint de Management API **`PATCH /v1/projects/{ref}/config/auth`** para configurar Auth de un proyecto (confirmado en la documentación de Supabase, que lo usa para otros parámetros de Auth). Los nombres exactos de los campos del toggle del hook deben verificarse contra la referencia viva de la API **en el momento de ejecutar** — no se hardcodean acá de memoria.
- **El servidor MCP de Supabase disponible en este entorno no expone ninguna herramienta de configuración de Auth** (su superficie es SQL, migraciones, logs, advisors, edge functions, branches y metadatos de proyecto). Verificado contra la lista de herramientas: no hay equivalente a `update_auth_config`.
- La vía por API requiere un **Personal Access Token de Management API**. Es una credencial: el agente no la pide, no la recibe y no la usa. Si el PO prefiere el camino programático, lo ejecuta él.

Conclusión operativa: **camino primario = Dashboard** (3 clics, reversible con 1). El camino por API queda documentado como opción del PO, no como automatización.

### D8 — La verificación se hace con un diagnóstico de presencia, no leyendo tokens

**Trampa que hay que desactivar antes de que alguien caiga en ella**: el hook **no escribe `auth.users.raw_app_meta_data`** (confirmado contra la documentación de Supabase: el hook sólo modifica los claims del token emitido). La query que la exploración usó como evidencia del estado actual —`raw_app_meta_data ? 'role'`— **seguirá dando 0 con el hook perfectamente activo**. Usarla como verificación post-activación produciría la conclusión exactamente inversa a la verdad.

Verificación en tres niveles, ninguno de los cuales requiere fabricar credenciales:

1. **DB, antes de activar** — invocar la función directamente con un `user_id` real: `SELECT public.custom_access_token_hook(jsonb_build_object('user_id', <uuid real>, 'claims', '{}'::jsonb))`. Prueba que la función devuelve las tres claves con los valores correctos. Es lo que el gate de la migración automatiza (D5).
2. **Backend, después de activar** — endpoint `GET /auth/claims-status` que, para el usuario **ya autenticado que lo llama**, devuelve `{role_claim_present, account_role_claim_present, plan_claim_present, effective_role, effective_account_role, effective_plan, source}`. **Sólo booleanos de presencia y valores efectivos; nunca el token, nunca el payload crudo, nunca otro usuario.** El PO lo consulta desde su propia sesión tras re-loguearse — su navegador ya tiene la credencial, el agente no la ve nunca.
3. **Comportamiento observable** — crear un centro de costo con una cuenta real deja de dar 403. `cost_centers` tiene 0 filas: la primera fila que aparezca **es** la prueba de aceptación.

**Alternativa descartada — un log temporal en el backend que registre la presencia del claim.** Funciona, pero deja código de instrumentación que alguien tiene que acordarse de sacar, y roza datos de sesión en los logs. Un endpoint explícito y acotado es más auditable y no caduca.

`GET /auth/claims-status` queda como endpoint permanente de diagnóstico: es útil cada vez que se toque el hook (empezando por `v3-rbac-multirole`) y no expone nada que el propio llamante no sepa ya de sí mismo.

### D9 — `cost_centers` es el único consumidor que migra en este change

Los 3 guards de `cost_centers` pasan de `require_role(auth, ["owner","admin"])` a `await require_account_role(conn, auth, ["owner","admin"])`. Son los únicos call sites que hablaban el espacio de nombres de tenant, y son la razón de que la tabla tenga 0 filas.

Los 56 de `["user","admin"]` **no se tocan**: hoy funcionan y seguirán funcionando, ahora por una razón escrita (hablan el espacio de plataforma). Su migración a roles funcionales es trabajo de `v3-rbac-multirole` y está dimensionada allá.

## Risks / Trade-offs

- **Se activa el toggle y el backend empieza a dar 403 masivos** → Mitigado en la raíz por D1: `role` mantiene la semántica de plataforma y prod tiene 33 `user` + 1 `admin`, exactamente los valores que los 56 guards aceptan. Adicionalmente, tests que ejercitan un JWT **con** `app_metadata` completo (hoy ningún test lo hace) y verifican que los guards existentes siguen pasando. Rollback: un toggle.
- **Se activa el toggle y una cuenta `gratis` no puede crear productos** → **Desactivado por el sign-off del 2026-07-31** (D3): al momento del corte las 34 cuentas están en trial PRO o exentas, así que el claim emite `'pro'` para todas y el enforcement empieza 30 días después. La cuenta con 123 productos conserva los 123 (excedente tolerado) y recibe aviso por la campana. Queda el residuo de que la fecha de encendido del toggle y la del vencimiento del trial son independientes: si el PO demorara la activación más de 30 días, el corte volvería a coincidir con el enforcement. Mitigación: la tarea-gate previa a la activación se conserva, ahora como verificación de que sigue habiendo trial vigente.
- **`get_effective_plan` no existe cuando se aplica la migración del hook** → Dependencia dura de secuencia con `billing-pro-trial` (D3). Mitigado por una verificación en el grupo 1 de tareas que falla temprano y con un mensaje explícito, en vez de dejar que el hook degrade en silencio por su `EXCEPTION WHEN OTHERS`.
- **El hook falla en silencio por permisos faltantes y nadie se entera** → El riesgo más insidioso, porque el `EXCEPTION WHEN OTHERS` está diseñado para tragar errores. Mitigado por el gate de la migración (falla el `db push`, no la producción), el `RAISE WARNING` con `SQLSTATE`, y el nivel 1 de verificación de D8 antes de tocar el Dashboard.
- **El hook agrega latencia a cada emisión de token** → Pasa de 1 a 3 lecturas indexadas por PK/FK, en una operación que ocurre una vez por hora por usuario. Con 34 usuarios es irrelevante; se anota como cosa a revisar si el volumen crece un orden de magnitud. Alternativa si llegara a doler: una sola query con joins en vez de tres.
- **El JWT crece** → Tres claves cortas en `app_metadata`. Irrelevante para el límite de cookie/header; se menciona sólo porque `v3-rbac-multirole` va a agregar un **array** de roles, y ahí sí conviene medirlo.
- **Un trial vence a mitad de sesión y el token sigue diciendo el plan viejo** → Hasta 1 h de gracia por diseño (el claim se recalcula en cada refresh). Aceptado explícitamente: es el mismo margen que la capability `plan-gating` ya tolera y no justifica invalidación de sesiones.
- **Alguien verifica con `raw_app_meta_data ? 'role'` y concluye que el hook no anda** → Mitigado documentándolo en tres lugares (proposal, D8 y la tarea de verificación). Es el error más probable de este change.
- **Doble sign-off encadenado**: este change y `v31-tenancy-pool-rls` corren en paralelo y ambos son CRÍTICOS; si el PO aprueba sólo uno, el cluster no avanza. Ninguno rompe nada por sí solo si el otro no llega (activar el hook sin arreglar el pool no es peligroso — es simplemente insuficiente para `v3-rbac-multirole`).

## Migration Plan

0. **Prerequisito** — `billing-pro-trial` mergeado y su backfill aplicado: `get_effective_plan` existe y las 34 cuentas están en trial PRO o exentas (D3).
1. **Preparación (agente)** — migración idempotente + código backend + tests. Merge a `main` dispara `db push`: la función queda **redefinida y dormida**. Nada cambia en producción todavía; el toggle sigue apagado.
2. **Verificación previa (agente, read-only)** — confirmar que sigue habiendo trial vigente en las cuentas no exentas, de modo que el corte no coincida con el vencimiento (D3, residuo del riesgo).
3. **Verificación DB (agente, read-only)** — invocar la función con un `user_id` real y confirmar las tres claves.
4. **Activación (MANUAL, PO)** — Dashboard → Authentication → Hooks (Beta) → Customize Access Token → `public.custom_access_token_hook` → guardar.
5. **Verificación post-activación (PO + agente)** — el PO re-loguea y consulta `GET /auth/claims-status` desde su sesión; se confirma `true` en las tres presencias. Prueba de aceptación final: crear un centro de costo (la tabla pasa de 0 a 1 fila).
6. **Observación** — 24-48 h: logs del backend sin 403 nuevos en endpoints que antes funcionaban, y `WARNING` del hook en logs de Postgres en cero.

**Rollback**: desactivar el toggle en el Dashboard. Los tokens ya emitidos con claims siguen siendo válidos y el backend los tolera; los siguientes salen sin claims y el fallback se hace cargo. **Sin migración destructiva, sin pérdida de datos, sin re-login forzado.** Si además hiciera falta revertir el código, es un `git revert` del PR (Render redeploya solo) — la función redefinida en la base es inerte sin el toggle.

## Open Questions

**Las tres OQ del propose quedaron resueltas por el sign-off del PO del 2026-07-31.** Se conservan con su resolución para que el apply no las re-litigue.

- **OQ-1 — enforcement del límite de plan → RESUELTA.** El claim `plan` emite el **plan efectivo** a través de `public.get_effective_plan(account_id)`, función canónica que introduce el change **`billing-pro-trial`** (exenta → `pro` de cortesía; pagadora → su plan; trial vigente → `pro`; si no → `billing_plan` con default fail-closed `gratis`). Esto **crea una dependencia dura de secuencia**: el apply de este change requiere `billing-pro-trial` mergeado primero. La consecuencia que OQ-1 pedía cuantificar quedó desactivada: con 30 días de trial PRO para todas las cuentas, en el instante de activar el toggle ninguna ve un límite reducido, y la cuenta que quede en excedente al vencer conserva sus datos (excedente tolerado) y recibe aviso. Ver D3.
- **OQ-2 — comunicación a usuarios → RESUELTA: no se comunica.** La activación del hook no se anuncia a las 34 cuentas; es transparente (sin re-login forzado, ~1 h de convivencia de tokens). *Nota de alcance*: esto se refiere **sólo** a la activación del hook. El **aviso de excedente** posterior al vencimiento del trial sí existe y es parte de `billing-pro-trial` — son dos comunicaciones distintas y sólo la primera se omite.
- **OQ-3 — selector de cuenta activa → RESUELTA: se diseña en `v3-rbac-multirole`.** Es el change que introduce la multi-membresía real, y por lo tanto el primero en el que el selector tiene algo que seleccionar. Este change se limita a hacer determinística la resolución actual (D4) y **no** agrega un claim `account_id`.
