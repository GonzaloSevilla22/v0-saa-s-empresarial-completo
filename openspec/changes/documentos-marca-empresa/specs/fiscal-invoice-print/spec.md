## ADDED Requirements

### Requirement: La Factura C lleva la marca de la cuenta sin alterar su contenido fiscal
La representación impresa de la Factura C SHALL llevar, además de su contenido mínimo, la marca de la cuenta (capability `document-branding`) leída **en vivo** al generar el PDF:

- el **logo** de la cuenta en la columna del emisor, escalado sin deformarse dentro de un recuadro máximo de 40 × 16 mm, o ninguno si la cuenta no tiene o el guardado no se puede leer;
- debajo de la leyenda de IVA, las líneas de **teléfono, email del negocio y sitio web** cargadas en la marca de la cuenta, las que existan. A diferencia de los papeles no fiscales, el teléfono NOT SHALL completarse desde el perfil del dueño: en la factura el contacto se imprime sólo cuando la cuenta lo cargó para sus papeles;
- la **paleta** de la cuenta sólo en elementos no fiscales: la banda de la cabecera de la tabla de detalle y el título "FACTURA". Con la paleta **Neutro**, esos elementos SHALL quedar con la tinta y el gris de hoy.

Los datos fiscales del emisor (nombre de fantasía, razón social, domicilio, CUIT, condición de IVA, Ingresos Brutos, inicio de actividades) SHALL seguir saliendo de la foto congelada al autorizar, completada desde el perfil fiscal como hasta ahora, y NOT SHALL completarse desde la marca. La marca NOT SHALL guardarse en la foto del emisor. El recuadro de la letra, el CAE, su vencimiento, el bloque del receptor y los textos legales SHALL quedar en tinta, y el QR de ARCA SHALL dibujarse siempre negro sobre blanco. La leyenda al pie de la marca NOT SHALL imprimirse en la factura. El encabezado SHALL medir su contenido antes de dibujarse y crecer en alto lo necesario, para que ningún logo ni línea de contacto se superponga ni salga del recuadro, en todas las páginas.

Esto reemplaza la decisión de `factura-fiscal-imprimible` de no imprimir teléfono, email ni web en la factura, por pedido del PO del 2026-10-11 ("toda la información de la empresa y el logo" en todos los papeles, facturas incluidas).

#### Scenario: Factura con logo y contacto
- **GIVEN** un comprobante `factura_c` autorizado de una cuenta con logo, teléfono "2615550101", email del negocio "ventas@negocio.com.ar" y web "negocio.com.ar" en su marca
- **WHEN** se genera su PDF
- **THEN** el PDF contiene una imagen y el texto incluye "2615550101", "ventas@negocio.com.ar" y "negocio.com.ar", además de todo su contenido mínimo

#### Scenario: Sin marca, la factura queda como estaba
- **GIVEN** el mismo comprobante de una cuenta sin marca configurada cuyo dueño tiene un teléfono en su perfil
- **WHEN** se genera su PDF
- **THEN** no contiene ninguna imagen, no imprime el teléfono del dueño y su texto es el mismo que antes de este cambio

#### Scenario: El QR no cambia de color
- **GIVEN** una cuenta con la paleta "azul"
- **WHEN** se genera el PDF de una de sus facturas
- **THEN** la banda de la cabecera de la tabla y el título usan el azul, y el QR, el recuadro de la letra y el CAE quedan en negro y tinta

#### Scenario: La marca no altera los datos fiscales congelados
- **GIVEN** un comprobante autorizado con foto del emisor de razón social "Ropa Deportiva SRL" y una marca posterior con nombre comercial "Sumar" y razón social "Otra SA"
- **WHEN** se genera su PDF
- **THEN** la razón social impresa es "Ropa Deportiva SRL" y no aparece "Otra SA"

#### Scenario: Un logo cuadrado no desborda
- **GIVEN** una cuenta con un logo de 1000 × 1000 px, nombre de fantasía largo y las tres líneas de contacto
- **WHEN** se genera el PDF de una factura de 60 líneas
- **THEN** en cada página el logo, el nombre, la leyenda de IVA y el contacto quedan dentro del recuadro del encabezado, y la tabla empieza debajo de él
