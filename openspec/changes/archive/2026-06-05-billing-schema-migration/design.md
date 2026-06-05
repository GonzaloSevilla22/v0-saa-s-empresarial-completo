# Design — billing-schema-migration

## Context

- **Stack:** Next.js 16 + React 19 + TypeScript + Supabase (Postgres + RLS) + Vercel.
- **Estado actual:** `profiles.plan TEXT DEFAULT 'pro'` con solo dos valores (`'free'`/`'pro'`); beta migration `20260424000001` forzó a todos a `'pro'`. Tracking de IA en una sola columna `insights_used` + `insights_reset_at`.
- **Objetivo:** preparar el schema para los 4 planes comerciales (RN-03) sin activar gating todavía (eso es C-02) y sin romper a los usuarios beta.
- **Governance:** CRÍTICO. La migración toca datos de plan de usuarios reales → analizar y proponer; aplicar solo con aprobación humana explícita.

## Goals / Non-Goals

**Goals**
- Modelar 4 tiers comerciales en el schema de forma aditiva y reversible.
- Centralizar los límites por plan en una tabla (`plan_limits`) en vez de hardcodear.
- Separar el uso de IA en dos contadores (Consultas vs Consejos).
- Dejar la base para trial de 60 días, estado de suscripción y billing externo futuro.
- Audit trail de cambios de plan (`billing_events`).
- Backfill seguro de usuarios existentes preservando su ventana de gracia.

**Non-Goals (explícitamente fuera de este change)**
- Activar gating/bloqueos por límite → C-02 (`plan-gating-engine`).
- Lógica de vencimiento de gracia y downgrade automático → C-03 (`grace-period-logic`).
- Reset mensual de contadores vía pg_cron y wiring de Edge Functions → C-04 (`ai-usage-counters-split`).
- Pasarela de pago real (Stripe/MercadoPago) y webhooks → C-10 (`subscription-ui-upgrade-flow`).
- Concepto de `organizations`/tenant → C-05 (`multi-user-tenant-architecture`).

## Key Decisions

### D1 — Nueva columna `billing_plan` en lugar de redefinir `profiles.plan`
**Decisión:** introducir `billing_plan TEXT` con `CHECK (billing_plan IN ('gratis','inicial','avanzado','pro'))` y dejar la columna legacy `plan` intacta.
**Por qué:**
- La columna `plan` actual tiene `'pro'` para todos los usuarios beta y es referenciada por código y migrations existentes (`20260424000001`). Reescribir su dominio en caliente es riesgoso sobre datos productivos.
- Una columna nueva es **aditiva** → la migración no puede romper lecturas existentes. C-02 puede leer `billing_plan` y, una vez estable, una migración futura puede deprecar `plan`.
- `CHECK` constraint en vez de un `ENUM` nativo de Postgres: agregar valores a un enum requiere `ALTER TYPE ... ADD VALUE` (no transaccional en algunas versiones) y complica rollbacks; un CHECK sobre TEXT es trivial de modificar.
**Trade-off aceptado:** coexisten dos columnas de plan temporalmente. Se documenta que `billing_plan` es la fuente de verdad de aquí en adelante; `plan` queda como legacy a deprecar.

### D2 — `plan_limits` como tabla seed (fuente de verdad de límites)
**Decisión:** crear `plan_limits` con una fila por plan y una columna por límite, sembrada con los valores de RN-03.
**Por qué:** evita hardcodear límites en TS; C-02 hace `SELECT * FROM plan_limits WHERE plan = $1`; cambiar un límite comercial = un `UPDATE`, sin deploy de código.
**Columnas (todas NOT NULL salvo flags booleanos con default):**
`plan` (PK, CHECK 4 valores), `price_monthly NUMERIC(12,2)`, `max_users INT`, `max_products INT`, `max_clients INT`, `max_suppliers INT`, `max_operations_per_month INT`, `history_days INT`, `max_exports_per_month INT`, `max_ai_queries_per_month INT`, `max_ai_advice_per_month INT`, `max_branches INT`, `has_product_profitability BOOL`, `has_comparative_reports BOOL`, `has_price_suggestion BOOL`, `internal_roles TEXT` (`'none'|'basic'|'advanced'`), `has_branches_module BOOL`, `has_monthly_analysis BOOL`.
**Historial:** se modela en días (`history_days`): gratis=30, inicial=365, avanzado=730, pro=1825 (5 años). Mantiene un solo tipo numérico comparable en queries de C-12.

### D3 — RLS de `plan_limits`: lectura pública, escritura admin
**Decisión:** `SELECT` permitido a `anon` y `authenticated` (los precios/límites son información pública de la landing); `INSERT/UPDATE/DELETE` solo para `role = 'admin'`.
**Por qué:** la página `/planes` (C-10) y el gating cliente necesitan leer límites sin fricción; la escritura es operación de plataforma.
**Patrón de policy (best practice Supabase):** usar `(select auth.uid())` envuelto para evitar llamada por fila; el chequeo de admin via subquery a `profiles`.

### D4 — Split de contadores de IA con backfill
**Decisión:** agregar `ai_queries_used` y `ai_advice_used`; backfill `ai_queries_used = COALESCE(insights_used, 0)`; mantener `insights_used` por compatibilidad (no se dropea en este change).
**Por qué:** RN-05 separa Consultas IA (insights/predicción/resumen/simulador/copiloto) de Consejos IA (fair-advisor). El rename/limpieza final de `insights_used` y el wiring de Edge Functions ocurre en C-04 — aquí solo se prepara el terreno de forma no destructiva.

