## MODIFIED Requirements

### Requirement: La carga masiva resuelve la categoría contra el catálogo del tenant y crea las que faltan

El sistema SHALL resolver la columna `Categoría` de la carga masiva contra el catálogo de la cuenta importadora de forma case-insensitive y tolerante a espacios, y SHALL **crear** la categoría cuando no exista, imputando el producto a ella. El sistema NO SHALL reemplazar por una categoría por defecto una categoría informada por el usuario.

La creación SHALL ocurrir en el servidor, dentro de la misma transacción por lote que persiste los productos, de modo que la tenencia se imponga del lado del servidor y no queden categorías creadas por un lote que falló. Esa transacción SHALL abarcar el **archivo completo**: mientras la carga masiva se trocee en sub-lotes, un archivo puede dejar categorías creadas por los sub-lotes que se confirmaron antes del que falló.

La creación automática SHALL estar acotada por dos salvaguardas: el sistema SHALL **anunciar en el paso de revisión, antes de confirmar**, qué categorías se van a crear y cuántas filas usan cada una; y SHALL rechazar la importación con un error explicativo cuando el archivo introduzca más categorías nuevas distintas que el tope admitido, en vez de crearlas. Una fila con errores fatales NO SHALL originar la creación de una categoría.

El tope SHALL evaluarse sobre el conjunto de categorías nuevas distintas del **archivo entero**, tanto en el cliente como en el servidor. Evaluarlo sobre un fragmento del archivo NO SHALL considerarse cumplimiento de esta salvaguarda: un tope aplicado a una porción arbitraria del archivo deja de acotar lo que dice acotar, y convierte al cliente en la única barrera efectiva.

El anuncio del paso de revisión SHALL provenir del veredicto del servidor y no únicamente de la comparación del cliente contra el catálogo que tiene cargado, de modo que lo que se anuncia sea lo que el servidor va a crear.

Una fila sin categoría informada SHALL imputarse a la categoría por defecto de la cuenta, sin crear nada.

#### Scenario: Categoría desconocida se crea e imputa

- **GIVEN** una cuenta cuyo catálogo no tiene "Ferretería"
- **WHEN** se importa un archivo con filas cuya categoría es "Ferretería"
- **THEN** se crea la categoría "Ferretería" en esa cuenta
- **AND** los productos de esas filas quedan imputados a ella
- **AND** ninguno queda imputado a la categoría por defecto

#### Scenario: Categoría existente se reutiliza sin duplicar

- **GIVEN** una cuenta con la categoría "Ropa"
- **WHEN** se importa un archivo con las variantes de escritura "ropa", "Ropa " y "ROPA"
- **THEN** todas las filas se imputan a la categoría "Ropa" existente
- **AND** no se crea ninguna categoría nueva

#### Scenario: Las categorías a crear se anuncian antes de confirmar

- **WHEN** el usuario llega al paso de revisión con un archivo que trae categorías nuevas
- **THEN** la pantalla lista las categorías que se van a crear y cuántas filas usa cada una, antes de que confirme la importación
- **AND** la lista proviene del veredicto del servidor

#### Scenario: Superar el tope detiene la importación

- **WHEN** un archivo introduce más categorías nuevas distintas que el tope admitido
- **THEN** la importación es rechazada con un error que explica el tope y sugiere revisar el mapeo de la columna
- **AND** no se crea ninguna categoría

#### Scenario: El tope se cuenta sobre el archivo, no sobre un fragmento

- **GIVEN** un archivo cuyas categorías nuevas distintas superan el tope, pero cuya primera mitad por sí sola no lo supera
- **WHEN** se importa el archivo
- **THEN** el servidor lo rechaza por exceder el tope
- **AND** no queda creada ninguna categoría de la primera mitad

#### Scenario: Una fila con error no crea su categoría

- **GIVEN** una fila sin nombre de producto y con una categoría nueva
- **WHEN** se importa el archivo
- **THEN** la fila se omite por su error
- **AND** su categoría no se crea

#### Scenario: Fila sin categoría informada

- **WHEN** se importa una fila con la columna de categoría vacía
- **THEN** el producto queda imputado a la categoría por defecto de la cuenta y no se crea ninguna categoría

#### Scenario: El template de ejemplo refleja el catálogo de la cuenta

- **WHEN** un usuario descarga el template de ejemplo de la carga masiva
- **THEN** las filas de ejemplo usan categorías reales de su cuenta
- **AND** la referencia de columnas declara que una categoría inexistente se crea y que un SKU coincidente actualiza el producto existente
