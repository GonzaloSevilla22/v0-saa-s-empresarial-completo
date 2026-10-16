# commercial-document-pdf Specification

## Purpose
PDF, descarga y envío por WhatsApp de los documentos comerciales **no fiscales** (el presupuesto primero; está diseñado para el remito). Define el constructor compartido del backend que dibuja una vista ya resuelta sin lógica de negocio, los datos del emisor sin bloqueo, la leyenda de documento no válido como factura, el endpoint del PDF por id con tenencia y el menú compartido del frontend para ver, descargar y compartir el documento.

## Requirements

### Requirement: Constructor compartido del PDF de un documento comercial
El sistema SHALL generar el PDF de los documentos comerciales **no fiscales** (el presupuesto primero; está diseñado para el remito) con un único constructor compartido en el backend, que dibuja una vista ya resuelta sin lógica de negocio. La vista contiene:

- el título del documento, su número visible y la fecha de emisión;
- la fecha de validez (opcional) y un sello de estado (opcional);
- los datos del emisor y del destinatario;
- las líneas (descripción, cantidad con el símbolo de su unidad, precio unitario con su precisión y subtotal);
- si se muestran precios;
- el total, las notas y la leyenda.

El constructor recibe además la **marca de la cuenta** del documento (capability `document-branding`): la paleta resuelta, el logo normalizado si lo hay y la leyenda al pie de la cuenta.

El PDF SHALL:

- dibujar el encabezado del emisor con el **helper de encabezado compartido** por todos los papeles de la cuenta (el comprobante interno de venta y la Factura C usan el mismo), con el logo arriba a la izquierda escalado sin deformarse dentro de un recuadro máximo de 50 × 18 mm, y sin el logo cuando la cuenta no tiene o el guardado no se puede leer;
- usar la **paleta de la cuenta** —**Neutro** por defecto— en el título, la regla del encabezado, la cabecera de la tabla, el importe total y el sello de un presupuesto aceptado; el sello de vencido o rechazado conserva su rojo de advertencia; NOT SHALL usar un color fijo propio;
- imprimir la leyenda al pie de la cuenta, si la tiene, en todas las páginas, junto a la leyenda del documento;
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

#### Scenario: presupuesto con logo y paleta
- **GIVEN** una cuenta con logo y la paleta "bordo"
- **WHEN** se construye el PDF de uno de sus presupuestos
- **THEN** el PDF contiene una imagen y el título, la cabecera de la tabla y el total en el bordó del catálogo

#### Scenario: remito con la misma marca
- **GIVEN** la misma cuenta
- **WHEN** se construye el PDF de un remito de venta y el de un remito de compra
- **THEN** los dos llevan la misma imagen, la misma paleta y el mismo encabezado del emisor que el presupuesto

#### Scenario: sin verde por defecto
- **GIVEN** una cuenta sin marca configurada
- **WHEN** se construye el PDF de un presupuesto aceptado
- **THEN** el título, la cabecera, el total y el sello "ACEPTADO" usan la tinta de la paleta Neutro y ningún elemento usa el verde (16, 185, 129)

#### Scenario: leyenda al pie de la cuenta
- **GIVEN** una cuenta con la leyenda al pie "Alias para transferencias: sumar.ropa"
- **WHEN** se construye el PDF de un presupuesto de dos páginas
- **THEN** las dos páginas llevan esa leyenda y la leyenda de presupuesto no válido como factura

### Requirement: Datos del emisor sin bloqueo
El sistema SHALL resolver los datos del emisor de un documento comercial desde la cuenta del documento con la cascada única de la capability `document-branding`:

- **nombre visible**: nombre comercial de la marca, si no el nombre de fantasía del perfil fiscal, si no la razón social del perfil fiscal, si no la razón social de la marca, si no el nombre del negocio del perfil del dueño de la cuenta y, en último término, "Mi Negocio";
- **razón social, CUIT y domicilio**: los del perfil fiscal y, si faltan, los de la marca; el CUIT impreso como `NN-NNNNNNNN-N` cuando tiene 11 dígitos;
- **condición frente al IVA**: la del perfil fiscal, si existe;
- **teléfono**: el de la marca y, si falta, el del perfil del dueño;
- **email**: sólo el **email del negocio** cargado en la marca. El email de acceso de ningún usuario NOT SHALL aparecer en un documento para terceros;
- **sitio web**: el de la marca.

A diferencia de la factura fiscal, un dato del emisor faltante NOT SHALL impedir generar el documento: se omite.

Los datos del emisor SHALL ser los mismos para cualquier miembro de la cuenta que genere el documento, sea o no el dueño: su lectura NOT SHALL depender de las políticas de fila del perfil de quien descarga. Esa lectura SHALL exponer sólo los campos del emisor enumerados arriba, la leyenda al pie, la paleta y la huella del logo —nunca la imagen, ni ningún email de acceso—, y SHALL rechazarse para quien no es miembro de la cuenta.

