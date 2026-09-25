## ADDED Requirements

### Requirement: Representación impresa de la Factura C autorizada

El sistema SHALL generar en el backend un PDF de la representación impresa de un comprobante fiscal `authorized` de tipo `factura_c` que contenga, como mínimo: la leyenda de copia ("ORIGINAL"); los datos del emisor (razón social, nombre de fantasía si existe, domicilio comercial, CUIT, la leyenda "IVA RESPONSABLE MONOTRIBUTO", Ingresos Brutos como número o condición, fecha de inicio de actividades); la letra "C" y el código "011"; el punto de venta en 4 dígitos y el número en 8 (`0003-00000501`); la fecha de emisión; el bloque del receptor; la condición de venta; el detalle de líneas (descripción, cantidad, precio unitario, subtotal); el importe total; el CAE; la fecha de vencimiento del CAE; y el QR de ARCA. Todo dato fiscal impreso (número, fecha, tipo, importe, receptor, CAE, vencimiento) SHALL salir de lo persistido en `fiscal_documents` al autorizar, nunca del estado actual de la venta ni del cliente. El importe total impreso SHALL ser `fiscal_documents.total`.

#### Scenario: La factura de Sumar se imprime con sus datos autorizados

- **GIVEN** el comprobante `factura_c` autorizado con `punto_de_venta = 3`, `number = 501`, `fecha_comprobante = 2026-09-25`, `total = 32500`, `cae_due_date = 2026-10-05`, sin receptor identificado, con una línea "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro" × 1 a $32.500
- **WHEN** se genera su PDF
- **THEN** el texto del PDF contiene "ORIGINAL", "C", "011", "0003-00000501", "25/09/2026", "Consumidor Final", "Contado", la descripción de la línea, "$ 32.500,00", el CAE completo y "05/10/2026"

#### Scenario: La fecha impresa es la del comprobante, no la de la venta

- **GIVEN** una venta cargada el 21/09 cuyo comprobante se autorizó con `fecha_comprobante = 2026-09-25`
- **WHEN** se genera el PDF
- **THEN** la fecha de emisión impresa es "25/09/2026"

#### Scenario: El detalle que no suma el total autorizado no se imprime

- **GIVEN** un comprobante autorizado cuya suma de subtotales de líneas difiere de `total` en más de $0,01
- **WHEN** se pide su PDF
- **THEN** la respuesta es 409 con `code = "invoice_lines_mismatch"` y no se genera ningún PDF

#### Scenario: Un tipo de comprobante todavía no soportado se rechaza

- **GIVEN** un comprobante autorizado de tipo `factura_b`
- **WHEN** se pide su PDF
- **THEN** la respuesta es 409 con `code = "invoice_type_not_printable"`

---

### Requirement: Bloque del receptor igual a lo declarado a ARCA

El bloque del receptor SHALL reflejar exactamente lo que se envió a ARCA. Si `receptor_doc_tipo` es NULL o 99, SHALL imprimir "Consumidor Final" sin número de documento. Si es 80 (CUIT) o 96 (DNI), SHALL imprimir el tipo y número de documento, `receptor_legal_name` si existe y la condición frente al IVA legible derivada de `receptor_iva_condition` ("Consumidor Final" si es NULL). El sistema NOT SHALL imprimir datos del cliente que no se declararon a ARCA en el bloque del receptor.

#### Scenario: Consumidor final sin identificar

- **GIVEN** un comprobante con `receptor_doc_tipo` NULL y un `client_id` con nombre cargado
- **WHEN** se genera el PDF
- **THEN** el receptor dice "Consumidor Final" y no aparece el nombre del cliente en el bloque del receptor

#### Scenario: Receptor identificado por CUIT

- **GIVEN** un comprobante con `receptor_doc_tipo = 80`, `receptor_doc_nro = '30712345678'`, `receptor_legal_name = 'ACME SA'`, `receptor_iva_condition = 'responsable_inscripto'`
- **WHEN** se genera el PDF
- **THEN** el receptor muestra "CUIT: 30-71234567-8", "ACME SA" y "IVA Responsable Inscripto"

---

### Requirement: Condición de venta impresa

La factura SHALL imprimir la condición de venta: "Cuenta Corriente" cuando la forma de pago de la orden de venta vinculada al comprobante —o, si la orden no tiene, la de su operación de venta— es de `kind = 'credit'`; "Contado" en cualquier otro caso, incluido el caso sin forma de pago registrada.

#### Scenario: Venta a crédito

- **GIVEN** un comprobante cuya orden tiene una forma de pago de `kind = 'credit'`
- **WHEN** se genera el PDF
- **THEN** la condición de venta impresa es "Cuenta Corriente"

#### Scenario: Orden sin forma de pago

- **GIVEN** un comprobante cuya orden y cuya operación de venta no tienen forma de pago
- **WHEN** se genera el PDF
- **THEN** la condición de venta impresa es "Contado"

---

### Requirement: QR de ARCA según RG 4892

