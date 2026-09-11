# product-import Specification

## Purpose
Expone la importación masiva de productos por archivo (CSV/Excel) como un endpoint de la API de aplicación (`POST /products/import`), en reemplazo de la escritura directa del cliente contra `rpc_bulk_upsert_products` vía Supabase. El servidor resuelve la cuenta y el usuario desde el token de sesión, invoca una única función `SECURITY DEFINER` que aplica el lote completo como una sola unidad de trabajo (todo-o-nada, sin trocear), y ofrece un modo de simulación que devuelve el mismo veredicto que la importación real sin escribir nada. Cada error se reporta con el número de fila de origen, la importación es idempotente por clave y deduplicada por huella de archivo, y la superficie vive en la pantalla de productos ya existente con revisión previa a la confirmación.

## Requirements

### Requirement: La importación de productos por archivo se sirve por la API, nunca desde el cliente contra la base

El sistema SHALL exponer la importación de productos por archivo como un endpoint de la API de aplicación, y el cliente NOT SHALL escribir productos invocando directamente la base de datos ni ninguna de sus funciones.

El identificador del usuario y la cuenta a la que se imputa la importación SHALL derivarse del token de la sesión del lado del servidor. El cuerpo de la petición NOT SHALL contener un identificador de usuario ni de cuenta: un dato de tenencia que viaja en el cuerpo es un dato que el cliente elige.

La función de base de datos que realiza el alta masiva NOT SHALL ser invocable por el rol de los usuarios autenticados: mientras lo sea, cualquier gate que la importación imponga por encima de ella es evitable con una llamada directa.

#### Scenario: La importación viaja por la API

- **WHEN** un usuario importa un archivo de productos
- **THEN** la escritura se produce a través del endpoint de importación de la API
- **AND** el cliente no abre ninguna conexión de escritura contra la base de datos

#### Scenario: La cuenta no se acepta desde el cliente

- **WHEN** una petición de importación incluye un identificador de usuario o de cuenta en su cuerpo
- **THEN** ese valor se ignora y la tenencia se resuelve desde el token de la sesión

#### Scenario: El alta masiva no es alcanzable sin pasar por la importación

- **WHEN** un usuario autenticado invoca directamente la función de alta masiva de productos
- **THEN** la invocación es rechazada por falta de permiso

#### Scenario: Sin rol de escritura en la cuenta no se importa

- **GIVEN** un miembro de la cuenta sin rol de escritura
- **WHEN** intenta importar un archivo de productos
- **THEN** la importación es rechazada y no se crea ni se modifica ningún producto

### Requirement: La importación de un archivo es una operación de lote atómica

El sistema SHALL importar un archivo de productos como **una sola unidad de trabajo de servidor**: o quedan escritos todos los productos, categorías, existencias y atributos del archivo, o no queda escrito ninguno.

La unidad de trabajo SHALL implementarse como una función de base de datos `SECURITY DEFINER` que reciba el lote completo, y NOT SHALL implementarse como una secuencia de llamadas independientes desde el cliente ni desde la capa de aplicación.

El lote NOT SHALL trocearse en sub-lotes: trocear reintroduce exactamente el fallo parcial que este comportamiento existe para eliminar, y convierte toda salvaguarda declarada sobre el archivo en una salvaguarda sobre un fragmento arbitrario de él.

Cuando el lote se rechaza, el sistema NOT SHALL dejar rastro alguno de él: ni productos, ni categorías creadas, ni existencias, ni atributos, ni la fila de importación, ni la marca de idempotencia.

#### Scenario: Una fila inválida no deja escrita ninguna de las válidas

- **GIVEN** un archivo de tres filas de producto en el que la segunda viola una regla de negocio
- **WHEN** se importa el archivo
- **THEN** el resultado informa que el lote no se aplicó
- **AND** no queda ningún producto nuevo, ninguna categoría nueva, ninguna existencia nueva y ninguna fila de importación

#### Scenario: Un lote válido se aplica entero

