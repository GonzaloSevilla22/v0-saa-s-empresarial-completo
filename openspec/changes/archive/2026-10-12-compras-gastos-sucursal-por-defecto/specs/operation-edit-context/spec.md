## MODIFIED Requirements

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
