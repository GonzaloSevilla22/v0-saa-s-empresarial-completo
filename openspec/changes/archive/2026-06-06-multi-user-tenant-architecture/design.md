## Context

Hoy cada `auth.users` es un tenant aislado: las ~18 tablas de negocio scopean por `user_id = auth.uid()`. Los planes comerciales (C-01) venden 1/2/5/10 usuarios por cuenta, pero no existe el concepto de cuenta compartida. C-05 introduce el tenant + membresía y migra el scoping de RLS, sin perder datos de los 26 usuarios en producción.

C-01 ya dejó `plan_limits.max_users` sembrado (gratis=1, inicial=2, avanzado=5, pro=10). C-02 dejó `lib/plan-utils.ts` (`getEffectivePlan`, `planHasAccess`) y `usePlanLimits`. C-05 reusa esa infraestructura, moviendo el plan de `profiles` a `accounts`.

## Goals / Non-Goals

**Goals**
- Modelo de cuenta (`accounts`) + membresía (`account_members`).
- Backfill 1:1 no destructivo: cada usuario actual → owner de su propia cuenta.
- Columna `account_id` aditiva en todas las tablas de negocio; `user_id` se conserva como autoría.
- Migración de RLS de per-usuario a per-cuenta vía helper `current_account_ids()`.
- Invitaciones de miembros gated por `plan_limits.max_users`.
- `plan-gating` (C-02) lee el plan efectivo desde la cuenta.

**Non-Goals**
- Roles internos diferenciados (owner/admin/member con permisos) → C-06.
- Sucursales / warehouses → C-07. Stock multisucursal → C-08.
- Un usuario perteneciendo a MÚLTIPLES cuentas (C-05 asume 1 cuenta por usuario tras el backfill; el schema lo permite a futuro pero la UI no).
- UI de gestión de equipo completa → se entrega lo mínimo (invitar/aceptar); el panel rico es follow-up.

## Decisions

### D1 — Nombres: `accounts` + `account_members` (no `companies`/`company_users`) ✅ RESUELTO
**Decisión**: usar `accounts` y `account_members` en el proyecto de producción. Diseño fresco.
**Por qué**: el otro proyecto (`pudaxiwqhwsxuaofsqda`) usa `companies`/`company_users`, pero quedó **inaccesible para ambas partes** (2026-06-05): no está en la org Supabase del usuario (API lo da como "not found", sin restore posible) y el usuario no tiene acceso al dashboard. Es un Supabase autogenerado por v0.dev, nunca usado (0 usuarios), huérfano. **O1 se resuelve por descarte: no se puede portar un schema que no se puede leer.** Se diseña fresco.
**Trade-off**: se descarta el trabajo previo de ese schema. Aceptado — era inaccesible y sin validar.

### D2 — `account_id` aditivo, `user_id` se conserva
**Decisión**: agregar `account_id uuid REFERENCES accounts(id)` a cada tabla de negocio. NO se elimina `user_id` — pasa a significar "creado por" (autoría/auditoría). El scoping de RLS migra a `account_id`.
**Por qué**: aditivo = la migración no rompe lecturas existentes durante la transición. El historial de "quién creó qué" se preserva (relevante para C-06 roles y auditoría).
**Tablas afectadas**: `products`, `sales`, `purchases`, `expenses`, `clients`, `stock_movements`, `units_of_measure`, `operation_idempotency`, `ai_insights`, `ai_conversations`, `fair_recommendations`, `invoice_documents`, `invoice_suppliers`, `product_aliases`, `course_progress`. (`posts`/`replies` son comunidad global, NO se scopean por cuenta — siguen per-usuario con gating de plan de C-02.)