- **GIVEN** un archivo de tres filas de producto todas válidas
- **WHEN** se importa el archivo
- **THEN** los tres productos quedan persistidos con sus existencias y sus atributos
- **AND** el resultado informa cuántos se crearon y cuántos se actualizaron

#### Scenario: Un fallo estructural también aborta el lote entero

- **GIVEN** un archivo cuyo procesamiento produce un error no previsto por las reglas de negocio
- **WHEN** se importa el archivo
- **THEN** el lote se rechaza completo y el resultado informa el error con su código y su número de fila

#### Scenario: Un archivo grande no se parte en varias escrituras

- **GIVEN** un archivo con más filas de las que cabían en un sub-lote del comportamiento anterior
- **WHEN** se importa el archivo
- **THEN** el sistema realiza una sola unidad de trabajo sobre la base y no varias escrituras confirmadas por separado

### Requirement: El veredicto del lote viaja como resultado, no como error de protocolo

El sistema SHALL devolver el rechazo de un lote por reglas de fila como una **respuesta exitosa** que informa que el lote no se aplicó, junto con la lista de errores. Un rechazo por reglas es un resultado del procesamiento, no un fallo de la petición.

El sistema SHALL reservar las respuestas de error de la petición para lo que impide procesarla: forma del payload inválida, tope de filas excedido, metadata de archivo ausente, falta de permisos, falta de clave de idempotencia y tope de categorías nuevas excedido — este último es un rechazo de CUOTA, no un veredicto sobre las filas del archivo, y el servidor lo deja escapar como error de la petición.

Tras el rechazo de un lote **por reglas de fila**, la conexión de base de datos del request SHALL quedar utilizable: el rechazo NOT SHALL propagarse como excepción de base de datos hasta abortar la transacción del request. Un rechazo por tope de categorías SÍ se propaga como excepción de base de datos — no está sujeto a esta garantía.

#### Scenario: Lote rechazado por reglas de fila

- **WHEN** se importa un archivo con filas que violan reglas de negocio
- **THEN** la respuesta es exitosa e informa que el lote no se aplicó, con un error por cada fila afectada

#### Scenario: Payload que no se puede procesar

- **WHEN** se envía una importación sin clave de idempotencia
- **THEN** la respuesta es un error de la petición y nada se procesa

#### Scenario: Lote rechazado por tope de categorías nuevas

- **WHEN** se importa un archivo que introduce más categorías nuevas que el tope admitido
- **THEN** la respuesta es un error de la petición, no un resultado con `committed: false`
- **AND** no se escribe nada

#### Scenario: Después de un rechazo la sesión sigue sirviendo

- **GIVEN** una importación que se rechaza por reglas de fila
- **WHEN** el servidor consulta la base de datos para construir la respuesta
- **THEN** la consulta se ejecuta con normalidad

### Requirement: Cada error del lote identifica su fila del archivo

El sistema SHALL informar cada error del lote con el **número de fila del archivo** que lo originó, además del motivo. Identificar la fila por su código de producto o por su nombre NOT SHALL considerarse suficiente: un catálogo puede no usar códigos y dos filas pueden compartir nombre.

La fila normalizada que el cliente envía SHALL poder transportar su número de línea de origen, y el número SHALL sobrevivir hasta el reporte de error.

#### Scenario: Error de una fila sin código de producto

- **GIVEN** un archivo cuyas filas no traen código de producto
- **WHEN** la fila 47 viola una regla de negocio
- **THEN** el error informa que el problema está en la fila 47

#### Scenario: El reporte no depende del código de producto

- **GIVEN** dos filas del archivo con el mismo nombre de producto y sin código
- **WHEN** una de las dos falla
- **THEN** el error identifica cuál de las dos filas falló

### Requirement: La vista previa es un veredicto del servidor, no una conjetura del cliente

