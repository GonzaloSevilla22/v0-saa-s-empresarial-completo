## Context

### El pedido y su sign-off

Pedido textual del PO (2026-10-11): *"Necesito que en todos los comprobantes, remitos, facturas, presupuesto, etc., tenga toda la información de la empresa y el logo de la misma, de cada usuario. Y sacale el color verde y dejalos blancos, o en Configuración que cada usuario pueda elegir la paleta de colores que ellos decidan para estos papeles."* "De cada usuario" es **de cada cuenta** (tenant): el logo y los datos son del negocio, no de la persona logueada. Las dos alternativas que el PO plantea ("dejalos blancos" **o** "que cada usuario elija la paleta") se cubren juntas: el valor por defecto es blanco (paleta **Neutro**) y cada cuenta puede elegir otra.

Sign-off anticipado (2026-10-11): *"cuando llegue el propose, continuá con todo lo recomendado"*. Cada Open Question de este documento está escrita como decisión con su recomendación, que es la que se implementa. Ninguna quedó marcada "requiere pregunta" (ver §Open Questions: ninguna toca dinero, auth ni datos fiscales de forma irreversible).

### Inventario de papeles (verificado contra el código el 2026-10-11)

| Papel | Generador | Endpoint / disparo | Emisor | Color |
|---|---|---|---|---|
| Comprobante interno de venta, PDF | `backend/services/receipts.py:189` `build_sales_receipt_pdf` (`FPDF` pelado, encabezado inline `:198-219`) | `POST /sales/receipt-pdf` (`routers/sales.py:32`, **sin DB**, construye el `SalesReceiptData` en el router) ← `SaleReceiptButton` "Enviar por WhatsApp" | `business_name`/`business_phone`/`business_email` **del body** (`schemas/sales.py:269`), que el navegador arma con `user.businessName \|\| user.name`, `user.phone`, **`user.email`** (`sale-receipt-button.tsx:122-129`) | `EMERALD (16,185,129)` (`receipts.py:24`) en N°, regla, cabecera de tabla y TOTAL |
| Comprobante interno, HTML imprimible | `frontend/lib/receipt.ts:393` `generateReceiptHTML` (CSS `:96-387`, `window.print()` con nonce) | "Descargar / Imprimir" | mismos datos del usuario; "logo" = `user.avatar` (`:126`, `:404-405`) | `--emerald:#059669` en `td.subtotal` (`:285`), `--primary:#0f172a` |
| Comprobante interno, textos | `receipt.ts:563` `generateReceiptText`, `:625` `generateReceiptShortText` | "Copiar texto", mensaje de WhatsApp | ídem (incluye el email de login en "Contacto") | — |
| Presupuesto | `services/commercial_documents/pdf.py:274` `build_commercial_document_pdf`, vista `view.py:138` | `GET /quotes/{id}/pdf` ← `DocumentShareMenu` en `/presupuestos/[id]` | `rpc_commercial_issuer` (`20261067000001:939`) + cascada `issuer.py:54` | `EMERALD`, `SLATE`, `GRAY` **importados de `receipts.py`** (`pdf.py:46`) en título `:118`, regla `:134`, cabecera `:206`, TOTAL `:232`, sello ACEPTADO `:55` |
| Remito de venta / de compra | mismo `pdf.py`, vista `view.py:173` | `GET /delivery-notes/{id}/pdf` ← `/remitos/[id]` | ídem | ídem |
| Factura C | `services/fiscal/invoice_pdf.py:693` `render_invoice_pdf`, `_draw_header :496` (recuadro de **alto fijo 42 mm**, columna izquierda de 81 mm) | `GET /fiscal/documents/{id}/pdf` (`routers/fiscal.py:338`, `invoice_print_service.py:29`) | `emisor_snapshot` congelado al autorizar, completado campo por campo desde `fiscal_profiles` (`invoice_pdf.py:233`) | **sin verde**: `_INK (30,41,59)`, `_MUTED`, `_RULE`, `_HEAD_FILL (241,245,249)` (`:441-448`) |

No son papeles del tenant (Non-Goals): el recibo de suscripción ALIADATA → suscriptor (`receipts.py:72`, marca de plataforma), los emails de `send-email` (`GREEN="#10b981"`, marca de plataforma), etiquetas de balanza, cierre de caja (sólo pantalla), exportaciones CSV/XLSX.

### Cómo se arma hoy (duplicaciones medidas)

- **Tres encabezados dibujados a mano** sin base común: inline en `receipts.py:198-219`; `_issuer_block` en `pdf.py:95-137` (columna de 105 mm); `_draw_header` en `invoice_pdf.py:496-567`.
- **Paleta repetida cuatro veces**: `receipts.py:24-26`, `invoice_pdf.py:441-448`, `lib/receipt.ts:99-107`, `send-email/index.ts:17-18`. `pdf.py:46` importa de `receipts.py` la paleta **y** los privados `_format_amount`/`_format_unit_price`; `invoice_pdf.py:46` importa `_format_amount`, `_format_unit_price`, `_latin1`.
- **Dos sanitizadores**: `_latin1` (`receipts.py:160`, convierte "—" en "?") y `_pdf_text` cp1252 (`pdf.py:65`, imprime "—" bien).
- **Ningún PDF embebe imágenes** (`.image(` → 0 en `backend/services`). Verificado en el venv (2026-10-11, spike fuera del repo): `fpdf2 2.8.9` + `Pillow 12.3.0` embeben PNG con transparencia, JPEG y **WebP** desde `BytesIO` con `keep_aspect_ratio`; `pypdf` cuenta las imágenes de una página (`page.images`), y el flujo de contenido descomprimido trae los colores como `0.0627 0.7255 0.5059 rg` (4 decimales) — las dos cosas sirven de aserción en los tests.

### Datos de la empresa hoy: tres fuentes

- `profiles` (por **usuario**): `business_name`, `phone`, `avatar_url` (Configuración → Perfil, `UPDATE` directo por PostgREST). `profiles` no tiene email: el email es el de Auth.
- `fiscal_profiles` (1:1 con la cuenta): `cuit` e `iva_condition` NOT NULL, y desde `20261064000001` `razon_social`, `nombre_fantasia`, `domicilio_comercial`, `iibb_numero`, `inicio_actividades`. Una cuenta que no factura **no puede** guardar razón social ni domicilio (el upsert exige CUIT e IVA).
- `accounts`: sin datos de empresa; allow-list de escritura **vacía** para `authenticated`.
- `rpc_commercial_issuer(uuid)`: `SECURITY DEFINER`, `STABLE`, guard por `current_account_ids()` (`P0404`), devuelve **exactamente 6 claves** (`business_name, cuit, domicilio_comercial, nombre_fantasia, phone, razon_social`). Lo fijan el gate `supabase/tests/test_presupuestos_modulo.sql:1125` y `backend/tests/test_commercial_document_pdf.py::test_the_issuer_never_carries_an_email` (`:287`). Cuerpo vivo en prod (2026-10-11): md5 sin CR `3abc66aee3eb3c2b19d5f8a3305941d9`, 1.119 caracteres, ACL `{postgres=X, authenticated=X, service_role=X}`, `COMMENT` md5 `a5e87fd4ee87573eb38049659cd3ea37`.

Medido en prod (2026-10-11, sólo `SELECT`): **41** cuentas, **2** perfiles fiscales (1 con razón social, domicilio y fantasía), **6** dueños con `business_name`, **19** con teléfono, **6** con avatar; 2 presupuestos, 0 remitos, 21 comprobantes `authorized`; **0** cuentas multiusuario; base de **58 MB**; `MAX(version) = 20261077000002` (325 migraciones); `account_branding` y un bucket `branding` **no existen**; 43 políticas `is_account_writer` sobre 17 tablas.

### Decisiones firmadas que este pedido supera o toca

