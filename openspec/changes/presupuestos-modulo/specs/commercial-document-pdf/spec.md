## ADDED Requirements

### Requirement: Constructor compartido del PDF de un documento comercial
El sistema SHALL generar el PDF de los documentos comerciales **no fiscales** (el presupuesto primero; está diseñado para el remito) con un único constructor compartido en el backend, que dibuja una vista ya resuelta sin lógica de negocio. La vista contiene:

- el título del documento, su número visible y la fecha de emisión;
- la fecha de validez (opcional) y un sello de estado (opcional);
- los datos del emisor y del destinatario;
- las líneas (descripción, cantidad con el símbolo de su unidad, precio unitario con su precisión y subtotal);
- si se muestran precios;
- el total, las notas y la leyenda.

El PDF SHALL:

- usar la misma familia visual que el comprobante interno de venta;
- sustituir los caracteres que la fuente no representa, en vez de fallar;
- repetir la cabecera de la tabla en cada página cuando las líneas no entran en una.

Precisión de los montos: los precios unitarios SHALL mostrarse con su precisión (RN-24-bis) y los importes, al centavo.

#### Scenario: presupuesto de una página
- **WHEN** se construye el PDF de un presupuesto de tres líneas
- **THEN** el PDF contiene el título "PRESUPUESTO", el número, las tres líneas, el total y la leyenda

#### Scenario: muchas líneas
- **WHEN** se construye el PDF de un presupuesto de 80 líneas
- **THEN** el PDF tiene varias páginas y cada una repite la cabecera de la tabla

#### Scenario: caracteres fuera de la fuente
- **WHEN** una descripción de línea contiene un emoji
- **THEN** el PDF se genera igual, con el carácter sustituido

#### Scenario: precio sub-centavo
- **WHEN** una línea tiene precio unitario 4,575 por gramo
- **THEN** el PDF muestra el precio unitario con sus decimales y el subtotal al centavo

### Requirement: Datos del emisor sin bloqueo
El sistema SHALL resolver los datos del emisor de un documento comercial desde la cuenta del documento:

- **nombre visible**: nombre de fantasía del perfil fiscal, si no la razón social, si no el nombre del negocio del perfil del dueño de la cuenta y, en último término, "Mi Negocio";
- **razón social, CUIT y domicilio comercial**, si están cargados en el perfil fiscal;
- **teléfono** del perfil del dueño. El email no se imprime: el perfil no lo guarda, y el email de acceso del dueño no debe aparecer en un documento para terceros.

A diferencia de la factura fiscal, un dato del emisor faltante NOT SHALL impedir generar el documento: se omite.

#### Scenario: cuenta con perfil fiscal completo
- **GIVEN** una cuenta con nombre de fantasía, razón social, CUIT y domicilio comercial
- **WHEN** se genera el PDF de uno de sus presupuestos
- **THEN** el encabezado muestra el nombre de fantasía, la razón social, el CUIT y el domicilio

#### Scenario: cuenta sin perfil fiscal
- **GIVEN** una cuenta sin perfil fiscal cuyo dueño tiene cargado el nombre del negocio
- **WHEN** se genera el PDF de uno de sus presupuestos
- **THEN** el PDF se genera con el nombre del negocio y sin CUIT ni domicilio

### Requirement: Leyenda de documento no válido como factura
Todo documento comercial no fiscal SHALL llevar al pie una leyenda que declare que no es válido como factura. Para el presupuesto, la leyenda SHALL ser "Presupuesto — documento no válido como factura." seguida, cuando hay fecha de validez, de "Precios válidos hasta el dd/mm/aaaa.".

#### Scenario: leyenda del presupuesto
- **WHEN** se genera el PDF de un presupuesto válido hasta el 14/10/2026
- **THEN** el pie dice "Presupuesto — documento no válido como factura. Precios válidos hasta el 14/10/2026."

### Requirement: Endpoint del PDF por id con tenencia
El backend SHALL exponer el PDF de cada documento comercial por su id (para el presupuesto, `GET /quotes/{id}/pdf`) con arquitectura de 3 capas: el router sin lógica, el service con las reglas y el repositorio con filtro explícito por `account_id`, además de la RLS. El contenido SHALL leerse de la base de datos, nunca del request. El endpoint:

