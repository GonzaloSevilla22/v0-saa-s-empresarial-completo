## ADDED Requirements

### Requirement: Borrar una compra nacida de un remito compensa el dinero, no toca el stock y devuelve el remito a pendiente
El sistema SHALL borrar una compra nacida de un remito de compra compensando cuenta corriente del proveedor, caja y banco igual que cualquier compra, SHALL NOT revertir stock (la reversa se saltea de forma explícita, no por ausencia de movimientos) y SHALL devolver el remito a `issued` con la transición `converted → issued`, el usuario que borró y el motivo, en la misma transacción.

Antes de cualquier efecto, el borrado SHALL exigir el rol de anular remitos de compra (administrador o dueño, `P0403 insufficient_role`) y que la sucursal del remito esté activa y no cerrada (`P0422 delivery_note_branch_inactive`). El diálogo de borrado SHALL explicar que el stock no vuelve y que, para sacar la mercadería del stock, hay que anular el remito.

#### Scenario: Borrado de una compra en efectivo nacida de un remito
- **GIVEN** una compra en efectivo nacida de un remito de compra, con la caja abierta
- **WHEN** un administrador la borra
- **THEN** la caja registra el contra-movimiento, el stock no cambia, la compra deja de existir y el remito vuelve a `issued`

#### Scenario: Sucursal del remito desactivada
- **GIVEN** una compra nacida de un remito cuya sucursal se desactivó después de convertir
- **WHEN** se intenta borrar la compra
- **THEN** la operación falla con `P0422 delivery_note_branch_inactive`, sin compensar dinero, y el remito sigue `converted`

#### Scenario: El diálogo explica el stock
- **WHEN** el usuario abre el diálogo de borrado de una compra nacida del remito `RC-00000012`
- **THEN** el diálogo dice que el stock no vuelve, que el remito `RC-00000012` vuelve a quedar pendiente y que para sacar la mercadería del stock hay que anularlo
