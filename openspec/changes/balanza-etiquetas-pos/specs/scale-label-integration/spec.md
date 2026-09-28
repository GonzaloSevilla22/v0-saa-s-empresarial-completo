## ADDED Requirements

### Requirement: Configuración de la balanza por cuenta

El sistema SHALL guardar por cuenta, en la tabla `scale_settings` (una fila por cuenta), si la lectura de etiquetas de balanza está habilitada y los tres formatos de código de barras de la balanza —venta por peso, venta por unidad y varios—, cada uno descrito como una lista ordenada de hasta cuatro campos (A a D) con su tipo (número fijo, código PLU, importe, cantidad —peso en kilogramos en el formato de peso, unidades en el de unidad— u otro que se ignora), su cantidad de dígitos y, según el tipo, su valor fijo o sus decimales. Una cuenta sin fila SHALL comportarse como balanza **deshabilitada** con los formatos de fábrica de la Systel Cuora Neo (peso `20` + código 4 + importe 6 con 2 decimales; unidad `21` + código 4 + importe 6 con 2 decimales; varios `22` + otro 2 + otro 8, contenido no interpretado).

Cualquier miembro de la cuenta SHALL poder leer la configuración. Sólo un owner o admin de la cuenta SHALL poder crearla o modificarla, y la restricción SHALL sostenerse en dos capas: el servicio de la API (respuesta 403) y la base de datos (rechazo `P0401` ante una escritura directa de otro rol, aunque la política de escritura habilite a los roles escritores). Ningún miembro de otra cuenta y ningún usuario anónimo SHALL leer ni escribir la configuración de una cuenta.

#### Scenario: Una cuenta sin configuración recibe los valores de fábrica deshabilitados

- **GIVEN** una cuenta que nunca guardó la configuración de la balanza
- **WHEN** un miembro consulta `GET /scale-settings`
- **THEN** la respuesta indica la balanza deshabilitada con los tres formatos de fábrica, y la línea "Resultado" del formato de peso es `20BBBBCCCCCCX`

#### Scenario: Un owner guarda la configuración

- **WHEN** un owner envía `PUT /scale-settings` con la balanza habilitada y un formato válido
- **THEN** la configuración queda guardada en la fila de su cuenta y la siguiente lectura la devuelve igual

#### Scenario: Un vendedor no puede cambiar la configuración

- **WHEN** un miembro con rol de vendedor envía `PUT /scale-settings`
- **THEN** la API responde 403 y la configuración no cambia

#### Scenario: La base rechaza la escritura directa de un rol no autorizado

- **WHEN** un miembro con rol de vendedor intenta insertar o actualizar la fila de `scale_settings` de su cuenta directamente contra la base
- **THEN** la escritura se rechaza con `P0401`

#### Scenario: Una cuenta no ve la configuración de otra

- **WHEN** un miembro de la cuenta B consulta la tabla `scale_settings`
- **THEN** no obtiene la fila de la cuenta A

### Requirement: Validación del formato de etiqueta

El sistema SHALL aceptar un formato habilitado sólo si cumple todas estas reglas, con la misma definición en el frontend y en la API: la suma de los dígitos de sus campos es exactamente 12; el campo A es un número fijo de 1 a 3 dígitos cuyo valor tiene esa cantidad de dígitos y empieza con `2`; los formatos de peso y de unidad tienen exactamente un campo de código PLU de 1 a 6 dígitos y exactamente un campo de valor (importe o cantidad); el formato de varios no tiene código PLU y sólo se le exige la cabecera; los decimales del valor son un entero de 0 a 3, y un campo de cantidad del formato por unidad tiene 0 decimales (el producto se vende por unidades); y ninguna cabecera de un formato habilitado es prefijo de la cabecera de otro formato habilitado. Una configuración que no cumple SHALL rechazarse con un error que identifique el formato y el campo, sin guardar nada.

#### Scenario: La suma de dígitos distinta de 12 se rechaza

- **WHEN** se guarda un formato de peso con número fijo 2, código 4 e importe 5
- **THEN** la API responde 422 indicando que los campos deben sumar 12 dígitos

#### Scenario: Una cabecera que no empieza con 2 se rechaza

- **WHEN** se guarda un formato cuyo número fijo es `77`
- **THEN** la configuración se rechaza, porque chocaría con los códigos de productos envasados

#### Scenario: Cabeceras que se pisan se rechazan

