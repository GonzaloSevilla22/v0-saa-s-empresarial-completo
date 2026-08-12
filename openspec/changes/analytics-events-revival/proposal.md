## Why

Los KPIs de producto (activación, UMV, retención 30d, MAU, distribución de uso semanal) miden ruido: las rutas **modernas** de escritura de operaciones no emiten `analytics_events`. Verificado 2026-08-11 (hallazgo F5 de `docs/plan-remediacion-kpis-2026-08-11.md`):

- `backend/` (FastAPI) tiene **cero** referencias a `analytics_events`. Gastos: `use-expenses-query.ts` → `POST /expenses` → `expense_repository.py:22-37` INSERT directo, sin telemetría.
- Ventas: `rpc_create_sale_operation` (path vivo desde C-29, `20260721000001`) **no** emite. Las RPCs que sí emitían (`20260228000101_rpc_sales`, `20260228000102_rpc_purchases`, `20260228000302_fix_sale_rpc`, `20260424000004_phase3_variant_guard_rpcs`) quedaron fuera del path vivo.
- El **único** emisor de `operation_created` / `first_operation` que sigue corriendo es el legacy `frontend/lib/supabase/services.ts:70-93` (`createExpense`), que la UI ya no usa.

Los consumidores en cambio siguen vivos y exigen esos eventos: `rpc_admin_kpi_overview` y `rpc_admin_retention_30d` (`20260309000003`), `rpc_admin_business_kpis` (activación + MAU, `20260228000400`), `rpc_admin_weekly_usage_distribution`, y la detección de UMV dentro de `rpc_create_insight` (`20260629000001_unify_insights.sql:133`, que exige `operation_created` para marcar `umv_reached`). Resultado: **la UMV — la métrica central de `knowledge-base/01_vision_y_objetivos.md` — nunca se dispara para usuarios de las rutas modernas**, y activación/retención cuentan sólo el residuo legacy.

Es prerequisito de valor de C-KPI-5 (`admin-kpi-refresh`): sin telemetría real, arreglar los paneles admin es pulir un cero.

## What Changes

- **Choke point único a nivel DB**: función de trigger `analytics_emit_operation_event()` (`SECURITY DEFINER`, `search_path = public`) + triggers `AFTER INSERT FOR EACH ROW` en `sales`, `purchases` y `expenses`. Toda ruta de escritura (FastAPI, RPCs v2, RPCs legacy, SQL directo, futuros importadores) emite uniforme sin duplicar lógica por consumidor.
- Cada INSERT de operación emite `operation_created`; el primero de cada usuario emite además `first_operation`.
- **degrade-don't-fail obligatorio**: el bloque de telemetría va envuelto en `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING … END`. Un fallo de la telemetría **nunca** aborta la venta/compra/gasto (precedente exacto: el seed de `handle_new_user` en `20260812000001`).
- **Deduplicación estructural** (no por `EXISTS`, que corre carrera bajo concurrencia):
  - índice único parcial sobre `(user_id) WHERE event_name = 'first_operation'` → una activación por usuario, garantizada por el motor;
  - índice único parcial sobre `(event_name, (event_data->>'entity_id')) WHERE event_name = 'operation_created' AND event_data ? 'entity_id'` → una operación = un evento, aunque una RPC legacy también emita o se reintente.
  - Ambos con `ON CONFLICT DO NOTHING` en el emisor. Requiere una limpieza previa idempotente de duplicados históricos de `first_operation` (conservando el más antiguo) antes de crear el índice.
- **Tenancy del evento**: `analytics_events` hoy sólo tiene `user_id`. Se agrega `account_id uuid` (nullable, FK `accounts` `ON DELETE CASCADE`) poblado por el trigger desde la fila de operación, más índice `(account_id, created_at)`. Aditivo: ningún consumidor actual lo referencia, y habilita KPIs por tenant para C-KPI-5 sin volver a tocar el schema.
- **Backfill histórico** derivado de `sales`/`purchases`/`expenses` — **condicionado al sign-off del PO (OQ-2)**. Marcado `event_data->>'source' = 'backfill'` y deduplicado contra los eventos legacy existentes. La emisión NO depende de esta decisión.
- **Gates SQL de comportamiento** en `supabase/tests/` (corren en el workflow `KPI_Validation.yml` con `-v ON_ERROR_STOP=1`): operación insertada → evento emitido; transacción abortada → sin evento huérfano; excepción del trigger → la operación sobrevive; segunda operación del mismo usuario → un solo `first_operation`; INSERT ejecutado como rol `authenticated` → evento igualmente emitido (verifica que el `REVOKE` sobre la función no rompe el trigger).
- **Sin superficie frontend**: es infraestructura de telemetría. Los paneles que la consumen (`/admin`, `frontend/lib/adminAnalytics.ts`) ya existen y no cambian su contrato. Declarado explícitamente por la regla PO 2026-08-02.

## Capabilities

### New Capabilities
- `product-analytics-events`: contrato de emisión de telemetría de producto — qué eventos se emiten, desde qué choke point, con qué payload y tenancy, y bajo qué garantías (atomicidad con la operación, degradación sin abortar, unicidad de `first_operation`).

### Modified Capabilities
- `insights`: se agrega un requirement que fija por escrito la dependencia hoy implícita — la detección de `umv_reached` dentro de `rpc_create_insight` sólo funciona mientras exista un emisor vivo de `operation_created`, y ese emisor pasa a ser el choke point de DB. La lógica de `rpc_create_insight` no cambia; lo que cambia es que su precondición vuelve a cumplirse.

## Impact

- **Nueva migración** `supabase/migrations/20260914000001_analytics_events_revival.sql` (timestamp posterior a `20260913000001_critical_stock_by_branch.sql`), idempotente y both-worlds-safe: la integración GitHub de Supabase auto-aplica al mergear ANTES del `db push` de Actions.
- **Schema**: `analytics_events` gana `account_id` + 3 índices (2 únicos parciales, 1 compuesto). Sin DROP, sin BREAKING.
- **Funciones nuevas**: `public.analytics_emit_operation_event()` (trigger-only). Gotcha del proyecto: `DROP`+`CREATE` resetea ACLs → `REVOKE ALL … FROM PUBLIC, anon, authenticated` re-aplicado en el mismo archivo. Es interna (nunca se llama como RPC), por lo que revocar `authenticated` es seguro; el gate de comportamiento como rol `authenticated` lo prueba.
- **Triggers nuevos**: `trg_analytics_operation_created` en `sales`, `purchases`, `expenses`. Costo por operación: 1-2 INSERTs adicionales en la misma transacción, sobre índices ya existentes (`idx_analytics_events_user`, `idx_analytics_events_name`, `idx_analytics_events_created_at`).
- **Consumidores** (sin cambios de código, empiezan a ver datos reales): `rpc_admin_kpi_overview`, `rpc_admin_business_kpis`, `rpc_admin_retention_30d`, `rpc_admin_weekly_usage_distribution`, `rpc_create_insight` (UMV).
- **Código legacy**: `frontend/lib/supabase/services.ts:70-93` queda como emisor redundante; el índice único por `entity_id` no lo desduplica (usa la clave `expense_id`, no `entity_id`). Se resuelve retirando su emisión en el mismo change — la telemetría pasa a ser responsabilidad exclusiva de la DB.
- **CI**: `.github/workflows/KPI_Validation.yml` suma el nuevo archivo de gates.
- **Governance**: MEDIO. No toca dinero, auth ni datos de negocio; el peor caso de un bug es telemetría faltante, nunca una operación perdida (garantizado por el `EXCEPTION` handler y probado por gate).
