## ADDED Requirements

### Requirement: El gasto se incorpora al contrato transversal de edición de operaciones

El sistema SHALL incorporar el gasto al mismo contrato transversal de edición que ya rige para ventas y compras, en sus tres piezas: la operación con dinero posteado es inmutable, la omisión de una clave de contexto en la petición preserva el valor vigente, y la reimputación se expresa con el contrato tri-estado.

La definición normativa de ese contrato para el gasto —los predicados de localización de movimientos, el código de error del bloqueo, los campos de contexto alcanzados y el criterio de rechazo de un valor ajeno o inactivo— SHALL vivir en la capability `expense-operation` y SHALL NOT duplicarse en esta capability, para que la regla tenga una sola fuente de verdad y no queden dos copias que diverjan en el próximo cambio que toque una sola de ellas.

El gasto SHALL quedar además cubierto por el criterio transversal de que el borrado evalúa los mismos predicados de movimientos que la edición, de modo que la superficie derive un único estado de bloqueo por operación y no dos criterios capaces de divergir.

#### Scenario: El gasto sigue el mismo criterio que la venta y la compra

- **GIVEN** un gasto con dinero posteado en algún libro
- **WHEN** un usuario intenta editarlo
- **THEN** es rechazado con el mismo criterio de inmutabilidad que ya rige para una venta o una compra con dinero posteado

#### Scenario: El contexto del header no se pierde por omisión

- **GIVEN** un gasto sin movimientos, con sucursal, centro de costo y forma de pago imputados
- **WHEN** se lo edita mencionando únicamente su importe
- **THEN** los tres campos de contexto conservan su valor vigente
- **AND** ninguno se interpreta como desimputación

#### Scenario: Edición y borrado leen el mismo estado de bloqueo

- **WHEN** la superficie muestra un gasto del listado
- **THEN** el estado de bloqueo de la edición y el del borrado se derivan de los mismos predicados que evalúa el servidor