- `factura-fiscal-imprimible` **OQ-1** (2026-09-26): *"Sin teléfono/email/web"* en la factura. **OQ-4**: logo *"fuera de este change (candidato aparte)"*. El pedido del 2026-10-11 nombra explícitamente las facturas y pide "toda la información de la empresa y el logo": se supera, y queda escrito así en el delta de `fiscal-invoice-print`.
- Spec `commercial-document-pdf`, "Datos del emisor sin bloqueo": *"El email no se imprime: el perfil no lo guarda, y el email de acceso del dueño no debe aparecer en un documento para terceros"*. Se conserva el **principio** (nunca el email de acceso) y se cambia el hecho (ahora la cuenta tiene dónde guardar el email **del negocio**).
- Misma spec, constructor compartido: *"usar la misma familia visual que el comprobante interno de venta"* — era el verde. Pasa a "la paleta de la cuenta".
- Gate de 6 claves del emisor: se mantiene como **allow-list exacta**, con las claves nuevas enumeradas.

### Hallazgos al leer el código

1. **El comprobante interno imprime el email de acceso** de quien lo descarga (`sale-receipt-button.tsx:125`, `receipt.ts:411`, `:610`, y viaja al PDF en `business_email`). Es el mismo dato que la spec de documentos comerciales prohíbe.
2. **El comprobante interno cambia según quién lo descargue**: nombre, teléfono y "logo" (avatar) son del usuario logueado.
3. **El verde no pasa AA**: texto blanco sobre `EMERALD` = **2,54:1**; `#059669` sobre blanco = **3,77:1** (umbral 4,5:1). Los colores de los PDF no los cubre ningún gate.
4. **El molde que el brief sugería para bajar el logo (`wsfe_adapter.py:577`, service client) es código deprecado (v22)**: su propio docstring dice *"DEPRECADO… ya no se llama"* y `adapter_factory.py` ignora `service_client`. El único uso vivo de `service_role` para Storage es la URL firmada de subida del certificado, también marcada `deprecated=True`. Ver D2.
5. `scale_settings` (el molde de tabla) conserva para `authenticated` los privilegios de tabla `DELETE` y `TRUNCATE` (`relacl` vivo `authenticated=arwdDxtm`). No es explotable por PostgREST (no tiene verbo `TRUNCATE` y no hay política de DELETE), pero la tabla nueva no lo copia (D1) y queda como hallazgo lateral.
6. CUIT del emisor impreso **sin formato** en presupuesto/remito (`pdf.py:108`, `"CUIT: 27213790337"`), mientras la factura lo formatea (`_format_cuit`, `invoice_pdf.py:173`).

### Changes activos (no chocar)

`compras-gastos-sucursal-por-defecto` (0/50, reserva `20261076000001/2`), `remitos-venta` (tanda A y B en main; pendiente humo + archive), `remitos-compra` (tanda A en main; tanda B sin aplicar: migración, conversión a compra, `purchase-form.tsx`, `/compras`). Ninguno toca en lo pendiente `pdf.py`, `view.py`, `issuer.py`, `receipts.py`, `invoice_pdf.py`, `receipt.ts`, `sale-receipt-button.tsx`, `DocumentShareMenu.tsx`, `configuracion/` ni `settings/`. Archivos en disputa: `openspec/specs/commercial-document-pdf/spec.md` (deltas ADDED de remitos sin sincronizar, ver D14), `KPI_Validation.yml` (se suma un paso al final), la numeración de migraciones (D12). `CHANGES.md`, `CLAUDE.md` y `AGENTS.md` se tocan sólo al archivar.

## Goals / Non-Goals

**Goals:**
- Que **todo papel que la cuenta entrega a un tercero** (comprobante interno PDF/HTML/textos, presupuesto, remito de venta, remito de compra, Factura C) lleve **los datos de la empresa y el logo de la cuenta**, iguales para cualquier miembro que lo genere.
- Que el verde desaparezca del valor por defecto ("blanco") y que cada cuenta pueda elegir su paleta desde Configuración, siempre legible (AA).
- **Un solo emisor y un solo encabezado**: una cascada de datos, una paleta, un helper de dibujo; nada de copiar la lógica en cada generador.
- No imprimir nunca el email de acceso de un usuario.
- No alterar lo que la Factura C declara fiscalmente.

**Non-Goals:**
- Emails transaccionales, recibo de suscripción y cualquier papel de la plataforma ALIADATA.
- Etiquetas de balanza; cierre de caja; comprobantes de compra, gasto o cobro (hoy no existen como papel).
- El tema de la UI de la app (`--primary` verde de la interfaz).
- SVG y GIF como logo; importar el avatar como logo; descargar logos de URLs.
- Condición frente al IVA cargada fuera del perfil fiscal; datos de Ingresos Brutos o inicio de actividades en papeles no fiscales.
- Datos bancarios estructurados (CBU/alias): quien los quiera los pone en la leyenda al pie.
- Unificar los formateadores duplicados (`_format_date`, cantidades) y el sanitizador de los textos fiscales de la factura: hallazgo lateral.
- Retirar el HTML imprimible del comprobante interno a favor del PDF (ver D8).

## Decisions

### D1 — Tabla `account_branding`, una fila por cuenta (molde `scale_settings`)

Alternativas evaluadas (exploración del 2026-10-11): **A. tabla nueva** (elegida); B. columnas en `accounts` + RPC por campo (cada campo nuevo cambia la firma: `DROP`+`CREATE`, `42725`, reseteo de ACL; engorda una tabla CRÍTICA cuya allow-list de escritura es vacía); C. `fiscal_profiles` (exige CUIT e IVA, cualquier escritor la cambia y se mezcla con la foto fiscal) — **no**; D. `profiles` (es por usuario: reproduce el defecto 2) — **no**.

```
public.account_branding
  account_id       uuid PK → accounts(id) ON DELETE CASCADE
  display_name     text NULL   -- nombre comercial para los papeles (≤ 80)
  legal_name       text NULL   -- razón social (≤ 120); sólo se usa si el perfil fiscal no la tiene
  tax_id           text NULL   -- CUIT, forma ^\d{2}-?\d{8}-?\d$; ídem
  address          text NULL   -- domicilio (≤ 200); ídem
  phone            text NULL   -- (≤ 40)
  email            text NULL   -- email DEL NEGOCIO (≤ 120, forma de dirección)
  website          text NULL   -- (≤ 120, sin espacios ni < > ")
  footer_note      text NULL   -- leyenda al pie (≤ 280)
  palette_preset   text NOT NULL DEFAULT 'neutro'  -- neutro|azul|verde|grafito|bordo|personalizado
  accent_color     text NULL   -- ^#[0-9a-f]{6}$, presente ⇔ palette_preset = 'personalizado'
  logo_image       bytea NULL  -- imagen NORMALIZADA (D2)
  logo_mime        text NULL   -- image/png | image/jpeg
  logo_sha256      text NULL   -- ^[0-9a-f]{64}$
  logo_width       int  NULL   -- 1..1000
  logo_height      int  NULL   -- 1..1000
  logo_updated_at  timestamptz NULL
  updated_at       timestamptz NOT NULL DEFAULT now()
  updated_by       uuid NULL   -- sin FK dura (molde scale_settings)
```

**`CHECK`s (segunda capa; la primera es Pydantic):** cada texto `IS NULL OR (btrim(x) <> '' AND char_length(x) <= N)` (el vacío se guarda como `NULL`, nunca como blanco); forma del email, del CUIT, del sitio y del color; `palette_preset IN (…)`; `(palette_preset = 'personalizado') = (accent_color IS NOT NULL)`; logo **todo o nada** (las seis columnas `logo_*` nulas o no nulas juntas); `octet_length(logo_image) <= 307200`; tipo y **firma** coherentes (`image/png` ⇒ empieza con `\x89504e470d0a1a0a`, `image/jpeg` ⇒ con `\xffd8ff`); `logo_width`/`logo_height` entre 1 y 1000. La aritmética de contraste **no** va en un `CHECK` (D3 la cubre en el render).