La factura SHALL incluir un código QR que codifique el texto `https://www.afip.gob.ar/fe/qr/?p=<DATOS>`, donde `<DATOS>` es el Base64 del JSON versión 1 de la especificación oficial de ARCA con las claves, en este orden, `ver` (1), `fecha` (`fecha_comprobante` en formato `AAAA-MM-DD`), `cuit` (CUIT del emisor como número), `ptoVta`, `tipoCmp` (código ARCA del tipo, 11 para Factura C), `nroCmp`, `importe` (total como número, sin decimales si son cero), `moneda` (`"PES"`), `ctz` (1), `tipoDocRec` y `nroDocRec` (los enviados a ARCA; 99 y 0 para consumidor final sin identificar), `tipoCodAut` (`"E"`) y `codAut` (el CAE como número), serializado sin espacios. Los campos numéricos SHALL ir como números JSON, no como texto. El QR SHALL imprimirse junto a la leyenda "Comprobante Autorizado", el CAE y su vencimiento.

#### Scenario: El QR de la factura de Sumar codifica sus datos autorizados

- **GIVEN** el comprobante de Sumar (CUIT 27213790337, PV 3, número 501, fecha 2026-09-25, total 32500, consumidor final)
- **WHEN** se decodifica el parámetro `p` del QR
- **THEN** el JSON es `{"ver":1,"fecha":"2026-09-25","cuit":27213790337,"ptoVta":3,"tipoCmp":11,"nroCmp":501,"importe":32500,"moneda":"PES","ctz":1,"tipoDocRec":99,"nroDocRec":0,"tipoCodAut":"E","codAut":<CAE>}` con los números como números

#### Scenario: El ejemplo oficial de ARCA se reproduce byte a byte

- **GIVEN** los datos del ejemplo de la especificación de ARCA (fecha 2020-10-13, CUIT 30000000007, PV 10, tipo 1, número 94, importe 12100, moneda DOL, cotización 65, receptor 80/20000000001, CAE 70417054367476)
- **WHEN** se arma el texto del QR
- **THEN** el Base64 resultante es idéntico al del ejemplo oficial

#### Scenario: Importe con centavos

- **GIVEN** un comprobante con `total = 32500.50`
- **WHEN** se arma el payload del QR
- **THEN** `importe` es el número `32500.5`

---

### Requirement: No se imprime una factura con datos adivinados

El sistema NOT SHALL generar la factura con un dato fiscal inferido. Si `fecha_comprobante` es NULL, SHALL responder 409 con `code = "invoice_date_unknown"`. Si falta un dato obligatorio del emisor (razón social, domicilio comercial, CUIT, condición IVA, inicio de actividades, e Ingresos Brutos como número o condición) tanto en la foto del emisor congelada en el comprobante como en el perfil fiscal actual, SHALL responder 409 con `code = "issuer_data_incomplete"` y la lista de campos faltantes. Un comprobante sin foto del emisor, o con un campo vacío en su foto, SHALL completarse campo por campo desde el perfil fiscal actual.

#### Scenario: Sin fecha confirmada

- **GIVEN** un comprobante autorizado con `fecha_comprobante` NULL
- **WHEN** se pide su PDF
- **THEN** la respuesta es 409 `invoice_date_unknown` y no se usa `created_at` ni la fecha del día

#### Scenario: Emisor sin domicilio

- **GIVEN** un comprobante autorizado cuya foto del emisor y cuyo perfil actual no tienen domicilio comercial ni inicio de actividades
- **WHEN** se pide su PDF
- **THEN** la respuesta es 409 `issuer_data_incomplete` con `domicilio_comercial` e `inicio_actividades` en la lista de faltantes

#### Scenario: Comprobante anterior a la foto del emisor

- **GIVEN** un comprobante autorizado con `emisor_snapshot` NULL y un perfil fiscal completo
- **WHEN** se pide su PDF
- **THEN** el PDF se genera con los datos del emisor del perfil actual

---

### Requirement: Comprobante de homologación marcado como sin validez

Si el comprobante se autorizó en el ambiente de homologación (según la foto del emisor o, sin foto, el perfil), el PDF SHALL mostrar una marca de agua "COMPROBANTE DE PRUEBA - SIN VALIDEZ FISCAL" y el título SHALL indicar "(HOMOLOGACION)".

#### Scenario: Factura de prueba

- **GIVEN** un comprobante autorizado con `emisor_snapshot.ambiente = 'homologacion'`
- **WHEN** se genera el PDF
- **THEN** el texto del PDF contiene "SIN VALIDEZ FISCAL"

---

### Requirement: Endpoint de la factura en PDF con tenencia

El backend SHALL exponer `GET /fiscal/documents/{id}/pdf` en el router `fiscal`, con arquitectura de 3 capas (router sin lógica, service con las reglas, repositorio con filtro explícito por `account_id` además de la RLS). SHALL responder 200 `application/pdf` sólo para un comprobante `authorized` de la cuenta del usuario, con `Content-Disposition` `inline` por defecto o `attachment` si `disposition=attachment`, y nombre de archivo `factura-<letra>-<PPPP>-<NNNNNNNN>.pdf`. Un comprobante de otra cuenta SHALL responder 404 con el mismo cuerpo que uno inexistente. Un comprobante en `pending_cae`, `rejected` o `voided` SHALL responder 409 `fiscal_document_not_authorized`. Los errores SHALL seguir RFC 7807.

