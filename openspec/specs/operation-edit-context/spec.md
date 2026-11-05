# operation-edit-context Specification

## Purpose
TBD - created by archiving change edicion-preserva-contexto. Update Purpose after archive.
## Requirements
### Requirement: La edición de una operación preserva el contexto de su header

Toda ruta que edite una operación de venta o compra SHALL preservar los atributos de contexto del header que no viajen en el payload de edición. Concretamente, `branch_id`, `canal` (venta), `unit_id`, `supplier_id` (compra) y `cost_center_id` (compra) SHALL conservar su valor vigente tras la edición cuando el payload no los informe.

**Excepción para la sucursal de una venta o de una compra** (`ventas-sucursal-por-defecto`, `compras-gastos-sucursal-por-defecto`): un `branch_id` vigente **nulo** de una venta o de una compra no se preserva. La edición lo SHALL resolver a la sucursal principal de la cuenta, con la regla del requirement «Sucursal y canal son reimputables al editar mediante contrato tri-estado». Un `branch_id` vigente no nulo se preserva como siempre.

El contexto SHALL capturarse **antes** de la eliminación de las filas viejas, dentro de la misma transacción, porque después no es recuperable.

La columna legacy `company_id` NO SHALL restaurarse: es un eje de tenancy retirado por C-19 y su omisión es deliberada.

`created_at` NO SHALL preservarse — refleja cuándo se escribió la versión actual de la fila. La fecha del hecho económico viaja en `date`, que sí se preserva por parámetro.

#### Scenario: editar la cantidad conserva la sucursal y el canal

- **GIVEN** una venta imputada a una sucursal no default y con `canal = 'instagram'`
- **WHEN** se edita la operación cambiando solo la cantidad, sin informar sucursal ni canal
- **THEN** la fila resultante conserva la misma `branch_id` y `canal = 'instagram'`

#### Scenario: editar una venta sin sucursal no preserva el nulo

- **GIVEN** una venta con `branch_id` nulo y `canal = 'instagram'`
- **WHEN** se edita la operación cambiando solo la cantidad, sin informar sucursal ni canal
- **THEN** la fila resultante queda en la sucursal principal de la cuenta y conserva `canal = 'instagram'`

#### Scenario: editar una compra sin sucursal no preserva el nulo

- **GIVEN** una compra histórica con `branch_id` nulo, con proveedor y centro de costo imputados
- **WHEN** se edita la operación cambiando solo el importe, sin informar sucursal, proveedor ni centro de costo
- **THEN** las filas resultantes quedan en la sucursal principal de la cuenta y conservan el proveedor y el centro de costo

#### Scenario: editar una compra conserva proveedor y centro de costo

- **GIVEN** una compra con `supplier_id` y `cost_center_id` imputados
- **WHEN** se edita la operación cambiando el importe, sin informar proveedor ni centro de costo
- **THEN** la fila resultante conserva ambos valores

#### Scenario: la unidad de medida sobrevive en el header y en la línea

- **GIVEN** una venta de un producto medido en kilogramos, con `unit_id` en el header y en `sale_items`
- **WHEN** se edita la operación
- **THEN** tanto el header como la línea resultantes conservan el mismo `unit_id`, en vez de quedar en `NULL`

### Requirement: Sucursal y canal son reimputables al editar mediante contrato tri-estado

La edición de una operación SHALL aceptar `branch_id` y `canal` como parámetros tri-estado, distinguiendo tres intenciones por **ausencia o presencia** del parámetro, nunca por su valor:

- parámetro **ausente** → preservar el valor vigente;
- parámetro **presente con `NULL`** → desimputar explícitamente (operación sin sucursal / sin canal);
- parámetro **presente con valor** → reimputar.

La distinción SHALL implementarse con un booleano `p_<campo>_provided` en la RPC y con `model_fields_set` en la capa Python. NO SHALL inferirse desde `is None`.

Una sucursal reimputada SHALL validarse antes de aplicarse: SHALL pertenecer a la cuenta de la operación y SHALL estar operativa. Si no cumple, la edición SHALL fallar con `ERRCODE = 'P0422'` sin modificar la operación.

