## Why

El PO pidió (2026-09-29), textual: *«el módulo presupuesto que se crea un presupuesto para un cliente y se descarga para enviárselo o se envía por WhatsApp si está el número y si éste acepta el presupuesto que haya un botón que sea venta que si se toca se envía a venta automáticamente con todos los productos que tiene […] cuando se crea el presupuesto no [baja stock]»*. Y agregó: *«quiero que tanto el remito como los presupuestos se puedan modificar»*.

Aliadata tiene el **backend** de presupuestos desde C-29 (2026-06-17), pero **ninguna pantalla** lo usa, y al circuito que pide el PO le faltan piezas:

- **Datos**: tablas `quotes`/`quote_items` (`supabase/migrations/20260702000001_c29_quote_salesorder.sql:82-163`) con FSM `draft|sent|accepted|expired|rejected`, snapshots de línea (`20260806000001_v3_snapshot_pattern.sql:91`), historial en `document_status_history` y catálogo de transiciones con roles (`20261048000001_v3_rbac_multirole_parte_b.sql:403-408`). En prod hay **0 presupuestos** (medido el 2026-09-29).
- **Aceptación**: `rpc_accept_quote` (viva: `20261045000001_operacion_party_guard.sql:1677-1820`) acepta el presupuesto y crea una `sales_orders` en **`draft`**, sin stock, caja ni cobro, y sin `FOR UPDATE` sobre el presupuesto. No llama a `_c29_confirm_order_core` (viva: `20261062000001_ventas_unidades_conversion.sql:1118-1583`), que es el núcleo que confirma la venta. Las pantallas de órdenes son de sólo lectura, así que un botón "Venta" montado sobre `accept` dejaría una orden colgada que nadie ve.
- **Endpoints**: existen `GET/POST /quotes`, `GET /quotes/{id}`, `POST /quotes/{id}/transition` y `/accept` (`backend/routers/quotes.py`). **No hay** edición, borrado, PDF ni envío. El alta escribe por `INSERT` directo (`backend/repositories/quote_repository.py:31-94`), con tres problemas:
  - **no numera**;
  - no valida la tenencia del `product_id`: el `INSERT … SELECT` copia `name/sku/cost` de un producto de cualquier cuenta;
  - las transiciones hechas por `UPDATE` directo **no registran historial** (RN-A1).
- **Frontend**: los hooks de `frontend/hooks/data/use-quotes.ts` están completos pero **huérfanos**. No existe `/presupuestos`.
- **Número y validez**: los presupuestos **no tienen número** visible ni validez por defecto, y ningún proceso los vence. Sólo existe el chequeo perezoso dentro de `rpc_accept_quote`.

Falta cerrar el circuito completo: crear → descargar o mandar por WhatsApp → modificar → convertir en venta con un solo toque.

## What Changes

- **Pantallas de presupuestos** (hoy no hay ninguna):
  - `/presupuestos`: listado paginado con filtros por estado, búsqueda por cliente o número y badge "Vencido".
  - `/presupuestos/nuevo`.
  - `/presupuestos/[id]`: detalle y acciones.
  - `/presupuestos/[id]/editar`.
  - Entrada **"Presupuestos"** en el sidebar (grupo *Operaciones*, entre "POS — Venta Rápida" y "Compras").
  - Acción **"Nuevo presupuesto"** en la ficha del cliente (`/clientes/[id]`), con el cliente preseleccionado.
- **Alta y edición con el editor de líneas de la venta**:
  - Buscador de productos, lector de códigos, etiquetas de balanza, unidades, descuento por línea y alta de cliente en el lugar. Reutiliza los componentes compartidos: `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput`, `resolveScan` y `lib/cart-utils`.
  - **Cliente obligatorio.**
  - Crear o editar un presupuesto **nunca** toca stock, caja ni cuenta corriente. El stock insuficiente no bloquea: sólo se informa.
