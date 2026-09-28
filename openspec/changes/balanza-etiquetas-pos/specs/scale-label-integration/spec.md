## ADDED Requirements

### Requirement: Configuración de la balanza por cuenta

El sistema SHALL guardar por cuenta, en la tabla `scale_settings` (una fila por cuenta), si la lectura de etiquetas de balanza está habilitada y los tres formatos de código de barras de la balanza —venta por peso, venta por unidad y varios—, cada uno descrito como una lista ordenada de hasta cuatro campos (A a D) con su tipo (número fijo, código PLU, importe, peso, cantidad u otro que se ignora), su cantidad de dígitos y, según el tipo, su valor fijo o sus decimales. Una cuenta sin fila SHALL comportarse como balanza **deshabilitada** con los formatos de fábrica de la Systel Cuora Neo (peso `20` + código 4 + importe 6 con 2 decimales; unidad `21` + código 4 + importe 6 con 2 decimales; varios `22` + otro 2 + importe 8 con 2 decimales).

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

El sistema SHALL aceptar un formato habilitado sólo si cumple todas estas reglas, con la misma definición en el frontend y en la API: la suma de los dígitos de sus campos es exactamente 12; el campo A es un número fijo de 1 a 3 dígitos cuyo valor tiene esa cantidad de dígitos y empieza con `2`; los formatos de peso y de unidad tienen exactamente un campo de código PLU de 1 a 6 dígitos y exactamente un campo de valor (importe o peso para el de peso; importe o cantidad para el de unidad); los decimales del valor son un entero de 0 a 3; y ninguna cabecera de un formato habilitado es prefijo de la cabecera de otro formato habilitado. Una configuración que no cumple SHALL rechazarse con un error que identifique el formato y el campo, sin guardar nada.

#### Scenario: La suma de dígitos distinta de 12 se rechaza

- **WHEN** se guarda un formato de peso con número fijo 2, código 4 e importe 5
- **THEN** la API responde 422 indicando que los campos deben sumar 12 dígitos

#### Scenario: Una cabecera que no empieza con 2 se rechaza

- **WHEN** se guarda un formato cuyo número fijo es `77`
- **THEN** la configuración se rechaza, porque chocaría con los códigos de productos envasados

#### Scenario: Cabeceras que se pisan se rechazan

- **WHEN** se guardan habilitados un formato de peso con cabecera `2` y uno de unidad con cabecera `21`
- **THEN** la configuración se rechaza porque `2` es prefijo de `21`

#### Scenario: El frontend y la API aplican la misma regla

- **GIVEN** el conjunto compartido de casos de validación
- **WHEN** se evalúa cada caso con el esquema del frontend y con el de la API
- **THEN** los dos coinciden en aceptar o rechazar cada caso

### Requirement: Decodificación de la etiqueta de balanza

El frontend SHALL decodificar un código leído con una única función pura de la capa canónica que, dada la configuración de la cuenta, distinga cuatro resultados: el código no es de balanza (balanza deshabilitada, no son 13 dígitos, o ninguna cabecera habilitada coincide); es de balanza pero inválido (dígito verificador EAN-13 incorrecto, o PLU igual a cero); es un ticket de varios artículos (no soportado); o es una etiqueta válida, en cuyo caso SHALL devolver el formato (peso o unidad), el PLU como entero sin ceros a la izquierda y el valor (importe, peso o cantidad) aplicando los decimales configurados. La validación del dígito verificador SHALL reutilizar la función EAN-13 existente.

#### Scenario: Ejemplo oficial de Systel con la configuración de fábrica

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2002610013638`
- **THEN** el resultado es una etiqueta de peso con PLU 261 e importe 13,63

#### Scenario: Importe configurado sin decimales

- **GIVEN** el formato de peso con importe de 6 dígitos y 0 decimales
- **WHEN** se decodifica `2002610135002`
- **THEN** el resultado es PLU 261 con importe 13.500

#### Scenario: Peso embebido

- **GIVEN** el formato de peso con cabecera `20`, código 4 y peso de 6 dígitos con 3 decimales
- **WHEN** se decodifica `2005090012504`
- **THEN** el resultado es PLU 509 con peso 1,250 kg

#### Scenario: Dígito verificador incorrecto

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2002610013639`
- **THEN** el resultado es inválido por dígito verificador y no se intenta ninguna otra búsqueda con ese código

#### Scenario: Ticket de varios artículos

- **GIVEN** la balanza habilitada con los formatos de fábrica
- **WHEN** se decodifica `2200000045003`
- **THEN** el resultado es "ticket de varios artículos, no soportado"

#### Scenario: Balanza deshabilitada

- **GIVEN** la balanza deshabilitada
- **WHEN** se decodifica `2002610013638`
- **THEN** el resultado es "no es de balanza"

### Requirement: Orden de resolución de un código leído