**Excepción para la sucursal de una venta o de una compra** (`ventas-sucursal-por-defecto`, `compras-gastos-sucursal-por-defecto`): ni una venta ni una compra pueden quedar sin sucursal. En su edición, la sucursal **presente con `NULL`** y la sucursal **ausente** cuyo valor vigente sea `NULL` SHALL resolverse a la sucursal principal de la cuenta (`c26_default_branch`), antes de revertir o reaplicar stock. Si la cuenta no tiene ninguna sucursal operativa a la cual resolver, la edición SHALL fallar con `P0422 no_branch_found` sin modificar la operación.

El canal de la venta conserva las tres intenciones sin excepción. La sucursal del gasto tiene su propia excepción, en su capability (`expense-operation`, «La edición de un gasto preserva su contexto mediante contrato tri-estado»): un nulo también se resuelve a la sucursal por defecto, con la regla del alta del gasto.

#### Scenario: reimputar la sucursal de una venta

- **WHEN** se edita una operación informando una sucursal distinta, perteneciente a la cuenta y operativa
- **THEN** la operación queda imputada a la sucursal nueva

#### Scenario: informar la sucursal de una venta como NULL la registra en la principal

- **GIVEN** una venta imputada a la sucursal B, en una cuenta cuya sucursal principal es A
- **WHEN** se edita la operación con `p_branch_provided = true` y `p_branch_id = NULL`
- **THEN** la operación resultante queda imputada a A, el stock de B se repone y el de A se descuenta

#### Scenario: una venta sin sucursal vigente queda en la principal al editarse

- **GIVEN** una venta con `branch_id` nulo
- **WHEN** se edita la operación sin informar sucursal
- **THEN** la operación resultante queda imputada a la sucursal principal de la cuenta

#### Scenario: informar la sucursal de una compra como NULL la registra en la principal

- **GIVEN** una compra sin dinero posteado, imputada a la sucursal B, en una cuenta cuya sucursal principal es A, con stock ingresado en B
- **WHEN** se edita la operación con `p_branch_provided = true` y `p_branch_id = NULL`
- **THEN** la operación resultante queda imputada a A, la pata de reversa resta el stock de B y la de aplicación lo suma en A

#### Scenario: una compra sin sucursal vigente queda en la principal al editarse

- **GIVEN** una compra histórica con `branch_id` nulo, sin dinero posteado
- **WHEN** se edita la operación sin informar sucursal
- **THEN** la operación resultante queda imputada a la sucursal principal de la cuenta, y el stock neto de la principal no cambia por la edición si las cantidades no cambiaron

#### Scenario: editar una compra sin sucursal operativa a la cual resolver es rechazado

- **GIVEN** una compra con `branch_id` nulo en una cuenta cuyas sucursales están todas inactivas o cerradas
- **WHEN** se edita la operación sin informar sucursal, o informándola como `NULL`
- **THEN** la edición falla con `P0422 no_branch_found` y la operación queda intacta, sin reversa ni reaplicación de stock

#### Scenario: desimputar el canal explícitamente

- **WHEN** se edita una operación informando `canal = NULL` con el indicador de "informado" en verdadero
- **THEN** la operación queda sin canal, y el valor previo no se restaura

#### Scenario: omitir el canal preserva el vigente

- **GIVEN** una venta con `canal = 'mercadolibre'`
- **WHEN** se edita la operación sin incluir el campo canal en el payload
- **THEN** la operación conserva `canal = 'mercadolibre'`

#### Scenario: reimputar a una sucursal ajena o cerrada es rechazado

- **WHEN** se edita una operación informando una sucursal de otra cuenta, o una sucursal cerrada
- **THEN** la edición falla con `ERRCODE = 'P0422'` y la operación queda intacta, sin reversa ni reaplicación de stock

### Requirement: La cantidad decimal atraviesa la ruta de edición igual que la de creación