- **Edición mientras no esté convertido** (requisito firmado):
  - Mientras no esté convertido se pueden cambiar las líneas, el cliente, la validez y las notas. Las líneas se reemplazan de forma atómica y los snapshots se vuelven a tomar.
  - Un presupuesto aceptado (convertido en venta) es **inmutable**: `P0423`, el mismo principio que la venta con comprobante o dinero posteado. Uno vencido o rechazado se puede editar, y la edición lo **reabre** como borrador (dos filas nuevas en el catálogo de transiciones).
- **Numeración interna visible** `P-00000001`, correlativa por cuenta. Nace la tabla genérica `internal_document_sequences`, que reusarán los remitos. La asigna un disparador, así que ningún escritor puede saltearla.
- **Validez con vencimiento automático**:
  - Validez por defecto configurable por cuenta (`accounts.default_quote_validity_days`, 15 días), editable en cada presupuesto y ampliable mientras esté abierto.
  - Un barrido diario de `pg_cron` pasa a `expired` los vencidos, con la transición de sistema ya sembrada. La API, además, deriva `is_expired` al leer.
  - El campo de configuración vive en la pestaña **Cobranzas** de `/configuracion`, junto al plazo de pago.
- **Escritura sólo por RPC** (`rpc_create_quote`, `rpc_update_quote`, `rpc_transition_quote`, `rpc_delete_quote`):
  - guards de tenencia sobre cliente, productos y unidades;
  - historial en la misma transacción;
  - total calculado en el servidor.
  - Se retiran las políticas de `INSERT`/`UPDATE` directo sobre `quotes`/`quote_items`, que hoy sólo usa el repositorio que se reemplaza. **BREAKING** interno, sin consumidores fuera del backend.
- **PDF del presupuesto** por id y con tenencia (`GET /quotes/{id}/pdf`, fpdf2):
  - Lo genera un constructor compartido, `build_commercial_document_pdf`, que nace para el presupuesto y queda listo para el remito.
  - Contenido: datos del emisor (perfil fiscal o, si no hay, perfil del negocio), número, fechas de emisión y validez, cliente, líneas con su unidad, total, notas y la leyenda *"Presupuesto — documento no válido como factura"*.
- **Descarga y envío por WhatsApp**: componente compartido `DocumentShareMenu` (Ver/Imprimir, Descargar PDF, Enviar por WhatsApp), con el mismo mecanismo que el comprobante de venta:
  - en el celular, comparte el PDF adjunto;
  - en escritorio, descarga el PDF y abre `wa.me/<teléfono del cliente>` con un texto corto;
  - si el cliente no tiene teléfono, abre el selector de contacto de WhatsApp.
  - Los helpers se extraen de `sale-receipt-button.tsx` a `lib/`.
  - Descargar o enviar un presupuesto en `draft` lo marca `sent`.
- **Botón "Venta"** — RPC nueva `rpc_convert_quote_to_sale`, que acepta el presupuesto y confirma la venta en **una sola transacción**:
  - Reutiliza la aceptación, extraída a un núcleo interno que comparte con `rpc_accept_quote` (esa RPC conserva su firma y su comportamiento).
  - Reutiliza `_c29_confirm_order_core` sin tocarlo.
  - La venta resultante descuenta stock, maneja caja, banco y cuenta corriente (con vencimiento), emite `SaleConfirmed` y **es facturable sin cambios**.
  - Usa el precio del presupuesto.
  - Si falta stock, falla con `P0409` y no escribe nada.
  - Es idempotente por `Idempotency-Key`.
  - Diálogo de cierre con sucursal, forma de pago, cuenta bancaria y caja (con efectivo, la caja abierta de la sucursal es obligatoria, como en el POS), reutilizando los selectores del POS y del formulario de venta. Al terminar ofrece "Facturar" (`EmitInvoiceButton`) y "Ver venta". Los campos de cierre nacen en `components/ventas/` para que los reutilicen los remitos.
