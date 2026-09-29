## MODIFIED Requirements

### Requirement: Política de snapshot al editar una línea de operación
El sistema SHALL preservar el snapshot congelado de una línea cuando una edición de una operación de **venta o compra** NO cambia el producto de esa línea: `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` MUST conservar el valor que tenían antes de la edición, y solo `quantity`, `price` y `subtotal` SHALL recalcularse desde el payload editado. Cuando la edición **cambia el producto** de la línea, o agrega una línea que la operación no tenía, el sistema SHALL congelar un snapshot **fresco** desde el maestro `products` en la misma transacción de la edición. La correspondencia entre la línea previa y la nueva SHALL resolverse por `product_id` de forma determinística. Una edición NO SHALL re-precificar con el costo actual una línea cuyo producto no cambió.

Esta política protege el costo histórico de una operación ya realizada. NOT SHALL aplicarse al presupuesto (`quote_items`), que se edita por reemplazo completo antes de confirmarse y re-congela los snapshots de todas sus líneas en cada edición, según el requirement de edición de la spec `quote`.

#### Scenario: corregir la cantidad no re-precifica la historia

- **GIVEN** una venta cuya línea congeló `unit_cost_snapshot = 600` y un producto cuyo costo hoy es `products.cost = 900`
- **WHEN** se edita la operación cambiando solo la cantidad
- **THEN** la línea resultante conserva `unit_cost_snapshot = 600` y refleja la cantidad nueva

#### Scenario: corregir el precio de venta tampoco toca el costo congelado

- **GIVEN** una venta cuya línea congeló `unit_cost_snapshot = 600`
- **WHEN** se edita la operación cambiando el precio unitario de venta
- **THEN** la línea resultante tiene el `price` y el `subtotal` nuevos y `unit_cost_snapshot = 600`

#### Scenario: cambiar el producto congela el snapshot del producto nuevo

- **GIVEN** una venta de un producto A con `unit_cost_snapshot = 600` y un producto B con `products.cost = 1500`
- **WHEN** se edita la operación reemplazando A por B
- **THEN** la línea resultante referencia a B con `unit_cost_snapshot = 1500` y `name_snapshot` de B, sin heredar nada de A

#### Scenario: una operación sin línea previa congela un snapshot fresco

- **GIVEN** una venta histórica sin fila en `sale_items` y un producto con `products.cost = 800`
- **WHEN** se edita esa operación
- **THEN** la línea creada tiene `unit_cost_snapshot = 800`, congelado en la transacción de la edición

#### Scenario: la compra preserva también el snapshot de su header

- **GIVEN** una compra cuyo header congeló `unit_cost_snapshot` al crearse
- **WHEN** se edita la operación de compra sin cambiar el producto
- **THEN** tanto la fila de `purchases` como su `purchase_items` conservan el `unit_cost_snapshot` original y reflejan la cantidad o el precio editados

#### Scenario: el presupuesto no se rige por esta política

- **GIVEN** un presupuesto cuya línea congeló `unit_cost_snapshot = 500` y un producto cuyo costo hoy es `products.cost = 600`
- **WHEN** se edita el presupuesto sin cambiar el producto de esa línea
- **THEN** la línea queda con `unit_cost_snapshot = 600`, según la spec `quote`