La ruta de edición de operaciones SHALL aceptar cantidades fraccionarias con la misma precisión que la ruta de creación y que las columnas que las almacenan (`numeric(15,4)`). Ninguna capa del camino — deserialización del payload, parámetros de la RPC, esquemas Pydantic, formularios — SHALL degradar la cantidad a entero, ni por error ni por redondeo silencioso.

Una operación creada con cantidad decimal SHALL ser editable. Editar su cantidad a otro valor decimal SHALL producir el valor exacto en el header, en la línea y en el delta aplicado al stock.

La edición SHALL normalizar la cantidad por unidad exactamente igual que la creación, en sus **dos** patas: la reversa de la operación vieja SHALL devolver al stock la cantidad normalizada que esa operación descontó (la unidad de la línea vieja convertida a la base del producto), y la aplicación de la operación nueva SHALL descontar la cantidad normalizada de la línea nueva. Esto rige para la edición de ventas y para la edición de compras. Una línea nueva con unidad incompatible con el producto SHALL abortar la edición completa con `P0400`, dejando la operación vieja intacta.

#### Scenario: editar una venta creada con cantidad fraccionaria

- **GIVEN** una venta de 2,5 kg de un producto medible
- **WHEN** se edita la operación a 3,25 kg
- **THEN** la edición se completa sin error
- **AND** el header y la línea quedan con `quantity = 3.25`
- **AND** el stock refleja el delta exacto `+2.5 - 3.25`, sin truncamiento

#### Scenario: la cantidad decimal no se redondea al editar

- **WHEN** se edita una operación con una cantidad de tres decimales
- **THEN** el valor persistido conserva los tres decimales, sin redondeo a entero

#### Scenario: editar una venta hecha en gramos revierte y reaplica en kilos

- **GIVEN** un producto con unidad base Kilogramo, stock `1`, y una venta de `450` con unidad Gramo (stock tras la venta: `0.55`)
- **WHEN** se edita la operación a `300` con unidad Gramo
- **THEN** la pata de reversa registra `quantity_delta = +0.45` y la de aplicación `quantity_delta = -0.3`
- **AND** el stock queda en `0.7`, nunca en `450.55` ni en `-299.45`

#### Scenario: editar una compra en gramos revierte y reaplica en kilos

- **GIVEN** un producto con unidad base Kilogramo y una compra de `2000` con unidad Gramo
- **WHEN** se edita la compra a `1500` con unidad Gramo
- **THEN** la reversa registra `quantity_delta = -2` y la aplicación `quantity_delta = +1.5`, y el stock refleja `-2 + 1.5` respecto del estado previo

#### Scenario: la edición rechaza una unidad incompatible sin tocar la operación vieja

- **GIVEN** una venta vigente de `0.5` con unidad Kilogramo sobre un producto en kilogramos
- **WHEN** se intenta editarla reemplazando la línea por una con unidad Litro
- **THEN** la edición falla con `P0400`, la venta vieja y su movimiento de stock permanecen sin cambios y no se registra ninguna pata de reversa

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

### Requirement: Editar una venta con asiento contable emitido no la bloquea (override del PO, 2026-08-20)

A diferencia de los otros tres ledgers (cuenta corriente, caja, banco), el asiento contable del libro diario de partida doble NO es causa de bloqueo de la edición. Una operación de venta del formulario que haya emitido un evento `SaleOperationCreated` (ya sea aún pendiente de procesamiento en el relay, o ya posteado como asiento en el libro diario) SHALL seguir siendo editable. La corrección del asiento contable ante una edición se resuelve ajustándolo en vez de bloqueando la operación: ver la capability `journal-entry`, requirement "SaleOperationAdjusted posts a contra-entry and a new entry", para el mecanismo (reemplazo del evento pendiente in-place, o contra-entry más entry nuevo si el asiento ya procesó). Este requirement documenta la decisión explícita porque el diseño original de este mismo change había recomendado lo contrario (extender el guard de este requirement al asiento contable) antes del override del PO.

#### Scenario: Una venta del formulario con asiento contable emitido sigue siendo editable

