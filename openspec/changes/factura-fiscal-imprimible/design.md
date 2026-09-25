## Context

### El caso real que dispara el change (medido en prod el 2026-09-25, sólo SELECT)

| Dato | Valor |
|---|---|
| Emisor | Sumar, CUIT 27213790337, `fiscal_profiles.iva_condition = 'monotributista'`, `iibb_condition = NULL`, `ambiente = 'produccion'`, PV activos 3 y 9999 |
| Comprobante | `fiscal_documents` `caaeccfd…`, `status = 'authorized'`, `comprobante_type = 'factura_c'`, `punto_de_venta = 3`, `number = 501` (= `arca_requested_number`: ARCA tenía 500 en ese PV por el sistema anterior; #580 adopta el número de ARCA) |
| CAE | 14 dígitos (`7…`, no se transcribe acá), `cae_due_date = 2026-10-05` |
| Importes | `total = 32500.00`, `neto`/`iva_amount`/`iva_alicuota_id` NULL (Factura C no discrimina IVA) |
| Receptor | `client_id` presente, pero `receptor_doc_tipo`/`receptor_doc_nro`/`receptor_legal_name`/`receptor_iva_condition` NULL → a ARCA fue **DocTipo 99, DocNro 0, CondicionIVAReceptorId 5** (consumidor final sin identificar) |
| Líneas | `sales_orders.fiscal_document_id` → 1 `sales_order_items`: "Ciclista Lycra con Bolsillos Kaese Talle 2 Negro" × 1 @ 32.500 (Σ = total) |
| Fechas | venta cargada el **21-09**, orden promovida y comprobante creado el **25-09 15:34 UTC**, marca de envío `cae_submit_started_at` 15:35 UTC (12:35 ART) |
| Forma de pago | la orden promovida no tiene `payment_method_id` |

Con ese comprobante la Factura C impresa tiene que decir `FACTURA C — Cód. 011 — 0003-00000501 — Fecha de emisión 25/09/2026`, "Consumidor Final", $ 32.500,00, el CAE y "Vto. CAE 05/10/2026", y el QR tiene que codificar exactamente esos datos.

En el resto de prod hay otras 2 Facturas C autorizadas, ambas de suscripciones de la plataforma (cuenta `9b52ebe0…`, `/admin/pagos`), sin `cae_submit_started_at` porque son anteriores a la marca previa.

### Qué hay hoy

- **No existe una factura imprimible.** `backend/services/receipts.py` genera con `fpdf2` (a) el recibo del pago de MercadoPago (*"no es una factura"*) y (b) el "Comprobante de venta" negocio → cliente que arma el frontend desde sus propios datos (`POST /sales/receipt-pdf`, render sin DB). `frontend/lib/receipt.ts` + `components/ventas/sale-receipt-button.tsx` ofrecen "Descargar / Imprimir" (HTML + `window.print()`), "Copiar texto" y "Enviar por WhatsApp" (PDF del comprobante interno por share nativo). Ninguno lleva CAE ni QR.
- **El CAE no se ve en ninguna pantalla.** `FiscalDocumentBadge` pinta el estado; `/ventas` muestra además `0003-00000501` (`op.fiscal.label`); el read model de ventas (`sales_repository.py` L114-131) no trae `cae` ni `cae_due_date`.
- **`/ventas/ordenes` muestra mal el estado**: `FiscalDocumentBadge` recibe `initialStatus={"pending_cae"}` fijo (L162-166) y Realtime sólo avisa `UPDATE`s, así que una orden ya autorizada al cargar la página queda "En trámite" para siempre.
- **La fecha del comprobante no se persiste.** `WSFEAdapter._call_wsfe` arma `CbteFch = (invoice_data.fecha_comprobante or datetime.date.today())` (L877) y el relay nunca pasa `fecha_comprobante`, así que es "hoy" según el reloj del servidor, que corre en UTC. Ni el request ni la respuesta se guardan (`fiscal_documents` **no tiene** columnas `payload`/`arca_response`). El QR exige la fecha exacta.
- **Faltan datos del emisor**: `fiscal_profiles` tiene sólo `cuit`, `iva_condition`, `iibb_condition` (texto libre, NULL en Sumar), `ambiente`, `delegacion_autorizada`, `certificado_afip_path`. No hay razón social, domicilio comercial, número de IIBB ni inicio de actividades, que RG 1415 exige en la factura. `FiscalProfileRepository.upsert` pisa `iibb_condition` con lo que venga (sin semántica PATCH).
- **Ya existe y se reutiliza**: `FiscalDocumentRepository.get_by_id(doc_id, account_id)` (filtro explícito por cuenta, además de la RLS); `formatComprobante`/`comprobanteTypeLabel` en `frontend/lib/fiscal-comprobante.ts`; `_COMPROBANTE_AFIP_CODE` en `wsfe_adapter.py` (`factura_c → 11`); `_format_amount`/`_latin1` en `receipts.py`; `getAuthHeaders`/`redirectedOnUnauthorized` para el fetch autenticado; `buildWhatsAppUrl`/`normalizeWhatsAppPhone`; el share nativo de `SaleReceiptButton`.

### Normativa (fuentes consultadas el 2026-09-25)

- **QR — RG 4892/2020.** Especificación oficial de ARCA, *"Especificaciones del QR incluido en las facturas electrónicas"*, `https://www.afip.gob.ar/fe/qr/documentos/QRespecificaciones.pdf` (PDF creado el 2025-02-03, enlazado desde `https://www.afip.gob.ar/fe/qr/`). Texto a codificar: `{URL}?p={DATOS_CMP_BASE64}` con `{URL} = https://www.arca.gob.ar/fe/qr/` y el JSON en Base64. JSON versión 1, **los numéricos van como números JSON, no como strings**:

  | Campo | Tipo | Obligatorio | Ejemplo oficial |
  |---|---|---|---|
  | `ver` | numérico 1 dígito | sí | `1` |
  | `fecha` | full-date RFC 3339 | sí | `"2020-10-13"` |
  | `cuit` | numérico 11 dígitos | sí | `30000000007` |
  | `ptoVta` | numérico hasta 5 | sí | `10` |
  | `tipoCmp` | numérico hasta 3 (tabla de tipos) | sí | `1` |
  | `nroCmp` | numérico hasta 8 | sí | `94` |
  | `importe` | decimal 13,2 | sí | `12100` |
  | `moneda` | 3 caracteres (tabla) | sí | `"DOL"` |
  | `ctz` | decimal 13,6 | sí (1 si es pesos) | `65` |
  | `tipoDocRec` | numérico hasta 2 | de corresponder | `80` |
  | `nroDocRec` | numérico hasta 20 | de corresponder | `20000000001` |
  | `tipoCodAut` | string | sí | `"E"` (CAE) / `"A"` (CAEA) |
  | `codAut` | numérico 14 dígitos | sí | `70417054367476` |

  El texto de la especificación dice `arca.gob.ar` pero su propio ejemplo codifica `https://www.afip.gob.ar/fe/qr/?p=…`; los dos dominios responden (302 a la página del QR, verificado con `curl` el 2026-09-25).
- **Contenido de la factura — RG 1415/2003** (y Anexo V): apellido y nombre o razón social, domicilio comercial, CUIT, número de inscripción en Ingresos Brutos (o condición), fecha de inicio de actividades, leyenda de la condición frente al IVA (**"RESPONSABLE MONOTRIBUTO"** para el emisor de Factura C), letra "C" y código del comprobante, número, fecha, datos del receptor, condición de venta, detalle, total, CAE y su vencimiento.
- **Verificación**: constatación pública de comprobantes con CAE, `https://servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx` (200 al 2026-09-25), además del QR (que abre la misma verificación) y "Mis Comprobantes" en la web de ARCA (demora ~1 día, visto el 2026-09-21).

## Goals / Non-Goals

**Goals:**
- Que el usuario pueda **ver, imprimir, descargar y mandar por WhatsApp** la Factura C autorizada, con contenido legal y un QR que ARCA reconoce.
- Que el **CAE y su vencimiento se vean** en las pantallas donde está la venta (`/ventas`) y la orden (`/ventas/ordenes`), junto con un enlace para verificarla en ARCA.
- Que lo impreso **coincida con lo que ARCA autorizó**: número, fecha, tipo, importe, receptor y CAE salen de lo persistido al autorizar, nunca del estado actual de la venta o del cliente.
- Dejar el renderer preparado para Factura A/B (tabla de tipos, bloque de IVA) sin habilitarlas.

**Non-Goals:**
- Elegir el punto de venta al vender o al facturar (la otra mitad del pedido del PO del 2026-09-25; va en un change aparte).
- Imprimir Factura A/B, notas de crédito/débito o comprobantes en moneda extranjera (hoy sólo se emite `factura_c` en pesos; los otros tipos responden 409 `invoice_type_not_printable`).
- La factura de las suscripciones en `/admin/pagos` (OQ-6).
- Enviar la factura por email, adjuntarla automáticamente al autorizar, o guardar el PDF en Storage (se genera a demanda, es determinístico).
- Logo en la factura (OQ-4).
- Cambiar la emisión, la numeración, los reintentos o el congelamiento del relay.
- El "Comprobante de venta" interno: queda igual y sigue disponible, rotulado como tal.

## Decisions

### D1 — PDF en el backend con `fpdf2`, no en el navegador

El comprobante interno se imprime con HTML + `window.print()`, pero una factura no puede depender del motor de impresión del navegador (márgenes, escalado, encabezados del navegador) ni ser armada con datos que manda el cliente. El backend ya genera PDFs con `fpdf2` y tiene el comprobante con tenencia verificada. El PDF sale de `GET /fiscal/documents/{id}/pdf` y el frontend lo abre, descarga o comparte como blob.

*Alternativa descartada*: extender `lib/receipt.ts` con el CAE y un QR en JS. Los datos vendrían del cliente (`SaleOperation`), no de la fila autorizada, y el resultado variaría por navegador.

### D2 — Modelo de vista puro + renderer

`backend/services/fiscal/invoice_pdf.py` separa:
1. `build_invoice_view(doc, profile, lines, sale_condition) -> InvoiceView`: función **pura** que resuelve todos los textos (encabezado, "0003-00000501", "25/09/2026", "Consumidor Final", importes con `_format_amount`, leyendas) y el payload del QR, y levanta `InvoiceNotPrintable(code, detail)` si falta algo.
2. `build_qr_url(view) -> str`: JSON v1 + Base64, puro.
3. `render_invoice_pdf(view) -> bytes`: dibuja con `fpdf2`, sin lógica de negocio.

Los tests de contenido atacan (1) y (2) sin PDF, y el render se prueba extrayendo el texto del PDF con `pypdf` (sólo en tests). Reutiliza `_format_amount` y `_latin1` de `receipts.py` (se mueven a un módulo común `backend/services/pdf_common.py` o se importan desde `receipts` — lo que sea menos invasivo; no se duplican).

### D3 — QR con `segno`, dibujado como rectángulos

`fpdf2` no dibuja QR (sus códigos de barras son Code39 e Interleaved 2 of 5). Opciones:
- `qrcode`: necesita Pillow para producir imagen (Pillow ya viene con `fpdf2`, pero es otra capa de imagen).
- **`segno`** (elegida): puro Python, sin dependencias, BSD; expone la matriz de módulos. El renderer recorre la matriz y dibuja cada módulo con `pdf.rect(..., style="F")` → vectorial, nítido a cualquier escala, sin archivos temporales ni imágenes.

Parámetros: `segno.make(url, error="m", micro=False)`, tamaño impreso ~30 mm (bien por encima del mínimo legible por una cámara de celular), zona de silencio de 4 módulos. El test verifica que el objeto QR se construye con **exactamente** la URL de `build_qr_url` (no se decodifica la imagen: no hay decoder puro Python sin dependencias nativas; la corrección del contenido la prueba el test del payload, y la lectura real por la cámara se verifica en la task manual con la factura de Sumar).

Costo: una dependencia de ~200 KB sin transitivas. Se agrega a `requirements.txt` y `pyproject.toml`.

### D4 — Payload del QR: sólo desde lo autorizado

```json
{"ver":1,"fecha":"2026-09-25","cuit":27213790337,"ptoVta":3,"tipoCmp":11,"nroCmp":501,
 "importe":32500,"moneda":"PES","ctz":1,"tipoDocRec":99,"nroDocRec":0,
 "tipoCodAut":"E","codAut":7…(14 dígitos)}
```

- `fecha` = `fiscal_documents.fecha_comprobante` (D5). Sin fecha persistida → 409 `invoice_date_unknown`, nunca "hoy" ni `created_at`.
- `cuit` = el CUIT emisor **congelado** (D6), sin guiones, como número.
- `tipoCmp` = `_COMPROBANTE_AFIP_CODE[comprobante_type]` (se reutiliza la tabla del adapter, movida a un módulo compartido si hace falta, nunca copiada).
- `importe` = `total` como número JSON: entero si no tiene centavos (`32500`), si no con 2 decimales (`32500.5` → `32500.5`). `moneda = "PES"`, `ctz = 1` (hoy toda emisión es en pesos, `MonId = "PES"`, `MonCotiz = 1` en el adapter).
- `tipoDocRec`/`nroDocRec` = los que **se mandaron a ARCA**: `receptor_doc_tipo`/`receptor_doc_nro` si existen; si no, `99`/`0`, que es exactamente lo que `_resolve_receptor_doc` envía para un consumidor final sin identificar. Se incluyen siempre (la especificación los marca "de corresponder" y el ejemplo oficial los trae; `99/0` es el valor declarado).
- `tipoCodAut = "E"` (sólo CAE; CAEA no existe en el sistema). `codAut` = `cae` como número.
- URL base `https://www.afip.gob.ar/fe/qr/` (la del ejemplo oficial; OQ-8 si el PO prefiere `arca.gob.ar`).
- Serialización: claves en el orden de la tabla y `json.dumps(payload, separators=(",", ":"))`. Verificado el 2026-09-25: con esa serialización, el JSON del ejemplo oficial produce **byte a byte** el mismo Base64 que trae la especificación — ese round-trip es un test.

### D5 — La fecha del comprobante la confirma ARCA y se persiste al autorizar

Nueva columna `fiscal_documents.fecha_comprobante date NULL`. Mismo principio que el número en #580 (G3): **ARCA es la fuente de verdad**.
- `CAEResponse` y `ReconcileResponse` ganan `fecha_comprobante: date | None`. En `FECAESolicitar` sale de `FeDetResp.FECAEDetResponse.CbteFch`; si ARCA no lo devuelve, de la fecha que el adapter mandó (que conoce). En `FECompConsultar` sale de `ResultGet.CbteFch`.
- `FiscalDocumentRepository.update_authorized(..., fecha_comprobante=...)` → `rpc_fiscal_document_authorize(p_doc_id, p_cae, p_cae_due_date, p_number, p_fecha_comprobante date DEFAULT NULL)`.
- La RPC se reescribe **desde el `pg_get_functiondef` vivo** (md5 `c8bc224d6f2767c6eb8d28031488e1f7`, 4.394 caracteres al 2026-09-25) con `DROP FUNCTION … (uuid,text,date,bigint)` + `CREATE` (nunca `CREATE OR REPLACE` con un parámetro nuevo: dejaría un overload vivo, gotcha `42725`), conservando `SECURITY DEFINER`, `search_path`, el `COMMENT` vivo y las ACL internas exactas (sin `EXECUTE` para `authenticated`/`anon`). El `DEFAULT NULL` mantiene compatible a un caller viejo de 4 argumentos durante la ventana de despliegue.
- Sólo se escribe en la transición real a `authorized` (el mismo `UPDATE … WHERE status = 'pending_cae'`); los caminos de idempotencia y de colisión (7b) no la tocan.

**Backfill de los 3 comprobantes existentes** (Sumar 0003-00000501 y los dos de la plataforma): no se puede derivar con certeza de `created_at` (los dos de la plataforma no tienen marca de envío y pudieron salir un día después). Se completa con un script de una sola vez que consulta `FECompConsultar` por cada `authorized` con `fecha_comprobante IS NULL` y escribe la fecha vía una RPC interna `rpc_fiscal_document_set_fecha_comprobante(p_doc_id, p_fecha)` (sólo si está NULL; sin `EXECUTE` para roles de aplicación). Corre en el apply con OK explícito del PO porque escribe en prod. Hasta que corra, esos 3 responden 409 `invoice_date_unknown` con un mensaje claro — nunca un PDF con una fecha adivinada.

*Alternativa descartada*: derivar la fecha de `cae_submit_started_at`. Vale para Sumar (12:35 ART, mismo día en UTC y en ART) pero no para los documentos sin marca, y deja la correctitud atada a un detalle del reloj del servidor.

### D6 — Foto del emisor congelada al autorizar (`emisor_snapshot jsonb`)

Los datos del emisor impresos tienen que ser los vigentes cuando se emitió, no los de hoy (si el comerciante se muda, sus facturas viejas no cambian de domicilio). El requisito existente "Datos del emisor vigentes congelados en el comprobante" ya prevé agregar de forma aditiva y NULLABLE lo que falte.

- Nueva columna `fiscal_documents.emisor_snapshot jsonb NULL` con `{cuit, razon_social, nombre_fantasia, domicilio_comercial, iva_condition, iibb_condition, iibb_numero, inicio_actividades, ambiente}`.
- La escribe `rpc_fiscal_document_authorize` en la misma transición a `authorized` (D5), leyendo `fiscal_profiles` por `fiscal_profile_id` del documento. Es el **único** punto por el que pasa todo comprobante autorizado (relay y reconciliación), así que no hay que tocar las 3 RPCs de emisión (`rpc_emit_pending_cae`, `rpc_emit_subscription_payment_cae`, `rpc_emit_sale_invoice`).
- ¿Por qué al autorizar y no al emitir (`pending_cae`), como el receptor? Porque el receptor define **qué** se le pide a ARCA y tiene que estar fijo antes del envío; los datos del emisor no viajan a ARCA (sólo el CUIT, que ya está en el perfil y en `list_pending`), y un solo punto de escritura es menos superficie en RPCs críticas. La diferencia entre emitir y autorizar es de segundos a minutos.
- **Comprobantes sin foto** (los 3 existentes, y cualquier campo que estuviera vacío en el perfil al autorizar): el render completa **campo por campo** desde el perfil actual. Es una concesión explícita: para esos documentos no hay otra fuente, y dejarlos sin imprimir es peor. Queda documentado en el requirement.
- **Campos obligatorios para imprimir**: razón social, domicilio comercial, CUIT, condición IVA, inicio de actividades, y Ingresos Brutos (número **o** condición: "Exento", "No inscripto", "Convenio Multilateral …"). Si falta alguno (en la foto y en el perfil) → 409 `issuer_data_incomplete` con la lista de campos, y el frontend lleva a `/configuracion/fiscal`.

### D7 — Datos del emisor en `fiscal_profiles` y su edición

Columnas nuevas, todas NULLABLE (no rompen perfiles existentes ni la emisión): `razon_social text`, `nombre_fantasia text`, `domicilio_comercial text`, `iibb_numero text`, `inicio_actividades date`. Se mantiene `iibb_condition` (texto libre existente).
- `FiscalProfileCreate`/`FiscalProfileOut` los exponen; el upsert usa **tri-estado por `model_fields_set`** (patrón `edicion-preserva-contexto`): campo ausente = no tocar, `null` explícito = borrar. De paso `iibb_condition` deja de pisarse cuando el payload no lo trae (hoy el `ON CONFLICT` lo sobreescribe siempre; en el formulario siempre viaja, así que no hay cambio visible).
- Validaciones en el schema: longitudes máximas (razón social 120, fantasía 120, domicilio 200, IIBB 30); `inicio_actividades` no futura.
- UI en `FiscalSettings.tsx`, card "Datos fiscales" (ruta `/configuracion/fiscal`, ya en el menú de Configuración): sección nueva **"Datos para imprimir la factura"** con los 5 campos y un aviso que lista lo que falta cuando algo está vacío ("Para imprimir tus facturas completá: domicilio comercial, inicio de actividades"). Mismos componentes `Form*` y tokens del formulario actual; responsive a una columna en móvil.

### D8 — Contenido y maqueta de la Factura C

A4 vertical, una página (el detalle hace salto de página con encabezado repetido si hay muchas líneas). Bloques, de arriba a abajo:
1. **Leyenda de copia**: "ORIGINAL" centrado arriba (OQ-2 para DUPLICADO).
2. **Encabezado en tres columnas**: izquierda, emisor (nombre de fantasía en grande si existe, debajo razón social, domicilio comercial, "IVA RESPONSABLE MONOTRIBUTO"); centro, recuadro con la letra **C** y "Cód. 011"; derecha, "FACTURA", "Punto de venta: 0003 Comp. Nro: 00000501", "Fecha de emisión: 25/09/2026", "CUIT: 27-21379033-7", "Ingresos Brutos: …", "Inicio de actividades: …".
3. **Receptor**: "Consumidor Final" cuando `DocTipo` es 99; si no, "CUIT/DNI: …", "Razón social: {receptor_legal_name}", "Condición frente al IVA: {receptor_iva_condition legible}". Sólo lo que se declaró a ARCA (OQ-5).
4. **Condición de venta**: "Cuenta Corriente" si la forma de pago de la orden (o, si la orden no la tiene, la de la operación de venta) es `kind = 'credit'`; en cualquier otro caso "Contado". Es lo que RG 1415 pide y lo que ya sabemos; no se imprime el medio de pago.
5. **Detalle**: Descripción (`name_snapshot`), Cantidad (`quantity` sin ceros de más, coma decimal), Precio unitario, Subtotal. Sin columna de IVA (C no discrimina).
6. **Totales**: "Subtotal" y **"Importe Total: $ 32.500,00"** = `fiscal_documents.total`. Invariante: Σ subtotales de las líneas = total (± $0,01). Si no se cumple → 409 `invoice_lines_mismatch` (no se imprime una factura cuyo detalle no suma lo autorizado; en prod hoy se cumple).
7. **Pie**: QR a la izquierda (~30 mm); a su derecha "Comprobante Autorizado", **"CAE N°: …"** y **"Fecha de Vto. de CAE: 05/10/2026"**; debajo, en chico, "Verificá este comprobante escaneando el código QR o en servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx".
8. **Homologación**: si `emisor_snapshot.ambiente` (o el perfil) es `homologacion`, marca de agua diagonal "COMPROBANTE DE PRUEBA — SIN VALIDEZ FISCAL" y el título dice "(HOMOLOGACIÓN)".

Fuentes core de `fpdf2` (latin-1): "Nº"/"á"/"ó" entran en latin-1; se evita el guion largo y las comillas tipográficas, como en `receipts.py`.

Preparado para A/B: `InvoiceView` tiene `letter`, `code`, `issuer_iva_legend` e `iva_breakdown: list | None`; la tabla `{factura_a: ("A","001"), factura_b: ("B","006"), factura_c: ("C","011")}` vive junto a `_COMPROBANTE_AFIP_CODE`. Para A/B faltan (y se dejan fuera) el desglose por alícuota y la leyenda del Régimen de Transparencia Fiscal al Consumidor; `build_invoice_view` rechaza hoy todo lo que no sea `factura_c`.

### D9 — Endpoint `GET /fiscal/documents/{id}/pdf`

- Router: sólo DI (`get_current_user`, `get_account_id`, `get_db_conn`) + `Response(media_type="application/pdf")`. Query param `disposition=inline|attachment` (default `inline`). Nombre de archivo `factura-C-0003-00000501.pdf`.
- Service `backend/services/fiscal/invoice_print_service.py`: lee el documento con `FiscalDocumentRepository.get_by_id(doc_id, account_id)` (filtro explícito por cuenta **y** RLS por la conexión con JWT); `None` → 404 `fiscal_document_not_found` (uno ajeno responde igual que uno inexistente). `status != 'authorized'` → 409 `fiscal_document_not_authorized` (un `pending_cae` no tiene CAE: no es una factura). Lee líneas y condición de venta con un método nuevo del repositorio (`get_invoice_lines(doc_id, account_id)`, JOIN `sales_orders` → `sales_order_items`, ordenado por inserción) y el perfil con `FiscalProfileRepository.get_by_account_id`. Traduce `InvoiceNotPrintable` a 409 RFC 7807 con `code` y `detail` en castellano.
- Cualquier miembro de la cuenta que puede ver ventas puede imprimir (lectura); no hay guard de rol extra.
- `id` no-UUID → 422 (validación de path con `uuid.UUID`).

### D10 — Superficie: un bloque reutilizable en dos pantallas

Componente nuevo `components/fiscal/FiscalInvoiceSummary.tsx` (PascalCase, tokens semánticos):
- Muestra `FiscalDocumentBadge` + `Factura C 0003-00000501` + (si está autorizado) **"CAE 7xxxxxxxxxxxxx · vence 05/10/2026"**, con el CAE copiable (botón de copiar con `aria-label`), y un enlace **"Verificar en ARCA"** a la constatación oficial (`target="_blank" rel="noopener noreferrer"`).
- En móvil apila el bloque en dos líneas; el CAE usa `tabular-nums` y `break-all` para no desbordar a 360 px.
- Se usa en `/ventas` (reemplaza el `<span>` de badge + label en `sale-operations-list.tsx` L590-606) y en `/ventas/ordenes` (reemplaza el badge con `initialStatus` fijo). Cuando Realtime cambia el estado a `authorized`, `/ventas` ya hace `onRefetch()`; el refetch trae el CAE.

`SaleReceiptButton` recibe `fiscal?: SaleFiscalState | null`:
- Si `fiscal.status === 'authorized'`: el menú "Comprobante ▾" pasa a llamarse **"Factura ▾"** y ofrece "Ver / imprimir factura" (abre el PDF en pestaña nueva; el visor de PDF del navegador imprime), "Descargar factura (PDF)" y "Verificar en ARCA"; debajo de un separador, "Comprobante interno (sin validez fiscal)" y "Copiar texto". "Enviar por WhatsApp" comparte **el PDF de la factura** con el mismo mecanismo (share nativo con archivo; si no, descarga + `wa.me` con el texto corto, que ahora menciona "Factura C 0003-00000501").
- Si no está autorizada: comportamiento actual, sin cambios.
- Helper `lib/api/fiscal-invoice.ts` (`fetchFiscalInvoicePdf(documentId, disposition)`), que usa `getAuthHeaders` + `redirectedOnUnauthorized` y traduce los 409 (`issuer_data_incomplete` → toast con acción "Completar datos fiscales" que lleva a `/configuracion/fiscal`; `invoice_date_unknown` → mensaje de "estamos confirmando la fecha con ARCA").
- Pestaña nueva con un `blob:` de tipo `application/pdf`: no ejecuta scripts, así que la CSP con nonce (#569) no interviene. Si el navegador bloquea la pestaña, se descarga.

Read models que se extienden (sin columnas denormalizadas): `sales_repository.py` agrega `fd.cae`, `fd.cae_due_date`, `fd.comprobante_type` al SELECT existente; `SaleFiscalState` gana `cae`, `caeDueDate`, `comprobanteType`; `use-sales.ts` los mapea. `sales_order_repository.list_orders` agrega el mismo `LEFT JOIN fiscal_documents` con `status`, `punto_de_venta`, `number`, `cae`, `cae_due_date`, `comprobante_type`, `is_frozen` (misma condición que ya usa `routers/fiscal.py`), y `/ventas/ordenes` pasa el estado real al badge.

### D11 — Fecha de ARCA en hora argentina (sujeto a OQ-7)

`WSFEAdapter._call_wsfe` usa `datetime.date.today()`; en un servidor en UTC, una factura pedida entre las 21:00 y las 23:59 de Argentina sale fechada al día siguiente (ARCA la acepta: para concepto "productos" admite hasta 5 días de diferencia). Con este change esa fecha queda **impresa**. Se propone que el relay pase `fecha_comprobante = hoy en America/Argentina/Buenos_Aires` en el `CAERequest` (el campo ya existe en el port y el adapter ya lo respeta), con un test que fija la hora a las 23:30 ART. Es un cambio a lo que se le envía a ARCA, por eso va a sign-off.

### D12 — Tests (TDD)

- `backend/tests/test_invoice_pdf.py`: `build_invoice_view` con el caso de Sumar (textos exactos: "0003-00000501", "25/09/2026", "Consumidor Final", "$ 32.500,00", "RESPONSABLE MONOTRIBUTO", "C", "011"); receptor CUIT con razón social y condición; fallback de la foto al perfil campo por campo; cada `InvoiceNotPrintable` (sin fecha, emisor incompleto, líneas que no suman, tipo no soportado); homologación con marca de agua.
- `build_qr_url`: decodifica el Base64 del parámetro `p` y compara el JSON **con tipos** (números como números; `importe` 32500 entero y 32500.5 con decimales; `tipoDocRec` 99/0 y 80/CUIT); el prefijo de URL; round-trip con el ejemplo oficial de ARCA (el JSON del PDF de especificaciones produce su mismo Base64).
- `render_invoice_pdf`: `%PDF`/`%%EOF`, una página, y el texto extraído con `pypdf` contiene los campos obligatorios y el CAE; el QR se construye con la URL exacta (se espía `segno.make`).
- Endpoint: 200 `application/pdf` para uno propio; **404 para uno de otra cuenta** y para uno inexistente, con el mismo cuerpo; 409 para `pending_cae`/`rejected`/`voided`; 409 `issuer_data_incomplete`; 422 para un id no-UUID; 401 sin sesión.
- Relay: `CbteFch` de la respuesta llega a `update_authorized`; reconciliación también; fallback a la fecha enviada.
- SQL (gate que **ejecuta** la RPC, regla del proyecto): `rpc_fiscal_document_authorize` escribe `fecha_comprobante` y `emisor_snapshot` en la transición real, no los escribe en el camino idempotente, conserva el historial, un solo overload, ACL sin `authenticated`/`anon`, `COMMENT` intacto; `rpc_fiscal_document_set_fecha_comprobante` sólo completa NULL.
- Frontend (Vitest): `FiscalInvoiceSummary` (CAE, vencimiento, enlace, copiar, sin CAE cuando no está autorizado); `SaleReceiptButton` (menú "Factura" sólo con `authorized`; WhatsApp usa el endpoint fiscal); `FiscalSettings` (sección nueva, aviso de faltantes, envío tri-estado); `/ventas/ordenes` pasa el estado real.

## Risks / Trade-offs

- **[Una factura impresa con un dato que no coincide con ARCA]** → todo lo que va al QR y al encabezado fiscal sale de la fila autorizada (número y fecha confirmados por ARCA, receptor declarado, total autorizado); ante un faltante se responde 409, nunca se completa con un valor "razonable". Verificación manual con la factura de Sumar: escanear el QR con un celular y confirmar que ARCA muestra el comprobante (task del humo).
- **[Tocar `rpc_fiscal_document_authorize`, una RPC crítica del relay]** → reescritura desde el cuerpo vivo con gate de integridad (md5 del cuerpo fuera de las líneas nuevas), parámetro con `DEFAULT NULL`, sin tocar el `WHERE` ni la lógica de colisión; el gate SQL la ejecuta en los tres caminos (transición, idempotente, colisión).
- **[Los 3 comprobantes existentes no tienen fecha ni foto]** → backfill de la fecha con `FECompConsultar` (D5, con OK del PO) y foto completada desde el perfil actual (D6, declarado). Mientras tanto, 409 con mensaje claro.
- **[El perfil del emisor está incompleto en todas las cuentas]** (Sumar no tiene ni IIBB) → la primera impresión lleva a completar los datos; el aviso en Configuración lo anticipa. La emisión no se bloquea por esto (Non-Goal), sólo la impresión.
- **[Dependencia nueva]** `segno` → pura, sin transitivas, versión fijada con piso (`segno>=1.6`); si algún día se retira, el reemplazo es `qrcode` con el mismo contrato de `build_qr_url`.
- **[`pypdf` sólo en CI]** → se agrega al `pip install` de `Backend_Tests.yml` y a `[project.optional-dependencies].dev`; producción no lo instala.
- **[Pestañas bloqueadas en móvil]** → fallback a descarga, igual que el comprobante interno hoy.

## Migration Plan

1. Migración única (número a confirmar al aplicar, `≥ 20261062000001`; revisar que ningún change en curso lo haya tomado): columnas nuevas en `fiscal_profiles` y `fiscal_documents` (`ADD COLUMN IF NOT EXISTS`, NULLABLE, sin defaults que reescriban la tabla), `DROP`+`CREATE` de `rpc_fiscal_document_authorize` con ACL/`COMMENT` re-aplicados, `rpc_fiscal_document_set_fecha_comprobante` interna, `DO` de introspección (un solo overload, ACL exacta). Idempotente.
2. Deploy del backend: `update_authorized` pasa la fecha; hasta que el backend nuevo esté arriba, la RPC vieja-firma sigue funcionando por el `DEFAULT NULL` (y un documento autorizado en esa ventana queda sin fecha → cae en el backfill).
3. Backfill de fechas con `FECompConsultar` (script de una vez, con OK del PO): los 3 documentos existentes más cualquiera autorizado en la ventana del paso 2.
4. El PO completa sus datos en `/configuracion/fiscal` y el de Sumar (o Sumar misma) los suyos.
5. Humo real: imprimir la 0003-00000501 de Sumar, escanear el QR, constatar en ARCA, mandarla por WhatsApp.

Rollback: el frontend deja de ofrecer la factura (un revert); las columnas nuevas son NULLABLE e inertes para el resto del sistema; la RPC se puede volver a la firma de 4 parámetros con otra migración (el backend viejo no la llama con 5).

## Open Questions

Todas necesitan sign-off del PO antes del apply (governance fiscal). La recomendación va primero.

- **OQ-1 — Campos del emisor a cargar.** Recomendado: razón social (obligatoria), nombre de fantasía (opcional), domicilio comercial (obligatorio, texto libre), número de IIBB **o** condición (uno de los dos obligatorio), inicio de actividades (obligatorio). ¿Falta algo que el PO quiera ver en la factura (teléfono, email, web)?
- **OQ-2 — ¿"ORIGINAL" único o también DUPLICADO?** Recomendado: por defecto una sola copia "ORIGINAL"; opción "Descargar duplicado" en el menú (`?copia=duplicado`, misma factura con la leyenda "DUPLICADO"). Alternativa: sólo ORIGINAL.
- **OQ-3 — Nombre de fantasía vs. razón social en el encabezado.** Recomendado: si hay nombre de fantasía, va grande arriba y la razón social debajo (la razón social es la obligatoria y nunca se omite); si no, sólo la razón social.
- **OQ-4 — Logo.** Recomendado: fuera de este change (exige Storage y moderación de imágenes); candidato aparte si el PO lo quiere.
- **OQ-5 — Nombre del cliente cuando la factura fue a "Consumidor Final" sin identificar (el caso de Sumar).** Recomendado: **no** imprimirlo — la factura dice lo que se declaró a ARCA (DocTipo 99). Alternativa: imprimir "Cliente: {nombre}" como dato informativo aparte del bloque del receptor.
- **OQ-6 — Facturas de suscripción en `/admin/pagos`.** Hoy son de la cuenta de la plataforma (`9b52ebe0…`), distinta de la cuenta del PO; imprimirlas exige decidir con qué cuenta se opera esa pantalla. Recomendado: fuera de este change (candidato `admin-pagos-factura-imprimible`); el endpoint ya sirve si el admin opera con la cuenta de la plataforma.
- **OQ-7 — Fecha en hora argentina (D11).** Recomendado: sí, en este change (un cambio chico, con test, que evita que una factura de la noche salga con la fecha de mañana impresa). Alternativa: candidato aparte.
- **OQ-8 — Dominio del QR.** Recomendado: `https://www.afip.gob.ar/fe/qr/` (el del ejemplo oficial y el que ya leen todas las apps de cámara). Alternativa: `https://www.arca.gob.ar/fe/qr/` (el del texto de la especificación). Los dos funcionan hoy.
- **OQ-9 — Backfill con `FECompConsultar` en prod (D5).** Recomendado: sí, por script con OK del PO en el momento, para los 3 documentos existentes. Alternativa: dejarlos sin imprimir.

## Nota sobre el resto del pedido del PO (2026-09-25)

- *"Verificá que todo esté bien"*: el comprobante de Sumar está `authorized` en producción con CAE de 14 dígitos, número 501 tomado de ARCA (continúa la numeración del sistema anterior), vencimiento del CAE 05/10/2026, importe igual a la línea de la orden. No hay nada que corregir en ese documento.
- *"¿Cómo verifico que se hizo bien?"*: hoy, en la constatación pública de ARCA (`servicioscf.afip.gob.ar/publico/comprobantes/cae.aspx`: CUIT emisor, tipo 11, PV 3, número 501, fecha, importe, CAE) o en "Mis Comprobantes" (tarda ~1 día). Con este change, escaneando el QR de la factura o con el enlace "Verificar en ARCA" junto al CAE.
- *"Elegir el punto de venta en la venta o al facturar"*: fuera de este change (Non-Goal), va por separado.