El sistema SHALL ofrecer un modo de **simulación** de la importación que ejecute el lote completo y lo deshaga, devolviendo el mismo veredicto que devolvería la importación real: errores por fila, cuántos productos se crearían y cuántos se actualizarían, y qué categorías se crearían.

La simulación NOT SHALL dejar ninguna escritura: ni productos, ni categorías, ni existencias, ni la fila de importación, ni la marca de idempotencia.

El paso de revisión de la superficie de importación SHALL mostrar ese veredicto **antes** de que el usuario confirme, y SHALL impedir la confirmación mientras exista al menos una fila con error, exhibiendo el motivo.

La validación de las celdas del lado del cliente SHALL conservarse como primera capa —avisos de ambigüedad de importes, cantidades, duplicados de código dentro del archivo y errores fatales de fila—, pero NOT SHALL considerarse el veredicto: lo que el sistema promete que va a pasar SHALL provenir del servidor.

#### Scenario: La revisión anuncia lo que va a pasar de verdad

- **GIVEN** un archivo cuya fila 12 referencia un producto padre que no existe
- **WHEN** el usuario llega al paso de revisión
- **THEN** la pantalla informa el error de la fila 12 antes de que confirme
- **AND** no se ha escrito nada en la base

#### Scenario: La simulación no deja rastro

- **GIVEN** un archivo completamente válido
- **WHEN** se solicita su simulación
- **THEN** el resultado informa cuántos productos se crearían
- **AND** no queda ningún producto, categoría, existencia ni fila de importación

#### Scenario: Confirmar queda bloqueado mientras haya un error

- **GIVEN** un archivo con una fila con error
- **WHEN** el usuario está en el paso de revisión
- **THEN** la acción de confirmar está deshabilitada y el motivo está a la vista

### Requirement: Tope de filas por lote, con rechazo y sin trocear

El sistema SHALL rechazar un archivo que supere el tope de filas admitido por lote, con un mensaje que informe el tope y el conteo del archivo, y NOT SHALL partirlo en varias unidades de trabajo para sortear el tope.

El tope SHALL fijarse por encima del uso real observado (el mayor lote real y el catálogo más grande medidos), con margen suficiente para no romper ningún caso legítimo.

#### Scenario: Archivo por encima del tope

- **WHEN** se importa un archivo con más filas que el tope admitido
- **THEN** la importación es rechazada informando el tope y el conteo del archivo
- **AND** no se escribe ninguna fila

#### Scenario: Archivo vacío

- **WHEN** se importa un lote sin ninguna fila
- **THEN** la importación es rechazada y no se escribe nada

### Requirement: La importación respeta el límite de productos del plan

El sistema SHALL evaluar el límite de productos del plan efectivo de la cuenta sobre el **estado resultante** de la importación —después de aplicar el lote, nunca calculándolo por adelantado sobre las filas del archivo— y SHALL rechazar el lote entero cuando la importación **agrega** productos y el conteo resultante supera ese límite.

Una importación que sólo actualiza productos existentes, sin aumentar el conteo de productos vivos de la cuenta, NOT SHALL rechazarse por este motivo, aunque la cuenta ya tenga más productos que el límite de su plan: el límite acota la creación, no la corrección de un catálogo que ya existe.

Cuando el rechazo ocurre, el sistema NOT SHALL escribir nada del lote —ni productos, ni categorías, ni existencias, ni la fila de importación, ni la marca de idempotencia—: la cuenta conserva los productos que ya tenía, y sólo queda impedida de agregar más hasta reducir su catálogo o cambiar de plan.

El veredicto del límite de plan —el plan efectivo, su tope, el conteo antes y después de la importación, cuántos productos agregaría y si excede el tope— SHALL viajar en el resultado del lote, tanto en la simulación como en la confirmación real, para que la superficie pueda anunciarlo antes de que el usuario intente confirmar.

#### Scenario: Cuenta excedida que sólo actualiza no se bloquea