El POS y el formulario de venta SHALL resolver todo código leído con una única función compartida y en este orden: (1) un producto vivo, que no sea padre con variantes, cuyo código de barras coincide exactamente (sin distinguir mayúsculas); (2) una etiqueta de balanza, si la decodificación la reconoce — una etiqueta inválida o de varios artículos SHALL terminar la resolución con un error, sin pasar al paso siguiente; (3) un producto vivo, que no sea padre con variantes, cuyo SKU coincide (sin distinguir mayúsculas); (4) un error de código no encontrado.

#### Scenario: Un código de barras declarado gana sobre la interpretación de balanza

- **GIVEN** la balanza habilitada con los formatos de fábrica y un producto cuyo código de barras es `2000123456782`
- **WHEN** se lee `2000123456782`
- **THEN** se agrega ese producto como un código común, sin decodificarlo como etiqueta

#### Scenario: Un SKU se resuelve cuando no es código ni etiqueta

- **GIVEN** un producto con SKU `ZAP-01`
- **WHEN** se lee `zap-01`
- **THEN** se agrega ese producto

#### Scenario: Un código desconocido informa el error

- **WHEN** se lee un código que no es código de barras, etiqueta ni SKU de ningún producto
- **THEN** la pantalla informa que el código no se encontró y el indicador del lector muestra el estado de error

### Requirement: Una etiqueta de balanza se convierte en una línea de venta

El frontend SHALL convertir una etiqueta válida en una línea de venta con una única función pura compartida por el POS y el formulario de venta, que busca el producto por su código de balanza entre los productos vivos de la cuenta y expresa la línea en la unidad base efectiva del producto. Con **importe** embebido, el subtotal de la línea SHALL ser exactamente el importe de la etiqueta, la cantidad SHALL derivarse como importe ÷ precio del catálogo redondeado a 0,001 kg (expresado en la unidad base) y el precio unitario SHALL derivarse del subtotal y la cantidad con la función canónica existente, de modo que el total cobrado sea el importe de la etiqueta. Con **peso** embebido, la cantidad SHALL ser el peso y el precio el del catálogo. En el formato **por unidad**, una cantidad embebida SHALL usarse tal cual con el precio del catálogo, y un importe embebido SHALL cobrarse exacto con una cantidad de al menos 1 derivada de importe ÷ precio. La línea SHALL nacer sin descuento y con el paso y mínimo de su unidad, editable como cualquier otra. Ninguna RPC ni endpoint de venta SHALL cambiar para aceptarla.

#### Scenario: Importe embebido cobra exactamente la etiqueta

- **GIVEN** el producto "Tomate" con unidad base Kilogramo, precio 4,80 y código de balanza 261
- **WHEN** se lee `2002610013638` con los formatos de fábrica
- **THEN** se agrega una línea de 2,840 kg con subtotal 13,63 y la venta confirmada cobra 13,63 por esa línea

#### Scenario: La cantidad se expresa en la unidad base del producto

- **GIVEN** el producto "Tomate" con unidad base Gramo, precio 4,5 por gramo y código de balanza 261, y el formato de peso con importe de 0 decimales
- **WHEN** se lee `2002610135002`
- **THEN** se agrega una línea de 3000 g con precio 4,5 y subtotal 13.500

#### Scenario: Peso embebido usa el precio del catálogo

- **GIVEN** el producto "Papa" con unidad base Kilogramo, precio 1.800 y código de balanza 509, y el formato de peso con peso de 6 dígitos y 3 decimales
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

Cuando una etiqueta válida no puede convertirse en línea, el sistema SHALL no agregar nada al carrito y SHALL mostrar un mensaje que diga qué hacer, distinguiendo al menos: PLU no asignado a ningún producto de la cuenta (indicando dónde asignarlo), PLU asignado a un producto padre con variantes, producto sin precio, modo de venta incompatible (etiqueta de peso para un producto cuya unidad base no es de peso, o etiqueta por unidad para un producto de peso) y cantidad derivada menor a la precisión mínima. Un ticket de varios artículos SHALL explicar que sus productos deben cargarse uno por uno. Cuando la línea supera el stock disponible SHALL aplicarse el mismo rechazo y el mismo mensaje que a un alta manual.

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

### Requirement: Cada etiqueta de balanza es una línea propia

Cada etiqueta de balanza leída SHALL agregar una línea nueva al carrito, aunque ya exista una línea del mismo producto y la misma unidad, para que cada pesada conserve su importe y pueda quitarse sola. Los códigos de barras comunes y los SKU SHALL conservar el comportamiento de sumar el mínimo de la unidad a la línea existente del mismo producto y unidad.

#### Scenario: Dos etiquetas del mismo producto

- **WHEN** se leen dos etiquetas distintas del mismo PLU
- **THEN** el carrito tiene dos líneas de ese producto, cada una con el importe de su etiqueta

### Requirement: El POS lee códigos con el lector

El POS (`/ventas/pos`) SHALL montar el lector de códigos y su indicador junto al buscador de productos, y SHALL agregar al carrito lo que resuelva la función compartida de resolución. El indicador SHALL mostrar el resultado de cada lectura (el producto agregado o el motivo del error) usando los tokens semánticos del sistema de diseño. El lector SHALL suspenderse mientras haya abierto un diálogo modal que no lo contenga, mientras se registra la venta y cuando el usuario no tiene permiso de escritura. Una lectura hecha con el foco en un campo de texto o numérico NO SHALL dejar el código escrito dentro de ese campo.

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

