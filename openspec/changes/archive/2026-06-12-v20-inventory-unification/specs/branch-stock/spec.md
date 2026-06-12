# branch-stock

## MODIFIED Requirements

### Requirement: Ledger de stock por sucursal (branch_stock)
El sistema SHALL mantener el inventario por combinación `(product_id, branch_id)` en `branch_stock` como **única fuente de verdad** del stock. Toda operación (venta o compra) SHALL afectar `branch_stock.quantity` de su `branch_id` — incluida la branch por defecto ("Casa Central"/"Principal") cuando la cuenta opera con una sola sucursal. La columna `products.stock` SHALL NOT mutarse por operaciones de stock (el dual-ledger queda retirado por C-21); el stock total de un producto es `SUM(branch_stock.quantity)`.

#### Scenario: Venta descuenta de branch_stock
- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** se registra una venta de 3 unidades en la sucursal A
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=A)` pasa a 7 y no se modifica ninguna columna de `products`

#### Scenario: Venta falla si stock insuficiente (gate global)
- **GIVEN** un producto con `SUM(branch_stock.quantity) = 2` en toda la cuenta
- **WHEN** se registra una venta de 5 unidades
- **THEN** la RPC retorna error `Insufficient stock` y no inserta ninguna fila

#### Scenario: Venta en sucursal sin stock local no se bloquea (gate global, decisión PO C-21)
- **GIVEN** un producto con 10 unidades en la branch por defecto y 0 en la sucursal B
- **WHEN** se registra una venta de 2 unidades en la sucursal B
- **THEN** la venta procede (el gate es `SUM(branch_stock)`); `branch_stock` de B queda en −2 transitorio y la suma global se preserva (se regulariza con transferencia)

#### Scenario: Compra incrementa branch_stock
- **GIVEN** un producto con 0 unidades en `branch_stock` de la sucursal B (o sin fila aún)
- **WHEN** se registra una compra de 20 unidades en la sucursal B
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=B)` pasa a 20 (fila creada si no existía)

#### Scenario: Operación sobre la branch por defecto afecta branch_stock, no products.stock
- **GIVEN** una cuenta con una sola sucursal (branch por defecto) y un producto con 10 unidades en `branch_stock`
- **WHEN** se registra una venta de 2 unidades
- **THEN** `branch_stock` de la branch por defecto pasa a 8 y la columna `products.stock` no participa (es la única verdad `branch_stock`)