### D3 — Helper `current_account_ids()` para RLS performante
**Decisión**: crear una función SQL `current_account_ids() RETURNS SETOF uuid` que devuelve las cuentas del usuario actual:
```sql
CREATE OR REPLACE FUNCTION public.current_account_ids()
RETURNS SETOF uuid
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public
AS $$ SELECT account_id FROM account_members WHERE user_id = (SELECT auth.uid()) $$;
```
Las policies pasan de `user_id = (select auth.uid())` a `account_id IN (SELECT current_account_ids())`.
**Por qué**: encapsula la lógica de membresía en un solo lugar; `STABLE` permite que el planner la cachee por query (evita el problema initplan). `SECURITY DEFINER` con `search_path` fijo para que pueda leer `account_members` sin exponer esa tabla por RLS recursivo.
**Gotcha**: `account_members` debe tener su propia policy que NO dependa de `current_account_ids()` (evitar recursión) — se scopea por `user_id = (select auth.uid())` directo.

### D4 — Backfill 1:1: un usuario, una cuenta
**Decisión**: por cada `profiles` existente, crear una `account` (owner = ese usuario), insertar `account_members(account_id, user_id, role='owner')`, y `UPDATE` todas sus filas seteando `account_id`. El `accounts.billing_plan` se copia desde `profiles.billing_plan`.
**Por qué**: preserva exactamente el estado actual (cada quien sigue viendo solo lo suyo), pero ahora a través de la capa de cuenta. Conteos de filas idénticos antes/después.
**Backfill de `account_id`**: `UPDATE products p SET account_id = am.account_id FROM account_members am WHERE p.user_id = am.user_id AND am.role='owner'` (y equivalente por tabla).

### D5 — Plan a nivel cuenta; `plan-gating` lee desde `accounts`
**Decisión**: `accounts.billing_plan`, `accounts.billing_status`, `accounts.trial_*` se vuelven la fuente de verdad. `profiles.billing_plan` queda como legacy (deprecated, sincronizado en el backfill). `getEffectivePlan` y `usePlanLimits` reciben la cuenta activa.
**Por qué**: el plan se vende por cuenta, no por persona. Si una cuenta PRO tiene 10 miembros, los 10 acceden a features PRO.
**Límites compartidos**: productos, clientes, operaciones/mes se cuentan por `account_id`, no por `user_id`.

### D6 — Invitaciones: `account_invitations` + RPC con guard de `max_users`
**Decisión**: tabla `account_invitations(id, account_id, email, token, status, invited_by, created_at, expires_at)`. RPC `rpc_accept_invitation(token)` que: valida token, cuenta miembros activos de la cuenta, compara contra `plan_limits.max_users` del plan efectivo, y si hay cupo inserta en `account_members`.
**Por qué**: el enforcement de `max_users` debe ser server-side (RPC `SECURITY DEFINER`), no confiable en cliente. Una cuenta gratis (max=1) no puede invitar; una PRO (max=10) admite hasta 9 invitados además del owner.

### D7 — RPCs de operaciones sellan `account_id`
**Decisión**: `rpc_create_operation_aggregate` y las RPCs de stock/idempotencia reciben/derivan `account_id` (de la cuenta activa del caller) y lo sellan en las filas creadas, validando que el caller pertenece a esa cuenta.
**Por qué**: si solo sellan `user_id`, las filas nuevas quedarían sin `account_id` y serían invisibles bajo la nueva RLS. Crítico para no romper el alta de ventas/compras post-migración.

## Estándares aplicados (skill-registry)

- **supabase-postgres-best-practices**: índices en `account_id` de cada tabla (scoping column); `(select auth.uid())` envuelto; `current_account_ids()` `STABLE`; TIMESTAMPTZ; migraciones idempotentes (`ADD COLUMN IF NOT EXISTS`, `ON CONFLICT`).
- **supabase**: `TO authenticated` + USING de pertenencia juntos; UPDATE policies con USING+WITH CHECK; `account_members` policy directa (no recursiva); `current_account_ids()` es el único SECURITY DEFINER justificado (encapsula membresía).
- **Reglas duras**: migraciones SIEMPRE via `npx supabase db push` (NUNCA MCP apply_migration); NUNCA `any` en TS; conventional commits.