- **Otras acciones**:
  - **Rechazar**, con motivo opcional.
  - **Duplicar**: crea un presupuesto nuevo con los precios de hoy.
  - **Eliminar**, sólo borradores (la política de borrado permite el hard delete de un `draft`).
- **Trazabilidad**: el detalle del presupuesto enlaza la venta, y la venta muestra "Desde presupuesto P-…".

## Capabilities

### New Capabilities
- `internal-document-numbering`: numeración interna para documentos no fiscales, correlativa y sin huecos por cuenta y tipo (`internal_document_sequences`). La asigna un disparador y se muestra con prefijo. Primer consumidor: presupuestos; queda lista para remitos.
- `commercial-document-pdf`: documento comercial no fiscal que se puede imprimir y compartir. Cubre:
  - el constructor de PDF compartido;
  - la resolución de los datos del emisor, que nunca bloquea la impresión;
  - la leyenda "no válido como factura";
  - el contrato del endpoint por id con tenencia;
  - el menú de compartir (ver, descargar, WhatsApp), calcado del comprobante de venta.

### Modified Capabilities
- `quote`:
  - número visible;
  - validez por defecto configurable y vencimiento automático;
  - cliente obligatorio;
  - escritura sólo por RPC, con guards de tenencia e historial;
  - edición mientras no esté convertido (la de un vencido o rechazado lo reabre) e inmutabilidad del convertido (`P0423`);
  - borrado de borradores y rechazo;
  - conversión atómica a venta (`rpc_convert_quote_to_sale`);
  - PDF y envío;
  - superficie `/presupuestos`.
  - Además se corrige el requirement del ciclo de vida para alinearlo con el catálogo vigente: `draft → accepted` y `draft → rejected` existen desde el seed.
- `sales-order`: la orden nacida de un presupuesto se crea y se confirma en la misma transacción (nunca queda visible en `draft`), y la venta resultante expone su presupuesto de origen en los read models.

## Impact

- **DB**: dos migraciones, una por tanda de apply (renumerar si otro PR toma los números).
  - `20261067000001_presupuestos_modulo.sql` (tanda A, sin dinero):
    - columnas `number`, `notes`, `sent_at`, `updated_at` y `updated_by` en `quotes`;
    - `accounts.default_quote_validity_days`;
    - tabla `internal_document_sequences`, helper `_next_internal_document_number` y disparador de numeración;
    - RPCs `rpc_create_quote`, `rpc_update_quote`, `rpc_transition_quote`, `rpc_delete_quote` y `rpc_set_default_quote_validity`;
    - retiro de las políticas de escritura directa;
    - barrido `_expire_overdue_quotes` + `cron.schedule`.
  - `20261068000001_presupuestos_conversion_venta.sql` (tanda B, dinero):
    - núcleo interno `_quote_accept_core`, extraído del cuerpo **vivo** de `rpc_accept_quote`. `rpc_accept_quote` pasa a ser un wrapper con la misma firma, el mismo `COMMENT` y las mismas ACLs;
    - RPC `rpc_convert_quote_to_sale`.
  - Gates SQL nuevos que **ejecutan** las RPCs (incluidos dos scripts de carrera: conversión y numeración), cableados en `KPI_Validation.yml`; `test_function_acl_gate.sql` extendido y `test_document_status_transition_role_matrix.sql` y el bloque (7) de `test_operacion_party_guard.sql` actualizados.
- **Backend**:
  - `schemas/quotes.py`, `services/quotes.py`, `repositories/quote_repository.py` y `routers/quotes.py`, reescritos sobre las RPCs, con `require_account_role` y la capacidad nueva `CAN_QUOTE` en `core/rbac.py`.
  - Endpoints nuevos: `PUT /quotes/{id}`, `DELETE /quotes/{id}`, `GET /quotes/{id}/pdf`, `POST /quotes/{id}/convert` (con `Idempotency-Key`) y `GET/PATCH /settings/quotes`. El listado pasa a ser paginado. Se **retira** `POST /quotes/{id}/accept`, sin consumidores: dejaría un presupuesto aceptado con una orden `draft` invisible.
  - Módulo nuevo `services/commercial_documents/` (vista + PDF), que reutiliza `_latin1`, `_format_amount` y `_format_unit_price` de `services/receipts.py`.
  - Los read models de ventas y órdenes suman el número del presupuesto de origen.
