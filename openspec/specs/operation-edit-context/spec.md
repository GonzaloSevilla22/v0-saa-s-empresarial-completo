# operation-edit-context Specification

## Purpose
TBD - created by archiving change edicion-preserva-contexto. Update Purpose after archive.
## Requirements
### Requirement: La edición de una operación preserva el contexto de su header

Toda ruta que edite una operación de venta o compra SHALL preservar los atributos de contexto del header que no viajen en el payload de edición. Concretamente, `branch_id`, `canal` (venta), `unit_id`, `supplier_id` (compra) y `cost_center_id` (compra) SHALL conservar su valor vigente tras la edición cuando el payload no los informe.

El contexto SHALL capturarse **antes** de la eliminación de las filas viejas, dentro de la misma transacción, porque después no es recuperable.

La columna legacy `company_id` NO SHALL restaurarse: es un eje de tenancy retirado por C-19 y su omisión es deliberada.

`created_at` NO SHALL preservarse — refleja cuándo se escribió la versión actual de la fila. La fecha del hecho económico viaja en `date`, que sí se preserva por parámetro.

#### Scenario: editar la cantidad conserva la sucursal y el canal

- **GIVEN** una venta imputada a una sucursal no default y con `canal = 'instagram'`
- **WHEN** se edita la operación cambiando solo la cantidad, sin informar sucursal ni canal
- **THEN** la fila resultante conserva la misma `branch_id` y `canal = 'instagram'`

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

#### Scenario: reimputar la sucursal de una venta

- **WHEN** se edita una operación informando una sucursal distinta, perteneciente a la cuenta y operativa
- **THEN** la operación queda imputada a la sucursal nueva

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

#### Scenario: editar una venta creada con cantidad fraccionaria

- **GIVEN** una venta de 2,5 kg de un producto medible
- **WHEN** se edita la operación a 3,25 kg
- **THEN** la edición se completa sin error
- **AND** el header y la línea quedan con `quantity = 3.25`
- **AND** el stock refleja el delta exacto `+2.5 - 3.25`, sin truncamiento

#### Scenario: la cantidad decimal no se redondea al editar

- **WHEN** se edita una operación con una cantidad de tres decimales
- **THEN** el valor persistido conserva los tres decimales, sin redondeo a entero

### Requirement: La orden de venta promovida sigue a la operación editada

Cuando la edición de una venta regenere el identificador de operación, toda `sales_orders` promovida desde esa operación que **no** tenga comprobante fiscal asociado SHALL re-apuntarse al identificador nuevo dentro de la misma transacción. NO SHALL quedar ninguna orden apuntando a un identificador de operación inexistente.

#### Scenario: la orden promovida no queda colgada tras editar

- **GIVEN** una venta promovida a `sales_orders` sin comprobante fiscal
- **WHEN** se edita la operación
- **THEN** la orden apunta al identificador de operación nuevo, y no queda ninguna orden huérfana

### Requirement: La operación con cargo en cuenta corriente o movimiento de caja posteado es inmutable

El sistema SHALL rechazar la edición de una operación de venta o de compra que ya haya posteado un cargo en cuenta corriente (`customer_account_movements` / `supplier_account_movements`), un movimiento de caja (`cash_movements`) o un movimiento bancario (`bank_movements`) referenciándola, y SHALL hacerlo antes de iniciar el ciclo REVERSE→DELETE→INSERT, con un código de error mapeado a HTTP 409. El bloqueo SHALL alcanzar a la operación completa y no sólo al importe o a la forma de pago: la fecha, la sucursal y las líneas también determinan la atribución del movimiento espejo, de modo que permitir su edición dejaría el movimiento posteado apuntando a un hecho distinto del que registró. La corrección de una operación en ese estado SHALL canalizarse por el instrumento contable correspondiente (nota de crédito, ajuste de cuenta corriente o movimiento bancario manual de ajuste) y no por la edición, porque el ledger de cuentas corrientes es append-only por diseño, porque `difference` en el arqueo de caja es una señal antifraude (RN-95) que no puede recalcularse retroactivamente sin destruir su valor probatorio, y porque el ledger bancario es append-only con `balance_after` acumulativo y su movimiento puede estar ya conciliado dentro de una sesión cerrada, de modo que mutarlo invalidaría tanto el saldo de todos los movimientos posteriores como una conciliación ya firmada. El mensaje de error SHALL nombrar la causa concreta —cargo de cuenta corriente, movimiento de caja o movimiento bancario— para que el usuario sepa qué instrumento usar.

