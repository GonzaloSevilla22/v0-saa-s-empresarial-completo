## ADDED Requirements

### Requirement: Borrar una venta nacida de un remito compensa el dinero, no toca el stock y devuelve el remito a pendiente
El sistema SHALL borrar una venta cuya orden nació de un remito con la misma compensación atómica que cualquier venta, en un todo o nada:
- el mismo bloqueo por comprobante fiscal emitido;
- la cuenta corriente, la caja con su sesión abierta y el banco;
- el evento de borrado y la cancelación de la orden.

La reversa de stock SHALL saltearse explícitamente: la mercadería quedó entregada con el remito, y su movimiento de stock pertenece al remito, no a la venta.

En la misma transacción, el remito SHALL volver al estado pendiente (`issued`), registrando la transición `converted → issued` con el usuario y un motivo que identifica el borrado de la venta.

Antes de cualquier efecto, el borrado SHALL exigir que la sucursal del remito siga activa y no cerrada; si no, SHALL rechazarse con `P0422 delivery_note_branch_inactive`, sin compensar nada, para no reabrir el remito en una sucursal que no opera.

El diálogo de borrado SHALL informar que el stock no vuelve y que, para devolver la mercadería al stock, hay que anular el remito, nombrando su número. Después del borrado, las pantallas de remitos SHALL mostrar el remito como pendiente sin necesidad de recargar.

#### Scenario: Borrado de una venta en efectivo nacida de un remito
- **GIVEN** una venta en efectivo nacida del remito R-00000003, con la caja de su sucursal abierta
- **WHEN** se borra la venta
- **THEN** la caja registra el contramovimiento, la orden queda `canceled`, el stock no cambia y el remito vuelve a `issued` con su historial

#### Scenario: Sin caja abierta
- **GIVEN** la misma venta y ninguna sesión de caja abierta en esa caja
- **WHEN** se intenta borrarla
- **THEN** el borrado falla con `P0426`, como cualquier venta, y el remito sigue `converted`

#### Scenario: Sucursal del remito desactivada
- **GIVEN** la misma venta, y la sucursal del remito vaciada y desactivada después de la conversión
- **WHEN** se intenta borrarla
- **THEN** el borrado falla con `P0422 delivery_note_branch_inactive`, sin compensación, y el remito sigue `converted`

#### Scenario: El diálogo explica que el stock no vuelve
- **WHEN** el usuario abre el diálogo de borrado de una venta nacida de un remito
- **THEN** el diálogo enumera las compensaciones de dinero y avisa que el stock no vuelve, con el número del remito y la indicación de anularlo para devolver la mercadería