- **Frontend**:
  - `app/(dashboard)/presupuestos/**` (4 rutas).
  - `components/quotes/*`: `QuoteForm`, `QuoteStatusBadge`, `ConvertQuoteDialog`, `QuoteSettingsCard`.
  - `components/shared/DocumentShareMenu.tsx`.
  - `lib/document-share.ts` y `lib/api/document-pdf.ts`, extraídos de `sale-receipt-button.tsx` y `lib/api/fiscal-invoice.ts`, que pasan a consumirlos.
  - `lib/internal-document-number.ts`, `lib/rbac-capabilities.ts` (espejo de `CAN_QUOTE`), `lib/quote-lines.ts` y `lib/query-invalidation.ts`.
  - `lib/cart-utils.ts` gana las funciones de carrito extraídas de `sale-form.tsx` (alta manual, despacho del lector, edición de línea), y `sale-form` pasa a consumirlas.
  - `components/ventas/SaleCheckoutFields.tsx` y `SaleCheckoutSuccess.tsx`; `ClientForm` devuelve el cliente creado; `ClientDetailHeader` suma la pestaña "Presupuestos".
  - `hooks/data/use-quotes.ts` (reescrito), `lib/query-keys.ts` y `lib/operation-errors.ts` (mensajes de presupuesto).
  - `components/app-sidebar.tsx`, `components/dashboard/breadcrumb-nav.tsx`, la ficha del cliente, la pestaña Cobranzas de `/configuracion` y el badge de origen en `/ventas`.
- **Superficie frontend** (regla del PO 2026-08-02):
  - Operaciones → **Presupuestos**: `/presupuestos`, `/presupuestos/nuevo`, `/presupuestos/[id]` y `/presupuestos/[id]/editar`.
  - `/clientes/[id]` → "Nuevo presupuesto".
  - `/configuracion?tab=cobranzas` → validez por defecto.
  - `/ventas` → "Desde presupuesto P-…".
  - Verificación en desktop y a 375 px, en tema claro y oscuro.
- **Governance: MEDIA con un tramo ALTO.**
  - La tanda A (pantallas, PDF, WhatsApp, numeración, vencimiento) no toca dinero.
  - La tanda B (conversión) escribe stock, caja, banco, cuenta corriente y outbox a través del núcleo del POS. Lleva checkpoint de integridad de función a partir del `pg_get_functiondef` vivo, un gate que ejecuta la conversión con matriz de evasión y revisión adversarial antes del merge.
- **Plan**: sin gate; disponible en todos los tiers, igual que ventas y compras.
- **Riesgos principales** (detalle en `design.md`):
  - doble conversión concurrente;
  - replay de la clave de idempotencia contra otro presupuesto;
  - orden de locks: `quotes` antes de `sales` → `sales_orders` → `fiscal_documents`;
  - producto dado de baja o sin stock al convertir;
  - reescribir `rpc_accept_quote` sobre un cuerpo que no sea el vivo;
  - que el retiro de las políticas de escritura directa rompa un camino que nadie listó. Checkpoint: grep de escritores + gates existentes que insertan en `quotes`.
- **Fuera de alcance**:
  - remitos de venta y de compra: changes propios (`remitos-venta` → `remitos-compra`), que reutilizan la numeración, el PDF y el menú de compartir que nacen acá;
  - link público, aceptación online del cliente y email;
  - el pedido (`sales_orders`) como pantalla propia: queda como detalle interno de la conversión;
  - reservar stock al presupuestar;
  - presupuesto → remito;
  - migrar el comprobante interno de venta y el POS al constructor y al carrito compartidos (quedan como candidatos);
  - IA sobre presupuestos;
  - importador CSV.