**Permisos** (molde `20261066000001:161-262`):
- RLS: `account_branding_member_select` (`account_id IN (SELECT current_account_ids())`), `account_branding_writer_insert`/`_update` (`is_account_writer(account_id)`), **sin política de DELETE**.
- Disparador `trg_account_branding_guard_owner_admin` `BEFORE INSERT OR UPDATE` → función `account_branding_guard_owner_admin()` `SECURITY DEFINER`, `SET search_path TO 'public'`: `account_id` inmutable (`P0401`) y el actor con rol activo `owner`/`admin` en esa cuenta (`member_active_roles`, `P0401`). `REVOKE ALL ON FUNCTION … FROM PUBLIC, anon, authenticated` (lo exige `test_function_acl_gate.sql` (1)).
- Privilegios de tabla: `REVOKE ALL … FROM anon`; **y además** `REVOKE DELETE, TRUNCATE, REFERENCES, TRIGGER … FROM authenticated` (hallazgo 5: "sin DELETE" queda cerrado también en la capa de privilegios, no sólo por la ausencia de política). El backend no borra filas: retirar el logo es un `UPDATE`.
- Sin fila = valores por defecto: el primer `PUT` inserta (upsert por `account_id`).

`fiscal_profiles` **no recibe** ninguna columna; `accounts` tampoco.

### D2 — El logo se guarda normalizado en la base, no en un bucket (desvío fundamentado del brief)

El brief recomendaba un bucket privado `branding` con políticas por cuenta y la descarga desde el backend con el *service client*. Se adopta **la imagen normalizada en `account_branding.logo_image`** por cuatro razones, cualquiera de las cuales alcanza:

1. **Regla dura del proyecto**: *"NUNCA usar `service_role` en el backend… Excepción única: jobs administrativos aislados"*. Bajar el logo en **cada** PDF que genera un usuario no es un job administrativo. El molde citado (`wsfe_adapter.py:577`) es código deprecado y sin uso (hallazgo 4).
2. **La subida tiene que pasar por el backend de todos modos**: el render decodifica la imagen, y un PNG de 300 KB puede declarar 20000×20000 px (una bomba de descompresión que tumba la instancia free de Render, 512 MB). Hay que validar dimensiones antes de decodificar, reescalar y quitar metadatos **en el servidor** (el navegador no es una frontera de confianza). Una subida por el backend a un bucket vuelve a necesitar credenciales de escritura de Storage → `service_role` otra vez.
3. **La alternativa sin `service_role`** (el JWT del usuario + la clave publicable contra la API de Storage, para que apliquen las políticas del bucket) exige una variable de entorno nueva en Render (`SUPABASE_ANON_KEY`/publicable: el backend hoy no la tiene, `core/config.py`) y dos saltos HTTP más por PDF; con la variable ausente el logo desaparecería en silencio.
4. **En la base todo pasa por la misma conexión con JWT** (RLS + disparador + `CHECK`s), es transaccional con el resto de la marca, entra en los backups, y el gate SQL puede **ejecutar** todo el camino (la regla "toda tabla nueva con un gate que la ejecute"). Hay precedente de binario chico en la base: el recibo de suscripción viaja en base64 en `email_logs.metadata` (`receipts.py:154`).

Costo acotado: tope de **300 KB** por cuenta (típico de un logo normalizado: 10-80 KB); 41 cuentas × 300 KB = 12 MB en el peor caso sobre 58 MB. **Umbral de revisión**: si el producto supera ~2.000 cuentas con logo, mover el almacenamiento a Storage **detrás del mismo contrato** (`GET /document-branding/logo` y la huella no cambian). Ese movimiento no requiere tocar ningún generador.

**Pipeline de subida** (`backend/services/commercial_documents/logo.py`, puro, sin I/O):
- El router lee el cuerpo binario por `request.stream()` con un contador: más de **2 MiB** → 413 `branding_logo_too_large` sin leer el resto (y rechazo temprano por `Content-Length` si viene). Sin `python-multipart` (no está en `requirements.txt`; no se suma una dependencia para un archivo).
- `Image.open(BytesIO)` es perezoso: se lee **sólo el encabezado**. Formato por **contenido** ∈ {PNG, JPEG, WEBP}; cualquier otro (SVG no es ni siquiera reconocido, GIF, BMP, TIFF, PDF, texto) → 415 `branding_logo_unsupported_type`. El `Content-Type` declarado se ignora.
- `ancho × alto > 25.000.000` → 422 `branding_logo_invalid` **antes** de `load()` (y `Image.MAX_IMAGE_PIXELS` como red). Error al decodificar → 422 `branding_logo_invalid`.
- `ImageOps.exif_transpose` (respeta la orientación de la cámara), conversión a `RGBA` si hay transparencia (modo `RGBA`/`LA`, o `P` con `transparency`) y a `RGB` si no; `thumbnail((1000, 1000), LANCZOS)`; re-codificación **sin metadatos**: PNG optimizado con transparencia, JPEG calidad 85 sin ella (fpdf2 incrusta el JPEG sin recodificar). Si el resultado supera 300 KB, se reintenta a 600 px; si todavía supera → 422 `branding_logo_too_heavy`. Huella SHA-256 de los bytes guardados.
- WebP de entrada se guarda como PNG o JPEG (lo que se guarda es lo que fpdf2 y todo navegador leen sin sorpresas).

**Al dibujar** (`load_logo_for_render(data, mime)`): vuelve a abrir perezoso, exige formato = tipo guardado y `≤ 1000 × 1000`; si no, devuelve `None` y loguea un warning (una fila escrita a mano por PostgREST con bytes válidos pero contenido raro no rompe ningún papel: sale sin logo). **Nunca** se pasa una URL a `pdf.image()`: siempre `BytesIO`.

**Caché**: `resolve_document_branding` mantiene un LRU en memoria de 32 entradas por `(account_id, logo_sha256)`. La clave incluye la huella, así que un logo nuevo invalida solo (no hay riesgo de servir uno viejo) y se evita mover hasta 300 KB por PDF. La RPC devuelve la huella (D4); los bytes se leen sólo si no están en caché.

### D3 — Paleta: catálogo cerrado + personalizado, con contraste verificable

**Catálogo** (fuente única: `backend/services/commercial_documents/palette.py`; el frontend lo recibe por `GET /document-branding`, no lo copia):

| clave | rótulo | acento | contraste vs blanco |
|---|---|---|---|
| `neutro` (**por defecto**) | Neutro (blanco) | — | — |
| `azul` | Azul | `#1d4ed8` | 6,70:1 |
| `verde` | Verde | `#047857` | 5,48:1 |
| `grafito` | Grafito | `#334155` | 10,35:1 |
| `bordo` | Bordó | `#9f1239` | 8,02:1 |
| `personalizado` | Personalizado | el que elija la cuenta | ≥ 4,50:1 exigido |

**Base de todas las paletas** = la tinta de la Factura C: `ink (30,41,59)` `#1e293b` (14,63:1), `muted (100,116,139)` `#64748b` (4,76:1), `rule (148,163,184)`, `surface (241,245,249)` (tinta sobre superficie 13,35:1). Con **Neutro** no hay rellenos de color: título, regla del encabezado, total y sello "ACEPTADO" en tinta; cabecera de la tabla en `surface` con texto en tinta. Es el "blanco" que pidió el PO y unifica los papeles con la factura. Con acento: título, regla del encabezado, banda de la cabecera de la tabla, total y sello "ACEPTADO" en el acento; el texto sobre la banda es el blanco o la tinta, el de **mayor contraste** (`best_text_on`). Los sellos "VENCIDO"/"RECHAZADO"/"ANULADO" conservan su rojo de advertencia `(185,28,28)`.

