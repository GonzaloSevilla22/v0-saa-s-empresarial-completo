# Exploración: v3-rbac-multirole — refresh del análisis (2026-09-10)

> **Tipo:** Exploración (modo thinking — sin implementación). Governance **CRÍTICO** (auth/RLS): esta sesión es solo análisis, no se escribió código ni se aplicó ninguna migración. No se creó ningún change OPSX.
> **Fecha:** 2026-09-10
> **Proyecto:** ALIADATA / EmprendeSmart (EIE) — Supabase prod `gxdhpxvdjjkmxhdkkwyb` (verificado read-only vía `mcp__supabase__execute_sql`, tool marcado read-only por el propio servidor — error `25006` ante cualquier intento de escritura)
> **Relación con el análisis previo:** este documento **actualiza** `openspec/explore/2026-07-30-v3-rbac-multirole.md` (PR #306). No lo reemplaza ni lo reescribe — cada sección dice explícitamente qué sigue vigente de julio, qué cambió y qué quedó invalidado. Léanse juntos.
> **Motivo del refresh:** desde el 2026-07-30 se cerraron y archivaron los tres bloqueantes duros que el análisis original identificó (`v31-fix-auth-shape-500`, `v31-authz-token-hook`, `v31-tenancy-pool-rls` + su hardening `v31-tenancy-role-assertion`). El bloqueo hoy es **exclusivamente el sign-off explícito del PO** — no hay ningún prerequisito técnico pendiente. Este documento verifica esa afirmación contra el código y contra prod, mide el estado real de uso (cuentas con más de un miembro, roles en uso), y encuentra una pieza que julio no vio: **ya existe una pantalla `/organizacion/roles`** en producción, construida para el modelo singular de C-06, que este change tiene que extender en vez de crear desde cero.

---

## 1. Resumen ejecutivo

`v3-rbac-multirole` reemplaza `account_members.role` (un solo rol por membresía: `owner`/`admin`/`member`) por un pivot multi-rol con expiración (`OWNER/ADMIN/SELLER/CASHIER/STOCK/PURCHASES/ACCOUNTANT/VIEWER`, catálogo cerrado del modelo V3 §5), activa por primera vez el enforcement real de rol de cuenta en el backend, y puebla la matriz rol×transición FSM que hoy vive inerte (`allowed_role` NULL en las 19 filas de `document_status_transitions`). Es **CRÍTICO** porque toca `RLS`/autorización de escritura en las tablas de dinero real (ventas, compras, gastos, cuentas corrientes, caja) de 39 cuentas con usuarios reales — un bug de enforcement aquí es la clase de error más cara que existe en este proyecto (fail-open cross-rol, o un owner que se queda sin poder operar su propia cuenta).

**Lo que cambió de fondo desde julio**: los tres bloqueantes técnicos (H-05 pool BYPASSRLS, H-06 fixture de auth, H-07 hook de rol dormido) están **cerrados, archivados y verificados en prod** — no analizados-pero-pendientes como en julio, sino con evidencia empírica de funcionamiento real (`SET LOCAL ROLE` transaccional activo, claims `role`/`account_role`/`plan` viajando en el JWT desde el 2026-08-01, guard `require_account_role` con tráfico real en 3 superficies). El único portón que falta abrir es el sign-off del PO — técnicamente, hoy se podría empezar a escribir código.

**Lo que la medición de prod agrega, y que julio no tenía**: de las 39 cuentas reales, **cero tienen más de un miembro**. El 100% son `owner` solitario, igual que en julio (eran 34/34) — pero ahora es una medición más fuerte porque confirma que en 5 semanas de crecimiento orgánico nadie invitó a un segundo usuario a su cuenta. Esto no invalida el change (media docena de changes futuros del roadmap — maker-checker, agente IA con tools de escritura, multiempresa — están bloqueados esperando este pivot, no esperando que alguien lo use hoy), pero sí cambia la urgencia relativa: es infraestructura para el futuro cercano, no un incendio activo de UX.

**Qué necesita del PO para avanzar**: (1) confirmar que quiere avanzar pese al hallazgo de cero uso real de equipos hoy — o priorizar solo la Parte A (modelo de datos, aditivo, sin cambiar enforcement); (2) la decisión de gating por plan de roles funcionales, pendiente desde julio y ahora con números reales (solo 2/39 cuentas en plan `pro`, 0 en `avanzado`); (3) confirmar si se extiende la pantalla `/organizacion/roles` ya existente o se reemplaza; (4) el gancho de datos `requires_second_approval` — julio lo recomendaba agregar ya, pero hoy existe un change futuro propio (`v4-seguridad-04`/`05`) que lo diseña con detalle, lo que cambia el cálculo de costo/beneficio de adelantarlo.

---

## 2. Qué cambió desde el análisis del 2026-07-30

| # | Premisa de julio | Estado en julio (2026-07-30) | Estado hoy (2026-09-10, verificado dónde) | Impacto en el diseño |
|---|---|---|---|---|
| 1 | **H-05 — pool `postgres` con `BYPASSRLS`** hace que la RLS sea inerte para el backend; `set_config(...,false)` de sesión (no transaccional) es la causa raíz de K5 (compras 500 intermitente) | Confirmado por query directa a `pg_roles`; recomendación: Opción A en dos pasos (`SET LOCAL` transaccional primero, cambio de rol después) | **`v31-tenancy-pool-rls` completada y archivada (rollout 2026-08-26, archive 2026-08-27)**: Paso 1 (transacción explícita + `SET LOCAL request.jwt.claims` con alcance transaccional) y Paso 2 (`SET LOCAL ROLE authenticated` por transacción) **ambos ON en prod**. Verificado hoy: `postgres` sigue con `rolbypassrls=true` como rol de **login** del pool (Paso 3 — rol de login dedicado sin BYPASSRLS — **no ejecutado**, es un residuo documentado, no bloqueante), pero cada transacción de negocio adopta `authenticated` y la RLS se evalúa de verdad. `v31-tenancy-role-assertion` (PRs #470/#471, archivado 2026-08-28) añadió una comprobación *fail-closed*: si un camino del backend omite la adopción del rol, la conexión de servicio se rechaza en vez de fallar abierto — verificado en prod con **0 rechazos** en 5 semanas (control positivo: la búsqueda encuentra tráfico cuando lo hay). | **Cambia el diseño de fondo**: en julio, tocar `is_account_writer`/`current_account_ids` no tenía efecto observable (el pool los bypaseaba). **Hoy tiene efecto real** — son la RLS que de verdad protege sales/purchases/expenses/products/clients. Migrar esos helpers para leer el pivot multi-rol en vez de `account_members.role` **es un cambio de comportamiento de producción**, no un refactor inerte. Ver Riesgo R4. |
| 2 | **H-06 — fixture de auth con shape falso** (`{sub, role:"authenticated"}` en vez de `{user_id, role, plan}`) enmascaraba 3 endpoints en 500 | Confirmado, código sin tocar | **`v31-fix-auth-shape-500` completado 2026-07-31** (PR #308): `TypedDict AuthContext` con el shape real, test de contrato anti-deriva. Verificado hoy leyendo `backend/core/auth.py:9-31` — el contrato declara `user_id`/`role`/`account_role`/`plan` como las únicas 4 claves válidas, con comentario normativo explícito. | Cerrado, sin acción pendiente. Los tests nuevos de la matriz rol×transición parten de un contrato real, no heredan la ceguera de H-06. |
| 3 | **H-07 — hook de rol deshabilitado en prod**: función existe pero 0/34 usuarios con `app_metadata.role`; `config.toml enabled=true` es dev-only y no prueba nada de prod | Confirmado por conteo directo sobre `auth.users` | **`v31-authz-token-hook` completado y archivado 2026-09-05**. El hook emite `role` (plataforma), `account_role` (tenant, claim **nuevo**) y `plan` (efectivo). **Activación verificada en prod** vía `auth_logs` (no vía `raw_app_meta_data` — trampa documentada: da 0/38 aunque el hook esté activo): invocaciones exitosas desde `2026-08-01T16:54:23Z`, ininterrumpidas — el bookkeeping había quedado 34 días desactualizado sin que el hook dejara de correr. Guard `require_account_role(conn, auth, allowed)` en `backend/core/guards.py` (leído hoy, línea 24-46) con fallback a DB. **Adopción real medida hoy**: 4 services lo usan — `cost_centers.py`, `payment_methods.py`, `product_categories.py`, `account_charges.py` — los 4 solo comparan contra `["owner","admin"]`, ninguno contra un rol funcional (no existen todavía). | El "rol llega al JWT" ya no es una promesa, es un hecho verificado con tráfico real de 5 semanas. Pero ver **Riesgo R3**: el guard prioriza el claim del JWT sobre la DB — una vez que el claim está presente, un cambio de rol en la DB **no** se refleja hasta que el token se refresca, lo cual no es solo un detalle de julio (era implícito), es una superficie de staleness que el pivot multi-rol hereda tal cual. |
| 4 | **Pivot de roles "más simple de lo que documenta la ficha"**: 34/34 cuentas `role='owner'`, CHECK `('owner','admin','member')` sin cambios desde C-06 | Confirmado; recomendación: backfill trivial (`INSERT ... SELECT 'OWNER', created_at FROM account_members`) | **Confirmado de nuevo, con más fuerza**: hoy son **39/39 cuentas, 100% `owner`**, y — dato nuevo que julio no midió explícitamente — **39/39 cuentas tienen exactamente 1 miembro** (`account_members` GROUP BY `account_id` da `cnt=1` para las 39). CHECK sin cambios (`role = ANY (ARRAY['owner','admin','member'])`). `account_member_roles` (la tabla del pivot) **no existe** (`to_regclass` → NULL). Columna `requires_second_approval` (maker-checker) **no existe en ningún lugar del schema `public`** (`count(*)=0` sobre `information_schema.columns`). | El backfill sigue siendo trivial y **sin ningún caso real de multi-membresía o rol no-owner que preservar** — reduce a cero el riesgo de esa parte de la migración. Pero también es la evidencia dura de la Sección 1: nadie usa colaboración multiusuario hoy. Ver pregunta PO §6.1. |
| 5 | **Matriz FSM (`document_status_transitions`) inerte, 18 filas, `allowed_role` todo NULL** — base concreta para RN-A4, pero bloqueada porque el trigger `BEFORE UPDATE` que hace cumplir la FSM (`v31-fsm-status-triggers`, H-17) todavía no existía | Bosquejo de asignación rol×transición propuesto, sin trigger de enforcement en DB (solo los RPCs "bien portados" respetaban la FSM) | **`v31-fsm-status-triggers` (H-17) completado 2026-07-31** (PR #309): el trigger `BEFORE UPDATE` ya está activo en las 6 tablas de documento. Hoy hay **19 filas** (no 18 — se agregó `sales_order: confirmed→canceled`, de trabajo posterior de reversión de ventas), **`allowed_role` sigue en 0/19 pobladas** — la matriz sigue completamente inerte, pero ahora sobre un enforcement de FSM que es real en DB, no solo "los RPCs que se portan bien". | RN-A4 ya no es un diseño sobre un enforcement de papel — el trigger existe, así que poblar `allowed_role` y hacer que `record_status_transition` lo valide **cambia comportamiento real** desde el día en que se aplique. El bosquejo rol×transición de julio (§5 del doc original) sigue siendo válido como punto de partida; falta re-confirmar la fila nueva (`sales_order confirmed→canceled`, candidata a excluir `CASHIER` explícitamente, tal como julio ya anticipaba para una futura transición de anulación). |
| 6 | *(no estaba en julio — hallazgo nuevo de este refresh)* Julio trataba la UI `/organizacion/roles` como scope a **construir** | — | **Ya existe en prod**: `frontend/app/(dashboard)/organizacion/roles/page.tsx` (247 líneas), construida sobre el modelo singular de C-06 — gestiona `owner`/`admin`/`member` vía `rpc_change_member_role`/`rpc_remove_member`, con el rol `admin` gateado a `billingPlan === "pro"` (no al esquema de 4 planes de `knowledge-base/03_actores_y_roles.md`, que promete "Roles internos: Básicos en Avanzado, Avanzados en Pro"). Usa el hook `useOrgRole` (lee `rpc_my_account_role`, con `initialData: user?.accountRole` — ya consume el claim `account_role` del JWT desde `v31-authz-token-hook`). El tipo `OrgRole` (`frontend/lib/types.ts:43`) es singular (`"owner" \| "admin" \| "member"`) y se referencia en **40 archivos** de frontend. | **Cambia el Scope de la Parte C** (§4): no es "crear una pantalla", es "migrar una pantalla en producción con usuarios reales" — mismo patrón de riesgo que el pivot de backend, a menor escala. La ruta/patrón de navegación (`/organizacion/roles`, enlazada desde `/organizacion/invitar` y desde `/configuracion`) debe preservarse para no romper accesos existentes. Los 40 archivos que consumen `useOrgRole`/`accountRole` son la superficie de migración frontend, análoga a los 65 call sites de `require_role` en el backend — **ninguno de los dos números** estaba dimensionado como "superficie de migración concreta" en julio. |
| 7 | Gating por plan de roles funcionales — pregunta abierta sin datos duros | Sin números de prod para argumentar ninguna opción | Medido hoy: `billing_plan` = `gratis` (36), `pro` (2), `inicial` (1), **`avanzado` (0)**. `billing_status` = `expired` (27, de los cuales 15 con `billing_exempt=true`), `trialing` (9), `active` (3, de las cuales 1 exenta). `plan_limits.max_users` = gratis:1, inicial:2, avanzado:5, pro:10. | Si el gating de roles funcionales se aplicara literalmente hoy (KB: básicos en `avanzado`, avanzados en `pro`), **0 cuentas** tendrían roles básicos y **2/39** tendrían el catálogo completo — coherente con que 0 cuentas tienen 2+ miembros de todos modos (nadie necesita un segundo rol si nadie invitó a un segundo usuario). El gating es una decisión comercial que hoy no tiene urgencia operativa medible, pero sigue siendo la promesa pública de `03_actores_y_roles.md`. |
| 8 | `deps.py:get_account_id` sin `ORDER BY` (no determinístico bajo multi-membresía) | Confirmado como bug latente (0 usuarios con 2+ cuentas) | **Corregido como parte de `v31-authz-token-hook` (D4)**: `backend/core/deps.py:27-30` ya tiene `ORDER BY created_at, id` — verificado hoy leyendo el archivo completo, con comentario explícito de que es el MISMO criterio que usa la migración del hook para resolver la cuenta activa al emitir `account_role`/`plan`. | Cerrado. El pivot puede asumir que la resolución de "cuenta activa" ya es determinística y coherente entre el hook (DB) y el resolver del backend — no hay que rediseñar esa pieza. |
| 9 | Placeholders del roadmap que dependen de este change | `v3-ai-agent-mcp-tools` era el único placeholder explícito bloqueado | Hoy son **al menos 4 changes futuros documentados** en `CHANGES.md` que se declaran explícitamente bloqueados o "construidos encima" de `v3-rbac-multirole`: `v4-seguridad-04`/`05` (maker-checker/aprobación dual, "construido explícitamente encima... no en paralelo"), `v4-ia-09`/`v3-ai-agent-mcp-tools` (tools de escritura del agente IA bloqueadas hasta sign-off), `v4-plataforma-01` (invitación masiva multiempresa — la porción de `expires_at` queda gateada), y menciones de sinergia en `v4-seguridad-09`/`v4-seguridad-05`. | El costo de **no** avanzar con al menos la Parte A creció desde julio: cada uno de estos 4 changes queda represado. Esto pesa a favor de desbloquear el modelo de datos (Parte A) aunque el uso real hoy sea cero — es la única pieza de infraestructura que los 4 changes futuros necesitan tocar primero. |

---

## 3. Estado medido de prod (agregados, sin PII)

Todas las queries corrieron read-only vía `mcp__supabase__execute_sql` (el servidor MCP conectado en este entorno es read-only — confirmado por convención del proyecto, ver `project_supabase_mcp_write_access` en engram). Ninguna consulta devolvió emails, `user_id` ni ningún identificador de persona — todo lo reportado abajo es agregado.

### 3.1 Membership y roles (`account_members`)

| Métrica | Valor |
|---|---|
| Total de filas (`account_members`) | 39 |
| Distribución por rol | `owner`: 39 (100%) — `admin`: 0 — `member`: 0 |
| Cuentas con exactamente 1 miembro | 39 (100%) |
| Cuentas con 2+ miembros | **0** |
| CHECK vigente sobre `role` | `CHECK ((role = ANY (ARRAY['owner','admin','member'])))` — sin cambios desde `20260606010000_roles_internos.sql` |
| Columnas de `account_members` | `id`, `account_id`, `user_id`, `role` (default `'member'`), `created_at` — sin `assigned_by`/`expires_at` |
| `account_member_roles` (tabla del pivot) | No existe (`to_regclass('public.account_member_roles')` → NULL) |
| `requires_second_approval` (gancho maker-checker) | No existe en ninguna tabla de `public` (0 columnas con ese nombre) |

### 3.2 Billing / plan (relevante para el gating de roles funcionales)

| `billing_plan` | Cuentas |
|---|---|
| `gratis` | 36 |
| `pro` | 2 |
| `inicial` | 1 |
| `avanzado` | 0 |

| `billing_status` × `billing_exempt` × tiene trial | Cuentas |
|---|---|
| `active`, no exenta, sin trial | 1 |
| `active`, no exenta, con trial | 1 |
| `active`, exenta | 1 |
| `expired`, no exenta, con trial | 12 |
| `expired`, exenta, con trial | 15 |
| `trialing`, no exenta | 9 |

`billing_plan.column_default` = `'gratis'` — confirma que el criterio de aceptación (b) de la ficha original ("gating de plan fail-closed, reemplazando el fail-open de 999999 para todos") **ya está satisfecho a nivel de default de columna**; no se verificó si algún camino de aplicación todavía asume `999999` en algún lugar no cubierto por este refresh (fuera de alcance de esta exploración, no se tocó código de billing).

### 3.3 Matriz FSM (`document_status_transitions`)

- 19 filas totales (6 `document_type`), **0 con `allowed_role` poblado** — completamente inerte, igual que julio (era 18/0).
- Enforcement de la FSM en sí (transición válida/inválida) **sí es real**: el trigger `BEFORE UPDATE` de `v31-fsm-status-triggers` está activo en las 6 tablas.

### 3.4 Enforcement de rol — quién ya usa qué

| Mecanismo | Estado verificado hoy |
|---|---|
| `require_role(auth, allowed)` (rol de **plataforma**, `profiles.role`) | 65 call sites en `backend/services/*.py` (grep `require_role(auth`) — sin cambios sustantivos desde julio (~66). Ninguno migrado al pivot todavía porque el pivot no existe. |
| `require_account_role(conn, auth, allowed)` (rol de **tenant**, nuevo desde `v31-authz-token-hook`) | 4 services lo usan hoy: `cost_centers.py`, `payment_methods.py`, `product_categories.py`, `account_charges.py`. Los 4 comparan únicamente contra `["owner","admin"]` — cero superficies comparan contra un rol funcional, porque no existen. |
| `is_account_writer(account_id)` / `current_account_ids()` (RLS) | Efectivos para el backend desde `v31-tenancy-pool-rls` (antes, el pool los bypaseaba). Siguen leyendo `account_members.role` legacy — **no** el pivot (que no existe). |
| `pg_roles.postgres.rolbypassrls` | `true` — sigue siendo el rol de **login** del pool (Paso 3 de `v31-tenancy-pool-rls`, "rol de login dedicado sin BYPASSRLS", **no ejecutado** — residuo documentado, no bloqueante porque la adopción por transacción ya mitiga el riesgo). |
| Frontend: `useOrgRole()` / `AuthContext.accountRole` (`OrgRole` singular) | 40 archivos de frontend referencian `useOrgRole`/`accountRole` — incluye pantallas de negocio (`ventas`, `compras`, `gastos`, `sucursales/[id]/stock`, `ventas/pos`) además de la propia pantalla de gestión de roles. |
| Pantalla `/organizacion/roles` | **Existe y está en producción** — gestión singular owner/admin/member, `admin` gateado a `billingPlan === "pro"` (no al esquema de 4 planes de la KB). |

### 3.5 Qué se puede afirmar con confianza vs qué queda como supuesto

**Verificado empíricamente en esta sesión** (no heredado sin re-chequear): los 8 valores de §3.1-3.3, el contenido completo de `guards.py`/`deps.py`/`auth.py`, la existencia y contenido de `/organizacion/roles/page.tsx` y `useOrgRole.ts`, el `rolbypassrls` de los 5 roles de Postgres relevantes, y los 65+4 call sites de `require_role`/`require_account_role` (por grep directo, no por memoria de julio).

**Heredado de julio y NO re-verificado en detalle en esta sesión** (se re-confirmó el resultado agregado, no se releyó cada línea de código): el mecanismo exacto de `SET LOCAL ROLE`/transacción explícita dentro de `get_db_conn` (se confirmó que las palancas están ON vía `pg_roles` y vía el archive de `v31-tenancy-pool-rls`, pero este refresh no releyó `backend/core/database.py` línea por línea); el detalle interno del trigger `BEFORE UPDATE` de `v31-fsm-status-triggers` (se confirmó que las 19 filas y el enforcement de FSM son reales por el comportamiento documentado en `CHANGES.md` y por la consulta a `document_status_transitions`, no por releer el trigger SQL). Si el próximo paso es escribir código sobre estas piezas, vale la pena una relectura puntual antes de tocarlas — este documento es suficiente para decidir alcance y secuencia, no para saltarse la lectura de implementación.

---

## 4. Alcance recomendado y su partición

Julio ya recomendaba trabajar en fases; este refresh mantiene esa idea pero la reordena a la luz de que **todos los prerequisitos técnicos ya cerraron** y de que la superficie frontend (hallazgo §2.6) ahora es explícita. Partición en 3 partes, cada una con su propia superficie frontend declarada (regla PO 2026-08-02: "todo change que produzca algo que un usuario deba ver u operar planifica su superficie desde el propose").

### Parte A — Modelo de datos: pivot multi-rol + expiración + auditoría

- Tabla `account_member_roles` (`member_id`, `role`, `assigned_by`, `assigned_at`, `expires_at`, `requires_second_approval` boolean default `false` — ver pregunta PO §6.4 sobre si vale la pena adelantarlo).
- Función `member_active_roles(member_id)` (o vista) — el índice parcial con `now()` no es válido en Postgres (predicado no inmutable), tal como ya documentó julio; sigue siendo cierto hoy.
- Backfill: 39 filas, `owner` → `OWNER`, trivial y sin ambigüedad (0 casos `admin`/`member` reales que preservar).
- `account_members.role` legacy: **no se dropea** — coexiste como snapshot histórico o se sincroniza por trigger (decisión de diseño, no crítica, igual que julio).
- **Aditivo puro**: si esta parte se corta acá (sin tocar `require_role`/`is_account_writer`/RLS), no cambia ningún comportamiento observable en prod. Es la parte de menor riesgo y la que más changes futuros desbloquea con menor esfuerzo.
- **Superficie frontend de esta parte sola**: ninguna nueva (los datos existen pero nada los lee todavía) — declarar explícitamente "sin superficie frontend" si se corta acá, tal como permite la regla PO cuando es una decisión y no un olvido.

### Parte B — Enforcement: migrar guards + RLS + FSM

- Migrar `require_role`/`require_account_role` (con Strangler Fig, tal como recomendaba julio) para leer `account_member_roles` en los 65+4 call sites relevantes de rol de **tenant** (no los de rol de **plataforma** — esos siguen leyendo `profiles.role`, sin relación con este change).
- Migrar `is_account_writer`/`current_account_ids` para que la RLS también lea el pivot — **coordinado en el mismo corte** que el punto anterior, o el backend (que ya adoptó `authenticated` de verdad desde `v31-tenancy-pool-rls`) y la RLS divergen: un usuario podría pasar el guard del backend pero ser bloqueado por RLS, o viceversa, durante la ventana de migración.
- Poblar `allowed_role` en las 19 filas de `document_status_transitions` (RN-A4) y hacer que `record_status_transition` lo valide — con el trigger `BEFORE UPDATE` ya activo, esto es enforcement real desde el día que se aplique, no un ejercicio de catálogo.
- Resolver el bloqueante de diseño de gating por plan (pregunta PO §6.2) **antes** de escribir el guard — cambia qué controla el catálogo de roles disponibles.
- Evolución del claim JWT: `account_role` (singular) se **conserva** como valor de compatibilidad derivado (el de mayor precedencia); nuevo claim `account_roles` (array, respetando `expires_at`) — contrato ya fijado por D2 de `v31-authz-token-hook`, no es una decisión nueva de este change, es una restricción heredada a cumplir.
- **Sin superficie frontend propia** más allá de que las pantallas que ya leen `accountRole`/`isWriter` (40 archivos) sigan funcionando sin romperse durante la transición — es un requisito de compatibilidad, no una pantalla nueva.

### Parte C — Superficie de administración de miembros

- **Extender** (no reemplazar desde cero) `frontend/app/(dashboard)/organizacion/roles/page.tsx`: de selector singular a asignación multi-rol con quién/cuándo/vencimiento. Mismo patrón de ruta (`/organizacion/roles`, enlazada desde `/organizacion/invitar` y `/configuracion`) para no romper accesos existentes.
- Actualizar `useOrgRole`/`OrgRole`/`AuthContext.accountRole` (40 archivos que los consumen) — decidir si las pantallas de negocio que solo necesitan "¿puedo escribir?" (`isWriter`) siguen funcionando con un derivado singular de precedencia más alta, o si migran a consultar el array completo. Recomendación: mantener `isWriter` como está (deriva de `accountRole` de compatibilidad) para las 40 pantallas existentes, y que solo la pantalla de gestión de roles en sí consuma el array completo — minimiza el churn.
- Verificación obligatoria en desktop y mobile, tema claro y oscuro, antes del merge (regla dura del proyecto).

**Orden y dependencias**: A puede arrancar apenas haya sign-off, sin esperar la decisión de gating por plan (§6.2) — es aditivo. B depende de A (necesita el pivot) y de que la pregunta de gating esté resuelta. C depende de A (necesita las RPCs de asignación) y puede avanzar en paralelo con el diseño de B, pero el enforcement real (qué puede hacer cada rol) solo tiene sentido una vez B esté cerrado — antes de eso, C sería una UI que asigna roles que nadie todavía respeta. Se puede diferir C un corte si el PO prioriza tener el modelo de datos y el enforcement antes que la UI de asignación (mientras tanto, `/organizacion/roles` legacy sigue sirviendo owner/admin/member, que es lo único que existe en prod hoy de todos modos).

**Governance por parte (modelo de gobernanza del orquestador — CRITICAL/HIGH/MEDIUM/LOW)**: Parte A es **HIGH** en la práctica más que CRÍTICO puro — toca un dominio de auth/tenencia pero es aditiva y no cambia ningún camino de autorización existente; aun así, dado que vive en la misma tabla que terminará gobernando dinero real, se recomienda tratarla con el mismo cuidado (proponer y esperar revisión antes de escribir, no autonomía plena). Parte B es **CRÍTICO** sin matices — cambia RLS y guards que hoy protegen ventas/compras/gastos/cuentas corrientes/caja de 39 cuentas reales; solo análisis hasta sign-off explícito, igual que dicta la ficha de `CHANGES.md`. Parte C es **MEDIO** — es UI de administración de miembros, no dinero directo, pero al escribir sobre roles que Parte B ya hace cumplir, sus decisiones no triviales (qué puede ver/editar cada rol en la pantalla misma) deben surfacearse al PO igual que cualquier lógica de negocio de esta franja.

### 4.1 Matriz rol × transición FSM (RN-A4) — reconfirmada sobre las 19 filas actuales

El bosquejo de julio (`openspec/explore/2026-07-30-v3-rbac-multirole.md` §5) sigue siendo el punto de partida correcto — nada de lo medido hoy lo invalida. La única fila nueva desde julio es `sales_order: confirmed → canceled` (18→19 filas), que julio ya anticipaba como "cuando exista una transición de anulación, esa fila deberá excluir a CASHIER explícitamente":

| `document_type` | `from → to` | Rol(es) propuestos | Nota |
|---|---|---|---|
| `sales_order` | `confirmed → canceled` | **ADMIN, OWNER** (no `CASHIER`) | Fila nueva desde julio. `CASHIER` cobra (`draft→confirmed`) pero RN-A4 explícita ("cobra pero no anula") excluye anular — anular una venta confirmada es una operación con impacto en caja/cta-cte/journal (reversión), no una acción de mostrador. |

El resto de la matriz (`quote`, `cash_session`, `reconciliation_session`, `fiscal_document`, `stock_transfer`) no tiene filas nuevas — se reconfirma el bosquejo de julio sin cambios. Las transiciones de sistema (`fiscal_document.*`, `quote.*→expired`) siguen sin actor humano y deben quedar exentas del chequeo de `allowed_role` (o resueltas contra un actor "sistema" explícito), tal como julio ya señalaba.

**Nota de diseño (pseudocódigo ilustrativo, no una propuesta de implementación)**: si `record_status_transition` empieza a validar `allowed_role` contra el actor, la forma más simple de no romper el relay CAE/cron es que el helper acepte un actor `NULL` (contexto de servicio) y lo trate como "sin restricción de rol" — análogo a como ya se exime a `get_service_conn` de los guards de usuario en `python-backend`:

```sql
-- Ilustrativo, no ejecutar:
IF p_actor_user_id IS NOT NULL THEN
  IF NOT (v_transition.allowed_role IS NULL
          OR p_actor_role = ANY(v_transition.allowed_role)) THEN
    RAISE EXCEPTION 'Rol insuficiente para esta transición' USING ERRCODE = 'P0403';
  END IF;
END IF;
```

---

## 5. Riesgos y modos de falla específicos

**R1 — Dejar a un owner sin permisos.** El pivot debe preservar el invariante que hoy protege `rpc_change_member_role` ("no se puede degradar al único owner", verificado en `20260606010000_roles_internos.sql`): con roles múltiples, la operación análoga es "no se puede quitar el rol `OWNER` de la única asignación `OWNER` activa de la cuenta". Una migración ingenua podría permitir revocar la fila `OWNER` del pivot dejando otras filas (p.ej. `ADMIN`) sin que ninguna transporte el mismo poder — hay que decidir explícitamente si `OWNER` sigue siendo un rol "supremo" con guard propio o si se convierte en un rol más del catálogo sin protección especial (ruptura de invariante).

**R2 — Expiración que corta acceso en medio de una operación.** `expires_at` se evalúa en el guard al inicio del request; una venta larga (POS con varios pasos, o un flujo async como el relay CAE) podría empezar con un rol válido y terminar después de que `expires_at` haya pasado. Julio ya señalaba esto como "M-ARQ-04"; este refresh no encuentra evidencia de que se haya resuelto en ningún change intermedio — sigue abierto. Decisión pendiente: ¿el guard se re-evalúa en cada paso de una operación multi-request, o solo al entrar? (recomendación: solo al entrar, documentando la ventana como aceptable — mismo principio que ya se usó para `expires_at` de invitaciones).

**R3 — Tokens con claims viejos hasta el refresh (hallazgo reforzado de este refresh, no solo heredado).** El guard `require_account_role` (`backend/core/guards.py:24-46`, leído completo) prioriza el claim del JWT sobre la DB: `if account_role is None: fallback a DB`. Esto significa que **una vez que el claim está presente, un cambio de rol en la base NO se refleja hasta que el token se refresca** — no es solo "el claim ausente cae a un default seguro" (eso ya lo maneja bien, fail-closed), es que **el claim presente pero desactualizado gana sobre la verdad actual de la DB**. Para un cambio de plataforma/tenant esto ya era cierto desde `v31-authz-token-hook` y se aceptó implícitamente; para el pivot multi-rol esto importa más porque los roles funcionales son más granulares y más propensos a cambiar seguido (un cajero que termina su turno, un contador externo cuyo acceso se revoca). Con roles múltiples en un claim `account_roles` (array), este mismo patrón se hereda tal cual salvo que se decida lo contrario explícitamente — ver pregunta PO §6.5.

**R4 — RLS vs guards del backend divergiendo durante la migración.** Si `is_account_writer`/`current_account_ids` (RLS) y `require_role`/`require_account_role` (guards del backend) no migran al pivot en el mismo corte, hay una ventana donde ambos caminos usan fuentes de verdad distintas (`account_members.role` legacy vs `account_member_roles` pivot) — desde que `v31-tenancy-pool-rls` hizo la RLS real para el backend, esta divergencia ya no es teórica: puede producir un 403 falso (RLS bloquea lo que el guard ya aprobó) o, peor, una autorización real donde debería haber un bloqueo (si el pivot cambia el rol pero la columna legacy queda desactualizada y algo todavía la lee).

**R5 — Migración del CHECK singular y doble fuente de verdad.** Si `account_members.role` se mantiene "congelada" en paralelo al pivot (recomendación de julio, ratificada acá), cualquier código nuevo que la lea directamente (como hoy hace el fallback DB de `require_account_role`, línea 27-30 de `guards.py`) queda leyendo un valor que puede divergir silenciosamente del pivot si no hay un trigger de sincronización — mismo patrón de riesgo que ya se resolvió explícitamente para otros pares legacy/nuevo en este proyecto (`products.category` TEXT vs `category_id`, resuelto con trigger espejo en `productos-categorias-sku`, luego retirado en `productos-categoria-text-retiro`). Recomendación: aplicar el mismo patrón (columna espejo por trigger mientras conviven, retiro en un change de limpieza posterior) en vez de dejarlas divergir sin garantía.

**R6 — Compatibilidad con `require_account_role` tal como existe hoy.** Su fallback a DB (`SELECT role FROM account_members WHERE user_id = auth.uid() ORDER BY created_at, id LIMIT 1`) asume una columna singular. El día que el pivot exista, ese fallback debe reescribirse en el **mismo PR** que crea la tabla — de lo contrario, cualquier usuario sin el claim `account_role` en su token (sesión vieja, previa al refresh) cae a un fallback que lee una columna que puede ya no ser la fuente de verdad.

**R7 — Cero uso real como superficie de prueba.** Con 0/39 cuentas con 2+ miembros, todo el enforcement multi-rol se probará por primera vez con datos sintéticos o con la primera cuenta real que invite a un segundo usuario — no hay tráfico real hoy contra el cual comparar un "antes/después", a diferencia de otros changes recientes de este roadmap que pudieron medir impacto contra volumen real. Mitigación sugerida: que el PO cree una segunda membresía de prueba en una cuenta de test (no en una cuenta real con datos de un cliente) antes de dar por buena la parte B.

**R8 — Efecto sobre las 40 pantallas de frontend que ya leen `accountRole`/`isWriter`.** El comentario en `useOrgRole.ts` documenta explícitamente que hoy es "fail-OPEN" a propósito (cualquier estado que no sea `member` confirmado se trata como escritor, para no bloquear falsamente a un owner por un estado transitorio). Si la Parte C cambia la forma del dato (de rol singular a array), hay que preservar ese mismo principio de fail-open del lado del cliente (la barrera real sigue siendo RLS + guard del backend) — un cambio de forma sin cuidado podría convertir accidentalmente ese fail-open en un fail-closed que bloquea a un owner real por una condición de carga.

**Rollback por parte**: A es reversible sin pérdida de datos (tabla nueva, aditiva — se puede dejar de leer y la columna legacy sigue siendo la fuente de verdad). B es el más delicado — revertir requiere volver a leer `account_members.role` en los guards/RLS migrados, posible sin pérdida de datos si R5 se resolvió con columna espejo sincronizada. C es un revert de frontend estándar (git revert de la pantalla), sin estado persistente que limpiar salvo que ya se hayan asignado roles múltiples reales, en cuyo caso quedan en la tabla pero simplemente no se muestran hasta re-desplegar la UI vieja.

---

## 6. Preguntas para el sign-off del PO

**6.1 — ¿Se avanza pese al hallazgo de cero cuentas con más de un miembro hoy?**
- (a) Sí, tal como está planificado — la inversión es para el futuro cercano y desbloquea 4 changes represados (maker-checker, tools de escritura del agente IA, invitación multiempresa).
- (b) Solo la Parte A (modelo de datos, aditivo) por ahora; B y C se posponen hasta que exista evidencia de uso real de equipos.
- (c) Posponer todo el change hasta que al menos una cuenta real tenga 2+ miembros.
- **Recomendación: (a) o (b)** — el costo de la Parte A es bajo (aditivo, sin cambio de comportamiento) y desbloquea el roadmap represado; si el PO quiere ser conservador con el riesgo de enforcement (Parte B), (b) es razonable sin perder el desbloqueo.

**6.2 — Gating por plan de roles funcionales (heredada de julio, ahora con números reales).**
- (a) Gating estricto según la tabla comercial de `03_actores_y_roles.md` (básicos en `avanzado`, avanzados en `pro`) — hoy afectaría 0 cuentas con roles básicos y 2/39 con el catálogo completo.
- (b) Todos los roles disponibles en todos los planes; el gating comercial es solo de cantidad de usuarios (ya existe vía `plan_limits.max_users`).
- (c) Gating parcial: catálogo completo disponible, pero `expires_at` (rol temporal) solo en planes pagos.
- **Sin recomendación fuerte** (decisión comercial, no técnica) — pero con el dato nuevo de que aplicar (a) literalmente hoy no le quita nada a nadie en la práctica (0 cuentas con 2+ miembros para empezar), por lo que el riesgo de "romper" algo real con el gating estricto es bajo ahora mismo.

**6.3 — ¿Extender `/organizacion/roles` (ya existe) o reemplazarla?**
- (a) Extender en el lugar, preservando ruta y patrón de navegación (recomendado — evita romper los enlaces existentes desde `/organizacion/invitar` y `/configuracion`).
- (b) Ruta nueva, deprecar la vieja.
- **Recomendación: (a)**.

**6.4 — Gancho `requires_second_approval` (maker-checker, M-SEC-13) — ¿ahora o diferido?**
- (a) Agregar la columna boolean ahora en el DDL del pivot (costo marginal bajo), sin lógica — como recomendaba julio.
- (b) Diferir por completo a `v4-seguridad-04`/`05`, que hoy ya existe como change futuro propio "construido explícitamente encima de `v3-rbac-multirole` (no en paralelo)" y va a necesitar diseñar la semántica real de todos modos.
- **Cambio de recomendación respecto de julio**: dado que `v4-seguridad-04`/`05` ya está identificado como un change separado con su propio diseño pendiente, **(b)** es defendible ahora — adelantar la columna ya no evita una "segunda migración destructiva" tan claramente, porque ese change futuro probablemente necesita su propia migración de todos modos (más columnas, tablas de aprobaciones, etc.). Si el PO prefiere el costo mínimo de una columna vacía por si acaso, (a) sigue siendo válido.

**6.5 — Staleness del claim de rol (R3): ¿aceptable como está, o se refuerza?**
- (a) Aceptar la ventana de staleness hasta el refresh del token como riesgo conocido — mismo criterio ya aceptado implícitamente para `account_role` desde agosto.
- (b) Forzar que el guard **siempre** consulte la DB para roles funcionales sensibles (p.ej. remover a un cajero), sacrificando el beneficio de performance del claim solo para esos casos.
- (c) Acortar el TTL del JWT de Supabase a nivel de plataforma (afecta a todos los usuarios y todos los claims, no solo rol).
- **Recomendación: (a)**, documentado explícitamente como riesgo aceptado — igual que ya es el caso hoy para `account_role`; (b) agrega complejidad y costo de latencia en el hot path para un escenario de baja frecuencia (revocar acceso a un empleado), (c) es una decisión de plataforma más amplia que no debería decidirse solo por este change.

**6.6 — Orden de ejecución (todos los prerequisitos técnicos ya cerraron; la única secuencia que falta decidir es interna a este change).**
- **Recomendación**: Parte A primero (sign-off cubre las 3 partes, pero A puede aplicarse apenas se firme) → resolver 6.2 antes de escribir Parte B → Parte B → Parte C (puede solaparse con el diseño de B, pero su enforcement real depende de que B esté cerrado).

**6.7 — Catálogo de roles: ¿aprobar tal cual (`OWNER/ADMIN/SELLER/CASHIER/STOCK/PURCHASES/ACCOUNTANT/VIEWER`)?**
- Sin evidencia nueva desde julio que sugiera cambios. **Recomendación: aprobar tal cual**, salvo que el PO tenga señales de campo no documentadas.

---

## 7. Non-goals y qué NO hacer hasta el sign-off

- **No crear** la tabla `account_member_roles` ni ninguna migración — este documento es análisis, no propuesta ni apply.
- **No tocar** `backend/core/guards.py`, `backend/core/deps.py`, `is_account_writer`/`current_account_ids`, ni ningún RLS policy.
- **No modificar** `frontend/app/(dashboard)/organizacion/roles/page.tsx` ni `useOrgRole.ts` — quedan documentados como "a extender", no extendidos.
- **No poblar** `allowed_role` en `document_status_transitions`.
- **No agregar** la columna `requires_second_approval` en ningún lado — queda como pregunta abierta (§6.4), no como hecho consumado.
- **No ejecutar** el "Paso 3" de `v31-tenancy-pool-rls` (rol de login dedicado sin `BYPASSRLS`) — es un residuo de un change ya archivado, mencionado acá solo porque es contexto relevante para R4, no porque este change deba tocarlo.
- **No iniciar** `v3-ai-agent-mcp-tools`, `v4-seguridad-04`/`05`, ni la porción de `expires_at` de `v4-plataforma-01` — siguen bloqueados hasta que este change tenga su propio sign-off y, en el caso de maker-checker, probablemente hasta que exista además su propio diseño.
- Cualquier consulta a prod en este documento fue **read-only**, agregada, sin exponer emails, `user_id` ni ningún identificador de persona.

---

## 8. Referencias

- `openspec/explore/2026-07-30-v3-rbac-multirole.md` — documento completo (análisis original, 348 líneas).
- `CHANGES.md:1550-1572` — gap-analysis Modelo V3 vs código (fila §5 RBAC).
- `CHANGES.md:1658-1679` — ficha completa de `v3-rbac-multirole` (scope, dependencias, estado de cada prerequisito).
- `CHANGES.md:908` — dependencia de `v3-ai-agent-mcp-tools`.
- `CHANGES.md:1268` — OQ-3 de `banco-caja-historial-ajustes` gateada a este change.
- `CHANGES.md:1866, 1905` — estado "prerequisito SATISFECHO" y verificación de `v31-authz-token-hook`.
- `CHANGES.md:2359-2388, 2490, 2546-2558, 2704-2715, 2800-2814, 2830, 2980, 3043` — changes futuros del roadmap V4 que dependen o sinergizan con este change (maker-checker, agente IA con tools, multiempresa, cuello de botella de ruta crítica).
- `modelo-dominio-aliadata-v3.md:195-238` (§5 RBAC enriquecido) — catálogo de roles, `RoleAssignment`, decisión de catálogo cerrado y global.
- `knowledge-base/03_actores_y_roles.md:64-84, 140-142` — tabla comercial de 4 planes con "Roles internos: ❌/❌/Básicos/Avanzados"; "Futuros roles" sin implementar.
- `backend/core/guards.py` (archivo completo, 55 líneas) — `require_role`, `require_plan`, `require_account_role` (líneas 24-46), `require_platform_admin`.
- `backend/core/deps.py` (archivo completo, 34 líneas) — `get_account_id` con `ORDER BY created_at, id`.
- `backend/core/auth.py:1-40` — `AuthContext` TypedDict, contrato normativo de las 4 claves.
- `backend/services/cost_centers.py`, `payment_methods.py`, `product_categories.py`, `account_charges.py` — los 4 call sites reales de `require_account_role` (grep, líneas exactas en el cuerpo del documento §2 fila 3).
- `supabase/migrations/20260606010000_roles_internos.sql` (archivo completo) — CHECK singular, `is_account_writer`, `rpc_change_member_role`, `rpc_remove_member`, `rpc_my_account_role`, `rpc_invite_member`, `rpc_accept_invitation`.
- `frontend/app/(dashboard)/organizacion/roles/page.tsx` (archivo completo, 247 líneas) — pantalla legacy ya en producción.
- `frontend/hooks/useOrgRole.ts` (archivo completo) — lectura de `account_role`, comentario "fail-OPEN" explícito.
- `frontend/lib/types.ts:43, 49, 293` — tipo `OrgRole` singular, `AuthContext.accountRole`.
- Queries de prod (read-only, `mcp__supabase__execute_sql`): conteo por rol de `account_members`; distribución de miembros por cuenta; `pg_get_constraintdef` del CHECK; columnas de `account_members`; columnas de `accounts`; distribución `billing_plan`/`billing_status`/`billing_exempt`/trial; conteo total y poblado de `allowed_role` en `document_status_transitions`; filas completas de `document_status_transitions`; `to_regclass('account_member_roles')`; conteo de columnas `requires_second_approval`; `pg_roles` (BYPASSRLS/superuser/canlogin) de `postgres`/`authenticator`/`authenticated`/`service_role`/`anon`; `plan_limits.max_users`.
- Engram: observación #507 (explore original, 2026-07-30), #557 (session summary del cluster completo, 2026-08-01), #550 (apply de `v31-authz-token-hook`, con el detalle del guard y el D4 de `deps.py`), #841 (archive de `v31-authz-token-hook`), #755 (archive de `v31-tenancy-pool-rls`).