- **GIVEN** una venta registrada desde el formulario cuya transacción emitió el evento `SaleOperationCreated`, ya sea pendiente de proceso o ya posteado como asiento
- **WHEN** se intenta editar esa operación, sin cargo en cuenta corriente, sin movimiento de caja y sin movimiento bancario
- **THEN** la edición procede — no hay `P0423` por causa del asiento contable — y el rastro contable se ajusta según el mecanismo de la capability `journal-entry`

#### Scenario: Una operación sin ningún rastro contable sigue siendo editable

- **GIVEN** una venta del formulario registrada antes de que existiera el productor del evento contable, sin cargo en cuenta corriente, sin movimiento de caja, sin movimiento bancario y sin evento emitido
- **WHEN** se edita esa operación cambiando importe y forma de pago
- **THEN** la edición procede normalmente con el acarreo de contexto ya establecido, y no se emite ningún evento contable para esa edición

#### Scenario: La superficie anticipa la falta de bloqueo por asiento

- **WHEN** el usuario abre el listado de operaciones y una de ellas tiene un asiento contable emitido o posteado pero sin cargo de cuenta corriente, movimiento de caja o movimiento bancario
- **THEN** la acción de editar aparece habilitada, porque el asiento contable no es causa de bloqueo

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

### Requirement: Exposición del estado de borrabilidad en el listado
El sistema SHALL exponer al listado de operaciones, derivado de lectura y nunca desde una columna denormalizada, si una operación es borrable y qué razón la bloquea cuando no lo es, y SHALL incluir entre esas razones la **falta de una sesión de caja abierta** cuando la operación tiene un movimiento de caja posteado que su borrado tendría que compensar.

Los derivados que alimentan esa exposición SHALL calcularse en el servidor con los **mismos predicados** que evalúa el comando de borrado. La razón es que uno de ellos —la existencia de una sesión abierta en la caja afectada— depende de un estado que el listado no tiene y que derivarlo en el cliente obligaría a traer las sesiones de todas las cajas para pintar una lista de operaciones.

El listado de compras SHALL exponer, además de los indicadores de cargo en cuenta corriente y de movimiento bancario que ya expone, el indicador de **movimiento de caja** y el de **borrado bloqueado**, que hasta ahora no calculaba porque la compra no tenía forma de tocar la caja.

#### Scenario: Operación facturada en el listado
- **WHEN** el listado incluye una operación con comprobante fiscal emitido
- **THEN** la operación se expone como no borrable
- **AND** la razón informada es el comprobante fiscal

#### Scenario: Operación borrable con compensación pendiente
- **WHEN** el listado incluye una operación con dinero posteado y sin comprobante
- **THEN** la operación se expone como borrable
- **AND** se exponen los libros que su borrado compensaría

#### Scenario: Compra con movimiento de caja y sesión abierta
- **WHEN** el listado incluye una compra que descontó de la caja y existe una sesión abierta en esa caja
- **THEN** la compra se expone como borrable
- **AND** entre los libros a compensar figura la caja

#### Scenario: Compra con movimiento de caja y sin sesión abierta
- **WHEN** el listado incluye una compra que descontó de la caja y no existe ninguna sesión abierta en esa caja
- **THEN** la compra se expone como no borrable
- **AND** la razón informada es que hay que abrir la caja

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

### Requirement: La edición avisa y pide confirmación antes de anular el comprobante pendiente

El formulario de edición de una venta SHALL distinguir en pantalla los tres casos fiscales, y NO SHALL presentarse en solo lectura salvo que la acción esté efectivamente bloqueada.

Cuando el comprobante YA SALIÓ hacia ARCA, el formulario SHALL abrirse en solo lectura con el control de guardado deshabilitado, y el motivo accesible SHALL nombrar la causa REAL —autorizado por ARCA, enviado y esperando respuesta, o congelado— porque la acción que le queda al usuario es distinta en cada caso.

