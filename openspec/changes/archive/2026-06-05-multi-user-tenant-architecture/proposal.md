## Why

Los cuatro planes comerciales venden **múltiples usuarios por cuenta** (Gratis=1, Inicial=2, Avanzado=5, PRO=10 — RN-03/RN-07), pero hoy cada fila de `auth.users` es un tenant totalmente independiente: las 20+ tablas de negocio están scopeadas por `user_id = auth.uid()` directamente, sin ningún concepto de "cuenta" u "organización" compartida. Sin una capa de tenant no se puede entregar la promesa comercial central de los planes pagos, y es el **BLOQUEO MAYOR** del roadmap: C-06 (roles internos), C-07 (sucursales) y C-08 (stock multisucursal) dependen de que exista primero el concepto de membresía multi-usuario.

Esta capability **sienta la base de tenant + membresía**. No implementa roles diferenciados (eso es C-06) ni sucursales (C-07): solo introduce el tenant, migra los 26 usuarios de producción a su propia cuenta sin pérdida de datos, y deja el scoping de RLS listo para compartir datos dentro de una cuenta gated por `plan_limits.max_users`.

## What Changes

- **Nuevo modelo de tenant (aditivo)**: tablas `accounts` (la cuenta/organización) y `account_members` (membresía usuario↔cuenta con un rol mínimo `owner`/`member`). Se reutiliza la infraestructura de billing existente: `accounts.billing_plan` pasa a ser la fuente de verdad del plan **a nivel cuenta** (hoy vive en `profiles`).
- **Columna `account_id` aditiva** en todas las tablas de datos de negocio (`products`, `sales`, `purchases`, `expenses`, `clients`, `stock_movements`, `units_of_measure`, `operation_idempotency`, `ai_insights`, `ai_conversations`, `fair_recommendations`, `invoice_documents`, `invoice_suppliers`, `product_aliases`, `posts`, `replies`, `course_progress`). `user_id` se **conserva** como "creado por" (autoría/auditoría); `account_id` se vuelve el eje de scoping.
- **Backfill 1:1 no destructivo**: cada uno de los 26 usuarios de producción se vuelve `owner` de su propia `account` recién creada (una cuenta por usuario), y todas sus filas existentes reciben el `account_id` de esa cuenta. Cero pérdida de datos, conteos de filas preservados.
- **Migración incremental de RLS** de `auth.uid() = user_id` a "el usuario pertenece a la cuenta de la fila" (`account_id IN (SELECT account_id FROM account_members WHERE user_id = (SELECT auth.uid()))`), vía una función helper `current_account_ids()` para no romper performance ni el patrón initplan.
- **Enforcement de `max_users`**: invitaciones de miembros gated por `plan_limits.max_users` del plan efectivo de la cuenta (tabla `account_invitations` + RPC de aceptación con guard de límite).
- **BREAKING (interno, no de API pública)**: el plan deja de ser estrictamente per-`profile` y pasa a ser per-`account`. La capability `plan-gating` (C-02) deberá leer el plan efectivo desde la cuenta del usuario, no desde su `profiles` individual. Se documenta como capability modificada.

> **Gobernanza CRÍTICA**: este change toca RLS de TODAS las tablas con datos de 26 usuarios reales en producción. Estos artefactos son **análisis + propuesta**. La implementación (`/opsx:apply`) **NO** se ejecuta sin aprobación humana explícita por bloque, según los gates definidos en `tasks.md` y la sección "Decisiones que requieren aprobación humana" de `design.md`.

## Capabilities

### New Capabilities
- `multi-tenant`: Modelo de cuenta/organización (`accounts`), membresía (`account_members`), invitaciones gated por plan (`account_invitations` + RPC), backfill 1:1 de usuarios existentes, y la migración del scoping de RLS de per-usuario a per-cuenta en todas las tablas de negocio.

### Modified Capabilities
- `plan-gating`: La determinación del plan efectivo y de los límites de recursos pasa a resolverse **a nivel cuenta** (el plan vive en `accounts`, no en `profiles`). Los contadores compartidos (operaciones/mes, productos, clientes) se cuentan por cuenta, no por usuario. Se introduce un nuevo límite enforced: `max_users` (cantidad de miembros activos de la cuenta).

## Impact

- **DB / Migraciones**: 1 migración aditiva grande (o serie de migraciones por bloque) — nuevas tablas, columnas `account_id`, backfill, función helper `current_account_ids()`, y reescritura de policies RLS de ~18 tablas. Todas idempotentes (`IF NOT EXISTS`, `ON CONFLICT`), siguiendo el patrón de la migración C-01.
- **RPCs**: las RPCs de operaciones atómicas (`rpc_create_operation_aggregate`, RPCs de stock, idempotencia, safe-delete) deben sellar `account_id` y validar pertenencia a la cuenta, no solo `user_id`.
- **Tipos / Frontend**: `lib/types.ts` (`User` gana `accountId`/`role` de cuenta; nuevo tipo `Account`, `AccountMember`), `lib/plan-utils.ts` (plan efectivo desde la cuenta), `hooks/auth/*` (contexto de cuenta activa), `contexts/auth-context.tsx`.
- **Auth / Sesión**: el login debe resolver la cuenta activa del usuario (y, a futuro, permitir pertenecer a más de una cuenta — fuera de alcance de C-05, que asume 1 cuenta por usuario tras el backfill).
- **Riesgo de seguridad**: una policy RLS mal migrada puede **filtrar datos entre cuentas** o **bloquear el acceso del dueño a sus propios datos** en producción. Mitigado con migración por bloques, branch de Supabase, y verificación humana antes de cada apply.
- **Prior art sin resolver**: existe un segundo proyecto Supabase (`pudaxiwqhwsxuaofsqda`, hoy PAUSADO) con un schema multi-tenant más avanzado (`companies`, `company_users`, `warehouses`, etc.). La reconciliación (portar ese schema vs. diseñar fresco) es una **Open Question** que requiere input humano antes de implementar — ver `design.md`.