- **GIVEN** una cuenta cuyo conteo de productos ya supera el límite de su plan
- **WHEN** se importa un archivo cuyas filas actualizan únicamente productos existentes de esa cuenta
- **THEN** el lote se aplica
- **AND** el veredicto informa que el límite no se excedió

#### Scenario: Cuenta excedida que agrega se bloquea entera

- **GIVEN** una cuenta cuyo conteo de productos ya supera el límite de su plan
- **WHEN** se importa un archivo que agrega al menos un producto nuevo
- **THEN** el lote se rechaza entero
- **AND** no se escribe ningún producto, categoría, existencia ni fila de importación

#### Scenario: La simulación informa el mismo veredicto de límite

- **GIVEN** un archivo cuya importación real excedería el límite del plan
- **WHEN** se solicita su simulación
- **THEN** el veredicto informa el mismo límite excedido, con el conteo antes y después
- **AND** no se escribe nada

#### Scenario: Cruzar el límite al agregar bloquea el lote

- **GIVEN** una cuenta cuyo conteo de productos está por debajo del límite de su plan
- **WHEN** se importa un archivo que agrega productos suficientes para superar ese límite
- **THEN** el lote se rechaza entero, aunque antes de la importación la cuenta no estuviera excedida

### Requirement: La importación es idempotente por clave y deduplicada por archivo

El sistema SHALL exigir una clave de idempotencia en la petición de importación y SHALL devolver el resultado del lote original —sin escribir de nuevo— cuando la misma clave se reintenta.

El sistema SHALL registrar además la **huella del archivo** importado y SHALL rechazar como repetición un archivo cuya huella ya fue importada por la misma cuenta, informándolo como repetición y sin escribir nada. Sin este mecanismo, volver a subir el mismo archivo duplica el catálogo cada vez que las filas no traen un código que sirva de clave de actualización.

La clave de idempotencia SHALL generarse una vez por archivo elegido y no por intento de envío, de modo que reintentar sea una repetición y no un segundo lote.

Un lote **rechazado** NOT SHALL consumir su clave de idempotencia ni registrar la huella del archivo: corregir el archivo y volver a intentarlo SHALL funcionar.

#### Scenario: Reintento por red con la misma clave

- **GIVEN** una importación aplicada con una clave de idempotencia
- **WHEN** la misma petición se reintenta con la misma clave
- **THEN** el sistema devuelve el resultado original y no crea ningún producto adicional

#### Scenario: El mismo archivo subido dos veces

- **GIVEN** un archivo ya importado por la cuenta
- **WHEN** el usuario lo vuelve a subir con una clave de idempotencia distinta
- **THEN** el sistema lo informa como repetición y no escribe nada

#### Scenario: Un lote rechazado no quema la clave

- **GIVEN** una importación rechazada por una fila inválida
- **WHEN** el usuario corrige el archivo y lo vuelve a importar
- **THEN** la importación se aplica

### Requirement: El parseo de las celdas ocurre en el cliente y el servidor recibe filas normalizadas

El sistema SHALL conservar en el cliente el parseo del archivo y la normalización de sus celdas —separadores, codificación, importes, cantidades, decimales y sus avisos de ambigüedad—, y SHALL enviar al servidor filas ya normalizadas con tipos explícitos.

El transporte de la fila normalizada SHALL preservar la **ausencia** de un valor como ausencia. Ningún campo declarado opcional por el modelo de datos SHALL recibir un valor por defecto en el transporte: sustituir una celda vacía por cero destruye una distinción del dominio en un lugar donde ninguna prueba del dominio la busca.

El servidor SHALL validar la forma de la fila recibida antes de tocar la base de datos, y SHALL delegar toda regla de negocio a la unidad de trabajo de base de datos.

#### Scenario: Celda vacía llega como ausencia

- **GIVEN** una fila del archivo con la celda de un campo opcional vacía
- **WHEN** la fila se transporta al servidor
- **THEN** el campo llega como ausente y no como cero

#### Scenario: Forma de fila inválida se rechaza antes de escribir