Cuando el comprobante está pendiente y NO salió, el formulario SHALL quedar completamente editable y SHALL avisar, antes de guardar, que guardar va a anular ese comprobante, identificándolo por su número. Ese aviso SHALL presentarse como advertencia y no como error: anular algo que nunca salió hacia ARCA no es destructivo y se puede volver a emitir.

El guardado en ese caso SHALL exigir una confirmación explícita que explique el motivo y la salida (volver a emitir después), y al cerrarse SHALL devolver el foco al control que la abrió, para no obligar a quien navega con teclado a recorrer el formulario de nuevo.

El resultado que la interfaz informa SHALL provenir de la respuesta del servidor y NO de lo que el cliente creía antes de guardar: si la carrera contra el relay hizo que el servidor bloqueara, el usuario SHALL ver el rechazo y nunca un "se anuló" falso.

El listado de ventas SHALL exponer el estado del comprobante —incluido el anulado, con rótulo propio— y SHALL habilitar o deshabilitar las acciones de editar y borrar según el mismo predicado del servidor, nombrando la causa real cuando estén deshabilitadas.

#### Scenario: comprobante pendiente no enviado

- **WHEN** el usuario abre la edición de una venta con comprobante pendiente sin enviar
- **THEN** el formulario está editable y muestra el aviso de que guardar anulará ese comprobante, con su número

#### Scenario: confirmación explícita

- **WHEN** el usuario guarda esa edición
- **THEN** se le pide una confirmación que explica que el comprobante se anula para no emitirse con los importes viejos, y que podrá emitir uno nuevo

#### Scenario: el foco no se pierde al cancelar

- **WHEN** el usuario cancela la confirmación
- **THEN** el foco vuelve al control de guardado que la abrió

#### Scenario: comprobante ya enviado

- **WHEN** el usuario abre la edición de una venta cuyo comprobante ya salió hacia ARCA
- **THEN** el formulario se presenta en solo lectura, con el motivo real nombrado y el control de guardado deshabilitado con su motivo accesible

#### Scenario: el resultado lo dicta el servidor

- **GIVEN** una edición que el cliente creía anulable
- **WHEN** el servidor la rechaza porque el comprobante salió hacia ARCA en el intervalo
- **THEN** la interfaz muestra el rechazo y no informa ninguna anulación

### Requirement: La edición y el borrado toman las filas de la operación antes de resolver su orden

`rpc_atomic_update_sale_operation` y `rpc_delete_sale_operation` SHALL tomar las filas de `sales` de la operación `FOR UPDATE`, en orden ascendente de `id`, ANTES de resolver su `sales_orders` y antes de tocar cualquier libro (stock, caja, banco, cuenta corriente, outbox), siguiendo el orden global `sales → sales_orders → fiscal_documents → resto`. La edición SHALL re-contar las filas bajo el lock y fallar con `P0404` si otra edición o un borrado se llevó alguna mientras esperaba (incluido un doble "Guardar"), antes de revertir stock. El borrado SHALL recalcular bajo el lock el conjunto de filas a borrar y devolver `false` si quedó vacío.

#### Scenario: una edición concurrente no ve una orden a medio crear

- **GIVEN** una promoción que ya tomó las filas de la operación y creó la orden sin commitear
- **WHEN** se edita la venta
- **THEN** la edición espera a la promoción, ve la orden creada y la recalcula; no queda ningún comprobante vivo por el importe anterior

#### Scenario: doble guardado de la misma edición

- **GIVEN** dos ediciones concurrentes de la misma operación
- **WHEN** la primera commitea
- **THEN** la segunda falla con `P0404` antes de revertir stock o escribir en cualquier libro, sin duplicar la operación

#### Scenario: un borrado que pierde contra una edición no borra nada

- **GIVEN** una edición en curso que ya tomó las filas de la operación
- **WHEN** se borra la venta por su `operation_id`
- **THEN** el borrado espera y, cuando la edición commitea, el recuento bajo el lock queda vacío: devuelve `false`, no encola `SaleOperationDeleted` para la operación vieja, no toca la venta editada ni mueve stock

#### Scenario: el borrado espera a una promoción en curso

