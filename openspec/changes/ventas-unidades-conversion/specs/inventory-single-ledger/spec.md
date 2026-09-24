# Spec Delta — inventory-single-ledger

## ADDED Requirements

### Requirement: El ledger de stock se expresa siempre en la unidad base del producto

`branch_stock.quantity` y `stock_movements.quantity_delta` (con `quantity_before` y `quantity_after`) SHALL expresarse siempre en la unidad base del producto, cualquiera sea la unidad con la que se registró la línea que originó el movimiento. Todo movimiento originado por una operación SHALL obtener su delta de la definición única de normalización de cantidad (capability `units-of-measure`), y la reversa de un movimiento (borrado de la operación o pata de reversa de la edición) SHALL devolver exactamente la cantidad normalizada que ese movimiento aplicó, nunca la cantidad cruda de la línea.

#### Scenario: la línea conserva su unidad, el ledger la base

- **GIVEN** un producto con unidad base Kilogramo
- **WHEN** se vende una línea de `450` con unidad Gramo
- **THEN** la línea persiste `quantity = 450` con la unidad Gramo, y el ledger persiste `quantity_delta = -0.45`

#### Scenario: el borrado revierte lo normalizado

- **GIVEN** la venta anterior, con su movimiento `quantity_delta = -0.45`
- **WHEN** se borra la operación
- **THEN** el ledger registra la reversa con `quantity_delta = +0.45` y el stock vuelve al valor previo a la venta

#### Scenario: invariante de reconstrucción con unidades mixtas

- **GIVEN** un producto en kilogramos con movimientos originados por líneas en kilogramos y en gramos
- **WHEN** se suma `quantity_delta` de todos sus movimientos en una sucursal
- **THEN** el resultado coincide con `branch_stock.quantity` de esa sucursal (mismo invariante que para unidades enteras)
