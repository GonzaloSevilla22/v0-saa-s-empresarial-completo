## Why

El 2026-09-25 Sumar (CUIT 27213790337) emitió su primera factura real desde la app: **Factura C 0003-00000501**, $32.500, autorizada por ARCA con CAE. La app guarda el CAE y su vencimiento, pero **no hay forma de imprimirla ni de entregársela al cliente**: el único PDF que existe es el "Comprobante de venta" interno (sin CAE, sin QR, sin datos fiscales del emisor), y ninguna pantalla muestra el CAE. El PO lo pidió textualmente: *"quiero que se pueda imprimir la factura"* y *"¿cómo verifico que se hizo bien?"*. Es el candidato `comprobante-fiscal-visible` de `CHANGES.md` (anotado el 2026-09-21), que con la primera factura de un cliente real deja de ser opcional: el comprador tiene derecho a recibir la representación impresa, y ARCA exige que lleve el QR (RG 4892/2020).

## What Changes

- **PDF legal de la Factura C** generado en el backend con `fpdf2` (ya está en el stack; `backend/services/receipts.py` es el molde): emisor (razón social, domicilio comercial, CUIT, "IVA Responsable Monotributo", Ingresos Brutos, inicio de actividades), letra y código de comprobante (C / 011), `PPPP-NNNNNNNN`, fecha de emisión **confirmada por ARCA**, receptor tal como se declaró a ARCA, condición de venta, líneas (snapshots de `sales_order_items`), total, CAE + vencimiento, **QR de ARCA** según la especificación oficial, leyenda "ORIGINAL" y marca de agua "SIN VALIDEZ FISCAL" en homologación. La estructura queda lista para A/B (tabla de tipos + bloque de IVA), pero A/B se rechazan con un error explícito hasta que exista un emisor RI.
- **Dependencia nueva, una sola y chica**: `segno` (QR puro Python, sin dependencias transitivas). No existe otra forma de dibujar un QR con lo que ya hay.
- **Endpoint `GET /fiscal/documents/{id}/pdf`** (3 capas, RFC 7807): sólo comprobantes `authorized` de la cuenta del usuario; 404 para uno de otra cuenta (no se distingue de uno inexistente), 409 para `pending_cae`/`rejected`/`voided` o si faltan datos obligatorios.
- **Datos del emisor** que faltan en `fiscal_profiles` (columnas nuevas, NULLABLE): razón social, nombre de fantasía (opcional), domicilio comercial, número de IIBB, inicio de actividades. Se cargan en **Configuración → Datos fiscales** (`/configuracion/fiscal`), con aviso de qué falta para poder imprimir.
- **Foto del emisor y fecha del comprobante congeladas al autorizar**: `fiscal_documents` gana `emisor_snapshot jsonb` y `fecha_comprobante date`, escritos por `rpc_fiscal_document_authorize` (el único punto por el que un comprobante pasa a `authorized`, tanto en el relay como en la reconciliación). La fecha es la que ARCA devuelve (`CbteFch`), igual que el número desde #580: hoy **no se persiste en ningún lado** y el QR la necesita exacta.
- **Superficie** (desktop + mobile, claro + oscuro), reutilizando `SaleReceiptButton` y `FiscalDocumentBadge`:
  - `/ventas`: junto al badge "Autorizado", el número de comprobante **y el CAE con su vencimiento**; en el menú "Comprobante ▾", "Ver / imprimir factura" y "Descargar factura (PDF)"; "Verificar en ARCA" (constatación oficial); "Enviar por WhatsApp" manda **la factura** cuando está autorizada.
  - `/ventas/ordenes`: mismo bloque. De paso corrige un bug preexistente: la página pasa `initialStatus="pending_cae"` fijo, así que una orden ya autorizada se muestra "En trámite" para siempre (Realtime sólo avisa cambios, no el estado inicial).
- **Hallazgo lateral para sign-off** (OQ-7): el adapter arma `CbteFch` con `datetime.date.today()` en un servidor en UTC, así que una factura pedida entre las 21:00 y las 23:59 de Argentina sale con la fecha del día siguiente. Se propone corregirlo en este change (una línea, con test) porque ahora esa fecha queda impresa en el papel.

## Capabilities

### New Capabilities
- `fiscal-invoice-print`: representación impresa (PDF) de un comprobante fiscal autorizado — contenido legal, QR de ARCA (RG 4892), endpoint con tenencia, y las superficies donde se ve el CAE y se imprime, descarga, verifica o envía la factura.

### Modified Capabilities
- `fiscal-profile`: el perfil gana los datos del emisor que exige la representación impresa (razón social, nombre de fantasía, domicilio comercial, IIBB, inicio de actividades); cambian la persistencia, la API y la UI de configuración fiscal.
- `afip-fiscal-document`: el comprobante autorizado conserva la fecha de emisión confirmada por ARCA y una foto del emisor tomada al autorizar (se amplía el requisito "Datos del emisor vigentes congelados en el comprobante"); la fecha que se le pide a ARCA pasa a ser la fecha de Argentina (sujeto a OQ-7).

## Impact

- **DB**: una migración nueva (número a confirmar al aplicar; hoy el último es `20261061000001`): 5 columnas en `fiscal_profiles`, 2 en `fiscal_documents`, reescritura de `rpc_fiscal_document_authorize` **desde su cuerpo vivo** (md5 `c8bc224d…`) con un parámetro nuevo `p_fecha_comprobante date DEFAULT NULL` (vía `DROP` + `CREATE`, sin overload), gate SQL que **ejecuta** la RPC.
- **Backend**: `services/fiscal/invoice_pdf.py` (nuevo: modelo de vista puro + renderer + QR), `routers/fiscal.py` (endpoint), `repositories/fiscal_document_repository.py` (lectura con líneas y condición de venta), `fiscal_profile_repository.py` + `schemas/fiscal.py` (campos del emisor, tri-estado), `wsfe_adapter.py`/`fiscal_document_port.py`/`cae_relay_processor.py` (propagan `CbteFch` hasta el authorize), `sales_repository.py` + `sales_order_repository.py` (el read model trae CAE, vencimiento y tipo). `requirements.txt`/`pyproject.toml`: `segno`; `pypdf` sólo en tests (CI).
- **Frontend**: `components/ventas/sale-receipt-button.tsx`, `components/fiscal/` (bloque nuevo con CAE y acciones, reutilizado en dos pantallas), `components/settings/FiscalSettings.tsx`, `hooks/data/use-sales.ts`, `hooks/data/use-fiscal-profile.ts`, `lib/fiscal-comprobante.ts`, `lib/types.ts`, `app/(dashboard)/ventas/ordenes/page.tsx`.
- **Governance**: MEDIA (lectura y render) con un **tramo ALTO por exactitud legal** (lo impreso tiene que coincidir con lo que ARCA autorizó) y porque toca el camino de autorización del relay (sólo agrega columnas a lo que escribe el authorize; no cambia qué se le pide a ARCA, salvo OQ-7). Sign-off del PO en las OQs antes del apply.
- **Sin cambios** en emisión, numeración, reintentos, congelamiento ni en el "Comprobante de venta" interno (sigue disponible).
- **Fuera de alcance**: elegir el punto de venta al vender o facturar (la otra mitad del pedido del PO de hoy; va por separado), la factura de las suscripciones en `/admin/pagos` (OQ-6), notas de crédito, envío por email, logo.