- **WHEN** se guardan habilitados un formato de peso con cabecera `2` y uno de unidad con cabecera `21`
- **THEN** la configuración se rechaza porque `2` es prefijo de `21`

#### Scenario: Una cantidad con decimales en el formato por unidad se rechaza

- **WHEN** se guarda un formato por unidad con número fijo `21`, código 4 y cantidad 6 con 1 decimal
- **THEN** la configuración se rechaza, porque una cantidad fraccionaria no es vendible para un producto por unidades

#### Scenario: El frontend y la API aplican la misma regla

- **GIVEN** el conjunto compartido de casos de validación
- **WHEN** se evalúa cada caso con el esquema del frontend y con el de la API
- **THEN** los dos coinciden en aceptar o rechazar cada caso

### Requirement: Decodificación de la etiqueta de balanza

El frontend SHALL decodificar un código leído con una única función pura de la capa canónica que, dada la configuración de la cuenta, distinga cuatro resultados: el código no es de balanza, con su motivo (balanza deshabilitada, no es un EAN-13 de 13 dígitos, o ninguna cabecera habilitada coincide); es de balanza pero inválido (dígito verificador EAN-13 incorrecto, valor igual a cero, o 12 dígitos que empiezan con una cabecera habilitada — el lector no transmite el dígito verificador —); es de balanza pero no soportado (un ticket de varios artículos, o una etiqueta de venta genérica con PLU igual a cero, que el equipo usa para el artículo genérico de fábrica y no identifica el producto); o es una etiqueta válida, en cuyo caso SHALL devolver el formato (peso o unidad), el PLU como entero sin ceros a la izquierda y el valor (importe, peso o cantidad) aplicando los decimales configurados. Una etiqueta de valor cero NO SHALL convertirse nunca en una línea. La validación del dígito verificador SHALL reutilizar la función EAN-13 existente.

#### Scenario: Etiqueta de peso con la configuración de fábrica

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2002610013638`
- **THEN** el resultado es una etiqueta de peso con PLU 261 e importe 13,63

#### Scenario: Importe configurado sin decimales

- **GIVEN** el formato de peso con importe de 6 dígitos y 0 decimales
- **WHEN** se decodifica `2002610135002`
- **THEN** el resultado es PLU 261 con importe 13.500

#### Scenario: Peso embebido

- **GIVEN** el formato de peso con cabecera `20`, código 4 y cantidad de 6 dígitos con 3 decimales
- **WHEN** se decodifica `2005090012504`
- **THEN** el resultado es PLU 509 con peso 1,250 kg

#### Scenario: Dígito verificador incorrecto

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2002610013639`
- **THEN** el resultado es inválido por dígito verificador y, salvo un producto cuyo SKU sea exactamente ese código, no se busca ningún producto con él

#### Scenario: Ticket de varios artículos

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2200000045003`
- **THEN** el resultado es "ticket de varios artículos, no soportado"

#### Scenario: Una etiqueta de venta genérica se reconoce

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2000000012346` (PLU 0)
- **THEN** el resultado es "etiqueta de venta genérica, no soportada", y el mensaje indica venderlo con su PLU o cargarlo a mano

