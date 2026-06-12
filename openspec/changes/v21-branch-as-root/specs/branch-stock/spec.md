# branch-stock

## MODIFIED Requirements

### Requirement: Ledger de stock por sucursal (branch_stock)
El sistema SHALL mantener el inventario por combinación `(product_id, branch_id)` en `branch_stock` como única fuente de verdad, con el invariante **`quantity >= 0`** garantizado por CHECK en la base. Las operaciones **con `branch_id` explícito** SHALL validar stock suficiente en ESA sucursal; las operaciones **sin `branch_id`** afectan la sucursal default de la cuenta con gate global (`SUM(branch_stock.quantity)`). El stock total de un producto es `SUM(branch_stock.quantity)`.

#### Scenario: Venta descuenta de branch_stock
- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** se registra una venta de 3 unidades en la sucursal A
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=A)` pasa a 7

#### Scenario: Venta con sucursal explícita falla si esa sucursal no tiene stock suficiente
- **GIVEN** un producto con 10 unidades en la sucursal default y 0 en la sucursal B
- **WHEN** se registra una venta de 2 unidades con `p_branch_id = B`
- **THEN** la RPC retorna `P0409 insufficient_branch_stock` y no inserta ninguna fila (transferir stock a B primero)

#### Scenario: Venta sin sucursal usa la default con gate global
- **GIVEN** una cuenta mono-sucursal con `SUM(branch_stock) = 2` para un producto
- **WHEN** se registra una venta de 5 unidades sin `branch_id`
- **THEN** la RPC retorna `P0409` Insufficient stock y no inserta ninguna fila

#### Scenario: Compra incrementa branch_stock
- **GIVEN** un producto con 0 unidades en `branch_stock` de la sucursal B (o sin fila aún)
- **WHEN** se registra una compra de 20 unidades en la sucursal B
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=B)` pasa a 20 (fila creada si no existía)

#### Scenario: Ninguna escritura puede dejar una sucursal en negativo
- **GIVEN** cualquier vía de escritura sobre `branch_stock` (RPCs, helper, importador)
- **WHEN** el resultado dejaría `quantity < 0`
- **THEN** la base rechaza la operación por CHECK constraint (red de seguridad física del invariante)

#### Scenario: Reversa de compra borrada con stock ya vendido hace floor a 0
- **GIVEN** una compra de 5 unidades cuyo stock ya fue vendido (la sucursal quedó en 0)
- **WHEN** se borra la compra y la reversa de −5 dejaría la sucursal en negativo
- **THEN** la cantidad queda en 0 y se registra un `stock_movement` de ajuste con reason `floor_on_purchase_delete` por la diferencia (trazabilidad en lugar de negativo)
