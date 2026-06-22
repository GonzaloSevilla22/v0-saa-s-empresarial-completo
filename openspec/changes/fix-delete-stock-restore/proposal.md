## Why

Al eliminar una venta, el stock del producto no vuelve a subir cuando la venta se creó por la ruta C-29 (POS `rpc_quick_sale` / `rpc_confirm_sales_order`) o por la ruta legacy (`sale_items_rpc_v2` OFF). El backend condiciona TODA la reversa de stock a que exista una fila en `sale_items`, pero esas rutas escriben `sales` + `stock_movements` sin tocar `sale_items` (usan `sales_order_items`). Resultado: el stock descontado nunca se devuelve a `branch_stock` y queda una fila huérfana en `stock_movements`. Verificado en producción: las ventas recientes (con `branch_id` seteado) tienen `n_sale_items = 0` y `n_stock_mov = 1`. El mismo bug espejo existe en compras.

## What Changes

- `SalesRepository.delete_by_id` y `delete_by_operation`: derivar los datos de la reversa (`product_id`, `quantity_delta`, `branch_id`) **directamente de `stock_movements`** —la fila que toda ruta de creación escribe— en lugar de gatear por `sale_items`.
- `PurchaseRepository.delete_by_id` y `delete_by_operation`: aplicar la misma corrección al bug espejo (la reversa de una compra eliminada).
- La fila de `stock_movements` SHALL borrarse en todos los casos en que se reversó (hoy queda huérfana cuando se saltea el bloque).
- Backfill puntual de las ventas ya eliminadas / afectadas que descontaron stock de más sin reversa (las que quedaron con `stock_movements` huérfano o stock descuadrado).
- Sin cambios de API ni de contrato HTTP: los endpoints `DELETE /sales/{id}`, `DELETE /sales?operation_id=`, y sus equivalentes de compras se comportan igual ante el cliente, solo que ahora sí reponen stock.

## Capabilities

### New Capabilities

<!-- Ninguna: es un bugfix sobre comportamiento existente. -->

### Modified Capabilities

- `inventory-single-ledger`: nuevo requirement — eliminar una venta o una compra SHALL revertir su movimiento de stock contra `branch_stock` de forma independiente de la ruta de creación (v2, legacy o C-29/POS), tomando los datos de reversa desde `stock_movements`, no desde `sale_items`/`purchase_items`.

## Impact

- **Código**: `backend/repositories/sales_repository.py` (`delete_by_id` :86, `delete_by_operation` :135); `backend/repositories/purchase_repository.py` (métodos espejo).
- **Datos**: una migración/script idempotente de backfill para reponer el stock de las ventas/compras ya eliminadas sin reversa y limpiar `stock_movements` huérfanos.
- **Ledger**: `branch_stock` (vía `rpc_apply_product_stock_delta`) y `stock_movements`. `products.stock` ya no existe (C-21).
- **Riesgo / gobernanza**: lógica de inventario = MEDIO. No toca auth/billing. Requiere tests de regresión que cubran las tres rutas de creación antes de mergear.
