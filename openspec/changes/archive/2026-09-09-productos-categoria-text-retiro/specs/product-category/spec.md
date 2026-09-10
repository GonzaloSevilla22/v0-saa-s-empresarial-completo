## MODIFIED Requirements

### Requirement: Imputación del producto a una categoría del catálogo

El sistema SHALL imputar cada producto a una categoría mediante la columna `products.category_id` (FK a `product_categories`, nullable en la base, `ON DELETE RESTRICT`), que SHALL ser la **única representación física** de la categoría del producto. El sistema NOT SHALL mantener una segunda columna con el nombre de la categoría en la tabla de productos: el nombre legible SHALL derivarse del catálogo en la lectura.

La categoría informada SHALL validarse contra la cuenta del producto **en la base de datos**, como punto de paso obligado de todo camino de escritura —incluidos los que no pasan por la capa de aplicación, como la carga masiva—, rechazando con `P0404` la imputación a una categoría de otra cuenta. Esta validación NO SHALL depender de lo que envíe el cliente, y SHALL sobrevivir a cualquier cambio en el mecanismo que la hospede.

#### Scenario: Alta de producto con categoría del catálogo

- **WHEN** se crea un producto informando una categoría activa de la cuenta
- **THEN** el producto queda con ese `category_id`
- **AND** al leerlo, su categoría se lee con el nombre de esa categoría

#### Scenario: Categoría de otra cuenta es rechazada

- **WHEN** se crea o se edita un producto informando un `category_id` que pertenece a otra cuenta
- **THEN** la operación es rechazada con `P0404` y el producto no queda imputado a ella

#### Scenario: La validación de cuenta no depende de la capa de aplicación

- **WHEN** un camino de escritura que no pasa por la capa de aplicación intenta imputar un producto a una categoría de otra cuenta
- **THEN** la escritura es rechazada igualmente con `P0404`

#### Scenario: Renombrar una categoría se refleja en sus productos

- **GIVEN** una categoría "Ropa" con productos imputados
- **WHEN** un `owner` la renombra a "Indumentaria"
- **THEN** los productos conservan su `category_id`
- **AND** su categoría pasa a leerse "Indumentaria", sin que ningún lector cambie

#### Scenario: Renombrar una categoría no reescribe los productos

- **GIVEN** una categoría con productos imputados
- **WHEN** se la renombra
- **THEN** el nombre nuevo se lee en todos sus productos
- **AND** ninguna fila de productos es reescrita para lograrlo

#### Scenario: La categoría no puede quedar desincronizada

- **WHEN** un producto se crea o se edita por cualquier camino de escritura del sistema, incluida la carga masiva
- **THEN** la categoría que se lee es siempre la del `category_id` vigente del producto, porque no existe ninguna otra representación que pueda divergir

## ADDED Requirements

### Requirement: El nombre legible de la categoría se deriva del catálogo sin excluir productos

El sistema SHALL derivar el nombre de la categoría de un producto resolviéndolo contra `product_categories` por `products.category_id` al momento de la lectura, y esa derivación NOT SHALL excluir ningún producto del resultado por no poder resolver su categoría. Un producto sin categoría imputada, o cuya categoría no sea visible para quien consulta, SHALL seguir apareciendo en el catálogo, en el stock y en las búsquedas por SKU y por código de barras, con su nombre de categoría vacío.

El sistema SHALL exponer esta derivación en el mismo punto de lectura que ya consumen los lectores existentes de la categoría del producto, conservando el nombre de campo, de modo que ningún consumidor de ese dato deba cambiar.

#### Scenario: Un producto sin categoría imputada sigue siendo visible

- **GIVEN** un producto sin `category_id`
- **WHEN** se lista el catálogo de la cuenta
- **THEN** el producto aparece en la lista, con su categoría vacía

#### Scenario: La derivación no filtra el catálogo

- **GIVEN** una cuenta con N productos
- **WHEN** se lee el catálogo por el punto de lectura que deriva la categoría
- **THEN** se obtienen exactamente N filas

#### Scenario: Un lector existente de la categoría no cambia

- **WHEN** un lector que ya consumía el nombre de la categoría del producto vuelve a leerlo tras el retiro de la columna desnormalizada
- **THEN** obtiene el mismo nombre de campo con el nombre vigente de la categoría

### Requirement: Un producto imputado a una categoría dada de baja conserva su nombre legible

El sistema SHALL seguir resolviendo el nombre de la categoría de un producto cuando esa categoría fue dada de baja —desactivada o soft-deleted—, de modo que la imputación histórica siga siendo legible para quien la consulta. La visibilidad de la categoría a efectos de esta derivación NOT SHALL depender de su estado de actividad ni de su borrado lógico, sino únicamente de la pertenencia a la cuenta.

#### Scenario: Categoría desactivada

- **GIVEN** un producto imputado a una categoría que luego se desactiva
- **WHEN** se lee el producto
- **THEN** su categoría se sigue leyendo con el nombre de esa categoría

#### Scenario: Categoría soft-deleted

- **GIVEN** un producto imputado a una categoría que luego se da de baja como soft delete
- **WHEN** se lee el producto
- **THEN** su categoría se sigue leyendo con el nombre de esa categoría

### Requirement: El nombre de la categoría no se acepta como dato de entrada del producto

El sistema NOT SHALL aceptar el nombre de la categoría como campo de entrada al crear o editar un producto: la única forma de imputar la categoría SHALL ser el identificador de la categoría del catálogo. Un nombre de categoría enviado por un cliente SHALL ignorarse sin provocar un error, de modo que un cliente desactualizado siga funcionando contra el servidor nuevo.

Esta regla NOT SHALL aplicar a la carga masiva, donde el nombre de la categoría es el dato que el usuario carga en su archivo y que el sistema resuelve contra el catálogo del tenant.

#### Scenario: Un cliente envía el nombre de la categoría

- **WHEN** una solicitud de alta o edición de producto incluye el nombre de la categoría además del identificador
- **THEN** el nombre se ignora, la solicitud no falla, y la categoría queda determinada por el identificador

#### Scenario: La carga masiva sigue aceptando el nombre

- **WHEN** se importa un archivo con una columna de categoría por nombre
- **THEN** el sistema resuelve ese nombre contra el catálogo de la cuenta como hasta ahora