#### Scenario: El dueño descarga su factura

- **WHEN** un usuario de la cuenta de Sumar pide `GET /fiscal/documents/<id>/pdf?disposition=attachment` de su comprobante autorizado
- **THEN** la respuesta es 200 con `Content-Type: application/pdf` y `Content-Disposition: attachment; filename="factura-C-0003-00000501.pdf"`

#### Scenario: Otra cuenta no puede ver la factura

- **GIVEN** un usuario de una cuenta distinta de la del comprobante
- **WHEN** pide su PDF
- **THEN** la respuesta es 404 `fiscal_document_not_found`, idéntica a la de un id inexistente

#### Scenario: Un comprobante en trámite no es una factura

- **GIVEN** un comprobante en `pending_cae`
- **WHEN** se pide su PDF
- **THEN** la respuesta es 409 `fiscal_document_not_authorized`

#### Scenario: Sin sesión

- **WHEN** se pide el PDF sin credenciales
- **THEN** la respuesta es 401

---

### Requirement: CAE visible junto al comprobante

Donde se muestra el estado de un comprobante fiscal de una venta (`/ventas`) o de una orden de venta (`/ventas/ordenes`), la interfaz SHALL mostrar, cuando el comprobante está autorizado, el tipo y número (`Factura C 0003-00000501`), el CAE completo copiable, su fecha de vencimiento y un enlace "Verificar en ARCA" a la constatación pública de comprobantes (`https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx`) que abre en una pestaña nueva. Los read models de ventas y de órdenes SHALL traer `cae`, `cae_due_date` y `comprobante_type` derivados de `fiscal_documents`, sin columnas denormalizadas. El bloque SHALL verse correctamente en desktop y en móvil (360 px, sin desborde horizontal) y en tema claro y oscuro.

#### Scenario: Venta facturada en /ventas

- **GIVEN** la venta de Sumar con su comprobante autorizado
- **WHEN** el usuario abre `/ventas` y expande la operación
- **THEN** ve "Autorizado", "Factura C 0003-00000501", el CAE, "vence 05/10/2026" y el enlace "Verificar en ARCA"

#### Scenario: El estado de la orden es el real al cargar

- **GIVEN** una orden cuyo comprobante ya está autorizado
- **WHEN** el usuario abre `/ventas/ordenes`
- **THEN** el badge muestra "Autorizado" (no "En trámite") y el bloque muestra el CAE

#### Scenario: Comprobante todavía en trámite

- **GIVEN** un comprobante en `pending_cae`
- **WHEN** se muestra su bloque
- **THEN** se ve el badge "En trámite" y no se muestra CAE ni el enlace de verificación

---

### Requirement: Imprimir, descargar y enviar la factura desde la venta

En `/ventas`, el menú de comprobante de una venta con comprobante autorizado SHALL ofrecer "Ver / imprimir factura" (abre el PDF del endpoint en una pestaña nueva, con descarga como alternativa si el navegador la bloquea), "Descargar factura (PDF)" y "Verificar en ARCA", y SHALL conservar, rotulado como "Comprobante interno (sin validez fiscal)", el comprobante interno existente. "Enviar por WhatsApp" SHALL compartir el PDF de la factura (share nativo con archivo; si no está disponible, descarga del PDF y apertura de WhatsApp con un texto que menciona la factura). Para una venta sin comprobante autorizado el menú y el envío por WhatsApp SHALL comportarse como hasta ahora. Un 409 `issuer_data_incomplete` SHALL mostrarse con una acción que lleve a `/configuracion/fiscal`.

#### Scenario: Imprimir la factura

- **GIVEN** una venta con comprobante autorizado
- **WHEN** el usuario elige "Ver / imprimir factura"
- **THEN** se abre una pestaña con el PDF devuelto por `GET /fiscal/documents/<id>/pdf`

#### Scenario: WhatsApp manda la factura

- **GIVEN** una venta con comprobante autorizado y un dispositivo con share de archivos
- **WHEN** el usuario toca "Enviar por WhatsApp"
- **THEN** se comparte el archivo `factura-C-0003-00000501.pdf`, no el comprobante interno

#### Scenario: Venta sin factura

- **GIVEN** una venta sin comprobante fiscal
- **WHEN** el usuario abre el menú
- **THEN** ve "Descargar / Imprimir" y "Copiar texto" del comprobante interno, como antes

#### Scenario: Datos del emisor incompletos

- **GIVEN** una cuenta sin domicilio comercial cargado
- **WHEN** el usuario pide la factura
- **THEN** ve un aviso que nombra los datos faltantes y un botón que lo lleva a `/configuracion/fiscal`
