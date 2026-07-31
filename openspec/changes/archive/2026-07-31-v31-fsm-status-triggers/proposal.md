## Why

`v3-document-status-history` (2026-07-03) modeló la FSM de documentos como datos en `document_status_transitions` (18 filas, 6 tipos de documento) y puso la validación dentro de `record_status_transition`. Pero esa validación **solo corre si alguien la llama**: es una convención entre RPCs bien portados, no una restricción de la base.

Quien haga un `UPDATE` directo de la columna `status` se salta la FSM entera. No es hipotético — hoy hay dos caminos reales que lo hacen:

1. **`quotes` tiene policy de `UPDATE` para `authenticated`** (`quotes_update`, migración `20260702000001`), así que un `PATCH` vía PostgREST desde el browser puede escribir cualquier `status` que pase el `CHECK` de la columna, sin pasar por el catálogo ni dejar rastro en el historial.
2. **`backend/repositories/quote_repository.py:125` hace ese `UPDATE` directo** (`UPDATE public.quotes SET status = $2`) para las transiciones `send`/`reject`/`expire`, validando contra un diccionario Python (`backend/services/quotes.py:22-26`) que es una **tercera** definición de la FSM, divergente tanto del catálogo en la base como de la spec de `quote`.

Y el backup que debería atajar esto tampoco existe: el pool del backend conecta como `postgres` con `rolbypassrls = true` (H-05, verificado en prod 2026-07-30), de modo que **RLS es inerte para el backend**. Un trigger, en cambio, corre igual para `postgres`, para `service_role` y para `authenticated` — es la única barrera que hoy aplica a todos los caminos de escritura por igual.

Mientras la matriz sea evadible, poblar `allowed_role` en `v3-rbac-multirole` (RN-A4) produciría enforcement **de papel**: reglas del tipo "CASHIER cobra pero no anula" que se saltan con un `UPDATE`. Por eso este change va **antes**, y por eso es el paso 2 de la secuencia firmada por el PO el 2026-07-30.

## What Changes

- **Trigger `BEFORE UPDATE` de validación** en las 6 tablas de documento del catálogo (`quotes`, `sales_orders`, `fiscal_documents`, `cash_sessions`, `reconciliation_sessions`, `stock_transfers`). Rechaza con `P0409` todo cambio de `status` cuyo par `(document_type, from, to)` no esté en `document_status_transitions`.
- **Una sola función genérica** parametrizada por `document_type` vía argumento del trigger — la lógica de validación no se duplica por tabla, y reutiliza `is_valid_transition()` en vez de reimplementarla.
- **El trigger solo valida; no registra.** El historial sigue siendo responsabilidad exclusiva de `record_status_transition`, invocado por los RPCs de negocio. La justificación está en `design.md` (D1) — no es una omisión, es la decisión que evita duplicar filas en una tabla append-only irreparable.
- **El trigger no dispara cuando `status` no cambia** (`WHEN (OLD.status IS DISTINCT FROM NEW.status)`), de modo que los `UPDATE` de otras columnas sobre documentos terminales siguen funcionando.
- **Sin mecanismo de bypass en runtime.** No se agrega ningún GUC de excepción; el único escape sancionado es deshabilitar el trigger explícitamente dentro de una migración (`ALTER TABLE ... DISABLE TRIGGER`), que exige ownership y queda visible en la revisión del PR. Justificación en `design.md` (D4).
- **Gates de comportamiento en la migración**, siguiendo el patrón ya usado por `v3-document-status-history` y `bank-reconciliation`: estructurales siempre, comportamentales solo sobre base vacía (CI), de modo que el gate de `validate-kpis` verifique que el trigger efectivamente rechaza una transición no catalogada y deja pasar una válida.
- **Migración idempotente y re-ejecutable** (`CREATE OR REPLACE FUNCTION` + `DROP TRIGGER IF EXISTS` antes de cada `CREATE TRIGGER`): la integración GitHub de Supabase auto-aplica al mergear, antes del `db push` de Actions.

Sin **BREAKING**: se verificó que las cinco transiciones que los caminos vigentes ejecutan (`quote draft→sent|expired`, `quote sent→rejected|expired|accepted`, `sales_order draft→confirmed`, `cash_session open→closed`, `reconciliation_session open→closed`, `fiscal_document pending_cae→authorized|rejected`) están todas en el catálogo. Ningún flujo de producción cambia de resultado.

## Capabilities

### New Capabilities

Ninguna.

### Modified Capabilities

- `document-status-history`: se agrega el enforcement estructural de la política de transiciones. Hasta hoy la spec declara el catálogo como datos y la validación dentro del helper de escritura, pero NO exige que la política sea inevadible: un `UPDATE` directo de `status` la elude por completo. El delta agrega ese requisito, delimita explícitamente la responsabilidad del guard frente a la del registrador, y fija que el guard aplica a todo escritor incluidos los roles que ignoran RLS.

## Impact

- **Base de datos**: una migración nueva en `supabase/migrations/` — función `trg_enforce_status_transition()` + 6 triggers `BEFORE UPDATE`. No crea ni altera tablas, no toca RLS, no toca ningún RPC, no toca el `CHECK` de `operation_idempotency.operation_kind`.
- **Código de aplicación**: ninguno. Backend y frontend no cambian. El `ERRCODE P0409` elegido ya está mapeado a HTTP 409 por los manejadores de error existentes (p. ej. `backend/services/quotes.py::_map_postgres_error`), así que un rechazo del trigger se traduce solo.
- **CI**: los gates de la migración corren en el job `validate-kpis` (`.github/workflows/KPI_Validation.yml`) sobre la base local recién reseteada.
- **Governance**: **ALTO**. Es un trigger de integridad sobre todas las tablas de documento: un error puede bloquear operaciones de negocio reales (ventas, caja, CAE). No toca auth ni dinero directamente, pero se implementa proponiendo primero y con la migración revisada antes del merge; las tareas de compatibilidad (verificar el catálogo contra los caminos vigentes y contra los datos de prod) son bloqueantes.
- **Cluster**: paso 2 de la secuencia del 2026-07-30. Prerequisito de secuencia para la matriz rol×transición (RN-A4) de `v3-rbac-multirole`. **La matriz rol×transición NO está en este change** — acá solo se hace inevadible la matriz de transiciones que ya existe.