## Risks / Trade-offs

- **R1 — Fuga de datos entre cuentas (CRÍTICO)**: una policy mal migrada expone datos de otra cuenta. Mitigación: migrar RLS tabla por tabla, cada una con un test de aislamiento (usuario A no ve datos de cuenta B) ANTES de pasar a la siguiente. Branch de Supabase para probar.
- **R2 — Owner pierde acceso a sus propios datos**: si el backfill de `account_id` falla en alguna fila, queda huérfana e invisible. Mitigación: aserción post-backfill de que 0 filas tienen `account_id IS NULL` en cada tabla; conteos pre/post idénticos.
- **R3 — RPCs sin `account_id` rompen el alta**: ventas/compras nuevas quedarían invisibles. Mitigación: D7 + test de alta E2E post-migración.
- **R4 — Recursión en RLS de `account_members`**: si su policy usa `current_account_ids()` se cuelga. Mitigación: policy directa por `user_id` (D3 gotcha).
- **R5 — Performance**: `account_id IN (SELECT ...)` en cada query. Mitigación: índice en `account_id`, función `STABLE`, índice en `account_members(user_id)`.

## Decisiones que requieren aprobación humana (Governance CRÍTICO)

Antes de **aplicar** (cada bloque de `tasks.md`):
1. ~~**O1 — Reconciliación con `pudaxiwqhwsxuaofsqda`**~~ ✅ RESUELTO (2026-06-05): el proyecto quedó inaccesible para ambas partes (huérfano de v0.dev, sin acceso). Se diseña fresco con `accounts`/`account_members` (D1). Decisión tomada por descarte.
2. **D1/D2 — Nombres de tablas y estrategia aditiva**: confirmar `accounts`/`account_members` + `account_id` aditivo vs alterar el modelo existente.
3. **Orden de migración de RLS**: confirmar la estrategia tabla-por-tabla con verificación humana entre bloques (vs. una migración monolítica).
4. **Ventana de aplicación**: la migración de RLS sobre datos productivos debe correrse en una ventana acordada (riesgo de bloqueo de acceso temporal).

## Migration Plan (por bloques, con gate humano entre cada uno)

1. **Bloque A — Tablas de tenant** (aditivo, sin tocar RLS existente): `accounts`, `account_members`, `account_invitations` + RLS propias + `current_account_ids()`.
2. **Bloque B — Backfill**: crear 1 cuenta por usuario, membership owner, copiar plan. Verificar conteos.
3. **Bloque C — Columna `account_id`**: `ADD COLUMN account_id` a las ~15 tablas + índices + backfill de `account_id` por tabla. Verificar 0 NULLs.
4. **Bloque D — Migración de RLS** (tabla por tabla, con test de aislamiento entre cada una).
5. **Bloque E — RPCs**: sellar `account_id` + validar pertenencia.
6. **Bloque F — Frontend/tipos**: `Account`, `AccountMember`, contexto de cuenta activa, `plan-gating` lee de cuenta.
7. **Bloque G — Invitaciones**: RPC + UI mínima de invitar/aceptar.

## Open Questions

- **O1 (bloqueante)**: reconciliar con el schema multi-tenant del otro proyecto Supabase, o diseñar fresco. Requiere despausar `pudaxiwqhwsxuaofsqda`.
- **O2**: ¿un usuario podrá pertenecer a más de una cuenta a futuro? El schema lo soporta (`account_members` N:N) pero la UI de C-05 asume 1. Definir si se expone un selector de cuenta activa.
- **O3**: ¿qué pasa con `posts`/`replies` de comunidad — siguen siendo globales per-usuario (confirmado en D2) o se quiere atribución por cuenta? Asumido: global per-usuario.
- **O4**: al invitar un usuario que YA tiene su propia cuenta (del backfill), ¿se le crea una membership adicional o se migra? Definir en C-06.
