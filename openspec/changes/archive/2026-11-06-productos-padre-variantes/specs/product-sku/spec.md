## MODIFIED Requirements

### Requirement: SKU opcional editable en el alta y la edición de producto

El sistema SHALL exponer `products.sku` como un campo **opcional** en el alta y en la edición de producto, de modo que un producto sin SKU sea plenamente válido y siga siendo la situación por defecto. El SKU informado SHALL normalizarse recortando espacios, y un SKU vacío SHALL persistirse como NULL y nunca como cadena vacía.

El SKU SHALL ser **borrable**: un usuario que cargó un SKU equivocado SHALL poder dejar el producto sin SKU. Para que esa intención sea expresable, la actualización de producto SHALL distinguir tres estados por **ausencia o presencia del campo** en el payload, y NUNCA por comparación contra nulo — campo ausente conserva el valor vigente, campo con valor lo asigna, campo en nulo lo desasigna. El mismo contrato tri-estado SHALL regir para la categoría del producto. Un producto padre `variant_only` NO SHALL llevar SKU: el alta de un padre con SKU no vacío SHALL rechazarse con `422` `parent_field_not_allowed` (`field = sku`), y la edición de un padre SHALL rechazar asignarle un SKU distinto del vigente (limpiarlo se acepta). El SKU se carga en cada variante.

#### Scenario: Alta de producto con SKU

- **WHEN** se crea un producto informando un SKU
- **THEN** el producto queda persistido con ese SKU, sin espacios sobrantes

#### Scenario: Alta de producto sin SKU

- **WHEN** se crea un producto sin informar SKU
- **THEN** el producto queda persistido con `sku = NULL` y es plenamente válido

#### Scenario: Un SKU en blanco no se guarda como cadena vacía

- **WHEN** se crea o edita un producto informando un SKU compuesto sólo de espacios
- **THEN** el producto queda con `sku = NULL`

#### Scenario: Editar un producto sin tocar su SKU lo conserva

- **GIVEN** un producto con SKU "REM-001"
- **WHEN** se edita cambiando el precio, sin incluir el campo de SKU en el payload
- **THEN** el producto conserva "REM-001"

#### Scenario: Borrar el SKU de un producto

- **GIVEN** un producto con SKU "REM-001"
- **WHEN** se edita informando el SKU en nulo
- **THEN** el producto queda con `sku = NULL`

#### Scenario: Un padre no acepta SKU

- **WHEN** se crea un producto `variant_only` informando un SKU
- **THEN** la API responde `422` con `code = parent_field_not_allowed` y `field = sku`, y el producto no se crea

#### Scenario: La variante lleva su propio SKU

- **WHEN** se crea una variante de un padre informando un SKU
- **THEN** la variante queda con ese SKU y el padre sigue sin SKU
