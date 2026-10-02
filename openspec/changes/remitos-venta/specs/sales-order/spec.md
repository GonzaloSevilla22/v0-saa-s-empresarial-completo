## ADDED Requirements

### Requirement: La orden nacida de un remito se confirma sin mover stock, decidido por su origen persistido
El sistema SHALL confirmar una orden de venta cuyo origen persistido (`source_delivery_note_id`) apunta a un remito sin verificar ni descontar stock y sin registrar movimientos de stock. Todo lo demás de la confirmación SHALL hacerse exactamente igual que en cualquier otra orden:
- forma de pago y caja;
- cuenta corriente y banco;
- numeración fiscal opcional;
- outbox, historial y fila legacy de ventas.

Los snapshots de cada línea de la venta (nombre, SKU, costo y alícuota de IVA) SHALL ser los de la línea del remito, copiados a la orden, sin releer ni bloquear el maestro de productos: sin stock que proteger, la confirmación no toma el bloqueo del producto.

La decisión de no mover stock SHALL tomarse sólo a partir de los datos persistidos de la orden. La confirmación NO SHALL aceptar ningún parámetro que pida no mover stock.

Antes de cualquier escritura, la confirmación SHALL revalidar el remito de origen:
- que sea de la misma cuenta y de sentido venta;
- que esté pendiente (`issued`);
- que tenga el mismo cliente y la misma sucursal que la orden;
- que el multiconjunto de líneas (producto, unidad, cantidad) de la orden sea idéntico al del remito.

Si algo no coincide, SHALL fallar con `P0409 delivery_note_order_mismatch` sin efectos. Una orden sin origen de remito SHALL seguir verificando y descontando stock como hasta ahora.

A lo sumo una orden no cancelada SHALL referenciar el mismo remito.

#### Scenario: Orden de un remito no descuenta
- **GIVEN** una orden `draft` creada por la conversión de un remito pendiente de 3 unidades de A
- **WHEN** se la confirma
- **THEN** el stock de A no cambia, no se escribe ningún movimiento de stock y la orden queda `confirmed`

#### Scenario: Nombre congelado del remito
- **GIVEN** una orden creada desde un remito cuyo producto se renombró después de emitirlo
- **WHEN** se la confirma
- **THEN** las líneas de la venta llevan el nombre y el SKU del remito

#### Scenario: Orden sin origen sigue descontando
- **WHEN** se ejecuta una venta rápida del POS de 2 unidades de A después de este cambio
- **THEN** el stock de A baja en 2 y existe su movimiento `sale` / `sale`

#### Scenario: Origen inválido
- **GIVEN** una orden `draft` cuyo origen apunta a un remito de otra cuenta, anulado, ya convertido, de otro cliente, de otra sucursal, o con líneas distintas
- **WHEN** se intenta confirmarla
- **THEN** la confirmación falla con `P0409 delivery_note_order_mismatch`, sin stock, venta, caja ni evento

#### Scenario: Una sola orden viva por remito
- **GIVEN** un remito con una orden confirmada
- **WHEN** cualquier camino intenta crear otra orden no cancelada con el mismo origen
- **THEN** la base lo rechaza por unicidad

### Requirement: La venta expone su remito de origen
El sistema SHALL exponer en el listado y en el detalle de ventas, y en los pedidos de venta, el id y el número del remito del que nació la venta. Esos datos SHALL derivarse del origen de la orden, filtrado por la cuenta, sin columnas desnormalizadas. Junto con ellos SHALL exponerse que la venta no es editable por ese motivo.

#### Scenario: Venta desde remito en el listado
- **WHEN** el listado de ventas incluye una venta nacida del remito 12
- **THEN** la fila trae el id del remito y su número, y la interfaz muestra "Desde remito R-00000012" con enlace

#### Scenario: Venta común
- **WHEN** el listado incluye una venta del POS
- **THEN** los campos de remito de origen vienen vacíos
