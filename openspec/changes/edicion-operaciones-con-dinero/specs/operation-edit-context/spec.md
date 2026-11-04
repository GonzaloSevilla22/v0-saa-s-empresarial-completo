## MODIFIED Requirements

### Requirement: La orden de venta promovida sigue a la operación editada

Cuando se edita una venta, toda `sales_orders` asociada a esa operación que **no** tenga comprobante fiscal vivo SHALL quedar apuntando a la operación editada **y recalcularse** dentro de la misma transacción: `total = round(Σ sales.total, 2)` de la operación editada, `client_id` y sucursal de sus filas, y una línea de `sales_order_items` por fila, con el mismo helper interno que usa la promoción (`_sales_order_sync_from_operation`). Como la edición conserva el `operation_id` (capability `operation-money-edit`), el apuntado no cambia de valor, salvo para la operación legacy que recibe un identificador al editarse; el recálculo SHALL ejecutarse igual. NO SHALL quedar ninguna orden apuntando a un identificador de operación inexistente, ni una orden con el total, el cliente o las líneas de la operación anterior a la edición — de lo contrario "Volver a facturar" o el "Facturar" de una venta editada emitirían por el importe viejo. Si la operación editada queda sin filas, la edición SHALL fallar con `P0400 operation_empty` en vez de dejar una orden confirmada sobre una operación vacía.

#### Scenario: la orden promovida no queda colgada tras editar

- **GIVEN** una venta promovida a `sales_orders` sin comprobante fiscal
- **WHEN** se edita la operación
- **THEN** la orden sigue apuntando al `operation_id` de la operación editada, que es el mismo de antes, y no queda ninguna orden huérfana

#### Scenario: la orden re-sincronizada se factura por el importe y el receptor nuevos

- **GIVEN** una venta de 500 × 2 promovida a una orden de $1000 sin comprobante
- **WHEN** se edita a 500 × 5 con otro cliente y después se emite el comprobante
- **THEN** la orden queda con `total = 2500.00`, el cliente nuevo y las líneas de la venta editada, y el comprobante sale por $2500 con el receptor del cliente nuevo

#### Scenario: volver a facturar después de anular emite el importe nuevo

- **GIVEN** una venta con comprobante `pending_cae` que no salió hacia ARCA
- **WHEN** se edita la cantidad (el comprobante queda `voided`) y se vuelve a facturar
- **THEN** el comprobante nuevo sale por el importe editado, también cuando el anterior había quedado `rejected`

### Requirement: El proveedor es reimputable al editar una compra mediante contrato tri-estado

La edición de una operación de compra SHALL aceptar `supplier_id` como parámetro tri-estado, con la misma mecánica ya definida para `branch_id` y `canal`, distinguiendo la intención por **ausencia o presencia** del parámetro y nunca por su valor:

- parámetro **ausente** → preservar el proveedor vigente;
- parámetro **presente con `NULL`** → desimputar explícitamente (compra sin proveedor);
- parámetro **presente con valor** → reimputar.

La distinción SHALL implementarse con un booleano `p_supplier_provided` en la RPC y con `model_fields_set` en la capa Python. NO SHALL inferirse desde `is None`.

Un proveedor reimputado SHALL validarse antes de aplicarse: SHALL pertenecer a la cuenta de la operación y NO SHALL estar borrado. Si no cumple, la edición SHALL fallar sin modificar la operación.

Cuando la compra tiene un cargo en la cuenta corriente de un proveedor, reimputar el proveedor SHALL trasladar el cargo: revertirlo en la cuenta corriente del proveedor anterior y registrarlo en la del nuevo, con las reglas de la capability `operation-money-edit`. Cuando la compra no tiene cargo y la edición no la pasa a cuenta corriente, el proveedor SHALL seguir siendo una imputación analítica, sin ningún movimiento de cuenta corriente.

#### Scenario: reimputar el proveedor de una compra sin cargo

- **GIVEN** una compra sin cargo de cuenta corriente, imputada al proveedor A, con una forma de pago que no es de cuenta corriente
- **WHEN** se edita la operación informando el proveedor B, perteneciente a la cuenta y no borrado
- **THEN** todas las líneas de la operación quedan imputadas a B, y no se crea ni se revierte ningún movimiento de cuenta corriente

#### Scenario: reimputar el proveedor de una compra a crédito traslada el cargo

- **GIVEN** una compra a crédito de 8000 con su cargo en la cuenta corriente del proveedor A
- **WHEN** se edita informando el proveedor B
- **THEN** la cuenta corriente de A recibe la reversión de 8000 y la de B un cargo de 8000, en la misma transacción

#### Scenario: omitir el proveedor preserva el vigente

- **GIVEN** una compra imputada a un proveedor
- **WHEN** se edita la operación sin incluir el campo proveedor en el payload
- **THEN** la operación conserva el mismo proveedor

#### Scenario: desimputar el proveedor explícitamente

- **GIVEN** una compra sin forma de pago de cuenta corriente
- **WHEN** se edita la compra informando proveedor `NULL` con el indicador de "informado" en verdadero
- **THEN** la operación queda sin proveedor, y el valor previo no se restaura

#### Scenario: reimputar a un proveedor ajeno o borrado es rechazado

- **WHEN** se edita una compra informando un proveedor de otra cuenta, inexistente, o con `deleted_at` seteado
- **THEN** la edición falla y la operación queda intacta, sin reversa ni reaplicación de stock

#### Scenario: el formulario de edición expone el selector que la RPC acepta

- **WHEN** el usuario abre una compra editable en el formulario de edición
- **THEN** el selector de proveedor aparece precargado con el proveedor vigente de la operación y su cambio produce un efecto real al guardar

