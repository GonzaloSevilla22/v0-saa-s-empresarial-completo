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

