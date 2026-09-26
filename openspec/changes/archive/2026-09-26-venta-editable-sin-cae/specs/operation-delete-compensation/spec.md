## MODIFIED Requirements

### Requirement: Bloqueo del borrado de una operación con comprobante fiscal

El sistema SHALL rechazar con el código de error `P0423` el borrado de una venta cuyo comprobante fiscal YA SALIÓ hacia ARCA —`authorized`, o `pending_cae` con marca de envío o congelado— aplicando el mismo predicado que bloquea su edición.

Un comprobante en `pending_cae` que todavía NO salió hacia ARCA NO SHALL bloquear el borrado: SHALL anularse (`voided`) en la misma transacción del borrado, con la misma definición única que usa la edición (ver `afip-fiscal-document`, "Anulación del comprobante pendiente al editar o borrar su venta"). Un comprobante `rejected` o `voided` tampoco bloquea, y no se toca.

El guard fiscal SHALL seguir siendo el PRIMERO del borrado, antes de compensar cuenta corriente, caja o banco y antes de revertir stock: si rechaza, ningún libro quedó tocado.

#### Scenario: Venta facturada

- **WHEN** un usuario intenta borrar una venta con comprobante `authorized`
- **THEN** el sistema rechaza la operación con `P0423`
- **AND** informa que el camino de corrección es la Nota de Crédito
- **AND** la venta, su comprobante y todos sus movimientos quedan intactos

#### Scenario: Venta con comprobante ya enviado a ARCA

- **WHEN** un usuario intenta borrar una venta cuyo comprobante tiene marca de envío y aún no tiene respuesta
- **THEN** el sistema rechaza la operación con `P0423` nombrando esa causa
- **AND** ningún libro recibe contra-movimientos

#### Scenario: Venta con comprobante pendiente no enviado

- **WHEN** un usuario borra una venta cuyo comprobante está en `pending_cae` sin marca de envío
- **THEN** el borrado procede, el comprobante queda `voided` en la misma transacción
- **AND** los libros con movimientos de esa operación reciben su contra-movimiento como en cualquier borrado