#### Scenario: cuenta con perfil fiscal completo
- **GIVEN** una cuenta con nombre de fantasía, razón social, CUIT, condición frente al IVA y domicilio comercial, sin marca configurada
- **WHEN** se genera el PDF de uno de sus presupuestos
- **THEN** el encabezado muestra el nombre de fantasía, la razón social, el CUIT con guiones, la condición frente al IVA y el domicilio

#### Scenario: descarga un vendedor que no es el dueño
- **GIVEN** una cuenta sin perfil fiscal ni marca cuyo dueño cargó el nombre del negocio "Almacén Don José" y un teléfono
- **WHEN** un usuario con rol de vendedor de esa cuenta, que no es el dueño, descarga el PDF de un presupuesto
- **THEN** el encabezado muestra "Almacén Don José" y el teléfono del dueño, y no "Mi Negocio"

#### Scenario: cuenta sin perfil fiscal
- **GIVEN** una cuenta sin perfil fiscal ni marca cuyo dueño tiene cargado el nombre del negocio
- **WHEN** se genera el PDF de uno de sus presupuestos
- **THEN** el PDF se genera con el nombre del negocio y sin CUIT ni domicilio

#### Scenario: marca completa sin perfil fiscal
- **GIVEN** una cuenta sin perfil fiscal con marca de nombre comercial "Kiosco Lola", CUIT 20111111112, domicilio, teléfono, email "hola@kioscolola.com" y web "kioscolola.com"
- **WHEN** se genera el PDF de uno de sus remitos
- **THEN** el encabezado muestra "Kiosco Lola", "CUIT: 20-11111111-2", el domicilio, el teléfono, "hola@kioscolola.com" y "kioscolola.com"

#### Scenario: la lectura del emisor nunca trae un email de acceso
- **GIVEN** una cuenta sin email del negocio en la marca
- **WHEN** un miembro lee el emisor de la cuenta
- **THEN** la lectura no trae email y ninguno de sus valores es el email de acceso del dueño

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

### Requirement: El constructor del PDF comercial admite el remito
El sistema SHALL construir el PDF del remito con el mismo constructor compartido de documentos comerciales, extendido de forma aditiva para el presupuesto, que no cambia. La vista suma dos campos opcionales:
- un **bloque de firma de recepción** con espacios para firma, aclaración, DNI y fecha, que no se parte entre páginas;
- un **rótulo de origen** con la sucursal de la que sale la mercadería.

Cuando la vista indica no mostrar precios, el PDF SHALL omitir las columnas de precio unitario y subtotal y el total, y la tabla de líneas SHALL quedar con descripción y cantidad con su unidad. La leyenda del remito SHALL ser "Remito — documento no válido como factura." Los datos del emisor SHALL resolverse igual que para el presupuesto, sin bloquear por datos faltantes.

#### Scenario: Remito sin precios
- **WHEN** se construye el PDF de un remito con la opción de no mostrar precios
- **THEN** el PDF contiene "REMITO", el número, la sucursal de origen, las cantidades con su unidad, el bloque de firma y la leyenda, y no contiene precios ni total

#### Scenario: Remito con precios
- **WHEN** se construye el mismo PDF con la opción de mostrar precios
- **THEN** el PDF incluye precio unitario, subtotal y total

#### Scenario: El presupuesto no cambia
- **WHEN** se construye el PDF de un presupuesto después de este cambio
- **THEN** no lleva bloque de firma ni rótulo de origen y su contenido es el mismo que antes

### Requirement: Endpoint del PDF del remito por id con tenencia
El sistema SHALL exponer `GET /delivery-notes/{id}/pdf` con `disposition` (`inline` o `attachment`) y `show_prices` (booleano, falso por defecto).

El endpoint SHALL devolver el PDF para cualquier estado del remito y para cualquier miembro de su cuenta. El archivo se llama `remito-R-00000012.pdf`, y `remito-R-00000012-con-precios.pdf` cuando se piden precios, para que las dos variantes no se confundan.

Un remito de otra cuenta o inexistente SHALL responder 404 con el mismo cuerpo RFC 7807. Un parámetro inválido SHALL responder 422 y un pedido sin sesión, 401.

#### Scenario: Descarga por defecto
- **WHEN** un miembro de la cuenta pide el PDF de un remito sin `show_prices`
- **THEN** recibe 200 `application/pdf` sin precios, con el nombre de archivo del número del remito

#### Scenario: Remito de otra cuenta
- **WHEN** un usuario pide el PDF de un remito de otra cuenta
- **THEN** recibe 404 `delivery_note_not_found`, igual que para un id inexistente

