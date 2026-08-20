## ADDED Requirements

### Requirement: La operación con comprobante fiscal emitido es inmutable

Una operación de venta que tenga un comprobante fiscal asociado en estado `pending_cae` o `authorized` NO SHALL poder editarse. La edición SHALL rechazarse con `ERRCODE = 'P0423'` **antes** de ejecutar cualquier reversa, eliminación o reaplicación, de modo que la operación quede intacta.

El vínculo SHALL resolverse por consulta en el momento de la edición, siguiendo `sales.operation_id → sales_orders.sale_operation_id → sales_orders.fiscal_document_id → fiscal_documents.status`. NO SHALL introducirse una columna denormalizada de "facturado" en `sales`: sería una segunda fuente de verdad capaz de desincronizarse del comprobante.

Un comprobante en estado `rejected` NO SHALL bloquear la edición: nunca llegó a existir fiscalmente.

El mensaje de error SHALL nombrar el camino correcto — emitir una nota de crédito y registrar una venta nueva — y no limitarse a informar el rechazo.

La compra queda **fuera** de este requirement: no lleva CAE propio, el comprobante lo emite el proveedor, y no existe vínculo entre `purchases` y `fiscal_documents`.

#### Scenario: editar una venta con CAE autorizado es rechazado

- **GIVEN** una venta promovida a `sales_orders` con un comprobante fiscal en estado `authorized`
- **WHEN** se intenta editar la operación
- **THEN** la edición falla con `ERRCODE = 'P0423'`
- **AND** el mensaje indica que corresponde emitir una nota de crédito y registrar una venta nueva
- **AND** la operación conserva sus filas, sus líneas y su stock sin cambio alguno

#### Scenario: editar una venta con comprobante pendiente de CAE es rechazado

- **GIVEN** una venta cuyo comprobante está en estado `pending_cae`, con numeración ya reservada
- **WHEN** se intenta editar la operación
- **THEN** la edición falla con `ERRCODE = 'P0423'`

#### Scenario: un comprobante rechazado no bloquea la edición

- **GIVEN** una venta cuyo único comprobante quedó en estado `rejected`
- **WHEN** se edita la operación
- **THEN** la edición se completa normalmente

#### Scenario: la venta no facturada sigue siendo editable

- **GIVEN** una venta sin `sales_orders` asociada, o con una orden sin comprobante fiscal
- **WHEN** se edita la operación
- **THEN** la edición se completa normalmente, sin activar el guard fiscal

#### Scenario: el frontend explica el bloqueo antes de que el usuario llegue al error

- **WHEN** el usuario abre el formulario de edición de una operación con comprobante emitido
- **THEN** el formulario se presenta en solo lectura, con la explicación del bloqueo y el camino de nota de crédito, y el control de guardado deshabilitado con su motivo accesible