**Regla de contraste**: todo acento ≥ **4,5:1 contra blanco** (WCAG 2.1 AA, texto normal) — el acento se usa como texto sobre el papel blanco (título, total) y como fondo de texto blanco (cabecera), y con esa regla los dos usos pasan. `#10b981` (el verde de hoy, 2,54:1) **no** se puede elegir; el preset "Verde" es un verde más oscuro que sí cumple. El servicio rechaza un personalizado que no cumple con 422 `branding_accent_low_contrast` (código estable, RFC 7807). `resolve_palette(preset, accent)` devuelve **Neutro** (y loguea) ante un valor guardado inválido o ilegible — la tabla no calcula contraste, así que una escritura directa nunca produce un papel ilegible.

**Aritmética compartida**: el gate `frontend/__tests__/lib/token-contrast-aa.test.ts` ya tiene HSL→RGB, linearización sRGB, luminancia y contraste, y su comentario dice que se promueve a `lib/` cuando aparezca un segundo consumidor. Se promueve a **`frontend/lib/color-contrast.ts`** (`hexToRgb`, `relativeLuminance`, `contrastRatio`, `bestTextOn`; el test pasa a importarla y sus 28 pares siguen verdes) para el aviso en vivo de la pestaña. El cálculo **autoritativo** es el de Python (`palette.py`). Los dos se atan con un fixture compartido **`backend/tests/fixtures/document_palette_cases.json`** (molde `scale_layout_cases.json`): colores, contraste esperado (2 decimales), aceptado o no, texto sobre el acento. pytest y vitest lo leen.

*Alternativa descartada*: un selector libre sin restricción (texto ilegible garantizado en algún caso) o sólo presets (el PO dijo "la paleta de colores que ellos decidan").

### D4 — Emisor único: cascada por campo y `rpc_commercial_issuer` ampliada

**Cascada** (pura, en Python, `commercial_documents/issuer.py`; normativa en la spec `document-branding`):

| Dato | Orden |
|---|---|
| nombre visible | marca `display_name` → fiscal `nombre_fantasia` → fiscal `razon_social` → marca `legal_name` → dueño `business_name` → "Mi Negocio" |
| razón social | fiscal → marca (se imprime si difiere del nombre, como hoy) |
| CUIT | fiscal → marca; `NN-NNNNNNNN-N` si tiene 11 dígitos (`format_cuit`) |
| condición IVA | sólo fiscal (`ISSUER_IVA_LEGEND`: "IVA RESPONSABLE MONOTRIBUTO", …) |
| domicilio | fiscal `domicilio_comercial` → marca `address` |
| teléfono | marca → dueño `phone` |
| email | **sólo** marca `email` (del negocio) |
| web, leyenda al pie | sólo marca |

Por qué **el perfil fiscal manda en la identidad fiscal**: es lo registrado ante ARCA y lo que imprime la factura; un presupuesto no puede contradecir a la factura del mismo negocio. Por qué **la marca manda en el nombre comercial y el contacto**: son presentación, y la pestaña existe para eso. Por qué se conserva el **perfil del dueño** como respaldo: sin fila de marca, cada papel sigue diciendo lo mismo que hoy (sólo cambia el color). El nombre de los textos de WhatsApp de presupuesto y remito (`issuer_name`, `services/quotes.py:280`, `services/delivery_notes.py:362`) sigue esta cascada **sin cambios en las pantallas**.

**RPC**: `rpc_commercial_issuer(p_account_id uuid) RETURNS jsonb` se reescribe con `CREATE OR REPLACE` y **la misma firma** (no hay overload posible ni reseteo de ACL), **partiendo del `pg_get_functiondef` vivo** (md5 `3abc66ae…`, re-medido en el checkpoint del apply). Cambios: `LEFT JOIN public.account_branding ab ON ab.account_id = a.id` y **claves nuevas, planas y aditivas**:

```
legado (sin cambios): business_name, cuit, domicilio_comercial, nombre_fantasia, phone, razon_social
nuevas:               iva_condition,
                      brand_display_name, brand_legal_name, brand_tax_id, brand_address,
                      brand_phone, brand_email, brand_website, brand_footer_note,
                      palette_preset, accent_color, logo_sha256
```

18 claves, **nunca la imagen** ni ningún email de Auth (la función no lee `auth.users`). Planas y aditivas a propósito: un backend viejo contra la base nueva sigue leyendo sus 6 claves (ventana de despliegue, D12). Sin fila de marca, las claves `brand_*`/paleta/huella vuelven `NULL` y Python aplica los valores por defecto. El gate (n) de `test_presupuestos_modulo.sql` pasa de exigir 6 claves a exigir exactamente estas 18; el gate nuevo asserta además que ningún **valor** es el email de Auth del dueño.

**Formateo compartido**: `_format_cuit` y `_ISSUER_IVA_LEGEND` salen de `invoice_pdf.py` a `backend/services/fiscal/comprobante.py` (el módulo compartido de tablas fiscales que ya usan el adapter y la factura) como `format_cuit` e `ISSUER_IVA_LEGEND`; `invoice_pdf.py` los importa. Movimiento mecánico en la tanda A con la red de seguridad de `test_invoice_pdf.py` en verde antes y después.

### D5 — `DocumentBranding` y un helper de encabezado compartido

Módulos nuevos en `backend/services/commercial_documents/` (el paquete ya agrupa emisor, vista y render):

- `palette.py` — `DocumentPalette` (frozen: `key`, `ink`, `muted`, `rule`, `surface`, `accent | None`; propiedades `heading`, `strong_rule`, `table_head_fill`, `table_head_text`, `total`, `accepted_stamp`), `PALETTE_CATALOG`, `NEUTRAL`, `relative_luminance`, `contrast_ratio`, `best_text_on`, `resolve_palette`, `MIN_ACCENT_CONTRAST = 4.5`.
- `logo.py` — `normalize_logo`, `load_logo_for_render`, `LogoImage` (bytes, mime, ancho, alto, huella), `fit_box(w, h, max_w, max_h)` y las excepciones con su código estable.
- `branding.py` — `DocumentBranding` (frozen: `issuer: CommercialIssuer`, `palette`, `logo: LogoImage | None`, `footer_note`, `brand_contact`: teléfono/email/web **sólo de la marca**, para la factura) y `resolve_document_branding(repo, account_id)`: una llamada a la RPC + los bytes del logo sólo si hay huella y no están en caché. **No lee `account_branding` directo** (todo pasa por la RPC), y eso es lo que hace segura la ventana de despliegue (D12).
- `header.py` — `IssuerBlock` (logo + nombre + `HeaderLine(text, bold, size, muted)`), `measure_issuer_column(pdf, width, block, logo_box)` y `draw_issuer_column(pdf, x, y, width, block, palette, logo_box) -> bottom_y`. El logo se dibuja arriba a la izquierda con el tamaño de `fit_box` (sin deformar; nunca `keep_aspect_ratio` centrado, para que la columna quede alineada) y debajo el nombre y las líneas. La medición usa `multi_cell(dry_run=True, output="LINES")` (verificado en el spike). Cada generador arma **su** `IssuerBlock` (el comercial desde `CommercialIssuer`; la factura desde la foto fiscal + `brand_contact`) y el helper sólo dibuja: tres consumidores reales, Regla de Tres cumplida.
- `text.py` — `pdf_text` (el `_pdf_text` cp1252 de `pdf.py:65`, promovido a público; `pdf.py` lo importa). El helper usa este sanitizador para que "—" y "€" en un nombre comercial se impriman bien.

`receipts.py` **conserva** `EMERALD`/`SLATE`/`GRAY` sólo para `build_receipt_pdf` (recibo de suscripción, marca de plataforma, Non-Goal); `pdf.py` deja de importarlos. `_format_amount`/`_format_unit_price`/`_latin1` siguen donde están (su reubicación es el hallazgo lateral de formateadores).

### D6 — Presupuesto y remitos (venta y compra)

