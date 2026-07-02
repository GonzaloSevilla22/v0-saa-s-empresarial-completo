## Purpose

Immutable snapshots of product metadata (name, SKU, cost, IVA rate) frozen at the moment a document line is created, preventing historical cost/margin calculations from being corrupted when product masters are updated. Foundational pattern for Model V3.

---

## Requirements

### Requirement: Columnas snapshot en las líneas de documento

El sistema SHALL agregar, de forma aditiva y NULLABLE, las columnas snapshot `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)` a las tablas de líneas `sale_items`, `purchase_items`, `quote_items` y `sales_order_items`. Estas columnas SHALL congelar el nombre, SKU, costo unitario y alícuota de IVA del maestro (`products`) vigentes al momento en que la línea se persiste. Ninguna columna existente SHALL ser eliminada ni cambiada de tipo por este requisito.

#### Scenario: Las columnas snapshot existen y admiten NULL

- **WHEN** se inspeccionan las tablas `sale_items`, `purchase_items`, `quote_items` y `sales_order_items` tras la migración
- **THEN** cada una tiene `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)`, todas NULLABLE, y ninguna columna previa fue removida

#### Scenario: Una línea preexistente conserva NULL en las columnas nuevas

- **WHEN** la migración agrega las columnas a una tabla con filas históricas
- **THEN** esas filas quedan con las cuatro columnas snapshot en NULL hasta que el backfill las complete

### Requirement: Congelamiento de snapshots en la transacción de escritura

Toda ruta de creación de línea confirmada SHALL congelar `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` desde el maestro `products` **en la misma transacción** que inserta la línea, leyendo `products.name`, `products.sku`, `products.cost` y la alícuota de IVA vigente del producto. El congelamiento MUST ocurrir en el mismo `INSERT` (o `INSERT ... SELECT` del maestro) que crea la línea, sin una escritura posterior. Cuando la línea no referencia un producto del maestro (`product_id IS NULL`, p. ej. una línea de servicio), `name_snapshot` MUST proveerse desde el payload de la operación y `sku_snapshot`/`unit_cost_snapshot`/`iva_rate_snapshot` MAY quedar en NULL.

#### Scenario: Una venta nueva congela el costo del maestro al crearse

- **GIVEN** un producto con `products.cost = 600` y `products.name = 'Yerba 1kg'`
- **WHEN** se crea una venta de ese producto por la ruta de escritura vigente
- **THEN** la fila en `sale_items` queda con `unit_cost_snapshot = 600` y `name_snapshot = 'Yerba 1kg'`, escritos en la misma transacción del header

#### Scenario: Remarcar el maestro luego de la venta no altera el snapshot

- **GIVEN** una venta cuya línea congeló `unit_cost_snapshot = 600`
- **WHEN** posteriormente el costo del producto sube a `products.cost = 900`
- **THEN** la línea de la venta original conserva `unit_cost_snapshot = 600` sin cambios

#### Scenario: Línea de servicio sin producto del maestro

- **WHEN** se crea una línea con `product_id IS NULL` y un nombre en el payload
- **THEN** la línea queda con `name_snapshot` igual al nombre del payload y `sku_snapshot`/`unit_cost_snapshot`/`iva_rate_snapshot` en NULL, sin error

### Requirement: Costo unitario congelado en el ledger de stock

El sistema SHALL agregar `unit_cost_snapshot NUMERIC(15,2)` NULLABLE a `stock_movements` y SHALL congelar el costo unitario del producto al registrar el movimiento, dentro de la misma transacción que ya escribe `quantity_after`. El valor congelado SHALL permitir la valuación de inventario sin depender de `products.cost` actual.

#### Scenario: El movimiento de stock congela el costo unitario

- **GIVEN** un producto con `products.cost = 600`
- **WHEN** una venta o compra genera un movimiento en `stock_movements`
- **THEN** el movimiento tiene `unit_cost_snapshot = 600`, escrito en la misma transacción que `quantity_after`

#### Scenario: Movimiento histórico admite NULL

- **WHEN** la migración agrega `unit_cost_snapshot` a `stock_movements`
- **THEN** los movimientos previos quedan con `unit_cost_snapshot = NULL` sin bloquear el ledger append-only

### Requirement: Líneas inmutables tras la confirmación del documento

Una vez que un documento pasó a un estado confirmado (`SalesOrder` confirmada, `FiscalDocument` emitido, `PurchaseOrder` recibida, `Quote` aceptada), sus líneas y sus columnas snapshot SHALL ser inmutables: ninguna capa (RPC, repositorio, endpoint) SHALL emitir `UPDATE` sobre las columnas de la línea. Toda corrección SHALL materializarse como un documento nuevo (nota de crédito, ajuste, contra-movimiento), no como una modificación de la línea original. Esta invariante es la regla de negocio equivalente a RN-04 del modelo de referencia y SHALL documentarse en `knowledge-base/05_reglas_de_negocio.md`.

#### Scenario: No se permite editar la línea de una venta confirmada

- **GIVEN** una `SalesOrder` confirmada con una línea de `unit_price_snapshot = 1000`
- **WHEN** se intenta corregir el precio de esa venta
- **THEN** la corrección se realiza emitiendo un documento nuevo (NC/ajuste), y la línea original permanece intacta

#### Scenario: La regla queda registrada en la base de conocimiento

- **WHEN** se revisa `knowledge-base/05_reglas_de_negocio.md` tras el change
- **THEN** existe una regla explícita que establece que las líneas de un documento confirmado no se editan y la corrección es un documento nuevo

### Requirement: Backfill best-effort de líneas históricas con flag de aproximación

El sistema SHALL agregar `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false` a `sale_items`, `purchase_items`, `quote_items` y `sales_order_items`, y SHALL ejecutar un backfill best-effort que complete las columnas snapshot de las líneas históricas leyendo el maestro `products` actual, marcando cada fila backfilleada con `snapshot_backfilled = true`. El backfill MUST ser idempotente (re-ejecutable sin duplicar ni sobrescribir snapshots ya congelados por la ruta transaccional) y MUST NOT tocar líneas cuyo `snapshot_backfilled = false` y que ya tengan snapshots (las congeladas en vivo).

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
