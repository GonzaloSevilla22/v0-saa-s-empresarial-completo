## MODIFIED Requirements

### Requirement: Ledger de stock por sucursal (branch_stock)
El sistema SHALL mantener el inventario por combinación `(product_id, branch_id)` en `branch_stock` como única fuente de verdad, con el invariante **`quantity >= 0`** garantizado por CHECK en la base.

- **Alta de una venta**: SHALL validar stock suficiente en su **sucursal efectiva** y descontarlo de ESA sucursal. La sucursal efectiva es la elegida o, si no se eligió ninguna, la sucursal principal de la cuenta (`c26_default_branch`). La validación compara contra la cantidad de esa sucursal, no contra `SUM(branch_stock.quantity)`.
- **Compra sin `branch_id`**: incrementa la sucursal principal de la cuenta.
- **Stock total de un producto**: es `SUM(branch_stock.quantity)`.

#### Scenario: Venta descuenta de branch_stock
- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** se registra una venta de 3 unidades en la sucursal A
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=A)` pasa a 7

#### Scenario: Venta con sucursal explícita falla si esa sucursal no tiene stock suficiente
- **GIVEN** un producto con 10 unidades en la sucursal default y 0 en la sucursal B
- **WHEN** se registra una venta de 2 unidades con `p_branch_id = B`
- **THEN** la RPC retorna `P0409 insufficient_branch_stock` y no inserta ninguna fila (transferir stock a B primero)

#### Scenario: Venta sin sucursal elegida valida el stock de la principal
- **GIVEN** un producto con 2 unidades en la sucursal principal A y 10 en la sucursal B
- **WHEN** se registra una venta de 5 unidades sin `branch_id`
- **THEN** la RPC retorna `P0409` Insufficient stock y no inserta ninguna fila: las unidades de B no cuentan para una venta que se registra en A

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

### Requirement: El alta de una venta desde el formulario opera sobre la sucursal elegida
El sistema SHALL entregar a la operación de alta de venta la sucursal que el usuario eligió en el formulario, de punta a punta (cliente, API y RPC), de modo que la venta y su movimiento de stock queden registrados en ESA sucursal y que el stock, la caja y el movimiento bancario se resuelvan contra ella.

Cuando el usuario no elige ninguna (cuenta sin módulo de sucursales, o selector sin cambiar), el sistema SHALL registrar la venta y su movimiento de stock en la sucursal principal de la cuenta, la misma de la que descuenta el stock y contra la que resuelve la caja y el movimiento bancario. La venta nunca queda con `branch_id = NULL`.

#### Scenario: Venta del formulario en una sucursal que no es la default
- **GIVEN** una cuenta con las sucursales A (default) y B, y un producto con 10 unidades en cada una
- **WHEN** el usuario elige la sucursal B en el formulario y registra una venta de 3 unidades
- **THEN** la fila en `sales` y el `stock_movement` de la venta tienen `branch_id = B`, `branch_stock` de B pasa a 7 y `branch_stock` de A permanece en 10

#### Scenario: La sucursal elegida no tiene stock aunque la default sí
- **GIVEN** un producto con 10 unidades en la sucursal default A y ninguna en la sucursal B
- **WHEN** el usuario elige B en el formulario y registra una venta de 2 unidades
- **THEN** el alta es rechazada con `P0409 insufficient_branch_stock` (HTTP 409), no se persiste ninguna fila y el stock de A no se toca

#### Scenario: Sucursal ajena, inactiva o cerrada
- **GIVEN** una sucursal que pertenece a otra cuenta, que está inactiva o que está cerrada
- **WHEN** una venta se registra indicando esa sucursal
- **THEN** la sucursal ajena o inactiva se rechaza con `P0404` (HTTP 404) y la cerrada con `P0422` (HTTP 422), sin persistir nada

#### Scenario: Venta sin sucursal elegida
- **GIVEN** un formulario de venta en el que el usuario no eligió otra sucursal
- **WHEN** el usuario registra la venta
- **THEN** la fila en `sales` y su `stock_movement` tienen `branch_id` igual a la sucursal principal de la cuenta, y el stock se descuenta de esa sucursal

#### Scenario: Caja y banco siguen a la sucursal elegida
- **GIVEN** el usuario eligió la sucursal B y una forma de pago en efectivo con la casilla "Registrar en caja" tildada
- **WHEN** registra la venta
- **THEN** el movimiento de caja se registra sólo si la sesión abierta es la de B (con la sesión de otra sucursal el alta se rechaza con `P0422`), y el movimiento bancario de una venta por transferencia lleva `branch_id = B`