- **GIVEN** una promoción en curso sobre la operación
- **WHEN** se borra la venta
- **THEN** el borrado espera, ve la orden y la cancela en la misma transacción

### Requirement: La edición valida el stock por sucursal y no usa una sucursal desactivada

La edición de una venta SHALL validar el stock POR SUCURSAL, sobre la misma sucursal en la que descuenta (la efectiva de la venta), y NOT SHALL aceptar que la suma de todas las sucursales alcance cuando la sucursal de descuento no alcanza. Cuando no alcanza, SHALL rechazar con el mismo `P0409` de stock insuficiente que el alta (`insufficient_branch_stock for product <id>` cuando la sucursal se informó, `Insufficient stock for product <id>` cuando se preservó o se resolvió a la principal), antes de escribir la línea nueva y con la transacción entera revertida (la pata de reversa incluida). La edición NOT SHALL terminar en el error de restricción `branch_stock_quantity_non_negative` (`23514`) por una falta de stock.

La edición de una compra SHALL comprobar, antes de revertir cada línea, que la sucursal de la fila (la principal si la fila no tenía) tiene stock suficiente para restar lo que la compra había sumado. Si la mercadería ya se vendió y no alcanza, SHALL rechazar con `P0409` `purchase_edit_stock_consumed: de <producto> en la sucursal quedan X y la edición necesita restar Y`, sin cambiar qué ediciones prosperan (las que antes terminaban en `23514` terminan en este rechazo legible) y con la transacción entera revertida. La salida para el usuario es borrar la compra, que sí aplica el piso en cero, y volver a cargarla.

Una sucursal desactivada (`is_active = false`) NOT SHALL recibir stock por una edición de venta: si la sucursal vigente de la venta fue desactivada, la edición SHALL tratarla como una venta sin sucursal y resolverla a la principal operativa, y la pata de reversa de una fila cuya sucursal está desactivada SHALL devolver el stock a la principal operativa, dejando en la `metadata` del movimiento `fallback_from_branch_id` y `fallback_reason = 'branch_inactive'` (mismas claves y criterio que la reversa del borrado). Una sucursal cerrada y activa SHALL conservarse como hasta ahora.

#### Scenario: Editar una venta con la sucursal sin stock aunque el total alcance

- **GIVEN** una venta de 2 unidades en la sucursal B (B queda en 0) y la principal con 10 del mismo producto
- **WHEN** se edita la venta a 5 unidades sin cambiar la sucursal
- **THEN** la edición se rechaza con `P0409` `Insufficient stock for product <id>`, B sigue en 0, la principal en 10, y la venta original y su único movimiento no cambian

#### Scenario: Editar una venta con sucursal explícita sin stock

- **WHEN** se edita la misma venta informando la sucursal B y 5 unidades
- **THEN** la edición se rechaza con `P0409` `insufficient_branch_stock for product <id>`

#### Scenario: Reimputar una venta a una sucursal con stock prospera

- **GIVEN** la venta anterior, con B en 1 tras bajarla a 1 unidad
- **WHEN** se edita a 4 unidades informando la principal (con 10)
- **THEN** B recupera la unidad devuelta y la principal descuenta 4

#### Scenario: Editar una compra cuya mercadería ya se vendió

- **GIVEN** una compra de 4 unidades y una venta de 12 que dejó 2 en la sucursal
- **WHEN** se edita la compra a 1 unidad (o sólo su precio)
- **THEN** la edición se rechaza con `P0409` `purchase_edit_stock_consumed: de <producto> en la sucursal quedan 2 y la edición necesita restar 4`, y el saldo, el libro y la compra original no cambian

#### Scenario: Editar una compra con la mercadería todavía en stock

- **GIVEN** una compra de 4 unidades y una venta de 1 (quedan 13)
- **WHEN** se edita la compra a 6 y después a 3 unidades
- **THEN** el stock pasa a 15 y después a 12, sin error

#### Scenario: Editar una venta de una sucursal desactivada