#### Scenario: Editar una venta con cargo de cuenta corriente es rechazado

- **GIVEN** una venta registrada con forma de pago de `kind = 'credit'` que posteó su cargo en `customer_account_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y ni las líneas, ni el ledger de stock, ni el cargo se modifican

#### Scenario: Editar una venta con movimiento de caja es rechazado

- **GIVEN** una venta registrada desde el formulario con el opt-in de caja marcado, que generó un `cash_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y el `expected_balance` de la sesión no cambia

#### Scenario: Editar una venta con movimiento bancario es rechazado

- **GIVEN** una venta registrada con una forma de pago de `kind` bancario y destino resuelto, que generó un `bank_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y el `bank_movement` conserva su `amount`, su `balance_after` y su estado de conciliación

#### Scenario: Editar una compra con movimiento bancario es rechazado

- **GIVEN** una compra imputada a una forma de pago de `kind` bancario con destino resuelto, que generó un `bank_movements` de egreso
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423` y el ledger bancario no cambia

#### Scenario: Una venta sin cargo ni movimiento sigue siendo editable

- **GIVEN** una venta imputada a una forma de pago de `kind = 'transfer'` sin destino bancario resuelto, y por lo tanto sin cargo en cuenta corriente, sin movimiento de caja y sin movimiento bancario
- **WHEN** se edita esa operación cambiando importe y forma de pago
- **THEN** la edición procede normalmente con el acarreo de contexto ya establecido

#### Scenario: El mensaje de error distingue la causa

- **WHEN** se intenta editar una operación bloqueada por un movimiento bancario
- **THEN** el mensaje nombra el movimiento bancario como causa y sugiere el ajuste manual en el ledger bancario como vía de corrección

#### Scenario: La superficie anticipa el bloqueo

- **WHEN** el usuario abre el listado de operaciones y una de ellas tiene cargo, movimiento de caja o movimiento bancario posteado
- **THEN** la acción de editar aparece deshabilitada con la razón visible, en vez de fallar recién al confirmar

### ADDED Requirement: Editar una venta con asiento contable emitido no la bloquea (override del PO, 2026-08-20)

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

La reimputación del proveedor NO SHALL postear, mover ni revertir cargos de cuenta corriente: una operación que ya tiene un cargo posteado es inmutable por la capability `supplier-account`, de modo que el único caso editable es el de una compra sin cargo, donde el proveedor es una imputación analítica.

#### Scenario: reimputar el proveedor de una compra

- **GIVEN** una compra sin cargo de cuenta corriente, imputada al proveedor A
- **WHEN** se edita la operación informando el proveedor B, perteneciente a la cuenta y no borrado
- **THEN** todas las líneas de la operación quedan imputadas a B, y no se crea ni se revierte ningún movimiento de cuenta corriente

#### Scenario: omitir el proveedor preserva el vigente

- **GIVEN** una compra imputada a un proveedor
- **WHEN** se edita la operación sin incluir el campo proveedor en el payload
- **THEN** la operación conserva el mismo proveedor

#### Scenario: desimputar el proveedor explícitamente

- **WHEN** se edita una compra informando proveedor `NULL` con el indicador de "informado" en verdadero
- **THEN** la operación queda sin proveedor, y el valor previo no se restaura

