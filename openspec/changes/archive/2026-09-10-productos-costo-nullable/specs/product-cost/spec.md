## ADDED Requirements

### Requirement: El costo del producto es opcional y la ausencia no es cero

`products.cost` SHALL admitir el valor ausente (`NULL`) y NOT SHALL tener valor por defecto: `NULL` significa **"no se cargó el costo"** y `0` significa **"el costo es cero, declarado"**. Los dos estados son hechos distintos del negocio y el sistema NOT SHALL representarlos con la misma fila.

Retirar el valor por defecto es parte del requirement y no un detalle de implementación: mientras exista, todo alta que omita la columna vuelve a escribir un cero indistinguible de la ausencia, y el defecto sobrevive en el único camino que nadie inspecciona.

Un producto padre de variantes (`stock_control_type = 'variant_only'`) NOT SHALL tener costo propio: su costo es el de cada variante.

#### Scenario: Un producto nuevo sin costo informado queda sin costo, no en cero

- **GIVEN** un alta de producto que no informa el costo
- **WHEN** se persiste el producto
- **THEN** su costo queda ausente
- **AND** ninguna consulta posterior puede distinguirlo de un producto cuyo costo se desconoce, porque es exactamente eso

#### Scenario: Un costo cero declarado se conserva como cero

- **GIVEN** un producto que se regala y cuyo costo es realmente cero
- **WHEN** el usuario informa `0` explícitamente
- **THEN** el producto queda con costo `0`
- **AND** su margen se calcula e informa normalmente, como el de cualquier producto con costo conocido

### Requirement: Ningún consumidor sustituye por cero un costo ausente al informar margen

Ningún read-model, pantalla, exportación ni contexto de IA SHALL sustituir por cero un costo ausente para informar un margen, una rentabilidad o una alerta de margen. La ausencia SHALL informarse como ausencia.

Un costo tratado como cero produce un margen del 100 %, que es indistinguible de un margen medido y sistemáticamente ubica al producto peor documentado en la cabecera de todo ranking por rentabilidad. Es el defecto que este requirement existe para prohibir.

Cuando una superficie no puede informar el margen por falta de costo, SHALL mostrarlo como ausente ("—" o equivalente) y NOT SHALL aplicarle los umbrales de color, los rangos o las clasificaciones que usa para los márgenes conocidos.

Cuando un consumidor de IA arma el contexto que envía al modelo, SHALL **omitir** el costo y el margen del producto sin costo, y NOT SHALL enviarlos con valor cero ni con una estimación propia.

#### Scenario: El catálogo muestra el margen ausente como ausente

- **GIVEN** un producto con precio cargado y sin costo
- **WHEN** el usuario abre el catálogo de productos
- **THEN** la fila muestra el margen como ausente ("—"), sin umbral de color — el catálogo no tiene columna de costo propia, sólo margen
- **AND** el CSV exportado desde el catálogo trae la celda de costo vacía para ese producto (mismo criterio D11 de `export-ranking`)
- **AND** NO muestra un margen del 100 % ni el color que ese valor tendría

#### Scenario: Una alerta de margen no se emite sobre un producto sin costo

- **GIVEN** un producto sin costo cargado
- **WHEN** el sistema evalúa alertas de margen
- **THEN** no emite ninguna alerta sobre ese producto, porque no hay margen que evaluar

#### Scenario: El contexto de IA omite el margen en vez de inventarlo

- **GIVEN** un producto sin costo entre los que un consumidor de IA incluye en su contexto
- **WHEN** se arma el contexto para el modelo
- **THEN** el producto aparece sin costo y sin margen
- **AND** el contexto NO contiene un costo cero ni un margen del 100 % para ese producto

### Requirement: El formulario de producto admite dejar el costo vacío

El formulario de producto SHALL permitir guardar un producto con el costo vacío, y la API SHALL distinguir "no informé el costo" de "el costo vale cero" por **ausencia de la clave** en el payload, nunca por su valor nulo.

Un campo ausente conserva el costo que el producto tenía; un campo informado con valor lo asigna; un campo informado en nulo lo desasigna. Sin esta distinción el costo es una escritura de un solo sentido: se puede poner y nunca quitar.

El control numérico del costo SHALL renderizar un cero declarado como `0` visible y el costo ausente como campo vacío: si el cero se dibuja vacío, el usuario no puede verificar lo que guardó.

#### Scenario: El usuario borra el costo de un producto que ya lo tenía

- **GIVEN** un producto con costo `500`
- **WHEN** el usuario vacía el campo Costo y guarda
- **THEN** el producto queda sin costo
- **AND** su margen pasa a informarse como ausente en todas las superficies

#### Scenario: Una actualización que no menciona el costo lo conserva