- **WHEN** una fila del lote no cumple el contrato de la fila normalizada
- **THEN** la petición se rechaza sin tocar la base de datos

#### Scenario: Las reglas de negocio no se evalúan en la capa de aplicación

- **WHEN** el servidor procesa un lote de importación
- **THEN** la capa de aplicación no decide qué filas son válidas según reglas de negocio; esa decisión proviene de la unidad de trabajo de base de datos

### Requirement: Una referencia explícita de producto padre que no resuelve es un error de fila

El sistema SHALL resolver una referencia explícita a un producto padre —por código o por nombre— primero dentro del propio archivo y, si no aparece, contra el catálogo **de la cuenta**. Cuando no resuelve por ninguna de las dos vías, la fila SHALL informarse como error.

El sistema NOT SHALL importar como producto independiente una fila cuya referencia explícita de padre no resolvió: un default silencioso sobre un dato que el usuario escribió convierte un error de tipeo en un producto mal creado que nadie detecta.

Una fila **sin ninguna referencia** de padre SHALL conservar el fallback vigente: se agrupa con la última fila de producto padre que la precede en el archivo y, si no hay ninguna, se importa como producto independiente con un aviso.

La resolución de la referencia NOT SHALL alcanzarse por usuario: un producto padre creado por otro miembro de la misma cuenta SHALL resolver.

#### Scenario: Código de padre inexistente

- **GIVEN** una fila de variante que referencia un código de producto padre que no existe ni en el archivo ni en la cuenta
- **WHEN** se importa el archivo
- **THEN** la fila se informa como error con su número de fila
- **AND** no se crea ningún producto independiente por esa fila

#### Scenario: Padre creado por otro miembro de la cuenta

- **GIVEN** un producto padre creado por otro miembro de la misma cuenta
- **WHEN** una variante lo referencia por código
- **THEN** la variante queda vinculada a ese padre

#### Scenario: Variante sin referencia conserva la agrupación por cercanía

- **GIVEN** una fila de variante sin ninguna referencia de padre, precedida en el archivo por una fila de producto padre
- **WHEN** se importa el archivo
- **THEN** la variante queda vinculada a ese padre

#### Scenario: Variante huérfana sin ninguna referencia

- **GIVEN** una fila de variante sin referencia de padre y sin ninguna fila de producto padre que la preceda
- **WHEN** se importa el archivo
- **THEN** la fila se importa como producto independiente con un aviso

### Requirement: La superficie de importación informa el lote y no promete lo que no hace

La superficie de importación SHALL vivir en la pantalla de productos ya existente, sin introducir una ruta nueva, y SHALL constar de la elección del archivo, la revisión con el veredicto del servidor y el resultado del lote.

El paso de resultado SHALL informar cuántos productos se crearon, cuántos se actualizaron, qué categorías se crearon y, cuando corresponda, que el archivo ya había sido importado.

La superficie NOT SHALL ofrecer ni describir un modo de "importar las filas que se puedan": deja de describir lo que el sistema hace.

La superficie SHALL usar los tokens semánticos del sistema de diseño para los estados de fila y SHALL ser operable en escritorio y en móvil, en tema claro y oscuro. En el ancho de móvil la tabla de revisión SHALL desplazarse dentro de su propio contenedor sin ensanchar el documento, y la acción de confirmar SHALL quedar alcanzable.

#### Scenario: El resultado informa el lote

- **WHEN** un lote se aplica
- **THEN** el paso de resultado informa creados, actualizados y categorías creadas

#### Scenario: Archivo repetido informado en el resultado

- **WHEN** se sube un archivo ya importado
- **THEN** el resultado lo informa como repetición y no como una importación nueva

#### Scenario: Revisión operable en móvil

- **GIVEN** un archivo con muchas filas
- **WHEN** el usuario abre la revisión en un ancho de móvil
- **THEN** la tabla se desplaza dentro de su contenedor, el documento no se ensancha y la acción de confirmar es alcanzable