- `CommercialDocumentView` cambia el campo `issuer: CommercialIssuer` por **`branding: DocumentBranding`** (que contiene al emisor) y `build_quote_view`/`build_delivery_note_view` reciben `branding` en la misma posición que hoy `issuer`. Para los tests, `DocumentBranding.neutral(issuer)` arma una marca por defecto. `view.py` no está en lo pendiente de ningún change activo.
- `_issuer_block` dibuja la columna izquierda con `draw_issuer_column` (ancho 105 mm, logo hasta 50 × 18 mm, nombre 18 pt, líneas 9 pt: razón social si difiere, `CUIT: NN-NNNNNNNN-N`, leyenda de IVA, domicilio, `Tel: …`, email, web) y la derecha como hoy, con el título en `palette.heading`. Regla del encabezado en `palette.strong_rule`.
- `_lines_table`: `headings_style` con `fill_color=palette.table_head_fill`, `color=palette.table_head_text`; bordes en `palette.rule`; cuerpo en `palette.ink`.
- Total en `palette.total`; sello "ACEPTADO" en `palette.accepted_stamp`.
- `_CommercialPdf.footer`: la leyenda del documento **y**, si la hay, la leyenda al pie de la cuenta (8 pt, en `muted`, hasta 3 renglones; lo que exceda se corta con "…"). El alto del pie se calcula una vez al construir el PDF (el margen de salto de página depende de él), así que la tabla nunca pisa el pie.
- `services/quotes.py` y `services/delivery_notes.py` resuelven la marca con `resolve_document_branding` (el repositorio ya hereda `CommercialIssuerMixin`, que suma `get_document_logo`). `issuer_name` del detalle sigue con `resolve_commercial_issuer` (sólo el nombre: no baja el logo).

### D7 — Comprobante interno, PDF: la marca se resuelve en el servidor

- `POST /sales/receipt-pdf` suma `get_account_id` + `get_db_conn`; la lógica que hoy arma `SalesReceiptData` en el router pasa a un service (`services/sales_receipt.py`), cumpliendo de paso la regla de 3 capas.
- **Contrato compatible, sin versionar**: `SalesReceiptPdfIn.business_name`, `business_phone` y `business_email` pasan a **opcionales e ignorados** (documentados como obsoletos). Fundamento: hay pestañas del navegador abiertas durante días con el frontend anterior que mandan esos campos (con `business_name` obligatorio); responderles 422 rompería "Enviar por WhatsApp" sin necesidad. El servidor nunca los imprime. El nuevo frontend deja de mandarlos. En la ventana inversa (frontend nuevo contra backend viejo, minutos), el backend viejo exige `business_name` y responde 422; el botón ya tiene el camino de respaldo (`sale-receipt-button.tsx:281-284`: WhatsApp con el texto corto) — degradación aceptada, sin cambios de código.
- `SalesReceiptData` reemplaza `business_name`/`business_phone`/`business_email` por `branding: DocumentBranding`. `build_sales_receipt_pdf` dibuja el encabezado con `draw_issuer_column` (a la derecha, "Comprobante de venta" y el N° en `palette.heading`), cabecera de tabla y TOTAL con la paleta, y el pie de hoy ("¡Gracias por su compra!", "Este documento es su comprobante de venta.") más la leyenda al pie de la cuenta. Sigue sin validez fiscal y rotulado como tal.

### D8 — Comprobante interno, HTML imprimible y textos: leen la marca de la API

- `GET /document-branding` devuelve el emisor **ya resuelto** por la misma cascada de Python, así que el HTML y el PDF imprimen lo mismo. El frontend lo lee con `useDocumentBranding()` (React Query, `staleTime` de 5 minutos) y el logo con `useDocumentLogoDataUri(sha)` (sólo si hay huella; `GET /document-branding/logo?v=<sha>` → blob → `data:` URI).
- `ReceiptOptions` reemplaza `businessName`/`businessPhone`/`businessEmail`/`logoUrl` por `branding: ReceiptBranding` (`issuer`, `footerNote`, `palette` en hex, `logoDataUri?`), armado por `toReceiptBranding(...)` en `lib/document-branding.ts`. **Validaciones antes de interpolar**: `isSafeLogoDataUri` (`^data:image/(png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$`; si no, se omite el logo y se dibuja la inicial como hoy) e `isSafeHexColor` (`^#[0-9a-f]{6}$`; si no, Neutro). Los textos siguen pasando por `esc()`. La web se imprime como **texto**, nunca como enlace. El CSS reemplaza `--emerald` y `--primary` fijos por variables de la paleta.
- `generateReceiptText`/`generateReceiptShortText` usan el nombre, el teléfono, el email del negocio y la web de la marca; desaparece el email de login.
- **Dentro del gesto del usuario**: la marca se precarga al abrir el menú "Comprobante" (el mismo patrón de precarga que `DocumentShareMenu`). Si al hacer clic todavía no llegó, se abre la pestaña primero y se le carga el HTML cuando llega (patrón de `handleInvoice`, `sale-receipt-button.tsx:214`); si falla, el comprobante sale con Neutro, sin logo y con el último nombre cacheado (o "Mi Negocio"), con un aviso.
- *Alternativa descartada*: retirar el HTML y abrir siempre el PDF del backend (una sola implementación visual). Se descarta porque el HTML imprime aunque el backend de Render esté en arranque en frío (~50 s), y es el camino que el PO usa todos los días; cambiarlo excede el pedido. Las dos versiones comparten la cascada (servidor) y la paleta (catálogo del servidor); la diferencia es sólo de maquetado.

### D9 — API `/document-branding`

Router nuevo `backend/routers/document_branding.py` (prefijo `/document-branding`, registrado en `main.py` junto a `scale_settings`), service `backend/services/document_branding.py`, repositorio `backend/repositories/document_branding_repository.py` (hereda `CommercialIssuerMixin`; toda consulta filtra **explícitamente** por `account_id` además de la RLS), esquemas `backend/schemas/document_branding.py`.

| Método y ruta | Quién | Respuesta |
|---|---|---|
| `GET /document-branding` | cualquier miembro | `settings` (guardado o por defecto) + `is_default`, `logo` (`sha256`, `mime`, `width`, `height`) o `null`, `issuer` (como se imprime), `sources` (por campo: `brand`/`fiscal`/`owner`/`default`), `fiscal` (los datos que vienen del perfil fiscal, para mostrarlos de sólo lectura) o `null`, `owner_fallback` (`business_name`, `phone`, para la vista previa en vivo), `palette` (resuelta, en hex), `palettes` (catálogo), `updated_at`, `updated_by` |
| `PUT /document-branding` | owner/admin (`require_account_role(CAN_CONFIGURE)`, 403 antes de escribir) | reemplaza datos y paleta (el logo no se toca) y devuelve lo mismo que el `GET`. 422 de validación (Pydantic v2: recorte, vacío → `null`, largos, formas, `Literal` del catálogo, coherencia paleta/color) y 422 `branding_accent_low_contrast` (service) |
| `PUT /document-branding/logo` | owner/admin | cuerpo binario (la imagen); 200 con `logo`; 413/415/422 con códigos estables (D2) |
| `DELETE /document-branding/logo` | owner/admin | 204; idempotente |
| `GET /document-branding/logo` | cualquier miembro | la imagen con su `Content-Type`, `ETag: "<sha256>"`, `Cache-Control: private, max-age=86400` (el frontend pide `?v=<sha>`, así que un logo nuevo es una URL nueva); 404 `branding_logo_not_found` |

Sin sesión → 401. Errores RFC 7807 (`ProblemHTTPException`). Ninguna respuesta incluye un email de Auth.

### D10 — Pestaña "Documentos" en Configuración

