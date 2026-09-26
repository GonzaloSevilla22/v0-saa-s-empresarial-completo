# Spec Delta — sales-order

## ADDED Requirements

### Requirement: La confirmación descuenta stock en la unidad base del producto

`confirm()` y `quickSale()` SHALL descontar el stock de cada línea con producto en la unidad base de ese producto, obteniendo el delta de la definición única de normalización de cantidad (capability `units-of-measure`) a partir de la cantidad y la unidad de la línea de la orden. La verificación de stock suficiente y el movimiento de stock resultante SHALL usar esa misma cantidad normalizada. La cantidad y la unidad de la línea de la orden SHALL conservarse tal como las ingresó el usuario; sólo el delta de stock se expresa en la unidad base.

Una línea cuya unidad no sea compatible con el producto SHALL abortar la confirmación completa con `P0400` antes de tocar stock, caja, cuenta corriente o outbox, y la orden SHALL permanecer en `draft`.

#### Scenario: quickSale en gramos sobre un producto en kilogramos

- **GIVEN** un producto con unidad base Kilogramo y `branch_stock = 1` en la sucursal de la operación
- **WHEN** se ejecuta `quickSale()` con una línea de `450` con unidad Gramo
- **THEN** tras el commit `branch_stock` es `0.55`, existe un `stock_movements` con `quantity_delta = -0.45` y `reference_type = 'sale'`, y la línea de la orden conserva `quantity = 450` con su `unit_id` de Gramo

#### Scenario: Stock insuficiente se evalúa en la unidad base

- **GIVEN** un producto con unidad base Kilogramo y `branch_stock = 0.3`
- **WHEN** se confirma una orden con una línea de `450` con unidad Gramo
- **THEN** la confirmación falla con `P0409` (stock insuficiente) porque `0.45 > 0.3`, y no porque `450 > 0.3`

#### Scenario: Unidad incompatible aborta antes de cualquier efecto

- **GIVEN** un producto con unidad base Kilogramo y una sesión de caja abierta
- **WHEN** se confirma una orden con una línea con unidad Litro
- **THEN** la confirmación falla con `P0400`, la orden sigue en `draft` y no existe movimiento de stock, de caja ni evento en la outbox para esa orden