- SHALL responder 200 `application/pdf` para un documento de la cuenta del usuario;
- SHALL usar `Content-Disposition` `inline` por defecto, o `attachment` con `disposition=attachment`, y un nombre de archivo con el tipo y el número visible;
- ante un documento de otra cuenta SHALL responder 404, con el mismo cuerpo RFC 7807 que un id inexistente;
- ante un valor de `disposition` inválido SHALL responder 422, y sin sesión, 401.

#### Scenario: el dueño descarga su presupuesto
- **WHEN** un usuario de la cuenta pide `GET /quotes/<id>/pdf?disposition=attachment` de su presupuesto P-00000012
- **THEN** la respuesta es 200 con `Content-Type: application/pdf` y `Content-Disposition: attachment; filename="presupuesto-P-00000012.pdf"`

#### Scenario: otra cuenta no ve el documento
- **GIVEN** un usuario de una cuenta distinta de la del presupuesto
- **WHEN** pide su PDF
- **THEN** la respuesta es 404 `quote_not_found`, idéntica a la de un id inexistente

#### Scenario: sin sesión
- **WHEN** se pide el PDF sin credenciales
- **THEN** la respuesta es 401

### Requirement: Menú compartido para ver, descargar y enviar un documento por WhatsApp
El frontend SHALL proveer un componente compartido de menú de documento con tres acciones —"Ver / Imprimir", "Descargar PDF" y "Enviar por WhatsApp"— que obtiene el PDF del endpoint del documento. Las acciones funcionan así:

- **"Ver / Imprimir"** SHALL abrir el PDF en una pestaña nueva, abierta dentro del gesto del usuario, y descargarlo si el navegador bloquea la pestaña.
- **"Enviar por WhatsApp"**:
  - SHALL compartir el **archivo PDF** con el share nativo cuando el dispositivo puede compartir archivos;
  - si no puede, SHALL descargar el PDF y abrir WhatsApp dirigido al teléfono normalizado del destinatario, con un texto corto;
  - si el destinatario no tiene un teléfono válido, SHALL abrir WhatsApp sin destinatario (selector de contacto) y avisarlo.

El componente SHALL notificar al consumidor cuando el documento se descargó o se compartió, y NOT SHALL hacerlo al sólo verlo ni cuando el usuario cancela el share nativo. El share nativo SHALL invocarse dentro del gesto del usuario con el PDF ya obtenido (precargado al abrir el menú), para que funcione en los navegadores que exigen ese gesto. Los helpers de descarga, share y fetch binario SHALL vivir en la capa canónica (`lib/`) y ser los mismos que usan el comprobante de venta y la factura, sin copias. Una sesión vencida SHALL llevar al login sin mostrar un error.

#### Scenario: compartir desde el celular
- **GIVEN** un dispositivo con share nativo de archivos
- **WHEN** el usuario elige "Enviar por WhatsApp" en un presupuesto
- **THEN** se comparte el archivo `presupuesto-P-00000012.pdf` con el texto corto

#### Scenario: compartir desde la computadora
- **GIVEN** un navegador sin share de archivos y un cliente con teléfono válido
- **WHEN** el usuario elige "Enviar por WhatsApp"
- **THEN** se descarga el PDF, se abre `wa.me/<teléfono>` con el texto corto y se avisa que hay que adjuntar el archivo

#### Scenario: cliente sin teléfono
- **WHEN** el usuario elige "Enviar por WhatsApp" para un cliente sin teléfono válido
- **THEN** se abre WhatsApp sin destinatario y se muestra el aviso de que no hay número registrado

#### Scenario: ver no notifica envío
- **WHEN** el usuario elige "Ver / Imprimir"
- **THEN** el PDF se abre y el consumidor no recibe la notificación de enviado

#### Scenario: cancelar el share no notifica envío
- **WHEN** el usuario elige "Enviar por WhatsApp" en un dispositivo con share nativo y cancela
- **THEN** el consumidor no recibe la notificación de enviado

#### Scenario: el comprobante de venta sigue igual
- **WHEN** el usuario comparte el comprobante interno o la factura de una venta
- **THEN** el comportamiento es el mismo que antes de la extracción de los helpers
