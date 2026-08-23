## ADDED Requirements

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