- **GIVEN** una venta de 2 unidades en la sucursal C, C vaciada y desactivada, y una principal operativa con 8
- **WHEN** se edita la venta a 1 unidad sin informar sucursal
- **THEN** C sigue en 0, la principal pasa a 9, la venta queda en la principal, y el movimiento de reversa de la edición registra la principal con `fallback_from_branch_id = C` y `fallback_reason = 'branch_inactive'`

#### Scenario: Editar una venta de una sucursal activa no marca respaldo

- **WHEN** se edita una venta de una sucursal activa
- **THEN** conserva su sucursal y el movimiento de reversa no lleva `fallback_reason`

### Requirement: La venta nacida de un remito es inmutable
El sistema SHALL rechazar con `P0423 delivery_note_sale_locked` toda edición de una venta cuya orden nació de un remito.

El rechazo SHALL evaluarse inmediatamente después de tomar las filas de la operación y antes de cualquier otro efecto: la anulación de un comprobante pendiente, la reversa o la aplicación de stock, y los libros. El bloqueo SHALL alcanzar a la operación entera, también a la cabecera, porque la edición de ventas reemplaza siempre las líneas y volvería a descontar stock.

El listado de ventas SHALL exponer el motivo para que la interfaz deshabilite "Editar" con la explicación: eliminar la venta, corregir el remito y volver a convertirlo.

#### Scenario: Edición rechazada sin efectos
- **GIVEN** una venta nacida de un remito, con un comprobante fiscal pendiente que todavía no salió hacia ARCA
- **WHEN** se intenta editarla
- **THEN** la operación falla con `P0423 delivery_note_sale_locked`, el comprobante sigue pendiente y el stock, la caja y las líneas no cambian

#### Scenario: Botón deshabilitado con motivo
- **WHEN** el listado de ventas muestra una venta nacida de un remito
- **THEN** "Editar" aparece deshabilitado con el motivo y el número del remito

### Requirement: La compra nacida de un remito es inmutable
El sistema SHALL rechazar la edición de una compra nacida de un remito de compra con `P0423 delivery_note_purchase_locked`, antes de los bloqueos por dinero posteado y antes de cualquier reversa o escritura, sin anular nada ni mover stock. El listado de compras SHALL exponerlo y deshabilitar "Editar" con el motivo: para corregirla, se borra la compra, se edita el remito y se vuelve a convertir.

#### Scenario: Editar la compra de un remito
- **GIVEN** una compra a crédito nacida de un remito de compra
- **WHEN** se intenta editar su cabecera o sus líneas
- **THEN** la operación falla con `P0423 delivery_note_purchase_locked`, y ni el stock, ni el ledger, ni la cuenta corriente del proveedor cambian

#### Scenario: Editar deshabilitado en el listado
- **WHEN** el usuario ve una compra nacida de un remito en `/compras`
- **THEN** la acción "Editar" está deshabilitada con el motivo de que la compra nació del remito

### Requirement: El listado de compras expone la borrabilidad de la compra nacida de un remito
El listado de compras SHALL exponer, para cada compra nacida de un remito, su remito de origen y si la sucursal del remito está activa, derivado en el servidor con el mismo predicado que evalúa el borrado. La interfaz SHALL deshabilitar "Eliminar" con su motivo cuando el usuario no tiene el permiso de anular remitos de compra o cuando la sucursal del remito está inactiva, y el motivo de remito de "Editar" SHALL tener precedencia sobre el bloqueo por dinero posteado.

#### Scenario: Eliminar deshabilitado para el rol de compras
- **GIVEN** una compra nacida de un remito y un usuario con rol `purchases`
- **WHEN** abre `/compras`
- **THEN** "Eliminar" está deshabilitado con el motivo de que borrarla reabre el remito y requiere administrador o dueño

#### Scenario: Eliminar deshabilitado con la sucursal del remito inactiva
- **GIVEN** una compra nacida de un remito cuya sucursal se desactivó
- **WHEN** un administrador abre `/compras`
- **THEN** "Eliminar" está deshabilitado con el motivo de reactivar la sucursal del remito

