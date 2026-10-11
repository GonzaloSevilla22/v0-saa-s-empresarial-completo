## Why

> **Governance:** tanda A **MEDIA** (lógica de presentación, una tabla de configuración por cuenta y una RPC de lectura reescrita); tanda B **MEDIA-ALTA** (toca el render de la Factura C, un documento fiscal: no cambia ningún dato autorizado ni lo que se le pide a ARCA, pero lo impreso lo recibe un tercero). Checkpoints 🛑 en lo que reescribe una RPC viva y en todo lo que dibuja la factura.

**Pedido textual del PO (2026-10-11):** *"Necesito que en todos los comprobantes, remitos, facturas, presupuesto, etc., tenga toda la información de la empresa y el logo de la misma, de cada usuario. Y sacale el color verde y dejalos blancos, o en Configuración que cada usuario pueda elegir la paleta de colores que ellos decidan para estos papeles."* Y después: *"cuando llegue el propose, continuá con todo lo recomendado"* — las decisiones de este change se aplican según su recomendación, sin otra ronda.

Hoy los papeles que la app genera para los clientes de cada cuenta salen de **tres fuentes de datos distintas y ninguna tiene logo**:

| Papel | Generador | Emisor hoy | Color hoy |
|---|---|---|---|
| Comprobante interno de venta (PDF) | `backend/services/receipts.py:189` | lo que **manda el navegador** desde el perfil del **usuario logueado**: nombre, teléfono y **el email de login** (`sale-receipt-button.tsx:122-129`) | verde `EMERALD (16,185,129)` en N°, regla, cabecera y TOTAL |
| Comprobante interno (HTML imprimible + textos de WhatsApp) | `frontend/lib/receipt.ts:393`, `:563`, `:625` | ídem, y como "logo" el **avatar** del usuario | `--emerald #059669` en los subtotales |
| Presupuesto, remito de venta y de compra | `backend/services/commercial_documents/pdf.py:274` | `rpc_commercial_issuer`: fantasía → razón social → `business_name` del dueño; teléfono del dueño; sin email, sin IVA, sin logo | el mismo `EMERALD` (importado de `receipts.py`) en título, regla, cabecera, TOTAL y sello |
| Factura C | `backend/services/fiscal/invoice_pdf.py:693` | `emisor_snapshot` congelado al autorizar; **sin** teléfono, email ni web (OQ-1 firmada el 2026-09-26) ni logo (OQ-4: "candidato aparte") | **sin verde**: tinta pizarra `_INK (30,41,59)` |

Medido en prod el 2026-10-11 (sólo lectura): 41 cuentas, **2** con perfil fiscal (1 con razón social y domicilio), **6** dueños con nombre del negocio, 19 con teléfono; 2 presupuestos, 0 remitos, 21 comprobantes autorizados; 0 cuentas multiusuario. El verde actual además **no pasa AA**: texto blanco sobre `EMERALD` mide **2,54:1** y `#059669` sobre blanco **3,77:1** (umbral 4,5:1).

Dos defectos que el pedido destapa y este change corrige de paso:
1. **El comprobante interno imprime el email de acceso** del usuario que lo descarga (`businessEmail: user?.email`, `sale-receipt-button.tsx:125`) — justo lo que `commercial-document-pdf` prohíbe para el presupuesto ("el email de acceso del dueño no debe aparecer en un documento para terceros").
2. **El mismo comprobante sale distinto según quién lo descargue** (nombre, teléfono y "logo" son del usuario, no de la cuenta): un vendedor imprime su avatar personal y su teléfono.

## What Changes

### Tanda A — marca de la cuenta en todos los papeles no fiscales (migración `20261078000001`, a re-verificar en el apply)