### Requirement: El formulario de venta usa la misma resolución

El formulario de venta SHALL resolver cada código leído con la misma función compartida que el POS, sin lógica propia de etiquetas, y SHALL seguir leyendo mientras él mismo está dentro de su diálogo "Nueva venta" o "Editar venta"; un diálogo anidado abierto encima SHALL suspender el lector. La lectura NO SHALL dejar el código escrito dentro del campo con foco.

#### Scenario: Escanear una etiqueta en el formulario de venta

- **GIVEN** la balanza habilitada y el diálogo "Nueva venta" abierto
- **WHEN** se lee `2002610013638` y existe un producto con código de balanza 261
- **THEN** la línea aparece en el carrito del formulario con subtotal 13,63

#### Scenario: Un código de barras común conserva su comportamiento

- **GIVEN** el formulario de venta con una línea del producto de código `7791234567898` y cantidad 1
- **WHEN** se vuelve a leer `7791234567898`
- **THEN** la misma línea pasa a cantidad 2

### Requirement: Pestaña Balanza en Configuración

La página de configuración SHALL tener una pestaña "Balanza", enlazable como `/configuracion?tab=balanza`, que permita habilitar la lectura de etiquetas, editar los tres formatos campo por campo con la línea "Resultado" que la balanza muestra para el mismo formato (dígitos fijos, la letra del campo repetida por cada dígito y `X` al final), restaurar los valores de fábrica, ver el importe máximo representable por cada formato con importe y un aviso cuando un producto con código de balanza tiene un precio por kilo mayor que ese máximo, y probar un código real contra la configuración **en edición**: el probador SHALL mostrar el formato detectado, el PLU, el valor decodificado, el producto resuelto y la línea que se agregaría, o el error correspondiente. Los miembros que no son owner ni admin SHALL ver la configuración en sólo lectura y poder usar el probador. La pestaña SHALL verse correctamente en desktop y en móvil, en tema claro y oscuro.

#### Scenario: La línea Resultado espeja la de la balanza

- **WHEN** el usuario configura el formato de peso con número fijo `20`, código 4 e importe 6
- **THEN** la pestaña muestra `Resultado: 20BBBBCCCCCCX`

#### Scenario: El probador usa la configuración sin guardar

- **GIVEN** la configuración guardada con importe de 2 decimales y el usuario cambió a 0 decimales sin guardar
- **WHEN** prueba `2002610135002`
- **THEN** el probador muestra importe 13.500

#### Scenario: Aviso de desborde

- **GIVEN** el formato de peso con importe de 6 dígitos y 2 decimales, y un producto con código de balanza y precio 12.000 por kilo
- **WHEN** se abre la pestaña
- **THEN** se muestra el importe máximo de 9.999,99 y un aviso de que ese producto desborda la etiqueta

#### Scenario: Un vendedor ve la pestaña en sólo lectura

- **WHEN** un miembro con rol de vendedor abre la pestaña Balanza
- **THEN** ve la configuración sin poder editarla y puede usar el probador

### Requirement: Exportación del catálogo para la balanza

La pestaña Balanza SHALL ofrecer "Exportar catálogo para la balanza", que genera en el navegador, sin consumir la cuota de exportaciones ni registrarse en el historial de exportaciones, un archivo CSV en el Formato 1 de importación de Systel Suite Neo: una línea por producto vivo con código de balanza, sin encabezado, exactamente 9 campos separados por `;`, fin de línea `\r\n`: nombre de la categoría, código de balanza, nombre del producto, SKU como código ERP, precio lista 1, precio lista 2 `0,00`, tipo de venta, vencimiento `0` y un campo extra vacío. El precio SHALL ir con 2 decimales, coma decimal, sin separador de miles ni símbolo, por kilo cuando la unidad base efectiva es de peso y por unidad en otro caso; el tipo de venta SHALL ser `p` para productos de peso y `u` para el resto. Todo texto SHALL transliterarse a ASCII imprimible sin tildes ni `ñ`, sin `;` ni saltos de línea, y truncarse a la longitud máxima del campo. Los productos sin precio, los padres con variantes y los códigos de balanza con más dígitos que el campo código del formato habilitado SHALL omitirse, y la pantalla SHALL informar cuántos se exportaron y cuáles se omitieron y por qué.

#### Scenario: Un producto de peso se exporta por kilo

- **GIVEN** el producto "Zanahoria orgánica" en la categoría "Verdulería", unidad base Kilogramo, precio 1.250, código de balanza 509 y SKU `ZAN-01`
- **WHEN** se exporta el catálogo
- **THEN** el archivo contiene la línea `Verduleria;509;Zanahoria organica;ZAN-01;1250,00;0,00;p;0;` seguida de `\r\n`

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
- **THEN** su línea tiene exactamente 9 campos y el nombre no contiene `;`
