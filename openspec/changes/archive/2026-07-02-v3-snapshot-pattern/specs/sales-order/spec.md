## ADDED Requirements

### Requirement: Snapshot congelado en las líneas de la orden de venta

El sistema SHALL agregar a `sales_order_items`, de forma aditiva y NULLABLE, las columnas `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)`, más `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false`. `_c29_confirm_order_core` (y las rutas de `confirm()` / `quickSale()` que lo invocan) SHALL congelar el nombre, SKU, costo y alícuota de IVA del maestro en la misma transacción atómica de la confirmación, sin alterar la atomicidad, la idempotencia ni el descuento de `branch_stock` ya especificados.

#### Scenario: confirm() congela el snapshot en la transacción atómica

- **GIVEN** un producto con `products.cost = 600` y una `SalesOrder` en DRAFT
- **WHEN** se confirma la orden vía `_c29_confirm_order_core`
- **THEN** cada `sales_order_items` de la orden queda con `unit_cost_snapshot = 600` y los demás snapshots congelados, en la misma transacción que descuenta `branch_stock` y escribe `sale_items`

#### Scenario: quickSale() congela el snapshot en un solo paso

- **WHEN** se ejecuta `quickSale()` (crear + confirmar)
- **THEN** las líneas resultantes quedan con los snapshots congelados desde el maestro, sin una escritura posterior

#### Scenario: La idempotencia de la confirmación se preserva

- **WHEN** se invoca `_c29_confirm_order_core` dos veces con la misma clave de idempotencia
- **THEN** la orden se confirma una sola vez con un único set de snapshots, y la segunda llamada devuelve el resultado original sin re-descontar stock

#### Scenario: Una venta promovida desde legacy admite snapshot backfilled

- **GIVEN** una venta legacy promovida a `SalesOrder`
- **WHEN** se le aplica el backfill de snapshots
- **THEN** sus `sales_order_items` quedan con snapshots completados desde el maestro actual y `snapshot_backfilled = true`