- **Tabla nueva `account_branding`** (una fila por cuenta, molde `scale_settings`): nombre comercial para los papeles, razón social, CUIT, domicilio, teléfono, **email del negocio**, sitio web, leyenda al pie, paleta (`palette_preset` cerrado + `accent_color` para la personalizada) y el **logo normalizado**. RLS: lectura de cualquier miembro, escritura `is_account_writer` + disparador que la restringe a **owner/admin** (`P0401`); sin DELETE; `CHECK`s de forma como segunda capa. Sin fila = valores por defecto (paleta **Neutro**, sin logo).
- **Logo** subido por el backend (`PUT /document-branding/logo`, cuerpo binario), que lo **valida y normaliza** con Pillow (PNG/JPEG/WebP de entrada; sin SVG ni GIF; tope de bytes y de píxeles **antes** de decodificar; reescalado a ≤ 1000 px; re-codificado sin metadatos a PNG o JPEG ≤ 300 KB) y lo guarda **en la base** junto con su huella SHA-256. Nunca se descarga de una URL, nunca se usa `profiles.avatar_url`. (Desvío fundamentado del brief, que sugería un bucket: ver D2 del design.)
- **Paleta**: catálogo cerrado — **Neutro** (por defecto, "blanco": tinta oscura, reglas grises, cabecera de tabla gris muy claro, igual que la Factura C de hoy), **Azul**, **Verde** (oscuro, AA), **Grafito**, **Bordó** — más **Personalizado** con un color validado por contraste (≥ 4,5:1 contra blanco). **El verde desaparece del valor por defecto en todas las cuentas** al desplegar. La aritmética WCAG del gate `token-contrast-aa` se promueve a `frontend/lib/color-contrast.ts` y tiene su espejo autoritativo en Python, atados por un fixture compartido.
- **Un solo emisor y un solo encabezado**: `rpc_commercial_issuer` (misma firma, `CREATE OR REPLACE` desde el cuerpo vivo) suma la marca y la condición de IVA a sus 6 claves actuales; la cascada por campo es **perfil fiscal → marca → perfil del dueño (compat.) → "Mi Negocio"** para la identidad fiscal, y **marca primero** para el nombre comercial y el contacto. `DocumentBranding` (paleta resuelta + logo + líneas de identidad y contacto) y un **helper de columna de emisor compartido** reemplazan los tres encabezados dibujados a mano; la paleta sale de `receipts.py` (que la conserva sólo para el recibo de suscripción de ALIADATA, marca de plataforma).
- **Comprobante interno**: el PDF resuelve la marca **en el servidor** por la cuenta del JWT (`POST /sales/receipt-pdf` acepta y **ignora** los campos de negocio que mandaba el navegador, para que una pestaña vieja no reciba 422); el HTML imprimible y los textos de WhatsApp/portapapeles leen `GET /document-branding` y el logo como `data:` URI validado. Se deja de usar el avatar y el email de login.
- **Presupuesto y remitos (venta y compra)**: logo, identidad completa (incluido CUIT formateado, condición de IVA, email del negocio y web), leyenda al pie de la cuenta y paleta. El nombre del negocio de los textos de WhatsApp (`issuer_name`) sigue la misma cascada sin cambios de código en las pantallas.
- **API** `/document-branding`: `GET` (cualquier miembro: configuración, emisor resuelto tal como se imprime, catálogo de paletas), `PUT` (owner/admin), `PUT`/`DELETE` del logo (owner/admin) y `GET` del logo (cualquier miembro, con `ETag`). 3 capas, RFC 7807.
- **Superficie frontend**: 12.ª pestaña **"Documentos"** en `/configuracion` (`?tab=documentos`, al lado de "AFIP"; la grilla `grid-cols-3 sm:grid-cols-4` cierra 4×3 / 3×4): datos de la empresa para los papeles (con los que manda el perfil fiscal mostrados como tales y enlazados a AFIP), subida/retiro del logo con vista previa, selector de paleta con color personalizado y aviso de contraste, **vista previa en vivo** de un encabezado de documento (mini-render HTML que representa el papel), y aviso de qué papeles la usan. Owner/admin editan (`CAN_CONFIGURE`); el resto ve en sólo lectura. Desktop + móvil, claro + oscuro.

### Tanda B — la Factura C suma logo, contacto y color (sin migración)

- `_draw_header` gana el **logo** en la columna del emisor y las líneas de **teléfono / email / web** de la marca; el recuadro deja de tener alto fijo (42 mm) y se mide antes de dibujar, para que ningún logo (horizontal o cuadrado) desborde. **Supera la OQ-1 de `factura-fiscal-imprimible`** ("sin teléfono/email/web") por el pedido nuevo del PO, que nombra explícitamente las facturas.
- La paleta se aplica **sólo a elementos no fiscales** (banda de la cabecera de la tabla y el título "FACTURA"); el recuadro de la letra, los datos fiscales, el CAE y el **QR (siempre negro sobre blanco)** quedan en tinta. Con **Neutro**, la factura queda igual que hoy salvo logo y contacto.
- La marca se lee **en vivo**: no entra en `emisor_snapshot`, que sigue congelando sólo la identidad fiscal. La leyenda libre al pie **no** se imprime en la factura.
- Checkpoint 🛑 de verificación visual con una factura de prueba (stub/homologación) con logo horizontal y cuadrado, y con la factura real de Sumar re-renderizada.

### Fuera de alcance, declarado

Emails transaccionales y recibo de suscripción (marca de plataforma ALIADATA); etiquetas de balanza; cierre de caja (no tiene papel); el tema de la UI de la app (el verde `--primary` de la interfaz no es lo que el PO pidió); papeles que hoy no existen (compra, gasto, cobro); SVG; condición de IVA cargada fuera del perfil fiscal; importar el avatar como logo.

## Capabilities

### New Capabilities

