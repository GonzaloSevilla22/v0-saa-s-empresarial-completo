## ADDED Requirements

### Requirement: Snapshot congelado en las líneas de presupuesto

El sistema SHALL agregar a `quote_items`, de forma aditiva y NULLABLE, las columnas `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)`, más `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false`. La ruta de creación del presupuesto SHALL congelar el nombre, SKU, costo y alícuota de IVA del maestro en la misma transacción en que persiste la línea, de modo que un presupuesto aceptado días después honre los valores cotizados y no los remarcados. Al aceptar el presupuesto (`Quote.accept()` que crea la `SalesOrder`), los snapshots de las líneas SHALL propagarse a `sales_order_items` sin re-leer el maestro.

#### Scenario: El presupuesto congela el precio cotizado

- **GIVEN** un producto con precio y costo vigentes al cotizar
- **WHEN** se crea un presupuesto con ese producto
- **THEN** la fila `quote_items` queda con `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` congelados en la transacción de creación

#### Scenario: Aceptar el presupuesto propaga el snapshot a la orden

- **GIVEN** un presupuesto con líneas que congelaron `unit_cost_snapshot`
- **WHEN** el presupuesto se acepta y se crea la `SalesOrder`
- **THEN** las `sales_order_items` resultantes heredan los mismos valores snapshot del `quote_items`, sin re-leer `products`

#### Scenario: Remarcar el maestro tras cotizar no cambia el presupuesto

- **GIVEN** un presupuesto que congeló el precio y costo al momento de emitirse
- **WHEN** el maestro se remarca antes de aceptar el presupuesto
- **THEN** el presupuesto conserva los valores cotizados originales en sus columnas snapshot
