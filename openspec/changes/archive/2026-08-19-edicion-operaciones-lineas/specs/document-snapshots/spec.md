## ADDED Requirements

### Requirement: Política de snapshot al editar una línea de operación
El sistema SHALL preservar el snapshot congelado de una línea cuando una edición de la operación NO cambia el producto de esa línea: `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` MUST conservar el valor que tenían antes de la edición, y solo `quantity`, `price` y `subtotal` SHALL recalcularse desde el payload editado. Cuando la edición **cambia el producto** de la línea, o agrega una línea que la operación no tenía, el sistema SHALL congelar un snapshot **fresco** desde el maestro `products` en la misma transacción de la edición. La correspondencia entre la línea previa y la nueva SHALL resolverse por `product_id` de forma determinística. Una edición NO SHALL re-precificar con el costo actual una línea cuyo producto no cambió.

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

## MODIFIED Requirements

### Requirement: Backfill best-effort de líneas históricas con flag de aproximación

El sistema SHALL agregar `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false` a `sale_items`, `purchase_items`, `quote_items` y `sales_order_items`, y SHALL ejecutar un backfill best-effort que complete las columnas snapshot de las líneas históricas leyendo el maestro `products` actual, marcando cada fila backfilleada con `snapshot_backfilled = true`. El backfill MUST ser idempotente (re-ejecutable sin duplicar ni sobrescribir snapshots ya congelados por la ruta transaccional) y MUST NOT tocar líneas cuyo `snapshot_backfilled = false` y que ya tengan snapshots (las congeladas en vivo).

Para las operaciones históricas que **no tienen línea alguna**, el sistema SHALL poder reconstruirla desde el header (`product_id`, `quantity`, `price` desde `amount`, `subtotal` desde `COALESCE(total, amount * quantity)`, `account_id` del header), y en esa reconstrucción:

- `unit_cost_snapshot` SHALL tomarse del snapshot del header cuando el header lo tenga congelado (caso de `purchases`), marcando la fila con `snapshot_backfilled = false` porque el valor es un snapshot genuino;
- `unit_cost_snapshot` SHALL quedar en `NULL` cuando no exista ningún costo congelado de la fecha de la operación, marcando la fila con `snapshot_backfilled = true`. El backfill NO SHALL congelar el costo actual del maestro como si fuera el costo histórico: el consumidor canónico ya resuelve `COALESCE(unit_cost_snapshot, products.cost)`, de modo que `NULL` preserva exactamente el cálculo vigente sin afirmar un costo que el sistema no conoce;
- `name_snapshot` y `sku_snapshot` MAY completarse desde el maestro actual, por ser etiquetas y no magnitudes monetarias.

El backfill de líneas inexistentes SHALL entregarse como script ejecutable a mano, NO como migración, para que el merge no mute datos de producción sin decisión explícita.

#### Scenario: El backfill marca la aproximación

- **GIVEN** una línea histórica con las columnas snapshot en NULL
- **WHEN** corre el backfill y encuentra el producto en `products`
- **THEN** la línea queda con los snapshots completados desde el maestro actual y `snapshot_backfilled = true`

#### Scenario: El backfill no sobrescribe un snapshot congelado en vivo

- **GIVEN** una línea creada por la ruta transaccional con `unit_cost_snapshot = 600` y `snapshot_backfilled = false`
- **WHEN** corre el backfill
- **THEN** la línea conserva `unit_cost_snapshot = 600` y `snapshot_backfilled = false`

#### Scenario: El backfill es idempotente

- **WHEN** el backfill se ejecuta dos veces seguidas
- **THEN** el resultado es idéntico a una sola ejecución: ninguna fila cambia en la segunda corrida

#### Scenario: Una compra sin línea reconstruye la línea con el snapshot genuino del header

- **GIVEN** una compra histórica sin fila en `purchase_items` cuyo header tiene `unit_cost_snapshot` congelado
- **WHEN** corre el backfill de líneas inexistentes
- **THEN** la línea creada toma ese `unit_cost_snapshot` del header y queda con `snapshot_backfilled = false`

#### Scenario: Una venta sin línea reconstruye la línea sin inventar el costo

- **GIVEN** una venta histórica sin fila en `sale_items`, cuyo header no tiene ningún costo congelado
- **WHEN** corre el backfill de líneas inexistentes
- **THEN** la línea creada tiene `unit_cost_snapshot = NULL` y `snapshot_backfilled = true`, y el margen calculado para esa venta es idéntico al que el sistema devolvía antes del backfill
