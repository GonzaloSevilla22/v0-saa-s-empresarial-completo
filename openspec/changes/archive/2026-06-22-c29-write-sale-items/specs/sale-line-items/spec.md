## ADDED Requirements

### Requirement: Invariante — toda venta con producto tiene su fila en sale_items, sin importar la ruta

El sistema SHALL garantizar que toda fila de `sales` con `product_id NOT NULL` tenga exactamente una fila asociada en `sale_items` (`sale_items.sale_id = sales.id`, `product_id` coincidente), **independiente de la ruta de creación**: `rpc_create_sale_operation_v2`, la ruta legacy, o la ruta C-29 `rpc_quick_sale` / `rpc_confirm_sales_order`. La ruta C-29 MUST insertar esa fila en la misma transacción que el header `sales`, espejando la doble escritura de `rpc_create_sale_operation_v2` (`variant_id = NULL`, `quantity`, `unit_id`, `price`, `subtotal` desde la línea de `sales_order_items`). Las líneas de servicio (`product_id IS NULL`) MUST NOT generar fila de ítem. Las ventas con producto creadas antes de este cambio que carezcan de `sale_items` SHALL ser backfilleadas desde las columnas planas de `sales`, de forma idempotente.

#### Scenario: quickSale (POS) escribe la línea en sale_items

- **WHEN** se ejecuta `rpc_quick_sale` con un ítem de producto
- **THEN** existe una fila en `sale_items` ligada a la fila `sales` generada, con `product_id` del producto, `variant_id = NULL`, y `quantity`/`price`/`subtotal` de la línea

#### Scenario: confirm de SalesOrder escribe la línea en sale_items

- **WHEN** se confirma un `SalesOrder` de un producto vía `rpc_confirm_sales_order`
- **THEN** existe una fila en `sale_items` con `sale_id` de la venta generada y `product_id` del producto

#### Scenario: no quedan ventas con producto sin sale_items

- **WHEN** se consulta el conjunto de filas `sales` con `product_id NOT NULL`
- **THEN** ninguna carece de fila en `sale_items` (gate de validación = 0 ventas sin ítem)

#### Scenario: el backfill de ventas sin ítem es idempotente

- **WHEN** la reconstrucción de `sale_items` para ventas con producto sin ítem se ejecuta dos veces seguidas
- **THEN** se crea exactamente una fila por venta afectada, sin duplicados, y las filas de variantes preexistentes (`variant_id NOT NULL`, `product_id IS NULL`) permanecen inalteradas
