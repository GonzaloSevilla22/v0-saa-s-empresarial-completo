## Why

"Facturar" sobre una venta cargada a mano en `/ventas` devolvía **500 desde que nació** (PR #242, 2026-06-27): `rpc_promote_legacy_sale_to_order` agregaba `MIN(s.account_id)` / `MIN(s.branch_id)` / `MIN(s.client_id)` sobre columnas `uuid`, y el agregado `min(uuid)` no existe ni en local ni en prod → `42883 function min(uuid) does not exist` en **cada** llamada (N2). Nadie lo vio en tres meses porque ningún gate SQL ejecutaba la RPC y el test de backend mockeaba asyncpg. Arreglar N2 **reabre** la carrera N1 que dejó declarada `venta-editable-sin-cae` (#582): la edición/borrado resuelven "¿hay orden que anular?" sin lock mientras la promoción crea la orden en OTRA transacción, y queda un comprobante `pending_cae` VIVO por los importes viejos (4/4 interleavings en el red team de #582). El estudio encontró además N3: la edición re-apuntaba la orden a la operación nueva sin recalcularle total, cliente ni líneas, así que "Volver a facturar" y el "Facturar" de una venta del POS editada emitían por el importe VIEJO. El PO aprobó el pedido el 2026-09-23 ("ok").

## What Changes

- **N2** — la promoción toma la cabecera de la **primera fila por `id`** (determinístico, sin `MIN(uuid)`), valida **homogeneidad** de cliente/sucursal/cuenta de TODAS las filas (`P0422 operation_inconsistent` / `P0404`), y calcula el total por **cabecera** (`round(Σ sales.total, 2)`, una línea por fila de `sales`) — la fórmula viva sobre `LEFT JOIN sale_items` habría facturado al DOBLE las 2 operaciones de prod con `sale_items` duplicados (H2).
- **N1** — exclusión anclada en lo único que existe antes de la orden: las **filas de `sales` de la operación**, `FOR UPDATE` en orden de `id`, tomadas PRIMERO por la promoción, la edición y el borrado. Orden global único de locks `sales → sales_orders → fiscal_documents → resto`; la emisión sólo lee `sales` (sin ciclo posible).
- **N3** — la edición recalcula la orden que re-apunta con un helper único (`_sales_order_sync_from_operation`, `SECURITY INVOKER`, cerrado a `anon`/`authenticated`) compartido con la promoción.
- **D6** — `rpc_emit_sale_invoice` rechaza fail-closed (`P0409 sales_order_out_of_sync`) una orden que no coincide con su venta; la promoción en *replay* la re-sincroniza si no tiene comprobante vivo (salida del usuario: tocar "Facturar" otra vez).
- Backend: `POST /sales/{operation_id}/promote-to-order` valida el id como `uuid` (422) y un `sqlstate` sin mapear deja de filtrar el texto de Postgres (500 genérico problem+json).
- **Superficie frontend** (ruta `/ventas`, entrada de menú "Ventas" existente): en la fila expandida de una venta cargada a mano, "Facturar" prepara la venta y el segundo paso pasa a llamarse **"Emitir comprobante"**; la fila pasa sola a "En trámite (esperando CAE)" con el número y a "Autorizado por AFIP" por Realtime; si la emisión falla, la fila vuelve a "Facturar". Mensajes rioplatenses para `operation_inconsistent`, `operation_empty`, `operation_not_found`, `sales_order_out_of_sync`, `sales_order_not_found` y la venta borrada; el texto crudo de Postgres nunca llega al toast.
- Sin ERRCODEs nuevos (se reusan `P0400`/`P0404`/`P0409`/`P0422` con tokens nuevos). Firmas idénticas (`CREATE OR REPLACE`, sin overload). COMMENT vivos conservados.

## Capabilities

### New Capabilities

(ninguna)

### Modified Capabilities

- `sales-order`: la promoción legacy cambia su cabecera (primera fila + homogeneidad), su total (por cabecera) y su idempotencia (bajo lock de las filas, con resync en el replay); se agrega la exclusión promoción ⟷ edición/borrado y el flujo "Facturar → Emitir comprobante" del listado de ventas.
- `operation-edit-context`: la orden re-apuntada por la edición se recalcula (total, cliente, sucursal y líneas); la edición y el borrado toman las filas de la operación antes de resolver su orden.
- `afip-fiscal-document`: la emisión rechaza una orden que no coincide con su venta (`P0409 sales_order_out_of_sync`).

## Impact

- Migración `supabase/migrations/20261061000001_venta_editable_vs_promocion_legacy.sql` (governance **CRÍTICO**, dominio fiscal): reescribe desde el cuerpo VIVO de prod `rpc_promote_legacy_sale_to_order`, `rpc_atomic_update_sale_operation`, `rpc_delete_sale_operation` y `rpc_emit_sale_invoice`; crea `_sales_order_sync_from_operation(uuid, uuid, uuid)`. Sin backfill (0/124 órdenes confirmadas desincronizadas en prod, 0 comprobantes de venta).
- Gates nuevos: `supabase/tests/test_facturar_venta_manual.sql` (el primero que EJECUTA la promoción) y `supabase/tests/test_facturar_venta_manual_race.sh` (dos conexiones, 6 interleavings × 20); `test_function_acl_gate.sql` cierra el helper nuevo. Cableados en `KPI_Validation.yml`.
- Backend: `backend/routers/sales.py`, `backend/services/sales.py` (+ tests unitarios y un test de integración real marcado `integration`).
- Frontend: `components/ventas/sale-operations-list.tsx`, `components/fiscal/EmitInvoiceButton.tsx`, `components/fiscal/FiscalDocumentBadge.tsx`, `hooks/data/use-promote-to-order.ts`, `hooks/data/use-sales-orders.ts`; arnés `app/dev-harness/facturar-venta`; e2e `e2e/facturar-venta-manual.spec.ts` y `e2e/harness/facturar-venta-visual.spec.ts` (`E2E_Tests.yml` suma un `RELAY_SECRET` descartable).
