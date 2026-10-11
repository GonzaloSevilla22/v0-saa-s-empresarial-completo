## MODIFIED Requirements

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
