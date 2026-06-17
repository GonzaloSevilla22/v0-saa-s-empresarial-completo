# sale-line-items

## ADDED Requirements

### Requirement: SalesOrder.confirm() es una ruta de escritura adicional del ledger de ventas
El sistema SHALL permitir que `SalesOrder.confirm()`/`quickSale()` (capability `sales-order`) produzcan filas en `sales` + `sale_items` reusando la mecánica de doble escritura de `rpc_create_sale_operation_v2` (header `sales` + `sale_items` + `stock_movements` con `reference_type = 'sale'`), dentro de la misma transacción atómica que el descuento de `branch_stock`. Esta ruta MUST preservar la idempotencia compartida (`operation_idempotency`, `operation_kind = 'sale'`) y el comportamiento de stock/ledger ya definido para las ventas. Las columnas planas del header `sales` (`product_id`, `amount`, `quantity`, `total`) NO SHALL ser la fuente de verdad: la línea vive en `sale_items`.

#### Scenario: confirm escribe la línea en sale_items, no en el header plano
- **WHEN** se confirma un `SalesOrder` de un producto
- **THEN** existe una fila en `sale_items` con `product_id` del producto, `variant_id = NULL`, ligada a la fila `sales` generada, y el `stock_movements` registra `reference_type = 'sale'`

#### Scenario: idempotencia compartida con la ruta de venta directa
- **WHEN** una `quickSale` y una venta directa usaran la misma `idempotency_key` (mismo `operation_kind = 'sale'`)
- **THEN** la segunda invocación se trata como replay y no duplica filas en `sale_items` ni descuenta stock dos veces

#### Scenario: las lecturas de ventas existentes incluyen las órdenes confirmadas
- **WHEN** el repositorio del backend pagina ventas leyendo del `JOIN sale_items`
- **THEN** las ventas originadas por `SalesOrder.confirm()`/`quickSale()` aparecen con su `product_id`, `quantity` y `amount` derivados de `sale_items`, igual que cualquier otra venta
