## MODIFIED Requirements

### Requirement: Sucursal y canal son reimputables al editar mediante contrato tri-estado

La edición de una operación SHALL aceptar `branch_id` y `canal` como parámetros tri-estado, distinguiendo tres intenciones por **ausencia o presencia** del parámetro, nunca por su valor:

- parámetro **ausente** → preservar el valor vigente;
- parámetro **presente con `NULL`** → desimputar explícitamente (operación sin sucursal / sin canal);
- parámetro **presente con valor** → reimputar.

La distinción SHALL implementarse con un booleano `p_<campo>_provided` en la RPC y con `model_fields_set` en la capa Python. NO SHALL inferirse desde `is None`.

Una sucursal reimputada SHALL validarse antes de aplicarse: SHALL pertenecer a la cuenta de la operación y SHALL estar operativa. Si no cumple, la edición SHALL fallar con `ERRCODE = 'P0422'` sin modificar la operación.

**Excepción para la sucursal de una venta** (`ventas-sucursal-por-defecto`): una venta no puede quedar sin sucursal. En la edición de una venta, la sucursal **presente con `NULL`** y la sucursal **ausente** cuyo valor vigente sea `NULL` SHALL resolverse a la sucursal principal de la cuenta (`c26_default_branch`), antes de revertir o reaplicar stock. Si la cuenta no tiene ninguna sucursal, la edición SHALL fallar con `P0422 no_branch_found` sin modificar la operación.

El canal de la venta y la sucursal de la compra conservan las tres intenciones sin excepción.

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

#### Scenario: desimputar la sucursal de una compra sigue permitido

- **GIVEN** una compra imputada a una sucursal
- **WHEN** se edita informando la sucursal como `NULL` con el indicador de "informado" en verdadero
- **THEN** la compra queda sin sucursal

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
