## ADDED Requirements

### Requirement: Marca de los papeles por cuenta
El sistema SHALL guardar, por cuenta y en una única fila, la marca que llevan los papeles que la cuenta entrega a terceros: nombre comercial para los papeles, razón social, CUIT, domicilio, teléfono, email del negocio, sitio web, leyenda al pie, paleta de colores y logo. Todos los campos de texto son opcionales; un campo vacío SHALL guardarse como ausente, nunca como texto en blanco. Una cuenta sin fila SHALL comportarse como una cuenta con todos los campos vacíos, la paleta **Neutro** y sin logo. La fila NOT SHALL borrarse por la API ni por PostgREST: retirar el logo o volver a los valores por defecto es una actualización. La marca NOT SHALL guardarse en el perfil fiscal, en `accounts` ni en el perfil de un usuario.

Límites que la base SHALL hacer cumplir además del backend: nombre comercial hasta 80 caracteres, razón social hasta 120, domicilio hasta 200, teléfono hasta 40, email hasta 120 con forma de dirección de correo, sitio web hasta 120 sin espacios ni caracteres de marcado, leyenda al pie hasta 280, CUIT con forma `NN-NNNNNNNN-N` (guiones opcionales), paleta dentro del catálogo, color personalizado `#rrggbb` presente si y sólo si la paleta es **Personalizado**, y el logo completo o ausente (imagen, tipo, huella, ancho y alto juntos).

#### Scenario: Cuenta que nunca configuró su marca
- **GIVEN** una cuenta sin fila de marca
- **WHEN** cualquier miembro consulta la marca de la cuenta
- **THEN** recibe todos los campos vacíos, la paleta "neutro", sin logo, y una marca de que son los valores por defecto

#### Scenario: Texto en blanco
- **WHEN** el dueño guarda el teléfono "   "
- **THEN** el teléfono queda ausente, no como texto en blanco

#### Scenario: Color personalizado sin paleta personalizada
- **WHEN** se intenta guardar la paleta "azul" con un color personalizado
- **THEN** la escritura se rechaza, tanto por la API (422) como directa contra la tabla

#### Scenario: Nadie borra la fila
- **WHEN** un owner intenta borrar la fila de marca de su cuenta por PostgREST
- **THEN** no se borra ninguna fila

### Requirement: Sólo owner y admin cambian la marca
La escritura de la marca (datos, paleta y logo) SHALL estar restringida a los miembros con rol activo `owner` o `admin` de la cuenta, en la base —un disparador que rechaza con `P0401` cualquier alta o cambio de otro rol, además de la RLS de escritor— y en el backend (`CAN_CONFIGURE`, 403 antes de escribir). Una fila NOT SHALL poder mudarse de cuenta. Cualquier miembro de la cuenta SHALL poder leer la marca; un usuario de otra cuenta NOT SHALL leerla ni escribirla. El disparador SHALL ser interno: sin `EXECUTE` para `PUBLIC`, `anon` ni `authenticated`. `anon` NOT SHALL tener privilegios sobre la tabla.

#### Scenario: Un vendedor no cambia la marca
- **GIVEN** un usuario cuyo único rol es vendedor
- **WHEN** intenta guardar la marca por la API
- **THEN** recibe 403 y la marca no cambia

#### Scenario: Un vendedor no la cambia por PostgREST
- **GIVEN** el mismo vendedor
- **WHEN** inserta o actualiza la fila de marca de su cuenta directamente contra la tabla
- **THEN** la escritura se rechaza con `P0401`

#### Scenario: Un vendedor ve la marca
- **WHEN** el vendedor consulta la marca de su cuenta
- **THEN** la recibe completa

#### Scenario: Otra cuenta
- **WHEN** un usuario de otra cuenta lee o escribe la fila de marca de la cuenta A
- **THEN** no la ve y la escritura se rechaza

### Requirement: Logo validado y normalizado por el servidor
El logo SHALL subirse por el backend, que SHALL:
- aceptar sólo PNG, JPEG o WebP, reconocidos por su contenido y no por el nombre ni el tipo declarado; rechazar SVG, GIF y cualquier otro formato con 415;
- rechazar con 413 un archivo de más de 2 MB, sin leerlo entero;
- leer las dimensiones **antes** de decodificar y rechazar con 422 una imagen de más de 25 millones de píxeles, una imagen corrupta o una que no se pueda decodificar;
- reescalar la imagen para que su lado mayor no supere 1000 px, quitar sus metadatos y volver a codificarla —PNG si tiene transparencia, JPEG si no—, y rechazar con 422 un resultado que supere 300 KB después de intentar un tamaño menor;
- guardar la imagen normalizada asociada a la cuenta, con su tipo, sus dimensiones y su huella SHA-256.