- **GIVEN** un producto con costo `500`
- **WHEN** se actualiza el producto informando sólo el nombre
- **THEN** el costo sigue siendo `500`

#### Scenario: Un cero declarado se ve como cero en el formulario

- **GIVEN** un producto con costo `0` declarado
- **WHEN** el usuario abre el formulario de edición
- **THEN** el campo Costo muestra `0`, no un campo vacío

### Requirement: El importador distingue la celda vacía del valor cero

El importador de productos SHALL tratar la celda de costo **vacía** y la celda con valor `"0"` como entradas distintas: la vacía deja el producto sin costo en un alta, y el `"0"` le asigna costo cero.

En una **edición** (producto ya existente, resuelto por la clave de upsert), la celda de costo vacía SHALL conservar el costo que el producto tenía y NOT SHALL borrarlo. Un importador que borra datos por una celda vacía convierte cualquier planilla incompleta en una pérdida de catálogo; el camino para quitar un costo es el formulario.

Una fila de producto padre SHALL importarse **sin costo**, no con costo cero: un padre de variantes no tiene costo propio.

Cuando el valor de la celda de costo es ilegible, el importador SHALL avisar que la fila quedará **sin costo** — NOT SHALL anunciar que usará cero, porque desde este momento el cero es un dato con significado propio.

#### Scenario: Alta con celda de costo vacía

- **GIVEN** una fila de producto nuevo cuya columna Costo está vacía
- **WHEN** se importa el archivo
- **THEN** el producto se crea sin costo

#### Scenario: Alta con costo cero explícito

- **GIVEN** una fila de producto nuevo con `0` en la columna Costo
- **WHEN** se importa el archivo
- **THEN** el producto se crea con costo `0`

#### Scenario: Edición con celda de costo vacía conserva el costo

- **GIVEN** un producto existente con costo `800` y una fila de importación que lo referencia con la columna Costo vacía
- **WHEN** se importa el archivo
- **THEN** el producto conserva su costo `800`

#### Scenario: Fila de producto padre se importa sin costo

- **GIVEN** una fila de tipo padre en el archivo de importación
- **WHEN** se importa el archivo
- **THEN** la entrada padre queda sin costo, no con costo cero

### Requirement: La línea de venta congela la ausencia de costo, no un cero

Cuando se escribe una línea de un documento (venta, compra, presupuesto, pedido o movimiento de stock) de un producto **sin costo**, el snapshot de costo de esa línea SHALL quedar ausente y NOT SHALL congelarse en cero.

El snapshot responde a la pregunta *"¿cuánto costaba esto cuando se vendió?"*. Si el catálogo no lo sabía, la respuesta honesta es "no se sabía", y congelar un cero convierte para siempre una ausencia en una afirmación falsa que ninguna corrección posterior puede revisar, porque las líneas de un documento confirmado son inmutables.

#### Scenario: Venta de un producto sin costo congela un snapshot ausente

- **GIVEN** un producto sin costo cargado
- **WHEN** se confirma una venta que lo incluye
- **THEN** la línea de la venta queda con snapshot de costo ausente
- **AND** el margen de esa venta se informa como ausente, no como 100 %

#### Scenario: Cargar el costo después no reescribe la línea ya emitida

- **GIVEN** una venta ya confirmada de un producto que entonces no tenía costo
- **WHEN** el usuario carga el costo del producto en el catálogo
- **THEN** la línea de esa venta conserva su snapshot ausente
- **AND** las ventas posteriores congelan el costo recién cargado

### Requirement: Las líneas históricas con snapshot de costo cero no se reescriben

Las líneas de documentos confirmados que ya tienen un snapshot de costo `0` NOT SHALL reescribirse a ausente por este cambio de modelo, aunque ese cero provenga del valor por defecto que la columna del catálogo tenía y no de una declaración del usuario.

La regla de inmutabilidad de las líneas de documento confirmado es la que garantiza que remarcar un producto no reescriba el margen histórico, y vale más que la precisión retroactiva de estas filas. No existe forma honesta de distinguir hoy, fila por fila, entre "se vendió con costo cero declarado" y "se vendió cuando el catálogo no sabía el costo".

Este residuo SHALL quedar declarado con su magnitud medida: al momento del cambio son **9 líneas de venta en 9 productos distintos**, que seguirán informando margen del 100 % con cobertura de costo del 100 %.

#### Scenario: Una línea histórica con snapshot cero conserva su valor

- **GIVEN** una línea de venta confirmada con snapshot de costo `0`
- **WHEN** se aplica el cambio de modelo del costo del producto
- **THEN** la línea conserva su snapshot `0`
- **AND** su margen sigue informándose como estaba, sin reescritura del pasado
