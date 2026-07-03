## Why

Hoy las máquinas de estado de los documentos (`quotes`, `sales_orders`, `fiscal_documents`, `cash_sessions`, `stock_transfers`, `reconciliation_sessions`) viven implícitas en `CHECK (status IN (...))` por tabla, sin transiciones válidas declaradas ni historial de cambios de estado. El `AuditLog` genérico (vía outbox) responde "algo cambió" pero no la pregunta de auditoría más frecuente en un ERP: **"¿quién confirmó esta venta, cuándo pasó a facturada, y por qué se anuló?"** El modelo V3 §2 eleva esto a patrón transversal: una FSM declarada como datos (`StatusTransitionPolicy`) + un historial append-only genérico (`document_status_history`) escrito en la misma transacción que la transición. Este change lo implementa.

Además, este change es **prerequisito de la matriz rol×transición** de `v3-rbac-multirole` (RN-A4): la política de transiciones se diseña con la dimensión `role` estructurada desde ahora, para que RBAC la active después sin migración disruptiva.

## What Changes

- **Tabla nueva `document_status_history`** genérica y append-only: `(id, account_id, document_type, document_id, from_status, to_status, performed_by, reason, occurred_at)`. RLS **sin políticas de INSERT/UPDATE/DELETE** para el rol `authenticated` (RN-A3 enforzado con grants, no por convención): solo SELECT por `account_id`; la escritura ocurre exclusivamente desde los RPCs `SECURITY DEFINER`.
- **`StatusTransitionPolicy` como datos**, no `if`s dispersos: una tabla catálogo `document_status_transitions` (mapa de transiciones válidas por `document_type`, con `is_terminal` y `requires_reason` por estado destino) + funciones helper `is_valid_transition(document_type, from, to)`, `is_terminal_status(document_type, status)`, `transition_requires_reason(document_type, to)`. La columna `allowed_role` queda **estructurada pero permisiva** (`NULL` = cualquier rol) para que `v3-rbac-multirole` la pueble sin migración disruptiva.
- **Helper `SECURITY DEFINER` `record_status_transition(...)`** que, en una sola llamada: valida la transición contra la policy (RN-A4 estructural), exige `reason` cuando la policy lo pide (RN-A5), e inserta la fila de historial. Se invoca **dentro de la misma transacción** de cada RPC que cambia estado (RN-A1).
- **Retrofit de los RPCs existentes** que cambian estado para que pasen por `record_status_transition`, sin cambiar la semántica de negocio:
  - `rpc_accept_quote` (quote `draft|sent → accepted`)
  - `_c29_confirm_order_core` (sales order `draft → confirmed`)
  - `rpc_close_cash_session` (cash session `open → closed`, con `reason` en diferencia de arqueo)
  - `rpc_close_reconciliation_session` (reconciliation `open → closed`)
  - la creación de documentos registra la primera entrada con `from_status = NULL` (RN-A2)
  - la ruta de emisión/relay del CAE (`fiscal_documents` `pending_cae → authorized|rejected`)
- **Seed del catálogo de transiciones** con las FSMs vigentes hoy en los CHECKs (fuente de verdad = las tablas reales, no el ideal del roadmap): Quote `draft→sent→accepted|expired|rejected`; SalesOrder `draft→confirmed|canceled`; FiscalDocument `pending_cae→authorized|rejected`; CashSession `open→closed`; Reconciliation `open→closed`; StockTransfer `completed` (terminal, transferencia atómica — sin transiciones aún).
- **UI: timeline "línea de tiempo del documento"** en el detalle de venta/presupuesto/factura (componente `DocumentTimeline` server-fetched, App Router + shadcn/ui).

**Fuera de alcance (explícito):**
- El **enforcement por rol** de RN-A4 (la matriz cashier-no-anula-factura): la columna `allowed_role` se crea y queda permisiva; poblarla y validarla es trabajo de `v3-rbac-multirole`. Este change deja la estructura lista, no la activa.
- Nuevas transiciones que hoy no existen (ej. `sales_order → canceled` no tiene RPC; `stock_transfer` `dispatched/received`; `fiscal_document → credited` por NC): el catálogo modela solo lo que las tablas permiten hoy. Agregar transiciones nuevas es scope de sus propios changes.
- Migrar la escritura a backend Python: el hot path sigue en RPCs SQL `SECURITY DEFINER` (decisión registrada — equivalente del UoW).
- Backfill retroactivo del historial de documentos ya existentes (sin transición histórica registrable; el historial arranca vacío y se llena hacia adelante).

## Capabilities

### New Capabilities
- `document-status-history`: el patrón transversal — la tabla append-only `document_status_history`, la `StatusTransitionPolicy` como datos (catálogo `document_status_transitions` + helpers), el helper `record_status_transition` con validación + `reason` obligatorio, las reglas RN-A1..A5, y la dimensión `allowed_role` estructurada (permisiva) para RBAC futuro.

### Modified Capabilities
- `quote`: `rpc_accept_quote` y la creación del presupuesto registran la transición de estado en `document_status_history` (RN-A1/A2).
- `sales-order`: `_c29_confirm_order_core` registra la transición `draft → confirmed`; la creación registra `from_status = NULL`.
- `cash-session`: `rpc_close_cash_session` registra `open → closed` con `reason` cuando hay diferencia de arqueo (RN-A5).
- `afip-fiscal-document`: la ruta de emisión/relay del CAE registra `pending_cae → authorized|rejected`; la creación del pending registra `from_status = NULL`.
- `bank-reconciliation`: `rpc_close_reconciliation_session` registra la transición `open → closed`.

## Impact

- **DB / migraciones**: una migración SQL nueva (`supabase/migrations/`) con: `CREATE TABLE document_status_history` + RLS solo-SELECT + grants; `CREATE TABLE document_status_transitions` (catálogo) + seed; helpers de policy y `record_status_transition` (`SECURITY DEFINER`); `CREATE OR REPLACE FUNCTION` de los RPCs de transición vigentes (partiendo del cuerpo más reciente de cada uno). CI aplica a prod al mergear a main (nunca a mano ni MCP).
- **RPCs retrofiteados (governance MEDIO)**: `rpc_accept_quote`, `_c29_confirm_order_core`, `rpc_close_cash_session`, `rpc_close_reconciliation_session`, ruta de emisión CAE. El único delta permitido es agregar la llamada a `record_status_transition` en la misma transacción; no se altera stock, caja, idempotencia ni el CHECK de `operation_idempotency.operation_kind`.
- **Frontend**: nuevo componente `DocumentTimeline` (Server Component) + hook/query de TanStack para el historial; se inserta en el detalle de venta/presupuesto/factura.
- **Knowledge base**: `knowledge-base/05_reglas_de_negocio.md` (reglas RN-A1..A5 en la sección "Dominio: Modelo V3 (retrofit)"); `CHANGES.md` (estado del change tras el archive).
- **Prerequisito de**: `v3-rbac-multirole` (la matriz rol×transición usa `document_status_transitions.allowed_role`).
- **Respeta**: RLS org-based (helpers `is_account_writer`, `current_account_ids`); RN-97 (no construye sobre columnas planas en retirada); append-only enforzado por grants (no por convención).