El sistema NOT SHALL descargar un logo desde una URL ni usar el avatar de un usuario como logo. Cualquier miembro SHALL poder obtener la imagen normalizada de su cuenta por la API; un owner o admin SHALL poder retirarla. Quien dibuja un papel SHALL volver a comprobar el formato y las dimensiones de la imagen guardada antes de decodificarla, y ante una imagen que no pasa la comprobación SHALL dibujar el papel sin logo, nunca fallar.

#### Scenario: Logo PNG con transparencia
- **WHEN** un owner sube un PNG de 2400 × 600 px con fondo transparente
- **THEN** se guarda un PNG de 1000 × 250 px con transparencia, su huella y sus dimensiones

#### Scenario: Logo JPEG grande
- **WHEN** un owner sube un JPEG de 4000 × 3000 px y 1,8 MB
- **THEN** se guarda un JPEG de 1000 × 750 px de no más de 300 KB, sin metadatos

#### Scenario: SVG
- **WHEN** un owner sube un archivo SVG
- **THEN** la respuesta es 415 y el logo no cambia

#### Scenario: Bomba de descompresión
- **WHEN** un owner sube un PNG de 300 KB que declara 20000 × 20000 px
- **THEN** la respuesta es 422 sin haber decodificado la imagen

#### Scenario: Imagen guardada que no se puede leer
- **GIVEN** una fila de marca cuyo logo guardado no se puede decodificar
- **WHEN** se genera el PDF de un presupuesto de esa cuenta
- **THEN** el PDF se genera sin logo

### Requirement: Paleta de colores de los papeles con contraste verificable
La paleta de los papeles SHALL elegirse de un catálogo cerrado —**Neutro** (por defecto), **Azul**, **Verde**, **Grafito**, **Bordó** y **Personalizado**— cuyos colores viven en una única fuente en el backend y se exponen por la API. **Neutro** SHALL dibujar sin rellenos de color: tinta pizarra oscura sobre blanco, reglas grises y la cabecera de la tabla en gris muy claro, la misma tinta que la Factura C. En los papeles no fiscales, las demás paletas SHALL usar su color de acento en el título del documento, la regla del encabezado, la cabecera de la tabla y el importe total (la Factura C lo usa sólo donde indica `fiscal-invoice-print`), y el texto sobre la cabecera SHALL ser el blanco o la tinta, el que dé más contraste. Todo color de acento —del catálogo o personalizado— SHALL tener un contraste de al menos 4,5:1 contra el blanco (WCAG 2.1 AA); un color personalizado que no lo cumple SHALL rechazarse con 422 `branding_accent_low_contrast`. Un color guardado que no lo cumpla (por ejemplo, escrito directo en la tabla) SHALL dibujarse con **Neutro**. El cálculo de contraste del frontend y el del backend SHALL coincidir sobre un mismo conjunto compartido de casos.

#### Scenario: Neutro por defecto
- **GIVEN** una cuenta sin marca configurada
- **WHEN** se genera el PDF de cualquiera de sus papeles
- **THEN** ningún elemento del PDF está pintado con el verde anterior (16, 185, 129)

#### Scenario: Paleta azul
- **GIVEN** una cuenta con la paleta "azul"
- **WHEN** se genera el PDF de un presupuesto
- **THEN** el título, la regla, la cabecera de la tabla y el total usan el azul del catálogo y el texto de la cabecera es blanco

#### Scenario: Color personalizado ilegible
- **WHEN** un owner guarda la paleta personalizada con el color `#10b981`
- **THEN** la respuesta es 422 `branding_accent_low_contrast` porque mide 2,54:1 contra el blanco

#### Scenario: Color personalizado válido
- **WHEN** un owner guarda la paleta personalizada con el color `#7c2d12`
- **THEN** se guarda y los papeles usan ese color