- `configuracion/page.tsx`: `TAB_VALUES` suma `"documentos"` **después de `"fiscal"`** (los datos de la empresa quedan al lado de AFIP); 12 pestañas en `grid-cols-3 sm:grid-cols-4` (4×3 en móvil, 3×4 desde `sm`; sin cambiar clases). Ícono `Stamp` o `Palette` de lucide; rótulo "Documentos". Enlazable como `/configuracion?tab=documentos`.
- `components/settings/DocumentBrandingSettings.tsx` (React Hook Form + Zod, componentes base shadcn, tokens semánticos):
  1. **Datos de tu empresa en los papeles**: nombre comercial, razón social, CUIT (validado con `isValidCuit` de `lib/cuit-utils.ts`), domicilio, teléfono, email del negocio (con la aclaración "no es el email con el que entrás a la app"), sitio web, leyenda al pie (contador de caracteres). Si la cuenta tiene perfil fiscal, razón social/CUIT/domicilio/IVA se muestran como **"Sale de Datos fiscales (AFIP)"**, de sólo lectura, con enlace a `/configuracion?tab=fiscal`.
  2. **Logo** (`DocumentLogoUpload.tsx`, patrón de `AvatarUpload`): `input type=file` con `accept="image/png,image/jpeg,image/webp"`, chequeo previo de tamaño (2 MB) y tipo para dar el mensaje antes de subir, subida inmediata, vista previa del logo **normalizado que devolvió el servidor**, "Quitar logo" con confirmación. Mensajes en castellano para 413/415/422.
  3. **Colores**: `RadioGroup` de muestras del catálogo (cada una con su nombre accesible) + "Personalizado" con un `input type="color"` nativo y un campo hex (sin dependencia nueva); medidor de contraste en vivo con `lib/color-contrast.ts` ("Se lee bien sobre blanco · 6,7:1" / "No se lee bien sobre blanco · 1,5:1") que deshabilita Guardar si no cumple.
  4. **Vista previa en vivo** (`DocumentHeaderPreview.tsx`): mini-render HTML de un encabezado de presupuesto (logo, nombre, líneas, "PRESUPUESTO N° P-00000001", banda de tabla con dos líneas y el total) con lo que se está editando. El emisor de la vista previa se arma con `previewIssuer(form, fiscal, owner_fallback)` en `lib/document-branding.ts`, que **refleja** la cascada de Python y se ata a ella con el fixture compartido `backend/tests/fixtures/document_issuer_cascade_cases.json`. La vista previa **representa el papel**: fondo blanco y colores de la paleta (estilos inline desde hex validados) **en los dos temas**, dentro de un marco con tokens semánticos; es la única excepción declarada a la regla de tokens.
  5. **Dónde se usa**: "Comprobante de venta, presupuestos y remitos" (tanda A) y "… y la Factura C (sólo logo, contacto y color de la tabla)" (tanda B).
- Sólo `CAN_CONFIGURE` edita (`useOrgRole`, mismo criterio que `ScaleSettings`); el resto ve todo en sólo lectura, sin controles de subida.
- Hooks en `hooks/data/use-document-branding.ts` (`useDocumentBranding`, `useUpdateDocumentBranding`, `useUploadDocumentLogo`, `useDeleteDocumentLogo`, `useDocumentLogoDataUri`), claves en `lib/query-keys.ts` (`documentBranding.all/detail/logo`). Guardar invalida `documentBranding.all` y también los detalles de presupuestos y remitos (su `issuer_name` sigue la cascada).
- Responsive (375 / 768 / 1366 px) y temas claro/oscuro verificados con el e2e de 4 combinaciones y capturas.

### D11 — Factura C (tanda B): logo, contacto y color sin tocar lo fiscal

- `invoice_print_service.get_invoice_pdf` suma el repositorio de marca y llama `resolve_document_branding`; `build_invoice_view` **no cambia** (sigue puro y fiscal). `render_invoice_pdf(view, branding=None)` recibe la marca aparte; sin marca dibuja exactamente lo de hoy.
- `_draw_header`: la columna izquierda se arma como `IssuerBlock` (logo hasta 40 × 16 mm; el nombre de fantasía grande y la razón social debajo, OQ-3 de la factura intacta; domicilio; leyenda de IVA en negrita; y las líneas de contacto **de la marca** — `brand_contact`, sin el respaldo del teléfono del dueño, para que una cuenta que nunca configuró su marca reciba la misma factura que hoy). Se **mide** con `measure_issuer_column` y el recuadro toma `max(42 mm, alto izquierdo + márgenes, alto derecho + márgenes)`; la división vertical, la caja de la letra y el bloque derecho se ubican con ese alto. `header()` se llama en cada página, el cálculo es determinístico, así que todas las páginas tienen el mismo encabezado y la tabla arranca debajo.
- **Paleta sólo en lo no fiscal**: `_draw_table_head` usa `table_head_fill`/`table_head_text`; el título "FACTURA" usa `heading`. El recuadro de la letra, los datos fiscales, el receptor, los totales, el CAE y su vencimiento quedan en `ink`; `_draw_qr` sigue fijando el relleno en negro `(0,0,0)` sobre blanco. Con Neutro, `table_head_fill = surface = _HEAD_FILL` y `heading = ink = _INK`: la factura queda igual que hoy. `_INK`/`_MUTED`/`_RULE`/`_HEAD_FILL` pasan a ser los valores de `NEUTRAL` importados de `palette.py` (una sola fuente); `_WATERMARK` queda.
- Fundamento fiscal: la RG 1415/2003 fija el **contenido** de la factura y la RG 4892/2020 el **QR**; ninguna fija colores ni prohíbe el logo o los datos de contacto. Se conserva la legibilidad de todo lo fiscal (tinta) y la del QR (negro sobre blanco, zona de silencio de 4 módulos sin tocar).
- **En vivo, no en la foto**: la marca es presentación y no entra en `emisor_snapshot`, que sigue congelando sólo la identidad fiscal (`afip-fiscal-document` sin cambios). Consecuencia declarada: si la cuenta cambia el logo, una reimpresión de una factura vieja sale con el logo nuevo, como pasa con cualquier membrete; la identidad fiscal impresa no cambia.
- La leyenda libre al pie **no** va en la factura: un texto como "precios con IVA incluido" en una Factura C sería engañoso, y el pie de la factura es del número de comprobante.
- Textos nuevos de la columna izquierda pasan por `pdf_text` (cp1252); los textos fiscales existentes conservan `_latin1` (no se cambia su sanitizador en este change: hallazgo lateral).
- **Supera OQ-1 y OQ-4 de `factura-fiscal-imprimible`** por el pedido del 2026-10-11.
- Checkpoint 🛑 visual (task 13): factura de prueba con el stub en homologación, con logo horizontal (4:1) y cuadrado, nombre de fantasía largo y las tres líneas de contacto, una y 60 líneas; y la factura real 0003-00000501 de Sumar re-renderizada en local con sus datos (sólo lectura) sin marca y con una marca de prueba. Revisar que el QR se lea con la cámara.

### D12 — Tandas, migraciones y orden de despliegue

- **Tanda A** (rama `opsx/documentos-marca-empresa-apply-a`): migración **`20261078000001_documentos_marca_empresa.sql`** (tabla, RLS, guard, privilegios, `rpc_commercial_issuer`, bloque `DO` de introspección: una sola firma, ACL exacta, `prosecdef`, `STABLE`) + backend + frontend + gate SQL + e2e. Governance MEDIA.
- **Tanda B** (rama `opsx/documentos-marca-empresa-apply-b`, recién con la A en prod): factura. **Sin migración** (todo lo que necesita lo trae la A). Governance MEDIA-ALTA.
- El número se re-verifica en el apply: `ls supabase/migrations` en `origin/main`, `gh pr list --state open` y `MAX(version)` en prod (hoy `20261077000002`; `compras-gastos-sucursal-por-defecto` reserva `20261076000001/2`, que el `db push --include-all` del deploy acepta aunque sea menor). Si `20261078000001` se tomó, se usa el siguiente libre y se anota.
- **Orden de despliegue sin pausa de Render**: la migración es aditiva (tabla nueva; RPC con la misma firma y claves de más), así que el backend viejo contra la base nueva sigue andando. El backend nuevo contra la base vieja **también genera todos los papeles**: `resolve_document_branding` sólo usa la RPC (las claves nuevas faltan → valores por defecto, Neutro) y no baja logo sin huella; sólo `GET/PUT /document-branding` fallan (`42P01`) durante esa ventana. El frontend nuevo contra el backend viejo ve 404 en la pestaña (estado de error) y el HTML del comprobante cae a Neutro. Ventanas de minutos, sin datos en riesgo. Se verifica después del merge el deploy de Render (memoria del proyecto: a veces hay que dispararlo).
- **Rollback**: revert del PR. La tabla queda inerte; la RPC con claves de más no molesta a un backend viejo. Si hiciera falta volver la RPC a 6 claves, otra migración con su cuerpo previo (guardado en la evidencia del apply).