### D5 — Trial de 30 días para usuarios nuevos; beta existentes van directo a Avanzado
**Decisión (confirmada por usuario 2026-06-05):**
- **Usuarios existentes (beta):** `billing_plan = 'avanzado'`, `billing_status = 'trialing'`, sin `trial_expires_at` (se define en C-03 cuando se active el billing real).
- **Usuarios nuevos:** `billing_plan = 'gratis'` (permanente) + `trial_plan = 'avanzado'` + `billing_status = 'trialing'` + `trial_expires_at = NOW() + INTERVAL '30 days'`. Al vencer, acceden solo a los límites de `gratis`.
- Se agrega columna **`trial_plan TEXT`** (nullable, CHECK 4 valores) para que C-02 sepa a qué plan corresponde el trial sin hardcodear 'avanzado'.
**Por qué:** RN-02 (actualizado a 30 días) distingue el plan base permanente del plan de prueba. La **lógica de vencimiento/downgrade es C-03**. Aquí solo se persisten los datos para que C-03 los consuma.

### D6 — `billing_events` inmutable (audit trail)
**Decisión:** tabla append-only `billing_events(id, user_id, event_type, from_plan, to_plan, reason, metadata JSONB, created_at)`. RLS: el usuario lee los propios; escritura solo vía `service_role`/admin (sistema). Sin UPDATE/DELETE para usuarios.
**Por qué:** dominio CRÍTICO de billing exige trazabilidad. La migración inserta un evento `migration_backfill` por usuario afectado.

### D7 — Tipos en TS alineados, fetch dinámico diferido a C-02
**Decisión:** en `lib/types.ts` definir `Plan`, `BillingStatus`, `PlanLimits`; en `lib/constants.ts` dejar las constantes de los 4 planes (mismos valores que el seed de `plan_limits`). El fetch en runtime desde `plan_limits` (hook `usePlanLimits`) es C-02.
**Por qué:** mantener constantes y seed sincronizados evita drift; el código no debe leer la DB para tipar.

## Estándares aplicados (skill-registry)

- **TIMESTAMPTZ, no TIMESTAMP** en todas las columnas datetime nuevas (`trial_started_at`, `trial_expires_at`, `usage_reset_at`, `created_at` de tablas nuevas).
- **Índices** en FKs y columnas de filtro: `plan_limits.plan` (PK), `billing_events.user_id`, `billing_events.created_at`, índice en `profiles.billing_plan` y `profiles.trial_expires_at` (los usará C-03 para el barrido de vencimientos).
- **RLS con `(select auth.uid())`** envuelto para evitar el problema de initplan (RN-83).
- **Upsert / seed idempotente:** el seed de `plan_limits` usa `INSERT ... ON CONFLICT (plan) DO UPDATE` para que re-correr la migración sea seguro.
- **`SET search_path = public`** en cualquier función nueva (RN-82). Este change no introduce funciones nuevas obligatorias.
- Tras aplicar: correr `supabase db advisors` (security + performance) y regenerar tipos.

## Risks / Trade-offs

- **R1 — Migración sobre datos productivos (CRÍTICO).** Mitigación: migración 100% aditiva (sin DROP/ALTER destructivo de columnas existentes), backfill idempotente, probada primero en branch de Supabase. Rollback = drop de columnas/tablas nuevas.
- **R2 — Drift entre `plan_limits` (DB) y `lib/constants.ts` (código).** Mitigación: una sola tabla de valores en `design.md` como fuente; C-02 hará que el runtime lea de DB y las constantes queden solo como fallback/tipos.
- **R3 — Doble columna de plan (`plan` legacy + `billing_plan`).** Mitigación: documentar `billing_plan` como única fuente de verdad; planificar deprecación de `plan` en un change posterior.
- **R4 — `insights_used` duplicado con `ai_queries_used`.** Aceptado temporalmente; C-04 hace la limpieza/rename definitivo.

## Decisiones que requieren aprobación humana (Governance CRÍTICO)

✅ **Todas resueltas el 2026-06-05:**

1. **Estrategia de columna (D1):** → **Nueva columna `billing_plan`** (aditiva). No se altera el ENUM existente.
2. **Estado inicial de usuarios beta:** → `billing_plan = 'avanzado'`. `trial_started_at = created_at`.
3. **Default de `billing_plan` para nuevos usuarios:** → `'gratis'` + `trial_plan = 'avanzado'` + 30 días de prueba (`trial_expires_at = NOW() + 30 days`).
4. **Mapeo del campo legacy `plan`:** → Se mantiene intacto por compatibilidad, se marca `@deprecated` en tipos TS. Se retira en una fase futura cuando no haya referencias activas.

## Migration Plan

1. Crear branch de Supabase (no aplicar directo a producción).
2. Migración aditiva: nuevas columnas en `profiles` + tablas `plan_limits` y `billing_events` + índices + RLS.
3. Seed idempotente de `plan_limits` (4 filas, valores RN-03).
4. Backfill de `profiles`: setear `billing_plan`, `billing_status`, `trial_started_at/expires_at`, `ai_queries_used`, `usage_reset_at`; insertar `billing_events` tipo `migration_backfill`.
5. Verificar: 0 usuarios con `billing_plan` NULL; 4 filas en `plan_limits`; usuarios beta en `billing_plan='pro'`.
6. `supabase db advisors` (security + performance) → resolver warnings.
7. Regenerar tipos TS; actualizar `lib/constants.ts` y `lib/types.ts`.
8. Revisión humana → merge del branch.

## Open Questions

- ¿Nombre final de la capability de spec: `billing`? (asumido `billing`).
- ¿Se versiona `insights_reset_at` a `usage_reset_at` o conviven? (este change agrega `usage_reset_at`; el rename de `insights_reset_at` se deja a C-04).