- `document-branding`: marca de la cuenta para sus papeles — persistencia (`account_branding`), permisos, logo (subida, normalización, servicio), paleta (catálogo, contraste, resolución), emisor único resuelto por cascada, API `/document-branding`, pestaña "Documentos" de Configuración y el comprobante interno de venta (PDF, HTML y textos) con la marca resuelta en el servidor.

### Modified Capabilities

- `commercial-document-pdf`: el constructor compartido pasa de "la misma familia visual que el comprobante interno" (el verde) a la **paleta de la cuenta** con el **logo** y un encabezado compartido; los datos del emisor suman marca, condición de IVA, **email del negocio** (el de login, nunca) y web, con la cascada nueva, y la lectura sigue exponiendo sólo los campos enumerados.
- `fiscal-invoice-print`: la Factura C lleva el logo y el contacto de la cuenta y la paleta en sus elementos no fiscales, leídos en vivo (requirement **ADDED**; el de contenido mínimo no cambia).

`quote` no cambia (su PDF delega el encabezado en `commercial-document-pdf`); `fiscal-profile` y `afip-fiscal-document` no cambian (`fiscal_profiles` no recibe marca y `emisor_snapshot` no se toca).

## Impact

- **DB** (tanda A, `20261078000001_documentos_marca_empresa.sql`; el apply re-verifica `MAX(version)` en prod —hoy `20261077000002`, 325 filas— y `gh pr list`; `compras-gastos-sucursal-por-defecto` reserva `20261076000001/2`): tabla `account_branding` + RLS + guard `P0401`; `rpc_commercial_issuer` reescrita con la misma firma. Tanda B: **sin migración**.
- **Backend**: nuevos `services/commercial_documents/{palette,logo,branding,header}.py`, `repositories/document_branding_repository.py`, `schemas/document_branding.py`, `services/document_branding.py`, `routers/document_branding.py` (+ registro en `main.py`); modificados `services/receipts.py`, `services/commercial_documents/{pdf,issuer,view}.py`, `services/quotes.py`, `services/delivery_notes.py`, `routers/sales.py`, `schemas/sales.py`, y en B `services/fiscal/{invoice_pdf,invoice_print_service}.py` + `routers/fiscal.py`. Sin dependencias nuevas (Pillow ya viene con `fpdf2` 2.8.9; WebP verificado en el venv; el logo viaja como cuerpo binario, sin `python-multipart`).
- **Frontend**: `lib/color-contrast.ts` (promovido del gate), `lib/document-branding.ts`, `hooks/data/use-document-branding.ts`, `lib/query-keys.ts`, `components/settings/{DocumentBrandingSettings,DocumentHeaderPreview,DocumentLogoUpload}.tsx`, `app/(dashboard)/configuracion/page.tsx`, `lib/receipt.ts`, `components/ventas/sale-receipt-button.tsx`, `__tests__/lib/token-contrast-aa.test.ts`.
- **Gates y tests**: gate SQL nuevo `supabase/tests/test_documentos_marca_empresa.sql` (cableado en `KPI_Validation.yml`); actualizados `test_presupuestos_modulo.sql` (bloque (n), claves del emisor), `test_is_account_writer_pivot.sql` (43/17 → 45/18), `test_function_acl_gate.sql` (guard interno); backend `test_receipts.py`, `test_commercial_document_pdf.py` (incluida la inversión de `test_the_issuer_never_carries_an_email`), `test_quotes_module.py`, `test_delivery_notes_module.py`, `test_invoice_pdf.py`, `test_factura_fiscal_*.py` + tests nuevos; frontend `receipt.test.ts`, `sale-receipt-button*.test.tsx`, `ConfiguracionPage-*.test.tsx`, `token-contrast-aa.test.ts` + tests nuevos; e2e nuevo `frontend/e2e/documentos-marca.spec.ts` (4 combinaciones).
- **Specs en curso**: `remitos-venta` y `remitos-compra` traen deltas ADDED sin sincronizar sobre `commercial-document-pdf` con un escenario "el presupuesto no cambia… su contenido es el mismo que antes". Este change **no** los modifica (sólo toca requirements que ya están en main) y declara el orden de archive en el design.
- **KB (al archivar, cuando sea cierto)**: regla nueva en `knowledge-base/05_reglas_de_negocio.md` ("todo papel del tenant lleva el emisor resuelto por la cascada perfil fiscal → marca de la cuenta y la paleta de la cuenta") y la Épica 8 de `06_funcionalidades.md`.
- **Comportamiento visible**: todos los papeles pierden el verde al desplegar (Neutro); los que ya tenían datos los conservan; quien configure la pestaña ve su logo y sus datos en todos los papeles. Sin cambios de rutas fuera de `?tab=documentos`, menú, planes, billing, dinero, outbox, Edge Functions ni emails.