#### Scenario: reimputar a un proveedor ajeno o borrado es rechazado

- **WHEN** se edita una compra informando un proveedor de otra cuenta, inexistente, o con `deleted_at` seteado
- **THEN** la edición falla y la operación queda intacta, sin reversa ni reaplicación de stock

#### Scenario: el formulario de edición expone el selector que la RPC acepta

- **WHEN** el usuario abre una compra editable en el formulario de edición
- **THEN** el selector de proveedor aparece precargado con el proveedor vigente de la operación y su cambio produce un efecto real al guardar

### Requirement: La edición no puede convertir una compra en compra a cuenta corriente

Como la edición de una compra NO postea cargos en cuenta corriente, el sistema SHALL rechazar toda edición cuyo resultado sea una compra imputada a una forma de pago de `kind = 'credit'` **sin el cargo correspondiente**. Concretamente, sobre el `kind` **efectivo** que queda tras aplicar el contrato tri-estado de forma de pago:

- si la edición **toca el contrato de crédito** —es decir, informa la forma de pago, el proveedor, o ambos— y el `kind` efectivo final es `credit` con el proveedor efectivo final sin informar, la edición SHALL rechazarse con el **mismo código y el mismo mensaje de negocio** que usa el alta de compra a crédito sin proveedor, de modo que el mapeo de error del backend y de la superficie sea uno solo. Una edición que NO informa ni la forma de pago ni el proveedor NO SHALL ser alcanzada por esta regla, aunque la operación quede en `credit` sin proveedor: no introduce la inconsistencia, solo la hereda;
- si la edición **informa explícitamente** la forma de pago y con ello mueve la operación desde un `kind` distinto de `credit` (incluida la ausencia de forma de pago) **hacia** `credit`, la edición SHALL rechazarse, y el mensaje SHALL nombrar el camino de corrección: borrar la compra y volver a cargarla como compra a crédito, que es el camino que sí postea el cargo.

Ambos rechazos SHALL ocurrir **antes** de cualquier reversa, borrado o reaplicación de líneas y de stock, y SHALL usar el código de error de negocio ya existente para entrada inválida, sin acuñar uno nuevo.

Una compra que **ya** estaba imputada a `kind = 'credit'` y no tiene cargo posteado —el estado de las compras registradas antes de que este circuito existiera, que además **no tienen proveedor** porque el maestro de proveedores no existía— SHALL seguir siendo editable **incluso sin proveedor**, mientras la edición no informe ni la forma de pago ni el proveedor: la restricción alcanza a quien **toca** el contrato de crédito, no a quien solo corrige una cantidad, una fecha o una descripción. Salir de `credit` hacia cualquier otro `kind` SHALL estar permitido cuando no hay cargo posteado; si lo hay, la operación ya es inmutable por la capability `supplier-account` y ese bloqueo SHALL tener precedencia.

#### Scenario: mover una compra a crédito desde la edición es rechazado

- **GIVEN** una compra imputada a una forma de pago de `kind = 'cash'`, con proveedor y sin cargo posteado
- **WHEN** se edita la operación informando una forma de pago de `kind = 'credit'`
- **THEN** la edición es rechazada nombrando el camino de corrección (borrar y volver a cargar), y la operación queda intacta: mismas líneas, mismo stock, misma forma de pago y ningún movimiento de cuenta corriente creado

#### Scenario: mover una compra a crédito sin proveedor también es rechazado

- **WHEN** se edita una compra informando a la vez una forma de pago de `kind = 'credit'` y proveedor `NULL`
- **THEN** la edición es rechazada y no se modifica ni la operación, ni el stock, ni la cuenta corriente de ningún proveedor

#### Scenario: desimputar el proveedor de una compra a crédito es rechazado

- **GIVEN** una compra imputada a una forma de pago de `kind = 'credit'`
- **WHEN** se edita la operación informando proveedor `NULL` con el indicador de "informado" en verdadero
- **THEN** la edición falla con el mismo error que el alta de una compra a crédito sin proveedor

