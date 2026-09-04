# product-sku Specification

## Purpose
Da a `products.sku` un contrato completo: campo opcional y borrable con contrato tri-estado (ausente conserva, con valor asigna, en nulo desasigna), unicidad case-insensitive alcanzada por **cuenta** (no por usuario, corrigiendo el alcance heredado `user_id`), comunicación legible del conflicto de unicidad, inclusión en la búsqueda del listado de productos, y uso como clave de upsert de la carga masiva (una fila cuyo SKU coincide con un producto vivo de la cuenta actualiza ese producto en vez de duplicarlo).

## Requirements

### Requirement: SKU opcional editable en el alta y la edición de producto

El sistema SHALL exponer `products.sku` como un campo **opcional** en el alta y en la edición de producto, de modo que un producto sin SKU sea plenamente válido y siga siendo la situación por defecto. El SKU informado SHALL normalizarse recortando espacios, y un SKU vacío SHALL persistirse como NULL y nunca como cadena vacía.

El SKU SHALL ser **borrable**: un usuario que cargó un SKU equivocado SHALL poder dejar el producto sin SKU. Para que esa intención sea expresable, la actualización de producto SHALL distinguir tres estados por **ausencia o presencia del campo** en el payload, y NUNCA por comparación contra nulo — campo ausente conserva el valor vigente, campo con valor lo asigna, campo en nulo lo desasigna. El mismo contrato tri-estado SHALL regir para la categoría del producto.

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

### Requirement: El SKU es único por cuenta, case-insensitive, sobre las filas vivas

El sistema SHALL garantizar que un SKU identifique como máximo un producto vivo dentro de una cuenta, mediante un índice único parcial sobre `(account_id, lower(sku))` restringido a las filas con SKU no vacío y `deleted_at IS NULL`. El alcance de la unicidad SHALL ser la **cuenta** y no el usuario: el catálogo de productos pertenece a la organización, de modo que dos miembros de la misma cuenta NO SHALL poder crear dos productos vivos con el mismo SKU, y el índice anterior alcanzado por `user_id` SHALL retirarse para que no convivan dos reglas de unicidad discrepantes.

La comparación SHALL ser case-insensitive: "REM-001" y "rem-001" SHALL considerarse el mismo código.

Todo camino que resuelva un producto por su SKU —incluida la carga masiva— SHALL usar el mismo alcance de cuenta que el índice, de modo que la clave de búsqueda y la clave de unicidad nunca discrepen.

#### Scenario: SKU duplicado dentro de la cuenta es rechazado

- **GIVEN** una cuenta con un producto vivo de SKU "REM-001"
- **WHEN** se intenta crear otro producto con SKU "rem-001" en la misma cuenta
- **THEN** la operación es rechazada por el índice único y el segundo producto no se persiste

#### Scenario: Dos cuentas pueden usar el mismo SKU

- **GIVEN** la cuenta A con un producto de SKU "REM-001"
- **WHEN** la cuenta B crea un producto con SKU "REM-001"
- **THEN** ambos coexisten, cada uno en su cuenta

#### Scenario: Dos miembros de la misma cuenta no pueden repetir el SKU

- **GIVEN** una cuenta con dos miembros y un producto de SKU "REM-001" creado por el primero
- **WHEN** el segundo miembro intenta crear un producto con SKU "REM-001" en esa misma cuenta
- **THEN** la operación es rechazada

#### Scenario: Se puede recrear el SKU de un producto borrado

- **GIVEN** un producto de SKU "REM-001" que fue soft-deleteado
- **WHEN** se crea un producto nuevo con SKU "REM-001" en la misma cuenta
- **THEN** la operación es permitida, porque el índice único sólo alcanza a las filas vivas

#### Scenario: No conviven dos reglas de unicidad de SKU

- **WHEN** se inspeccionan los índices únicos de `products` sobre la columna `sku`
- **THEN** existe únicamente el índice alcanzado por `account_id`, y no queda ninguno alcanzado por `user_id`

### Requirement: El conflicto de SKU se comunica como un error legible

El sistema SHALL traducir la violación del índice único de SKU a un error de conflicto legible en la superficie de alta y edición de producto, que nombre el SKU en cuestión y permita al usuario corregirlo sin perder lo cargado. La fuente de verdad del rechazo SHALL ser la restricción de la base de datos y no una comprobación previa: una verificación anticipada SHALL usarse únicamente para dar un mensaje mejor, nunca como la garantía.

#### Scenario: El formulario informa el conflicto

- **WHEN** el usuario intenta guardar un producto con un SKU que ya pertenece a otro producto vivo de su cuenta
- **THEN** la pantalla muestra un mensaje que identifica el conflicto de SKU
- **AND** los datos cargados en el formulario se conservan para corregirlo

#### Scenario: El rechazo se sostiene aunque se evada la comprobación previa

- **WHEN** una solicitud llega directamente a la API con un SKU en conflicto
- **THEN** la escritura es rechazada por la restricción de la base de datos y el producto no se persiste

### Requirement: El SKU es criterio de búsqueda del listado de productos

El sistema SHALL incluir el SKU entre los criterios de la búsqueda del listado de productos, junto a los ya vigentes, y SHALL mostrarlo cuando el producto lo tiene. Un producto sin SKU NO SHALL presentarse con un valor de relleno que se confunda con un código real.

#### Scenario: Buscar un producto por su SKU

- **GIVEN** un producto con SKU "ACE-500"
- **WHEN** el usuario escribe "ACE-500" en la búsqueda del listado de productos
- **THEN** el producto aparece entre los resultados

#### Scenario: La búsqueda por SKU es case-insensitive

- **GIVEN** un producto con SKU "ACE-500"
- **WHEN** el usuario busca "ace-500"
- **THEN** el producto aparece entre los resultados

#### Scenario: Un producto sin SKU no muestra un código inventado

- **WHEN** se lista un producto sin SKU
- **THEN** la fila no exhibe ningún código en el lugar del SKU

### Requirement: El SKU es la clave de upsert de la carga masiva

El sistema SHALL conservar el SKU como clave de upsert de la carga masiva: una fila cuyo SKU coincide con el de un producto vivo de la cuenta SHALL **actualizar** ese producto en lugar de crear uno nuevo, y una fila sin SKU SHALL seguir resolviéndose por los criterios de deduplicación ya vigentes. La resolución SHALL alcanzarse por cuenta, en coherencia con el índice único.

El sistema SHALL advertir en el paso de revisión cuando dos filas del **mismo archivo** traen el mismo SKU, porque la segunda actualiza la fila que escribió la primera y hoy eso ocurre en silencio.

#### Scenario: Reimportar actualiza el producto existente

- **GIVEN** un producto de la cuenta con SKU "REM-001"
- **WHEN** se importa un archivo con una fila de SKU "REM-001" y un precio distinto
- **THEN** el producto existente queda actualizado y no se crea un producto nuevo

#### Scenario: SKU repetido dentro del archivo se advierte

- **WHEN** un archivo trae dos filas con el mismo SKU y nombres distintos
- **THEN** el paso de revisión advierte que ambas filas afectan al mismo producto

#### Scenario: La resolución de la carga masiva usa el alcance de la cuenta

- **GIVEN** un producto con SKU "REM-001" creado por otro miembro de la misma cuenta
- **WHEN** un miembro importa un archivo con una fila de SKU "REM-001"
- **THEN** la fila actualiza ese producto existente en lugar de crear un duplicado en la misma cuenta

