## Why

Una venta cargada a mano en `/ventas` (modelo legacy `sales` / `sale_operation`) **no se puede facturar a AFIP**: la facturación opera sobre `sales_orders` (V2.1) y la carga manual nunca crea esa fila. El PO confirmó (2026-06-27) que el caso "cargo a mano y después facturo" es real y vale resolverlo. El botón "Enviar al ARCA" que hoy existe en `/ventas` emite un comprobante **huérfano** (vía `POST /fiscal/documents/emit`, sin `sales_order` asociada): no reconcilia contra una orden, no setea `sales_orders.fiscal_document_id`, no deriva el receptor de la identidad fiscal del cliente de la orden y rompe el modelo canónico V2.1. Hay que cerrar la asimetría **bien**: materializando el objeto fiscal canónico (`SalesOrder`) a partir de la venta legacy y reusando el flujo `emit-invoice` de C-27.

Decisión de diseño tomada y razonada en `openspec/explore/2026-06-27-promote-legacy-sale-to-order.md` (Opción C — promoción lazy), descartando la Opción B (unificar el write-path) por sus 4 gaps: backdating (el core clava `CURRENT_DATE`), `sales_orders` sin columna `date`, editabilidad (legacy mutable vs SalesOrder inmutable) y sesión de caja para ventas pasadas.

## What Changes

- **Nueva RPC `rpc_promote_legacy_sale_to_order(p_operation_id uuid)`** (`SECURITY DEFINER`, **side-effect-free**): materializa una `SalesOrder` con `status='confirmed'` a partir de una venta legacy ya existente. Reconstruye `sales_order_items` desde `sale_items` (fallback al header plano `sales.product_id/quantity/amount` vía `COALESCE` para ventas pre-backfill); resuelve `branch_id = COALESCE(sales.branch_id, c26_default_branch(account_id))`; setea `sale_operation_id = p_operation_id` y `total = Σ subtotales`. Devuelve el `sales_order_id`.
- **La promoción NO pasa por `_c29_confirm_order_core`**: NO descuenta `branch_stock` (ya se descontó al crear la venta), NO registra caja (`cash_movement`), NO emite el outbox `SaleConfirmed`. Es **materialización fiscal, no una venta nueva** — pasar por el core doble-contaría stock y dispararía un asiento contable fantasma vía el Consumer 3 del outbox (V2.5 journal-entry).
- **Idempotencia** vía índice único parcial `sales_orders(sale_operation_id) WHERE sale_operation_id IS NOT NULL`: doble clic en "Facturar" devuelve la orden existente en vez de duplicarla; bonus: protege contra que POS y promoción pisen la misma operación.
- **Nuevo endpoint `POST /sales/{operation_id}/promote-to-order`** (FastAPI, 3 capas router→service→repository): invoca la RPC, mapea errores Postgres→HTTP (P0401→403, P0404→404, P0409→409, P0422→409).
- **Frontend**: un botón "Facturar" en `SaleOperationsList` (`/ventas`) que (1) promueve la venta legacy a `SalesOrder` y (2) reusa el flujo `emit-invoice` (C-27) sobre la orden materializada, mostrando `EmitInvoiceButton` + `FiscalDocumentBadge`. El comprobante queda **reconciliado** a la orden (`sales_orders.fiscal_document_id`), a diferencia del actual "Enviar al ARCA".
- **NO toca**: hot path POS (`rpc_quick_sale`), `rpc_create_sale_operation` (alta legacy), stock, caja, outbox, ni el flujo `emit-invoice` de C-27 (se reusa tal cual).

## Capabilities

### New Capabilities
<!-- Ninguna capability nueva: la promoción se expresa como requisitos nuevos sobre capabilities existentes (sales-order, afip-fiscal-document). -->

### Modified Capabilities
- `sales-order`: nuevo requisito "Promoción de una venta legacy a SalesOrder facturable" — una RPC dedicada side-effect-free que materializa una `SalesOrder` confirmada desde una venta legacy, idempotente por `sale_operation_id`, sin re-descontar stock ni registrar caja ni emitir outbox.
- `afip-fiscal-document`: el requisito existente "Emisión posterior de comprobante para una SalesOrder confirmada" se **reusa sin cambios funcionales**; el delta documenta que la `SalesOrder` materializada por promoción es un origen válido de ese flujo (la emisión es el mismo camino para una venta recién confirmada, una histórica o una promovida).

## Impact

- **DB** (Supabase Postgres, gobernanza **FISCAL = CRÍTICO**): 1 migración nueva — RPC `rpc_promote_legacy_sale_to_order` + índice único parcial en `sales_orders(sale_operation_id)`. Aplicar con `npx supabase db push` (NUNCA el MCP `apply_migration`).
- **Backend** (FastAPI): `backend/routers/sales.py` (endpoint `POST /sales/{operation_id}/promote-to-order`), `backend/services/sales.py` (guard `require_role` + mapeo de errores), `backend/repositories/sales_repository.py` (llamada a la RPC), `backend/schemas/sales.py` (response schema Pydantic v2). Tests pytest + pytest-asyncio.
- **Frontend** (Next.js / React): `frontend/components/ventas/sale-operations-list.tsx` (botón "Facturar" cableado a promote + emit), un hook React Query nuevo `usePromoteToOrder` (`frontend/hooks/data/`), reuso de `EmitInvoiceButton` y `FiscalDocumentBadge`.
- **Specs**: deltas a `sales-order` y `afip-fiscal-document`.
- **RN-97 respetada**: la promoción *lee* `sales` pero NO agrega lógica de negocio *a* esa tabla en retirada; toda la lógica nueva vive en `sales_orders`. Si algún día se implementa la Opción B (un solo modelo), la promoción queda obsoleta sin deuda residual.
- **Gobernanza**: requiere **aprobación humana explícita antes del apply** (dominio fiscal = CRÍTICO). El apply NO debe ejecutarse sin firma del PO.
- **Caveat fiscal documentado** (riesgo de negocio, no bloqueante): el comprobante AFIP lleva fecha de **emisión** (hoy), no la de la venta original; AFIP limita la antigüedad facturable. Relevante solo al facturar ventas viejas.