#### Scenario: Una etiqueta con valor cero no agrega ninguna línea

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2002610000003` (importe 0) o `2101000000002`
- **THEN** el resultado es inválido por valor cero y no se agrega ninguna línea

#### Scenario: Lector sin dígito verificador

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se lee `200261001363` (12 dígitos que empiezan con la cabecera `20`)
- **THEN** el resultado es inválido y el mensaje indica habilitar la transmisión del dígito verificador EAN-13 en el lector

#### Scenario: Balanza deshabilitada

- **GIVEN** la balanza deshabilitada
- **WHEN** se decodifica `2002610013638`
- **THEN** el resultado es "no es de balanza"

### Requirement: Orden de resolución de un código leído

El POS y el formulario de venta SHALL resolver todo código leído con una única función compartida y en este orden: (1) un producto vivo, que no sea padre con variantes, cuyo código de barras coincide exactamente respetando mayúsculas o, si ninguno, sin distinguir mayúsculas cuando hay un único candidato — con más de un candidato SHALL terminar con un error que diga con cuántos productos coincide —; (2) una etiqueta de balanza, si la decodificación la reconoce — una etiqueta inválida o no soportada SHALL terminar la resolución con el error del decodificador, salvo que un producto vivo, que no sea padre con variantes, tenga exactamente ese código como SKU, en cuyo caso se resuelve ese producto —; (3) un producto vivo, que no sea padre con variantes, cuyo SKU coincide (sin distinguir mayúsculas); (4) un error. Cuando el código del paso 4 es un EAN-13 válido que empieza con `2`, el error SHALL decir que parece una etiqueta de balanza e indicar Configuración → Balanza: con la lectura de etiquetas deshabilitada, que está deshabilitada y cómo activarla; con la lectura habilitada, que no coincide con ningún formato configurado. En otro caso SHALL decir que el código no se encontró.

#### Scenario: Un código de barras declarado gana sobre la interpretación de balanza

- **GIVEN** la balanza habilitada con los formatos de fábrica y un producto cuyo código de barras es `2000123456782`
- **WHEN** se lee `2000123456782`
- **THEN** se agrega ese producto como un código común, sin decodificarlo como etiqueta

#### Scenario: Una etiqueta con la lectura deshabilitada se explica

- **GIVEN** una cuenta con la lectura de etiquetas deshabilitada
- **WHEN** se lee `2002610013638` y ningún producto tiene ese código de barras ni ese SKU
- **THEN** el mensaje indica que parece una etiqueta de balanza pero la lectura está deshabilitada, y que se active en Configuración → Balanza

#### Scenario: Un SKU con forma de etiqueta no queda robado por la balanza

- **GIVEN** la balanza habilitada con los formatos de fábrica y un producto con SKU `200261001363`
- **WHEN** se lee `200261001363`
- **THEN** se agrega ese producto, sin el error de dígito verificador faltante

#### Scenario: Un SKU se resuelve cuando no es código ni etiqueta

- **GIVEN** un producto con SKU `ZAP-01`
- **WHEN** se lee `zap-01`
- **THEN** se agrega ese producto

#### Scenario: Un código desconocido informa el error

- **WHEN** se lee un código que no es código de barras, etiqueta ni SKU de ningún producto
- **THEN** la pantalla informa que el código no se encontró y el indicador del lector muestra el estado de error

#### Scenario: Una etiqueta con una cabecera no configurada se explica

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se lee `2702610013637` y ningún producto tiene ese código de barras ni ese SKU
- **THEN** el mensaje indica que parece una etiqueta de balanza con cabecera 27 que no coincide con ningún formato configurado y que se revise Configuración → Balanza

### Requirement: Una etiqueta de balanza se convierte en una línea de venta

El frontend SHALL convertir una etiqueta válida en una línea de venta con una única función pura compartida por el POS y el formulario de venta, que busca el producto por su código de balanza entre los productos vivos de la cuenta y expresa la línea en la unidad base efectiva del producto. Una etiqueta del formato de peso SHALL exigir que la unidad base efectiva sea de tipo peso, y una del formato por unidad que el producto se venda por unidades (unidad de tipo unidad o sin unidad base); un producto medible que no es de peso (volumen, longitud) no admite ninguno de los dos formatos. Con **importe** embebido, el subtotal de la línea SHALL ser exactamente el importe de la etiqueta, la cantidad SHALL derivarse como importe ÷ precio del catálogo redondeado a 0,001 kg (expresado en la unidad base) y el precio unitario SHALL derivarse del subtotal y la cantidad con la función canónica existente, de modo que el total cobrado sea el importe de la etiqueta. Con **peso** embebido, la cantidad SHALL ser el peso y el precio el del catálogo. En el formato **por unidad**, una cantidad embebida SHALL usarse tal cual con el precio del catálogo, y un importe embebido SHALL cobrarse exacto con una cantidad de al menos 1 derivada de importe ÷ precio. La línea SHALL nacer sin descuento y con el paso y mínimo de su unidad, editable como cualquier otra. Ninguna RPC ni endpoint de venta SHALL cambiar para aceptarla.

#### Scenario: Importe embebido cobra exactamente la etiqueta

- **GIVEN** el producto "Tomate" con unidad base Kilogramo, precio 4,80 y código de balanza 261
- **WHEN** se lee `2002610013638` con los formatos de fábrica
- **THEN** se agrega una línea de 2,840 kg con subtotal 13,63 y la venta confirmada cobra 13,63 por esa línea

#### Scenario: La cantidad se expresa en la unidad base del producto

- **GIVEN** el producto "Tomate" con unidad base Gramo, precio 4,5 por gramo y código de balanza 261, y el formato de peso con importe de 0 decimales
- **WHEN** se lee `2002610135002`
- **THEN** se agrega una línea de 3000 g con precio 4,5 y subtotal 13.500

#### Scenario: Peso embebido usa el precio del catálogo

- **GIVEN** el producto "Papa" con unidad base Kilogramo, precio 1.800 y código de balanza 509, y el formato de peso con cantidad de 6 dígitos y 3 decimales
- **WHEN** se lee `2005090012504`
- **THEN** se agrega una línea de 1,250 kg a 1.800 con subtotal 2.250

#### Scenario: Etiqueta por unidad con importe

- **GIVEN** el producto "Lechuga" con unidad base Unidad, precio 4,50 y código de balanza 100
- **WHEN** se lee `2101000009005` con los formatos de fábrica
- **THEN** se agrega una línea de 2 unidades con subtotal 9,00

#### Scenario: Precio distinto en la balanza y en el catálogo

- **GIVEN** el producto "Tomate" con precio 5,00 en el catálogo, código de balanza 261, y una etiqueta impresa con el precio de la balanza de 4,80
- **WHEN** se lee `2002610013638`
- **THEN** la línea cobra 13,63 (el importe de la etiqueta) con una cantidad derivada de 2,726 kg

### Requirement: Errores accionables al leer una etiqueta

Cuando una etiqueta válida no puede convertirse en línea, el sistema SHALL no agregar nada al carrito y SHALL mostrar un mensaje que diga qué hacer, distinguiendo al menos: PLU no asignado a ningún producto de la cuenta (indicando dónde asignarlo), PLU asignado a un producto padre con variantes, producto sin precio, modo de venta incompatible (etiqueta de peso para un producto cuya unidad base no es de peso, o etiqueta por unidad para un producto de peso) y cantidad derivada menor a la precisión mínima. Un ticket de varios artículos SHALL explicar que sus productos deben cargarse uno por uno, y una etiqueta de venta genérica (PLU 0) que no identifica el producto y debe venderse con su PLU o cargarse a mano. El control de stock SHALL ser **acumulativo**: cuando la suma de las cantidades (en la unidad base) de todas las líneas del carrito del mismo producto agregadas en la sesión (al editar una venta, las líneas ya persistidas no cuentan: su cantidad ya está descontada del disponible) más la de la etiqueta supera el stock disponible, SHALL aplicarse el mismo rechazo y el mismo mensaje que a un alta manual, en el POS y en el formulario de venta.

#### Scenario: PLU sin producto

- **WHEN** se lee una etiqueta válida con PLU 509 y ningún producto vivo de la cuenta tiene ese código de balanza
- **THEN** no se agrega ninguna línea y el mensaje dice que el PLU 509 no está asignado y cómo asignarlo en Productos

#### Scenario: Modo de venta incompatible

- **GIVEN** el producto "Lechuga" con unidad base Unidad y código de balanza 261
- **WHEN** se lee `2002610013638` (formato de peso)
- **THEN** no se agrega ninguna línea y el mensaje indica que la etiqueta es de venta por peso y el producto se vende por unidad

#### Scenario: Ticket de varios artículos

- **WHEN** se lee `2200000045003` con los formatos de fábrica
- **THEN** no se agrega ninguna línea y el mensaje indica cargar los productos del ticket uno por uno

#### Scenario: Dos etiquetas que juntas superan el stock

- **GIVEN** el producto "Tomate" con unidad base Kilogramo, código de balanza 261 y 3 kg disponibles, y una línea de balanza de 2 kg ya en el carrito
- **WHEN** se lee otra etiqueta de 2 kg del mismo producto
- **THEN** no se agrega la segunda línea y el mensaje es el mismo de stock insuficiente que el de un alta manual

### Requirement: Cada etiqueta de balanza es una línea propia

Cada etiqueta de balanza leída SHALL agregar una línea nueva al carrito, aunque ya exista una línea del mismo producto y la misma unidad, para que cada pesada conserve su importe y pueda quitarse sola. La línea de balanza SHALL quedar marcada como tal y NO SHALL fusionarse nunca con otra: un alta manual, un código de barras común o un SKU del mismo producto y unidad SHALL sumar sobre una línea que no sea de balanza, o crear una nueva, y nunca modificar la cantidad, el precio ni el subtotal de una línea de balanza. Los códigos de barras comunes y los SKU de un producto que se vende por unidades SHALL sumar el mínimo de la unidad a la línea existente (no de balanza) del mismo producto y unidad, con una única función compartida por el POS y el formulario de venta. Al editar una venta, las líneas ya persistidas —que no conservan la marca de balanza— SHALL quedar marcadas como persistidas y tampoco SHALL fusionarse: un alta manual o un código del mismo producto y unidad SHALL crear una línea nueva. Un código común o SKU de un producto medible (por ejemplo, de peso) NO SHALL agregar una cantidad mínima arbitraria: SHALL dejar el producto elegido en el selector de alta de la pantalla con el foco en la cantidad, para que se ingrese.

#### Scenario: Dos etiquetas del mismo producto

- **WHEN** se leen dos etiquetas distintas del mismo PLU
- **THEN** el carrito tiene dos líneas de ese producto, cada una con el importe de su etiqueta

#### Scenario: Un alta manual no se suma sobre una línea de balanza

- **GIVEN** el carrito con una línea de balanza de "Tomate" de 2,840 kg y subtotal 13,63
- **WHEN** se agrega a mano, o por un código de barras común, 1 kg de "Tomate" en la misma unidad
- **THEN** el carrito tiene dos líneas y la de balanza conserva 2,840 kg y subtotal 13,63

#### Scenario: Al editar una venta, un alta manual no modifica una línea persistida

- **GIVEN** la edición de una venta con una línea persistida de "Tomate" de 2,840 kg y subtotal 13,63
- **WHEN** se agrega a mano 1 kg de "Tomate" en la misma unidad
- **THEN** el carrito tiene dos líneas y la persistida conserva 2,840 kg y subtotal 13,63

#### Scenario: Un producto de peso leído por código común pide la cantidad

- **GIVEN** un producto con unidad base Kilogramo y código de barras `7790000000010`
- **WHEN** se lee `7790000000010`
- **THEN** no se agrega ninguna línea con una cantidad mínima y el producto queda elegido en el selector de alta con el foco en la cantidad

### Requirement: El POS lee códigos con el lector

El POS (`/ventas/pos`) SHALL montar el lector de códigos y su indicador junto al buscador de productos, y SHALL agregar al carrito lo que resuelva la función compartida de resolución. El indicador SHALL mostrar el resultado de cada lectura (el producto agregado o el motivo del error) usando los tokens semánticos del sistema de diseño, en una región que los lectores de pantalla anuncian (`role="status"`, `aria-live`), con un texto corto que no desborda en móvil; el mensaje completo de un error SHALL mostrarse además en un aviso. El lector SHALL suspenderse mientras haya abierto un diálogo modal del sistema de diseño (diálogo, hoja lateral, cajón o diálogo de confirmación) que no lo contenga, mientras se registra la venta y cuando el usuario no tiene permiso de escritura; los desplegables (buscador de productos, selects, menús) NO SHALL suspenderlo. Una lectura hecha con el foco en un campo de texto o numérico NO SHALL dejar el código escrito dentro de ese campo, y una tecla mantenida apretada NO SHALL tomarse como una lectura.

#### Scenario: Escanear una etiqueta en el POS

- **GIVEN** la balanza habilitada y un producto con código de balanza 261
- **WHEN** en el POS se lee `2002610013638`
- **THEN** la línea aparece en el carrito y el indicador muestra el producto agregado

#### Scenario: El lector no escribe dentro del campo con foco

- **GIVEN** el POS con el foco en el campo de cantidad, que vale 1
- **WHEN** se lee una etiqueta
- **THEN** el campo de cantidad sigue valiendo 1 y la línea se agrega al carrito

#### Scenario: Un diálogo abierto suspende el lector

- **GIVEN** el POS con la hoja de cuenta bancaria abierta
- **WHEN** se lee una etiqueta
- **THEN** no se agrega ninguna línea

#### Scenario: El buscador de productos abierto no suspende el lector

- **GIVEN** el POS con el desplegable del buscador de productos abierto
- **WHEN** se lee una etiqueta válida
- **THEN** la línea se agrega al carrito

#### Scenario: Una tecla mantenida no es una lectura

- **GIVEN** el POS con el foco en el campo de precio unitario
- **WHEN** el usuario mantiene apretada la tecla `0`
- **THEN** los ceros quedan escritos en el campo y no aparece ningún error de código no encontrado

### Requirement: El formulario de venta usa la misma resolución

El formulario de venta SHALL resolver cada código leído con la misma función compartida que el POS, sin lógica propia de etiquetas, y SHALL seguir leyendo mientras él mismo está dentro de su diálogo "Nueva venta" o "Editar venta"; un diálogo anidado abierto encima (por ejemplo, la confirmación de anulación) SHALL suspender el lector. La lectura NO SHALL dejar el código escrito dentro del campo con foco, y el control de stock SHALL ser acumulativo (todas las líneas del producto agregadas en la sesión), tanto para lo que agrega el lector como para el alta manual, en sus dos caminos (sumar sobre una línea existente o crear una nueva).

#### Scenario: Escanear una etiqueta en el formulario de venta

- **GIVEN** la balanza habilitada y el diálogo "Nueva venta" abierto
- **WHEN** se lee `2002610013638` y existe un producto con código de balanza 261
- **THEN** la línea aparece en el carrito del formulario con subtotal 13,63

#### Scenario: Un código de barras común conserva su comportamiento

- **GIVEN** el formulario de venta con una línea del producto de código `7791234567898` (vendido por unidad) y cantidad 1
- **WHEN** se vuelve a leer `7791234567898`
- **THEN** la misma línea pasa a cantidad 2

#### Scenario: El alta manual después de una etiqueta respeta el stock acumulado

- **GIVEN** el producto "Tomate" con 3 kg disponibles y una línea de balanza de 2 kg en el carrito del formulario
- **WHEN** se agregan a mano 2 kg de "Tomate"
- **THEN** no se agrega la línea manual y el mensaje es el de stock insuficiente

#### Scenario: La confirmación de anulación abierta suspende el lector

- **GIVEN** el formulario de venta con la confirmación de anulación abierta encima
- **WHEN** se lee una etiqueta válida
- **THEN** no se agrega ninguna línea

### Requirement: Pestaña Balanza en Configuración

La página de configuración SHALL tener una pestaña "Balanza", enlazable como `/configuracion?tab=balanza`, que permita habilitar la lectura de etiquetas, editar los tres formatos campo por campo con la línea "Resultado" que la balanza muestra para el mismo formato (dígitos fijos, la letra del campo repetida por cada dígito y `X` al final), restaurar los valores de fábrica, ver el importe máximo representable por cada formato con importe y un aviso cuando un producto con código de balanza tiene un precio por kilo mayor que ese máximo, y probar un código real contra la configuración **en edición**: el probador SHALL mostrar el formato detectado, el PLU, el valor decodificado, el producto resuelto y la línea que se agregaría, o el error correspondiente con su motivo, y SHALL decodificar aunque la lectura de etiquetas esté deshabilitada (avisándolo), para que el comercio confirme una etiqueta real antes de habilitarla. El campo del probador SHALL tener una etiqueta asociada y su resultado SHALL anunciarse a los lectores de pantalla. La pestaña SHALL incluir una guía con los pasos de configuración del equipo citando la página del manual: el requisito operativo de trabajar con rollo de etiquetas en venta directa (una etiqueta por pesada; la acumulación en un comprobante sólo funciona con papel continuo), la verificación de que el formato de impresión y el PLU imprimen el código de barras, la restricción de la venta de genéricos, la recomendación de una cabecera propia si el comercio recibe mercadería etiquetada por terceros, la configuración del lector (transmitir el dígito verificador EAN-13, sufijo Enter) y los dos caminos para llevar el archivo a la balanza — el importador de Systel en una PC, marcado como no verificado, y la importación periódica desde un servidor FTP/SFTP del propio comercio. Los miembros que no son owner ni admin SHALL ver la configuración en sólo lectura y poder usar el probador. La pestaña SHALL verse correctamente en desktop y en móvil, en tema claro y oscuro.

#### Scenario: La línea Resultado espeja la de la balanza

- **WHEN** el usuario configura el formato de peso con número fijo `20`, código 4 e importe 6
- **THEN** la pestaña muestra `Resultado: 20BBBBCCCCCCX`

#### Scenario: El probador usa la configuración sin guardar

- **GIVEN** la configuración guardada con importe de 2 decimales y el usuario cambió a 0 decimales sin guardar
- **WHEN** prueba `2002610135002`
- **THEN** el probador muestra importe 13.500

#### Scenario: Con la lectura deshabilitada el probador decodifica igual

- **GIVEN** una cuenta sin configuración guardada (lectura deshabilitada, formatos de fábrica)
- **WHEN** prueba `2002610013638`
- **THEN** el probador muestra PLU 261 e importe 13,63, y avisa que la lectura de etiquetas todavía está deshabilitada

#### Scenario: Aviso de desborde

- **GIVEN** el formato de peso con importe de 6 dígitos y 2 decimales, y un producto con código de balanza y precio 12.000 por kilo
- **WHEN** se abre la pestaña
- **THEN** se muestra el importe máximo de 9.999,99 y un aviso de que ese producto desborda la etiqueta

#### Scenario: Un vendedor ve la pestaña en sólo lectura

- **WHEN** un miembro con rol de vendedor abre la pestaña Balanza
- **THEN** ve la configuración sin poder editarla y puede usar el probador

### Requirement: Exportación del catálogo para la balanza

La pestaña Balanza SHALL ofrecer "Exportar catálogo para la balanza", que genera en el navegador, sin consumir la cuota de exportaciones ni registrarse en el historial de exportaciones, un archivo CSV en el Formato 1 de importación de Systel Suite Neo: una línea por producto vivo con código de balanza, sin encabezado, sin marca de orden de bytes (BOM) ni comillas, fin de línea `\r\n`, con los 9 campos de datos del Formato 1 —nombre de la categoría, código de balanza, nombre del producto, SKU como código ERP, precio lista 1, precio lista 2 `0,00`, tipo de venta, vencimiento `0` y un campo extra vacío— completados con campos vacíos hasta 31 campos separados por `;`, como la línea "PLU 9 campos" del ejemplo oficial. El precio SHALL ir con 2 decimales, coma decimal, sin separador de miles ni símbolo, por kilo cuando la unidad base efectiva es de peso y por unidad en otro caso; el tipo de venta SHALL ser `p` para productos de peso y `u` para los que se venden por unidades. Todo texto SHALL transliterarse a ASCII imprimible sin tildes ni `ñ`, sin `;` ni saltos de línea, y truncarse a la longitud máxima del campo, salvo el SKU: un SKU de más de 25 caracteres NO SHALL truncarse (dos SKU con el mismo prefijo quedarían iguales); su código ERP SHALL ir vacío y la pantalla SHALL avisarlo. Los productos sin precio, los padres con variantes, los productos medibles que no son de peso y los códigos de balanza con más dígitos que el campo código del formato habilitado SHALL omitirse, y la pantalla SHALL informar cuántos se exportaron y cuáles se omitieron y por qué.

#### Scenario: Un producto de peso se exporta por kilo

- **GIVEN** el producto "Zanahoria orgánica" en la categoría "Verdulería", unidad base Kilogramo, precio 1.250, código de balanza 509 y SKU `ZAN-01`
- **WHEN** se exporta el catálogo
- **THEN** el archivo contiene la línea `Verduleria;509;Zanahoria organica;ZAN-01;1250,00;0,00;p;0;;;;;;;;;;;;;;;;;;;;;;;` (31 campos: los 9 del Formato 1 y 22 vacíos) seguida de `\r\n`

#### Scenario: Un producto por unidad se exporta con tipo u

- **GIVEN** el producto "Lechuga" con unidad base Unidad, precio 4,5 y código de balanza 100
- **WHEN** se exporta el catálogo
- **THEN** su línea lleva el precio `4,50` y el tipo de venta `u`

#### Scenario: Un producto con precio por gramo se exporta por kilo

- **GIVEN** un producto con unidad base Gramo, precio 4,5 por gramo y código de balanza 300
- **WHEN** se exporta el catálogo
- **THEN** su línea lleva el precio `4500,00` y el tipo de venta `p`

#### Scenario: Productos que no se pueden exportar

- **GIVEN** un producto con código de balanza y sin precio, y otro sin código de balanza
- **WHEN** se exporta el catálogo
- **THEN** ninguno de los dos aparece en el archivo, y la pantalla informa el primero como omitido por falta de precio

#### Scenario: Un punto y coma en el nombre no rompe el archivo

- **GIVEN** un producto con código de balanza llamado `Papa; negra`
- **WHEN** se exporta el catálogo
- **THEN** su línea tiene exactamente 31 campos y el nombre no contiene `;`

#### Scenario: Un SKU demasiado largo no se trunca

- **GIVEN** un producto con código de balanza y un SKU de 30 caracteres
- **WHEN** se exporta el catálogo
- **THEN** su código ERP va vacío y la pantalla avisa que el SKU excede 25 caracteres
