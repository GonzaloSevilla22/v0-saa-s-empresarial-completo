## ADDED Requirements

### Requirement: Costo unitario congelado en stock_movements para valuación

El sistema SHALL agregar `unit_cost_snapshot NUMERIC(15,2)` NULLABLE a `stock_movements` y SHALL congelar el costo unitario del producto al registrar cada movimiento generado por una venta o compra, dentro de la misma transacción que ya escribe `quantity_before`/`quantity_after`. Este costo congelado SHALL habilitar la valuación de inventario histórica sin depender de `products.cost` actual, y SHALL respetar la inmutabilidad del ledger (append-only) ya especificada: el valor se escribe una única vez en el INSERT del movimiento.

#### Scenario: El movimiento generado por una venta congela el costo

- **GIVEN** un producto con `products.cost = 600`
- **WHEN** una venta genera un movimiento `type = 'sale'` en `stock_movements`
- **THEN** el movimiento tiene `unit_cost_snapshot = 600`, escrito en la misma transacción que `quantity_after`, y no se modifica luego

#### Scenario: Movimientos históricos conservan NULL sin romper el ledger

- **WHEN** la migración agrega `unit_cost_snapshot` a `stock_movements`
- **THEN** los movimientos previos quedan con `unit_cost_snapshot = NULL` y el carácter append-only del ledger se mantiene (ni UPDATE ni DELETE)

#### Scenario: La reversa de stock preserva el costo del movimiento original

- **GIVEN** un movimiento de venta con `unit_cost_snapshot = 600`
- **WHEN** se elimina la venta y se genera el contra-movimiento de reversa
- **THEN** el contra-movimiento congela su propio `unit_cost_snapshot` sin alterar el `unit_cost_snapshot` del movimiento original