### D13 — Tests y gates (TDD estricto)

RED visto fallar → GREEN mínimo → triangular → refactor, en SQL, backend y frontend. Nunca aserciones triviales. Todo gate negativo con su control positivo. CUITs de fixtures sólo de la allow-list sintética de `backend/tests/test_fixtures_sin_cuit_real.py` (`20123456786`, `20111111112`, …).

- **Gate SQL nuevo** `supabase/tests/test_documentos_marca_empresa.sql` (molde `test_balanza_etiquetas_pos.sql` + `test_accounts_privilege_columns.sql`; `BEGIN … ROLLBACK`; usuarios `@test.local`; degrade-don't-fail sólo en la fixture), cableado en `KPI_Validation.yml`: (a) metadatos — tabla, RLS activa, exactamente 3 políticas sin DELETE, `relacl` sin `anon` y sin `d`/`D` para `authenticated`, disparador y función sin `EXECUTE` para `PUBLIC`/`anon`/`authenticated`; (b) matriz de `CHECK`s — cada fila inválida rechazada con `23514` y su control positivo aceptado; (c) RLS y guard bajo `SET LOCAL ROLE authenticated` + claims — owner y admin escriben, seller `P0401`, viewer `42501`, otra cuenta no lee ni escribe, `account_id` inmutable `P0401`, `DELETE` → `42501` *permission denied*; (d) `rpc_commercial_issuer` **ejecutada** como vendedor no dueño: claves exactas (18), valores de marca y del dueño, ningún valor igual al email de Auth del dueño, `P0404` a otra cuenta, sin fila de marca → claves nuevas `NULL`; (e) introspección de la RPC — una firma, `SECURITY DEFINER`, `STABLE`, ACL exacta, `COMMENT` con la procedencia; (f) residuo cero.
- **Gates existentes**: `test_presupuestos_modulo.sql` bloque (n) → 18 claves exactas; `test_is_account_writer_pivot.sql` → **45 políticas / 18 tablas** con la línea de mantenimiento en la cabecera (re-contar en local antes de fijar); `test_function_acl_gate.sql` → corre verde con el guard nuevo (sin cambios si el `REVOKE` está; agregarlo a su lista sólo si el gate lo pide); `test_anon_table_writes_revoked.sql` → verde con la tabla nueva.
- **Backend**: `test_document_palette.py` (fixture compartido; catálogo ≥ 4,5:1; Neutro sin acento; `best_text_on`; `resolve_palette` cae a Neutro con un guardado inválido o ilegible; `#10b981` rechazado), `test_document_logo.py` (PNG con transparencia → PNG 1000 px; JPEG grande → JPEG ≤ 300 KB sin EXIF; WebP → PNG/JPEG; SVG/GIF/texto → 415; encabezado de 20000×20000 → 422 **sin** `load()` (espía); corrupto → 422; ruido que no baja de 300 KB → 422 `too_heavy`; `load_logo_for_render` → `None` con tipo cambiado o tamaño excedido), `test_document_branding_issuer.py` (cascada desde `document_issuer_cascade_cases.json`; CUIT formateado; leyenda de IVA; nunca un email que no sea `brand_email`), `test_document_branding_api.py` (GET por defecto; PUT owner/admin; seller y cajero 403; 422 de validación y `branding_accent_low_contrast`; logo 413 por stream y por `Content-Length`, 415, 422, 200; DELETE idempotente; GET logo 404/200 con `ETag`; 401; otra cuenta no ve nada), `test_commercial_document_pdf.py` (imagen presente con logo y ausente sin; operadores de color de la paleta y **ausencia de `0.0627 0.7255 0.5059`**; leyenda al pie en todas las páginas; email del negocio y web impresos; CUIT con guiones; `test_the_issuer_never_carries_an_email` se **reemplaza** por "el emisor sólo lleva el email del negocio de la marca" + "ignora cualquier otra clave de email"), `test_receipts.py` (comprobante con marca; endpoint que ignora los campos viejos; nada de verde; recibo de suscripción intacto con su `EMERALD`), `test_quotes_module.py` y `test_delivery_notes_module.py` (servicios con la marca; `issuer_name` con `brand_display_name`). Tanda B: `test_invoice_pdf.py` (texto de Sumar idéntico sin marca; con logo y contacto; sin teléfono del dueño; banda y título con la paleta; QR con relleno negro; recuadro que crece; 60 líneas con el encabezado repetido; logo horizontal y cuadrado sin superposición — se asserta con las coordenadas que devuelve el helper), `test_factura_fiscal_*.py` (endpoint con la marca).
- **Frontend**: `__tests__/lib/color-contrast.test.ts` (fixture compartido), `token-contrast-aa.test.ts` importando la lib (28 pares verdes), `__tests__/lib/document-branding.test.ts` (Zod; `previewIssuer` contra el fixture de cascada; `isSafeLogoDataUri`; `isSafeHexColor`; `toReceiptBranding`), `receipt.test.ts` (marca en HTML y textos; logo `data:`; sin URL de avatar; sin `--emerald`; escapado; `data:` o hex inválidos se omiten), `sale-receipt-button*.test.tsx` (usa la marca; el payload sin campos de negocio; ningún email de login en los textos), `DocumentBrandingSettings.test.tsx`, `DocumentLogoUpload.test.tsx`, `DocumentHeaderPreview.test.tsx`, `ConfiguracionPage-documentos-tab.test.tsx` + las dos de Configuración existentes (12 pestañas, `?tab=documentos`).
- **E2E** `frontend/e2e/documentos-marca.spec.ts` (molde `factura-imprimible.spec.ts` y `fixtures/fiscal-e2e.ts`): el dueño completa la marca, sube un PNG generado en el test, elige "Bordó", guarda, ve la vista previa; un presupuesto sembrado por API descarga un PDF real; capturas en 1366×768 y 375×812, claro y oscuro, sin desborde horizontal.

### D14 — Specs y orden de archive

- **Nueva** `document-branding` (8 requirements). **Modificada** `commercial-document-pdf`: `MODIFIED` de "Constructor compartido del PDF de un documento comercial" y de "Datos del emisor sin bloqueo" (los dos ya están en main). **Modificada** `fiscal-invoice-print`: un requirement `ADDED` (el de contenido mínimo dice "como mínimo" y no cambia).
- `remitos-venta` y `remitos-compra` traen deltas `ADDED` sin sincronizar sobre `commercial-document-pdf` ("El constructor del PDF comercial admite el remito…") con un escenario *"El presupuesto no cambia… su contenido es el mismo que antes"*. Este change **no** los toca (gotcha del proyecto: dos deltas sobre el mismo requirement, el segundo pisa al primero) y ninguno de los dos modifica los requirements que éste modifica, así que el archive es mecánicamente seguro en cualquier orden. **Recomendado**: archivar los remitos antes. Si al archivar éste ya están en main, la task 15.2 revisa ese escenario y, si quedó ambiguo frente a la marca, suma un `MODIFIED` que lo acote a la estructura (sin bloque de firma ni rótulo de origen).
- KB al archivar (no antes): regla nueva en `05_reglas_de_negocio.md` — *"Todo papel que la cuenta entrega a un tercero lleva el emisor resuelto por la cascada perfil fiscal → marca de la cuenta → perfil del dueño, la paleta de la cuenta (Neutro por defecto, acento ≥ 4,5:1) y su logo; nunca un email de acceso. La Factura C toma de la marca sólo logo, contacto y color de elementos no fiscales"* — y la Épica 8 de `06_funcionalidades.md`.

## Risks / Trade-offs

- **[Un logo malicioso o enorme tumba el render]** → tope de bytes en el stream, dimensiones leídas antes de decodificar, normalización a ≤ 1000 px y ≤ 300 KB, `CHECK`s de tipo/firma/tamaño en la tabla, y el render vuelve a comprobar perezoso y dibuja sin logo ante cualquier duda. Test con una bomba real.
- **[Logo en la base en vez de Storage]** → costo acotado y medido (≤ 12 MB hoy); umbral de revisión declarado; el contrato de la API oculta el almacenamiento.
- **[El encabezado de la factura desborda con un logo o mucho contacto]** → recuadro medido antes de dibujar; tests con logo horizontal, cuadrado, fantasía larga y 60 líneas; checkpoint visual 🛑.
- **[Cambiar el render de la factura introduce un error en un documento fiscal]** → `build_invoice_view` intacto; la marca entra sólo al render; sin marca el texto es idéntico (test); la paleta no toca el QR ni lo fiscal; tanda propia con checkpoint.
- **[El verde desaparece de golpe para todas las cuentas]** → es exactamente lo pedido ("sacale el color verde"); quien quiera color elige un preset. Se anuncia en la pestaña.
- **[Divergencia entre el cálculo de contraste o la cascada de TS y Python]** → fixtures compartidos (`document_palette_cases.json`, `document_issuer_cascade_cases.json`) leídos por los dos lados; Python es la autoridad (el servidor rechaza y el render cae a Neutro).
- **[Ventanas de despliegue]** → claves de la RPC aditivas; `resolve_document_branding` no lee la tabla directo; contrato de `POST /sales/receipt-pdf` tolerante; el botón de WhatsApp ya tiene camino de respaldo (D12).
- **[XSS en el HTML imprimible]** → logo sólo como `data:` PNG/JPEG validado por regex; colores sólo `#rrggbb`; textos escapados; web como texto; SVG rechazado desde la subida.
- **[El gate de 6 claves y el test "never carries an email" se tocan]** → se mantienen como allow-list exacta (18 claves) y se reemplazan por aserciones más fuertes (ningún valor es el email de Auth), en el mismo PR.
- **[Choque con los deltas de remitos]** → requirements disjuntos; orden de archive recomendado y task de revisión (D14).

## Migration Plan

1. **Tanda A**: checkpoint (re-medir `MAX(version)`, cuerpo vivo de `rpc_commercial_issuer`, conteo de políticas `is_account_writer`, ACL); gate RED; migración `20261078000001`; backend; frontend; e2e; PR con CI verde; merge (pipeline: `db push` + Render + Vercel). Verificación post-merge en prod sólo lectura: `MAX(version)`, tabla y políticas, ACL de la RPC, deploy de Render, y un PDF de presupuesto sin marca (Neutro, sin verde).
2. **Humo del PO (tanda A)**: configurar su marca en `/configuracion?tab=documentos` (logo + datos + paleta), descargar un comprobante interno, un presupuesto y un remito, y mandarlos por WhatsApp.
3. **Tanda B**: rama nueva desde `main` con la A en prod; render de la factura; checkpoint 🛑 visual; PR; merge; humo del PO reimprimiendo una factura propia.
4. Archive (después de los remitos si es posible): specs sincronizadas, KB, `CHANGES.md`, `CLAUDE.md` + `AGENTS.md` (`check_docs_sync.py --fix`).

Rollback: revert del PR de cada tanda; la tabla queda inerte y la RPC compatible (D12).

## Open Questions

Todas resueltas por su recomendación según el sign-off anticipado del PO (*"continuá con todo lo recomendado"*, 2026-10-11). Ninguna queda como "requiere pregunta": no hay dinero, auth ni datos fiscales afectados de forma irreversible — la tanda B cambia sólo el render (reversible con un deploy), no lo autorizado ni lo que se pide a ARCA, y la supersesión de la OQ-1 de la factura está cubierta por el pedido textual, que nombra las facturas.

| # | Pregunta | Resolución adoptada (recomendación) |
|---|---|---|
| OQ-1 | ¿Dónde se guarda el logo? | **En la base**, normalizado por el backend (D2). Desvío del brief (bucket + service client) por la regla dura de `service_role` y porque la subida igual tiene que pasar por el backend. Umbral de revisión a Storage: ~2.000 cuentas con logo. |
| OQ-2 | Paleta por defecto | **Neutro** ("blanco", la tinta de la factura). |
| OQ-3 | Catálogo | Neutro, Azul, Verde (oscuro), Grafito, Bordó y Personalizado (D3). |
| OQ-4 | Regla del color personalizado | ≥ 4,5:1 contra blanco; el servidor rechaza y el render cae a Neutro. |
| OQ-5 | ¿La Factura C adopta la paleta? | Sí, **sólo** en elementos no fiscales (banda de la tabla y título); QR negro, lo fiscal en tinta (D11). |
| OQ-6 | ¿De dónde sale el contacto de la factura? | **Sólo de la marca** (sin el respaldo del perfil del dueño): sin marca, la factura queda como hoy. |
| OQ-7 | ¿La leyenda al pie va en la factura? | **No** (riesgo de leyendas engañosas en un documento fiscal). |
| OQ-8 | Nombre y lugar de la pestaña | **"Documentos"**, después de "AFIP"; `?tab=documentos`. |
| OQ-9 | ¿Condición de IVA en los papeles no fiscales? | Sí, **sólo** si hay perfil fiscal. |
| OQ-10 | Contrato de `POST /sales/receipt-pdf` | Compatible: los campos de negocio pasan a opcionales **e ignorados**; sin versionar (D7). |
| OQ-11 | ¿Se conserva el HTML imprimible? | Sí; lee la marca de la API (D8). |
| OQ-12 | ¿Se importa el avatar del dueño como logo inicial? | **No** (es una foto personal y una URL escribible por el usuario). |
| OQ-13 | ¿Se conserva el perfil del dueño como respaldo del nombre y el teléfono? | Sí, para que sin marca nada cambie salvo el color. |
| OQ-14 | ¿Cómo se "borra" la marca? | No se borra la fila: retirar el logo y volver a los valores por defecto son actualizaciones; `DELETE` revocado. |

## Hallazgos laterales (para registrar en `CHANGES.md` al archivar)

1. `scale_settings` (y probablemente otras tablas de configuración) conserva `DELETE`/`TRUNCATE` de tabla para `authenticated` (`relacl` vivo `arwdDxtm`); no explotable por PostgREST, pero sobra.
2. Guard owner/admin copiado tres veces (`points_of_sale`, `scale_settings`, `account_branding`): candidato a un guard genérico por `TG_TABLE_NAME`.
3. Formateadores duplicados (`_format_date` en `receipts.py:66` e `invoice_pdf.py:184`; `format_quantity` en `view.py:98` vs `_format_quantity` en `invoice_pdf.py:188`) y los privados de `receipts.py` importados por otros módulos.
4. Textos fiscales de la factura con `_latin1` (un "—" en la razón social sale "?").
5. `frontend/lib/database.types.ts` desactualizado (faltan columnas de `accounts` y `fiscal_profiles`).
6. Código deprecado de Storage con `service_role` (`wsfe_adapter._read_cert_from_storage`, `/fiscal/profile/cert-upload-url`) sin uso en el modelo de delegación.
7. Colisión de prefijo `RC-` entre el remito de compra y el recibo de suscripción (de la exploración; ajeno a este change).