### Requirement: El borrado consulta los mismos locks que la edición

El sistema SHALL evaluar en el borrado de una operación el mismo predicado de bloqueo fiscal que gobierna su edición, y SHALL localizar el dinero que su borrado compensa con la misma definición de huella neta que usa la edición (capability `operation-money-edit`).

El dinero registrado no bloquea ni la edición ni el borrado. La edición lo ajusta y el borrado lo compensa, libro por libro.

El lock fiscal SHALL bloquear con `P0423` cuando el comprobante ya salió hacia ARCA (`authorized`, o `pending_cae` con marca de envío o congelado), y SHALL habilitar la acción anulando el comprobante (`voided`) en la misma transacción cuando todavía no salió. Edición y borrado SHALL compartir una única definición de esa regla, no dos copias.

#### Scenario: Operación con comprobante fiscal ya enviado

- **WHEN** se intenta borrar una operación cuyo comprobante está `authorized`, marcado como enviado o congelado
- **THEN** el sistema rechaza el borrado con `P0423`
- **AND** aplica exactamente el mismo predicado que bloquea la edición

#### Scenario: Operación con comprobante pendiente no enviado

- **WHEN** se borra una operación cuyo comprobante está en `pending_cae` sin marca de envío
- **THEN** el borrado procede y el comprobante queda anulado en la misma transacción
- **AND** la edición de esa misma operación se resuelve igual, por la misma definición

#### Scenario: Operación con dinero registrado y sin comprobante

- **WHEN** se borra una operación con dinero registrado y sin comprobante fiscal
- **THEN** el borrado procede
- **AND** cada libro con huella neta distinta de cero recibe su contra-movimiento

### Requirement: El gasto se incorpora al contrato transversal de edición de operaciones

El sistema SHALL incorporar el gasto al mismo contrato transversal de edición que ya rige para ventas y compras, en sus tres piezas:

- la edición de una operación con dinero ajusta sus libros según la capability `operation-money-edit`, en vez de rechazarse;
- la omisión de una clave de contexto en la petición preserva el valor vigente;
- la reimputación se expresa con el contrato tri-estado.

La definición normativa de ese contrato para el gasto —los campos de contexto alcanzados y el criterio de rechazo de un valor ajeno o inactivo— SHALL vivir en la capability `expense-operation`, y la del ajuste de sus libros en `operation-money-edit`. Ninguna de las dos SHALL duplicarse en esta capability, para que la regla tenga una sola fuente de verdad y no queden dos copias que diverjan en el próximo cambio que toque una sola de ellas.

El gasto SHALL quedar además cubierto por el criterio transversal de que el borrado y la edición localizan su dinero con la misma huella neta, de modo que la superficie derive un único estado por operación y no dos criterios capaces de divergir.

#### Scenario: El gasto sigue el mismo criterio que la venta y la compra

- **GIVEN** un gasto con dinero registrado en algún libro
- **WHEN** un usuario lo edita
- **THEN** la edición ajusta sus libros con el mismo criterio que ya rige para una venta o una compra con dinero registrado, en vez de rechazarse

#### Scenario: El contexto del header no se pierde por omisión

- **GIVEN** un gasto sin movimientos, con sucursal, centro de costo y forma de pago imputados
- **WHEN** se lo edita mencionando únicamente su importe
- **THEN** los tres campos de contexto conservan su valor vigente
- **AND** ninguno se interpreta como desimputación

#### Scenario: Edición y borrado leen la misma huella

- **WHEN** la superficie muestra un gasto del listado
- **THEN** los indicadores de dinero que usan la edición y el borrado se derivan de la misma huella neta que evalúa el servidor

## REMOVED Requirements

### Requirement: La operación con cargo en cuenta corriente o movimiento de caja posteado es inmutable
**Reason**: El PO pidió (2026-10-14) que toda venta, compra y gasto sea editable aunque tenga dinero registrado, y que la única excepción sea el comprobante fiscal. La edición ya no se rechaza por dinero registrado: compensa la huella vigente y registra el efecto nuevo en la misma transacción, sólo en los libros que cambian.
**Migration**: El comportamiento lo define la capability `operation-money-edit`. El guard `P0423` por cargo, caja o banco se retira de `rpc_atomic_update_sale_operation` y de `rpc_atomic_update_purchase_operation`. El indicador `is_payment_locked` se retira de los listados y se reemplaza por `edit_locked_reason`. El camino "emití una nota de crédito y registrá una venta nueva" deja de ser el único para corregir una venta con dinero sin comprobante.

### Requirement: La edición no puede convertir una compra en compra a cuenta corriente
**Reason**: Existía porque la edición no podía postear cargos en cuenta corriente. Ahora la edición registra el cargo del proveedor cuando el contrato de pago pasa a cuenta corriente, con las mismas reglas del alta.
**Migration**: Se retira `credit_transition_not_allowed`. `credit_requires_supplier` (`P0400`) se conserva y se evalúa cuando el efecto deseado en cuenta corriente existe (regla de herencia de `operation-money-edit`). Una compra a crédito histórica sin proveedor y sin cargo sigue siendo editable sin crearle deuda mientras la edición no cambie su forma de pago ni su proveedor.

### Requirement: El bloqueo de edición de una compra alcanza su movimiento de caja
**Reason**: El movimiento de caja de una compra deja de bloquear su edición: la edición lo ajusta con las reglas de `operation-money-edit` y `cash-movement`.
**Migration**: El tercer `P0423` de `rpc_atomic_update_purchase_operation` se retira. El indicador `has_cash_movement` del listado de compras se conserva con semántica de huella neta y alimenta el diálogo de borrado y el plan de la edición.