### Requirement: Emisor único de los papeles resuelto por cascada
El sistema SHALL resolver los datos de la empresa que imprime cualquier papel de la cuenta con una sola cascada, campo por campo, en el servidor:
- **nombre visible**: el nombre comercial de la marca; si no, el nombre de fantasía del perfil fiscal; si no, la razón social del perfil fiscal; si no, la razón social de la marca; si no, el nombre del negocio del perfil del dueño de la cuenta; y en último término "Mi Negocio";
- **razón social**: la del perfil fiscal; si no, la de la marca;
- **CUIT**: el del perfil fiscal; si no, el de la marca; impreso como `NN-NNNNNNNN-N` cuando tiene 11 dígitos;
- **condición frente al IVA**: sólo la del perfil fiscal;
- **domicilio**: el domicilio comercial del perfil fiscal; si no, el de la marca;
- **teléfono**: el de la marca; si no, el del perfil del dueño;
- **email**: sólo el email del negocio de la marca;
- **sitio web** y **leyenda al pie**: sólo los de la marca.

El email de acceso de ningún usuario NOT SHALL imprimirse en un papel ni formar parte de lo que devuelve la lectura del emisor. Los datos SHALL ser los mismos para cualquier miembro que genere el papel. La Factura C toma de la marca sólo el logo, la paleta y el contacto cargado en la marca, según su propia capability (`fiscal-invoice-print`): su identidad fiscal sigue saliendo de la foto congelada al autorizar. Un dato faltante NOT SHALL impedir generar un papel no fiscal: se omite. La lectura SHALL exponer sólo los campos enumerados, la paleta y la huella del logo (nunca la imagen) y SHALL rechazarse para quien no es miembro de la cuenta.

#### Scenario: Cuenta sin marca, igual que antes
- **GIVEN** una cuenta sin fila de marca cuyo dueño cargó el nombre del negocio "Almacén Don José"
- **WHEN** se resuelve el emisor
- **THEN** el nombre es "Almacén Don José", como antes de este cambio

#### Scenario: El perfil fiscal manda en la identidad fiscal
- **GIVEN** una cuenta con perfil fiscal de razón social "Ropa Deportiva SRL" y CUIT 20123456786, y una marca con razón social "Otra SA", CUIT 20111111112 y nombre comercial "Sumar"
- **WHEN** se resuelve el emisor
- **THEN** el nombre es "Sumar", la razón social "Ropa Deportiva SRL" y el CUIT "20-12345678-6"

#### Scenario: Cuenta sin perfil fiscal con marca completa
- **GIVEN** una cuenta sin perfil fiscal con marca de razón social, CUIT, domicilio, teléfono, email y web
- **WHEN** se resuelve el emisor
- **THEN** todos esos datos salen de la marca y no hay condición frente al IVA

#### Scenario: Nunca el email de acceso
- **GIVEN** una cuenta cuyo dueño accede con "duenio@example.com" y sin email del negocio en la marca
- **WHEN** se resuelve el emisor
- **THEN** no hay email, y ningún valor de la lectura es "duenio@example.com"

#### Scenario: Un vendedor que no es el dueño
- **GIVEN** una cuenta cuya marca no tiene teléfono y cuyo dueño tiene el teléfono 2615550101
- **WHEN** un vendedor que no es el dueño genera un papel
- **THEN** el papel lleva el teléfono 2615550101

### Requirement: API de la marca de documentos
El backend SHALL exponer, con arquitectura de 3 capas y errores RFC 7807:
- `GET /document-branding` para cualquier miembro: la configuración guardada (o los valores por defecto), si hay logo y su huella, el emisor tal como se imprime con el origen de cada dato (perfil fiscal, marca, perfil del dueño o valor por defecto), y el catálogo de paletas con sus colores;
- `PUT /document-branding` para owner y admin: reemplaza los datos y la paleta de la marca (el logo no cambia) y devuelve lo mismo que el `GET`;
- `PUT /document-branding/logo` para owner y admin, con la imagen como cuerpo binario; `DELETE /document-branding/logo` para owner y admin;
- `GET /document-branding/logo` para cualquier miembro: la imagen normalizada con su tipo, `ETag` igual a su huella y `Cache-Control: private`; 404 `branding_logo_not_found` si la cuenta no tiene logo.

Toda lectura y escritura SHALL filtrar explícitamente por la cuenta del usuario además de la RLS. Sin sesión, la respuesta SHALL ser 401.

#### Scenario: Guardar la marca
- **WHEN** un admin hace `PUT /document-branding` con nombre comercial "Sumar", email "ventas@sumar.com.ar" y paleta "grafito"
- **THEN** la respuesta es 200 con esos datos y el emisor resuelto con nombre "Sumar"

