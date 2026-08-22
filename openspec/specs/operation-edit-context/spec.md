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