#### Scenario: una compra que ya era a crédito y no tiene cargo sigue siendo editable

- **GIVEN** una compra imputada a `kind = 'credit'` sin ningún movimiento posteado en la cuenta corriente del proveedor
- **WHEN** se edita su cantidad sin tocar la forma de pago
- **THEN** la edición se aplica normalmente y no se postea ningún cargo

#### Scenario: la compra a crédito histórica, sin proveedor, sigue siendo editable

- **GIVEN** una compra imputada a `kind = 'credit'`, **sin proveedor** y sin cargo posteado —el estado de las compras anteriores a este circuito—
- **WHEN** se edita su cantidad sin informar ni la forma de pago ni el proveedor
- **THEN** la edición se aplica normalmente, sin rechazo y sin postear ningún cargo

#### Scenario: reimputar la forma de pago de esa misma compra sí es rechazado

- **GIVEN** la misma compra a `kind = 'credit'` sin proveedor y sin cargo posteado
- **WHEN** se edita informando otra forma de pago de `kind = 'credit'`
- **THEN** la edición es rechazada con el mismo error que el alta de una compra a crédito sin proveedor, y la operación queda intacta

#### Scenario: salir de crédito está permitido cuando no hay cargo

- **GIVEN** la misma compra a crédito sin cargo posteado
- **WHEN** se edita informando una forma de pago de `kind = 'cash'`
- **THEN** la edición se aplica y no se crea ni se revierte ningún movimiento de cuenta corriente

#### Scenario: con cargo posteado, la inmutabilidad tiene precedencia

- **GIVEN** una compra a crédito con su cargo ya posteado
- **WHEN** se intenta editarla, con o sin cambio de forma de pago
- **THEN** la operación es rechazada por el conflicto de estado de operación inmutable, antes que por cualquier regla de transición

### Requirement: El borrado consulta los mismos locks que la edición
El sistema SHALL evaluar en el borrado de una operación los mismos predicados de lock que ya gobiernan su edición — comprobante fiscal emitido y dinero posteado en los libros — y SHALL resolverlos de forma diferenciada: el lock fiscal bloquea el borrado, y el lock por dinero posteado lo habilita compensando los libros en lugar de impedirlo.

#### Scenario: Operación con comprobante fiscal
- **WHEN** se intenta borrar una operación con comprobante `pending_cae` o `authorized`
- **THEN** el sistema rechaza el borrado con `P0423`
- **AND** aplica exactamente el mismo predicado que bloquea la edición

#### Scenario: Operación con dinero posteado y sin comprobante
- **WHEN** se borra una operación bloqueada para edición por tener dinero posteado, pero sin comprobante fiscal
- **THEN** el borrado procede
- **AND** cada libro con movimientos de esa operación recibe su contra-movimiento

#### Scenario: Borrar y recrear como camino de corrección
- **WHEN** un usuario intenta editar una operación con dinero posteado, recibe el bloqueo, la borra y la vuelve a crear con los datos corregidos
- **THEN** los saldos de todos los libros reflejan únicamente la operación recreada
- **AND** no queda ningún cargo, movimiento ni asiento remanente de la operación borrada

### Requirement: Exposición del estado de borrabilidad en el listado
El sistema SHALL exponer al listado de operaciones, derivado de lectura y nunca desde una columna denormalizada, si una operación es borrable y qué razón la bloquea cuando no lo es.

#### Scenario: Operación facturada en el listado
- **WHEN** el listado incluye una operación con comprobante fiscal emitido
- **THEN** la operación se expone como no borrable
- **AND** la razón informada es el comprobante fiscal

#### Scenario: Operación borrable con compensación pendiente
- **WHEN** el listado incluye una operación con dinero posteado y sin comprobante
- **THEN** la operación se expone como borrable
- **AND** se exponen los libros que su borrado compensaría

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