#### Scenario: Un cajero no sube el logo
- **WHEN** un usuario cuyo único rol es cajero hace `PUT /document-branding/logo`
- **THEN** la respuesta es 403 y el logo no cambia

#### Scenario: Pedir el logo de una cuenta sin logo
- **WHEN** un miembro pide `GET /document-branding/logo` y la cuenta no tiene logo
- **THEN** la respuesta es 404 `branding_logo_not_found`

### Requirement: El comprobante interno de venta lleva la marca resuelta en el servidor
El comprobante interno de venta —su PDF, su versión HTML imprimible y sus textos para WhatsApp y el portapapeles— SHALL llevar el emisor resuelto por la cascada, la paleta y el logo de la cuenta de la venta, nunca los datos del perfil, el avatar ni el email del usuario que lo genera. `POST /sales/receipt-pdf` SHALL resolver la marca por la cuenta del usuario autenticado y SHALL aceptar e **ignorar** los campos de nombre, teléfono y email del negocio que mandaba el navegador, para no rechazar a un cliente anterior a este cambio. La versión HTML SHALL incrustar el logo como una imagen `data:` de tipo PNG o JPEG validada antes de interpolarla y los colores sólo con forma `#rrggbb` validada. El comprobante SHALL seguir rotulado como comprobante de venta sin validez fiscal.

#### Scenario: Comprobante con la marca de la cuenta
- **GIVEN** una cuenta con nombre comercial "Sumar", logo, email del negocio y paleta "azul"
- **WHEN** un vendedor descarga el PDF del comprobante interno de una venta
- **THEN** el PDF lleva "Sumar", el logo, el email del negocio y los colores azules, y no el nombre ni el email del vendedor

#### Scenario: Un navegador viejo manda los datos del negocio
- **WHEN** llega `POST /sales/receipt-pdf` con `business_name` "Otro Nombre" y `business_email` "login@example.com"
- **THEN** la respuesta es 200 y el PDF lleva el emisor de la cuenta, sin "Otro Nombre" ni "login@example.com"

#### Scenario: HTML imprimible con logo
- **WHEN** el usuario elige "Descargar / Imprimir" en una venta de una cuenta con logo
- **THEN** el HTML muestra el logo como imagen `data:image/png;base64,…` o `data:image/jpeg;base64,…` y no contiene la URL del avatar del usuario

### Requirement: Pestaña Documentos en Configuración
La página de configuración SHALL tener una pestaña "Documentos", enlazable como `/configuracion?tab=documentos`, que permita cargar los datos de la empresa para los papeles, subir, ver y retirar el logo, elegir la paleta (con un color personalizado y el aviso de contraste antes de guardar) y ver una **vista previa en vivo** del encabezado de un documento con lo que se está editando. Los datos que salen del perfil fiscal SHALL mostrarse como tales, sin poder editarse ahí, con un enlace a la configuración de AFIP. La pestaña SHALL decir qué papeles usan la marca. Los miembros que no son owner ni admin SHALL verla en sólo lectura. La vista previa representa el papel y SHALL ser blanca en los dos temas; el resto de la pestaña SHALL usar los tokens semánticos del sistema de diseño y verse correctamente en desktop y en móvil, en tema claro y oscuro, sin desborde horizontal.

#### Scenario: El dueño configura la marca
- **WHEN** el dueño completa el nombre comercial, sube un logo, elige "Bordó" y guarda
- **THEN** la vista previa muestra el logo, el nombre y el bordó, y el próximo presupuesto que descarga los lleva

#### Scenario: Aviso de contraste en vivo
- **WHEN** el dueño escribe el color personalizado `#facc15`
- **THEN** la pestaña avisa que no se lee bien sobre blanco y no permite guardarlo

#### Scenario: Cuenta con perfil fiscal
- **GIVEN** una cuenta con perfil fiscal con razón social y domicilio
- **WHEN** el dueño abre la pestaña
- **THEN** la razón social, el CUIT y el domicilio se muestran como datos del perfil fiscal, con un enlace a AFIP, y no como campos editables

#### Scenario: Un vendedor ve la pestaña en sólo lectura
- **WHEN** un miembro con rol de vendedor abre la pestaña Documentos
- **THEN** ve la marca y la vista previa sin poder editar ni subir un logo
