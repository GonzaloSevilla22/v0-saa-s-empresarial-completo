# Explore — Presupuestos y Remitos (venta y compra)

> Modo `openspec-explore`: pensar, no implementar. Fecha: 2026-09-29. `openspec list` vacío al momento del explore.
>
> **Pedido del PO (textual)**: «lo siguiente que necesito que hagas son 2 cosas, el módulo remito tanto de venta como de compra y el módulo presupuesto que se crea un presupuesto para un cliente y se descarga para enviárselo o se envía por WhatsApp si está el número y si éste acepta el presupuesto que haya un botón que sea venta que si se toca se envía a venta automáticamente con todos los productos que tiene, y quiero lo mismo para remito pero que éste sí baje de stock; cuando se crea el presupuesto no.»
>
> **Lectura del pedido** (la que usa todo este documento):
> - **Presupuesto**: se crea para un cliente → se descarga (PDF) o se manda por WhatsApp si el cliente tiene teléfono → si el cliente acepta, un botón **"Venta"** lo convierte en una venta con todos sus productos. **Crear el presupuesto NO mueve stock**; el stock se mueve recién en la venta.
> - **Remito** (de venta y de compra): el mismo circuito (crear → descargar/WhatsApp → botón que lo convierte en venta / compra), con una diferencia: **el remito SÍ mueve stock al crearse** (el de venta lo descuenta, el de compra lo suma). La venta/compra que nace del remito **no** vuelve a moverlo.
>
> ⚠️ Uno de los cuatro mapas de insumo (el de KB/roadmap) leyó al revés la parte del remito ("remito que NO baje stock al crearse"). Este documento sigue la lectura literal del pedido: el remito **sí** baja (venta) / sube (compra) stock al crearse.

---

## 1. Lo que existe hoy

### 1.1 Presupuestos (`quotes`): backend completo, **0 % de UI**

| Pieza | Dónde | Estado |
|---|---|---|
| Tablas `quotes` / `quote_items` | `supabase/migrations/20260702000001_c29_quote_salesorder.sql:82-234` | `quotes`: `id, account_id, branch_id, client_id, status (draft\|sent\|accepted\|expired\|rejected), valid_until, total, created_by, created_at`. **No tiene número** visible para el cliente. RLS sólo `SELECT`; escritura vía RPC. |
| Snapshots de línea | `20260806000001_v3_snapshot_pattern.sql` | `quote_items` tiene `name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot`, que se propagan a `sales_order_items`. |
| Spec | `openspec/specs/quote/spec.md` (6 requirements) | `:11` ciclo de vida; `:27` "la creación/edición NO SHALL tener efecto sobre `branch_stock` ni caja"; `:37` `accept()` crea un `SalesOrder` con los mismos ítems y **NO descuenta stock ni caja**; `:63` snapshot congelado; expiración; historial en `document_status_history`. |
| RPC `rpc_accept_quote` (viva) | `supabase/migrations/20261045000001_operacion_party_guard.sql:1677-1820` | Valida auth, tenencia (incluye guard de `client_id` ajeno), estado `draft\|sent` y que no esté vencido (`reporting_local_today()`). Crea `sales_orders` en **`status='draft'`** (comentario literal ~L1755: "sin tocar stock aún"), copia las líneas con snapshots, pasa el quote a `accepted`, registra el historial de ambos documentos y emite `QuoteAccepted` al outbox. **No llama a `_c29_confirm_order_core`.** |
| FSM (catálogo) | `20260807000001_v3_document_status_history.sql:85-129`; roles en `20261048000001_v3_rbac_multirole_parte_b.sql:403-408` | Transiciones de `quote`: `NULL→draft`, `draft→sent`, `draft\|sent→accepted`, `draft\|sent→rejected` (roles `seller/admin/owner`); `draft\|sent→expired` con `allowed_role NULL` (transición de **sistema**). `document_type` es un `CHECK` cerrado: `quote, sales_order, fiscal_document, cash_session, reconciliation_session, stock_transfer`. |
| Expiración | — | **No hay cron** que expire presupuestos (grep de `cron.schedule` + quote: 0 resultados). Sólo el chequeo perezoso dentro de `rpc_accept_quote`. |
| Endpoints | `backend/routers/quotes.py` | `GET /quotes`, `POST /quotes` (crea draft), `GET /quotes/{id}`, `POST /quotes/{id}/transition` (send/reject/expire), `POST /quotes/{id}/accept`. **No hay** edición (`PUT/PATCH`), borrado, PDF ni envío. Sin `require_plan`; el rol se controla en la FSM (`record_status_transition`). Schema: `backend/schemas/quotes.py` (`price` por línea, `valid_until` opcional, ítems no vacíos). |
| Hooks frontend | `frontend/hooks/data/use-quotes.ts` | `useQuotes/useQuote/useCreateQuote/useTransitionQuote/useAcceptQuote` completos y **huérfanos** (ninguna página los importa). |
| UI | — | **No existe** `/presupuestos` ni `/quotes` en `frontend/app`. `CHANGES.md:974` lo declara: "Vista de presupuestos UI — diferida del C-29 apply. Candidata para change propio". El candidato `v4-producto-calidad-09` (CHANGES.md:3049-3064) nunca se ejecutó. |
| Tests | `backend/tests/test_c29_quote_salesorder.py` | Cubre accept, confirm y quickSale. No hay tests de UI (no hay UI). |

### 1.2 Pedidos (`sales_orders`) y el núcleo de venta

- **`_c29_confirm_order_core`** (viva: `supabase/migrations/20261062000001_ventas_unidades_conversion.sql:1118-1583`) es el núcleo transaccional real. Confirma una `sales_orders` en `draft` y hace todo esto:
  - gate de stock por sucursal (`:1404-1461`, `P0409`);
  - descuento vía `c21_apply_branch_stock_delta` + `stock_movements(type='sale', reference_type='sale')`;
  - caja (opt-in, tres condiciones);
  - forma de pago del catálogo (`payment_method_id`) y banco;
  - cargo en cuenta corriente para `credit` (helper compartido `_pay_register_party_charge`, con vencimiento por cascada);
  - numeración y outbox.

  Además inserta `sales`/`sale_items` con un `operation_id` **nuevo** y al final hace `UPDATE sales_orders SET status='confirmed', sale_operation_id=…` (`:1566-1573`). Ese es el **único** puente orden→venta (`sales` no tiene `sales_order_id` ni `quote_id`).
- **`rpc_quick_sale`** (viva: `20261003000001_limpiezas_pagos_admin.sql:470`) crea la orden y llama al core (POS).
- **`rpc_create_sale_operation_v2`** (viva: `20261062000001:330-697`) es el camino del formulario `/ventas` y mueve stock por su cuenta (`:529-584`).
- Endpoints: `backend/routers/sales_orders.py` → `GET /sales-orders`, `POST /sales-orders/quick-sale`, `GET /sales-orders/{id}`, `POST /sales-orders/{id}/confirm`, `POST /sales-orders/{id}/emit-invoice`.
- UI: `frontend/app/(dashboard)/ventas/ordenes/page.tsx` y `.../ordenes/[id]/page.tsx:41-112` son **sólo lectura** (badges, CAE). No hay botón "confirmar" ni "convertir". La única creación+confirmación real en la UI es el POS (`ventas/pos/page.tsx`).
- Borrado de venta: `rpc_delete_sale_operation` (viva: `20261061000001_venta_editable_vs_promocion_legacy.sql:1078`) compensa caja, banco y cuenta corriente, **revierte stock vía `rpc_reverse_stock_movement(sale_id,'sale')`** y cancela la `sales_order` (`confirmed→canceled`).
  - Importante para el remito: `rpc_reverse_stock_movement` (`20260828000001_v31_rls_collision_rpcs.sql`) **revierte los `stock_movements` existentes con ese `reference_id`/`reference_type`**. No recalcula desde `sale_items`. Sólo acepta `reference_type IN ('purchase','sale')`.

### 1.3 Compras

- `rpc_create_purchase_operation` (viva: `20261062000001:700-1115`) es una operación **plana de un paso** (no hay `purchase_orders`). Suma stock al registrarse (`:979-1000`, `type='purchase'`), tiene caja opt-in y carga `supplier_accounts` si `kind='credit'`. No existe un agregado "orden de compra" ni `receive()` (diseñado en `modelo-dominio-aliadata-v2.md:483`, nunca construido).
- Proveedores: `/proveedores` + `backend/schemas/suppliers.py` (tiene `phone`).

### 1.4 PDF, descarga, WhatsApp, email, links

| Pieza | Dónde | Qué hace |
|---|---|---|
| PDF genérico de comprobante | `backend/services/receipts.py:189-264` `build_sales_receipt_pdf(SalesReceiptData)` | fpdf2, Helvetica latin-1 (`_latin1` `:160-163`), tabla de ítems + total + encabezado del negocio. Plantilla natural para presupuesto y remito. |
| Endpoint stateless | `backend/routers/sales.py:31-63` `POST /sales/receipt-pdf` | Recibe el payload armado por el cliente, no toca la DB y devuelve el PDF inline. |
| Factura C fiscal | `backend/services/fiscal/invoice_pdf.py:36-460`; spec `openspec/specs/fiscal-invoice-print/spec.md:138` (endpoint `GET /fiscal/documents/{id}/pdf` **con tenencia**, lee de la DB) y `:190` (imprimir/descargar/WhatsApp desde la venta) | Patrón "documento persistido → PDF por id con tenencia": el mejor molde para documentos que ya viven en la DB. Lee los datos del emisor desde `fiscal_profiles`. |
| Botón de comprobante | `frontend/components/ventas/sale-receipt-button.tsx` (437 líneas): `sharePdf` `:86-96`, descarga/impresión `:156-190`, WhatsApp `:271-308` | Descargar/Imprimir usa el HTML de `frontend/lib/receipt.ts` en un blob con nonce CSP. WhatsApp usa la Web Share API con el **archivo PDF** (celular); si no hay Web Share, descarga + `wa.me` con texto corto. |
| Teléfonos | `frontend/lib/phone-utils.ts:34-68` `normalizeWhatsAppPhone`, `:97-106` `buildWhatsAppUrl` | Con número válido → `wa.me/<549…>?text=`; sin número → `wa.me/?text=` (selector de contacto). Ya lo reutiliza `frontend/lib/debt-reminder.ts`. `clients.phone` existe (`frontend/lib/database.types.ts:1590`). |
| Links públicos / Storage firmado | — | **No existe** ningún link público para documentos comerciales. Storage firmado sólo se usa para `exports`, OCR, avatares y certificados AFIP. Todos los comprobantes se generan al vuelo. |
| Email | `backend/services/receipts.py:154-157` + `supabase/functions/send-email` | Sólo el recibo de suscripción de la plataforma. **No hay** email comercio→cliente. |

### 1.5 Remito: **no existe**

`rg -il "remito|delivery_note"` sobre `supabase/`, `backend/`, `frontend/app`, `frontend/components`, `frontend/lib` y `openspec/specs` da un solo hit, que no tiene relación (`frontend/components/invoice/InvoiceUploadZone.tsx`). La única mención de dominio es como fuera de alcance en `openspec/changes/archive/2026-08-23-compras-proveedor-cuenta-corriente/design.md:57`. Es greenfield completo.

Moldes cercanos:
- **`stock-transfer`** (`openspec/specs/stock-transfer/spec.md`): tabla propia + RPC dedicada + `reference_type` propio agregado de forma aditiva al `CHECK` (`20260608000000_branch_stock.sql:38-63`).
- El par `accept` (no mueve stock) / `confirm` (mueve stock).

`CHECK` vigentes de `stock_movements`:
- `type` (`20260608000000_branch_stock.sql:41-51`) incluye `sale, purchase, sale_return, purchase_return, transfer_out, transfer_in, …`.
- `reference_type` (`20260828000001_v31_rls_collision_rpcs.sql:351-357`) = `sale, purchase, adjustment, initial, sale_update, purchase_update, transfer, sale_reversal, purchase_reversal`.

Ninguno de los dos contempla un remito.

### 1.6 Numeración

`document_sequences` (`20260627000001_c27_fiscal_profile.sql:138`) es **fiscal**: va por `point_of_sale_id` + `comprobante_type` y sólo se escribe vía `rpc_next_document_number`. No hay numeración interna por cuenta para documentos no fiscales (los presupuestos hoy no tienen número).

### 1.7 Reglas KB / V3 aplicables

- RN-A1..A5 (`knowledge-base/05_reglas_de_negocio.md:296-309`): FSM como datos en `document_status_transitions`; historial append-only en la misma transacción (incluida la creación `NULL→x`); `reason` obligatorio en las transiciones destructivas.
- RN-100 (`:291-295`): las líneas son inmutables tras confirmar/emitir; una corrección es un documento nuevo.
- RN-21 (`:120-125`): ledger de stock inmutable, contramovimientos `*_return` / `*_reversal`.
- RN-24 (`:142-150`): toda escritura de stock normaliza unidades (`_uom_normalize_quantity`), incluso "una función futura".
- RN-90: stock, caja y numeración son atómicos en la misma transacción.
- Política de borrado por categoría (`:326-332`): un borrador se puede borrar; un documento confirmado nunca se borra, se anula con motivo.
- Spec `document-snapshots`: el snapshot va en el mismo `INSERT`.
- Spec `operation-delete-compensation`: borrado atómico todo-o-nada; `P0423` (inmutable con fiscal/dinero posteado); `P0425`.
- Reglas del proyecto:
  - superficie frontend obligatoria;
  - reutilizar antes que repetir;
  - toda RPC que otras invocan necesita un gate SQL que la **ejecute**;
  - las RPCs se reescriben desde el `pg_get_functiondef` **vivo**, conservando el `COMMENT`;
  - `DROP`+`CREATE` resetea las ACLs;
  - orden global de locks `sales → sales_orders → fiscal_documents`.

---

## 2. Brecha contra el pedido

### 2.1 Presupuesto

| Paso del pedido | Hoy | Falta |
|---|---|---|
| Crear para un cliente | `POST /quotes` (client_id opcional) | UI de alta que reutilice el editor de líneas del formulario de venta (buscador de productos, unidades, PLU/balanza). Cliente **obligatorio**, número visible, validez por defecto y edición mientras esté en `draft`/`sent` (hoy no hay endpoint). |
| Descargar | — | PDF de presupuesto (endpoint por id con tenencia) + "Imprimir". |
| Enviar por WhatsApp si hay número | — | Menú compartir que reutilice `sharePdf` + `buildWhatsAppUrl`. Al enviar o descargar, marca `draft→sent`. |
| Cliente acepta → botón "Venta" | `accept()` deja una orden **draft** sin stock ni caja | Un paso atómico accept + confirm, con forma de pago, caja y cuenta corriente, y su UI (diálogo de cierre de venta). Sin esto, el botón crearía una orden colgada que nadie ve (las pantallas de órdenes son de sólo lectura). |
| Sin stock hasta la venta | ✅ ya lo garantizan la spec y la RPC | Nada. El gate de stock corre en la conversión y puede fallar con `P0409`; la UI tiene que explicarlo. |
| Listado / seguimiento | — | `/presupuestos` con filtros por estado, vencidos, rechazar y duplicar (opcional). |
| Vencimiento | `valid_until` + chequeo perezoso | Validez por defecto, estado "vencido" visible, cron o derivación. |

### 2.2 Remito de venta

Falta todo:
- tabla(s), numeración y FSM;
- RPC de creación que **descuenta stock** (gate `P0409`, RN-24, `stock_movements` con `reference_type` nuevo);
- anulación con contramovimiento;
- PDF y WhatsApp;
- conversión a venta **sin** volver a descontar;
- vínculo remito↔venta;
- reglas de borrado y edición de la venta nacida del remito;
- UI.

### 2.3 Remito de compra

Igual que el de venta, pero con stock **positivo** y sin gate. Cambia además lo siguiente:
- proveedor en lugar de cliente;
- la conversión es a **compra**, con `rpc_create_purchase_operation`, que hoy siempre suma stock: hay que lograr que no lo vuelva a sumar;
- la cuenta corriente del proveedor la toca la compra, no el remito;
- no hay precedente de "documento de compra previo" (no existe `purchase_orders`).

---

## 3. Opciones de diseño y recomendación

### (a) Presupuesto → venta

| Opción | Pros | Contras |
|---|---|---|
| **A1. RPC atómica nueva `rpc_convert_quote_to_sale`** = cuerpo de `rpc_accept_quote` + `_c29_confirm_order_core` en **una** transacción, con los parámetros de cobro del core (forma de pago, sesión de caja, banco, canal, sucursal) | Reutiliza el núcleo real (stock, caja, banco, cuenta corriente con vencimiento, outbox, idempotencia). No deja una "orden draft huérfana". La venta queda como `sales_order` confirmada, así que **"Facturar" funciona sin cambios** (`/emit-invoice`). Mantiene el modelo V3 (Quote → SalesOrder). | RPC `SECURITY DEFINER` nueva que escribe dinero → necesita un gate SQL que la ejecute; hay que respetar el orden de locks. |
| A2. Dos requests desde el front (`accept` y después `confirm`) | Cero SQL nuevo | Si el segundo falla (p. ej. `P0409` por falta de stock), quedan el presupuesto en `accepted` y una orden `draft` invisible, sin forma limpia de reintentar. |
| A3. Pre-cargar el formulario `/ventas` y crear con `rpc_create_sale_operation_v2` | Máxima flexibilidad (editar antes de vender, vencimiento editable) | Pierde el vínculo presupuesto→venta (`sales` no tiene columna de origen), duplica el camino y rompe la spec `quote` (accept crea un SalesOrder). |

**Recomendación: A1.**
- El botón "Venta" abre un **diálogo de cierre** con las líneas del presupuesto en sólo lectura. Reutiliza `PaymentMethodSelect`, el opt-in de caja y el selector de sucursal del POS/formulario.
- Al confirmar, llama a `rpc_convert_quote_to_sale`.
- Si el cliente pidió cambios, primero se **edita el presupuesto** (se permite en `draft`/`sent`) y después se convierte.
- El precio de la venta es el snapshot del presupuesto (lo que se le prometió al cliente), no el precio actual del catálogo (OQ-P3).
- `rpc_accept_quote` se conserva por compatibilidad, pero la UI no la usa sola.

### (b) PDF

| Opción | Recomendación |
|---|---|
| **B1. fpdf2 en el backend, por id y con tenencia** (`GET /quotes/{id}/pdf`, `GET /delivery-notes/{id}/pdf`), con `Content-Disposition` inline/attachment y datos leídos de la DB (molde `fiscal-invoice-print`) | **Recomendada.** El documento vive en la DB: hay una sola fuente de verdad y el cliente no arma el contenido. Se generaliza `build_sales_receipt_pdf` a un `build_commercial_document_pdf(kind=…)` en `backend/services/receipts.py` (capa canónica), con la leyenda "Documento no válido como factura". El encabezado del negocio sale de los datos del emisor que ya carga `factura-fiscal-imprimible`. |
| B2. HTML + `window.print()` en el navegador (`lib/receipt.ts`) | Sirve sólo para "Imprimir": no produce un archivo para compartir por WhatsApp. "Imprimir" se puede resolver abriendo el PDF inline. |

### (c) Envío

| Opción | Recomendación |
|---|---|
| **C1. Patrón existente**: Web Share con el **archivo PDF** (en el celular, WhatsApp recibe el PDF adjunto). En escritorio: descarga + `wa.me/<tel>?text=` con texto corto. Sin teléfono: `wa.me/?text=` | **Recomendada para v1.** No suma superficie de seguridad y ya está probado en producción. Se extrae un componente compartido `DocumentShareMenu` (Descargar / Imprimir / WhatsApp) desde `sale-receipt-button.tsx`; lo consumirían el presupuesto, el remito y, más adelante, la venta. |
| C2. Link público firmado (página `/p/<token>` o PDF en un bucket con URL firmada y vencimiento) | Diferir a v2. Es una capability nueva: ruta pública fuera de `PROTECTED_PREFIXES`, token no adivinable con vencimiento y revocación, rate limit, CSP y exposición de datos del cliente a cualquiera que tenga el link. Merece su propio change con governance ALTA. |
| Email | Diferir: hoy no hay canal comercio→cliente; el canal establecido es WhatsApp. |

### (d) Remito como documento propio

**Recomendación:**

- **Una sola tabla para los dos sentidos.**
  - `delivery_notes` con: `id, account_id, branch_id NOT NULL, direction ('sale'|'purchase')`; `client_id` (venta) o `supplier_id` (compra), con un `CHECK` de coherencia; `number` interno, `status`, `date`, `notes`, `show_prices`; `sale_operation_id` / `purchase_operation_id` (puente al documento convertido); `canceled_reason`, `created_by`, `created_at`.
  - `delivery_note_items` con: `product_id, unit_id, quantity numeric(15,4), price, subtotal` + los 4 snapshots, en el mismo `INSERT`.
  - RLS sólo `SELECT`; escritura sólo por RPC.

- **FSM** con `document_type='delivery_note'` nuevo (hay que ampliar los dos `CHECK` de `document_status_history` y `document_status_transitions`):
  - `NULL→issued`: al crear, **mueve stock**.
  - `issued→invoiced`: convertido en venta o compra.
  - `invoiced→issued`: se borró la venta/compra nacida del remito. El remito vuelve a quedar pendiente y la mercadería sigue entregada.
  - `issued→canceled`: anulación, con `requires_reason`, **revierte stock**.
  - No hay estado `draft` en v1: el remito se emite directamente, que es lo que pide el PO ("baja stock cuando se crea").
  - Roles: venta `seller/stock/admin/owner`; compra `stock/admin/owner` (OQ-R7).

- **Stock:**
  - `rpc_create_delivery_note`, por cada línea: normaliza con `_uom_normalize_quantity` (RN-24); aplica el gate `branch_stock >= cantidad` (`P0409`) sólo si `direction='sale'`; mueve con `c21_apply_branch_stock_delta` (negativo o positivo); registra `stock_movements(type='sale'|'purchase', reference_type='delivery_note', reference_id=delivery_note_id)`.
  - Anulación: contramovimiento `sale_return`/`purchase_return` con `reference_type='delivery_note_reversal'`. Se extiende `rpc_reverse_stock_movement` a `'delivery_note'` o se hace un helper espejo.
  - Son dos valores nuevos, aditivos, en el `CHECK` de `reference_type`.
  - ⚠️ En el propose: grep de los consumidores de `stock_movements.type='sale'` para confirmar que ninguno asume "type sale ⇒ existe una fila en `sales`". Si alguno lo asume, usar `type` nuevos (`delivery_out`/`delivery_in`).

- **Numeración interna:**
  - Tabla nueva `internal_document_sequences(account_id, document_type, last_number)` con `rpc_next_internal_number` (`SECURITY DEFINER`, `FOR UPDATE`).
  - La consumen presupuestos **y** remitos (dos consumidores reales). No se toca `document_sequences`, que es fiscal y va por punto de venta.
  - Formato visible `P-00000001` / `R-00000001` (OQ-P2).

- **Conversión sin doble movimiento de stock** (el punto más delicado):
  - **Venta:** `rpc_convert_delivery_note_to_sale` crea la `sales_order` con `source_delivery_note_id` (columna nueva) y llama a `_c29_confirm_order_core`.
    - El core **se salta el gate y el movimiento de stock cuando la orden tiene `source_delivery_note_id`**.
    - La decisión se **deriva de los datos** de la orden y **nunca de un parámetro público**: un caller no puede pedir "no muevas stock".
    - Las líneas se copian del remito, no del request.
  - **Borrado de la venta:** la venta resultante no tiene `stock_movements` propios. Por eso `rpc_delete_sale_operation` **no devuelve stock** al borrarla (la reversa va por movimientos existentes, no por `sale_items`) y el remito vuelve a `issued`. Es lo correcto: la mercadería sigue en manos del cliente, y para devolver stock se anula el remito.
  - **Edición de una venta nacida de un remito:** el espejo REVERSE+APPLY de `stock-movements-edicion` volvería a mover stock.
    - En v1 se **bloquea la edición de líneas** con `P0423`: "venta originada en el remito N°…; anulá la venta y corregí el remito".
    - La cabecera (forma de pago, etc.) sigue las reglas vigentes de `operation-edit-context`.

- **Remito `invoiced`:** inmutable y no anulable (`P0423`) hasta que se borre la venta/compra.
- **Edición de un remito `issued`:** no en v1. Se anula y se rehace (seguro para el ledger: una sola ruta de reversión).
- **Non-goals v1:** remito parcial, varios remitos → una factura, presupuesto → remito y venta → remito. En v1, 1 remito → 1 venta con todas las líneas.

### (e) Remito de compra ↔ proveedores y cuenta corriente

- `supplier_id` **obligatorio**. Además del número interno, el número del remito del proveedor queda como campo opcional (`supplier_reference`).
- El remito de compra **no toca dinero** (ni caja ni `supplier_accounts`). La compra nacida del remito sí lo toca con todo lo que ya hace `rpc_create_purchase_operation`: forma de pago del catálogo, caja opt-in y cargo en la cuenta corriente del proveedor si es `credit`.
- **Conversión** con `rpc_convert_delivery_note_to_purchase`. `rpc_create_purchase_operation` es monolítica (24 migraciones la tocaron), así que se recomienda:
  - **extraer un núcleo interno** `_purchase_operation_core(…, p_source_delivery_note_id)`, sin `EXECUTE` para `authenticated` y cubierto por el chequeo (4) del gate de ACLs;
  - dejar la firma pública **idéntica**, como wrapper;
  - que el núcleo salte el stock sólo si recibe un remito `issued` de la misma cuenta, proveedor y sucursal (validado adentro);
  - sumar a `purchases` la columna `source_delivery_note_id` (nullable), para el vínculo y para el `P0423` de edición de líneas;
  - hacer el checkpoint de integridad de función partiendo del `pg_get_functiondef` vivo.
- **Borrado de la compra nacida del remito:** `rpc_delete_purchase_operation` revierte por movimientos, así que no toca stock, y el remito vuelve a `issued`.
- **Anulación del remito de compra:** resta el stock, que puede quedar negativo si ya se vendió (OQ-R6).

### (f) Aceptación del presupuesto

**Recomendación v1: aceptación manual.**
- El comercio toca "Venta" cuando el cliente le confirma (por WhatsApp o en persona).
- El estado `accepted` existe sólo como consecuencia de la conversión atómica.
- Se suma un botón "Rechazar" (con motivo opcional).
- **El link público donde el cliente acepta queda para v2:** tiene la misma superficie de seguridad que el link firmado de (c) y, además, implica una escritura anónima sobre la FSM.

### (g) Vencimiento del presupuesto

- Validez por defecto configurable por cuenta (`accounts.default_quote_validity_days`, default 15, OQ-P4) y editable en cada presupuesto (`valid_until`).
- **Barrido diario con `pg_cron`** que pasa los `draft|sent` vencidos a `expired` usando las transiciones de sistema ya sembradas (`allowed_role NULL`). Es el mismo patrón que `cobranzas-overdue-digest-sweep`.
- La conversión ya rechaza los vencidos. Para vender uno vencido: "Duplicar" (presupuesto nuevo con precios de hoy) o extender la validez (OQ-P5).

### (h) Permisos y plan

- Roles por FSM. Para `quote` ya existe: `seller/admin/owner`. La conversión también usa la transición `sales_order draft→confirmed`, que admite `cashier`. Para el remito hacen falta filas nuevas en `document_status_transitions` con su `allowed_role`.
- En el router, `require_account_role` como el resto de los ABM, y tenencia explícita por `account_id` en todos los repositories (regla dura desde el incidente #446).
- **Plan: sin gate** (todos los tiers), igual que ventas y compras (OQ-P8).

---

## 4. Split propuesto en changes

| # | Change | Alcance | Depende de | Governance |
|---|---|---|---|---|
| 1 | **`presupuestos-modulo`** | UI completa de presupuestos, número interno, edición en draft/sent, validez y cron de vencimiento, PDF por id, menú compartir (WhatsApp) y botón "Venta" con la RPC atómica `rpc_convert_quote_to_sale`. Acá nacen, en capa canónica, las 3 piezas compartidas: `internal_document_sequences`, `build_commercial_document_pdf` y `DocumentShareMenu`. | — | **MEDIA con tramo ALTO** (la conversión escribe stock, caja, banco y cuenta corriente vía el core). Apply en dos tandas: A = UI/PDF/WhatsApp/numeración (sin dinero); B = conversión. |
| 2 | **`remitos-venta`** | Tablas `delivery_notes`/`delivery_note_items` (ya con `direction` para los dos sentidos), FSM `delivery_note`, `rpc_create_delivery_note` (stock −), anulación (stock + contramovimiento), PDF/WhatsApp, `rpc_convert_delivery_note_to_sale` con el salto de stock derivado de `sales_orders.source_delivery_note_id` dentro de `_c29_confirm_order_core`, `P0423` de edición de líneas y vuelta a `issued` al borrar la venta. | 1 (reusa numeración, PDF, share y el diálogo de cierre de venta) | **MEDIA con tramo ALTO** (escribe el ledger de stock y reescribe `_c29_confirm_order_core`, hot path del POS). |
| 3 | **`remitos-compra`** | `direction='purchase'`: creación con stock +, anulación, proveedor obligatorio + número del proveedor, extracción de `_purchase_operation_core`, `rpc_convert_delivery_note_to_purchase`, `purchases.source_delivery_note_id`, `P0423` de edición de líneas y pestaña "De compra". | 2 (tabla, FSM y RPC de creación) | **MEDIA con tramo ALTO** (refactor de `rpc_create_purchase_operation` + ledger de stock + dinero de la compra). |

Alternativa considerada: un solo change `remitos` (venta+compra). Se descarta por tamaño: tocaría a la vez los dos núcleos de escritura (venta y compra) y duplicaría la superficie de revisión adversarial.

### Superficie frontend por change

1. **`presupuestos-modulo`**
   - Sidebar: entrada **"Presupuestos"** en el grupo *Operaciones*, entre "POS — Venta Rápida" y "Compras" (`frontend/components/app-sidebar.tsx:71-74`), y breadcrumb en `breadcrumb-nav.tsx`.
   - `/presupuestos`: listado con filtros de estado, búsqueda por cliente o número y badge "Vencido".
   - `/presupuestos/nuevo`.
   - `/presupuestos/[id]`: detalle con acciones Editar (si `draft|sent`), Descargar/Imprimir, WhatsApp, **Venta**, Rechazar y Duplicar.
   - Diálogo "Convertir en venta" (forma de pago, caja, sucursal). Al terminar navega a la venta creada, que ya ofrece comprobante y "Facturar".
   - Desde `/clientes`, acción "Nuevo presupuesto" con el cliente preseleccionado (opcional, OQ-P7).
   - Configuración: campo "validez por defecto de los presupuestos" en la pestaña de `/configuracion` que corresponda (se decide en el propose).
   - Verificación en desktop + mobile, tema claro + oscuro.
2. **`remitos-venta`**
   - Sidebar: entrada **"Remitos"** en *Operaciones*.
   - `/remitos` con pestañas **De venta** / **De compra**. Hasta el change 3, la de compra aparece vacía, deshabilitada u oculta (se decide en el propose).
   - `/remitos/nuevo?tipo=venta`.
   - `/remitos/[id]`: Descargar/Imprimir, WhatsApp, **Venta** y Anular con motivo.
   - En `/ventas` (detalle y listado): badge "Desde remito R-…" con link, y mensaje de `P0423` accionable en `operation-errors.ts`.
3. **`remitos-compra`**
   - Pestaña **De compra** en `/remitos`.
   - `/remitos/nuevo?tipo=compra` con proveedor obligatorio + número del proveedor, y botón **Compra**.
   - En `/compras`: badge "Desde remito R-…" con link.

### Non-goals (los tres changes)

- Link público y aceptación online por el cliente.
- Email.
- Remito legal "R" con CAI o remito electrónico de ARCA.
- Remito parcial, o varios remitos → una factura.
- Presupuesto → remito y venta → remito.
- Orden de compra formal.
- Edición de un remito emitido.
- Importador CSV.
- IA sobre presupuestos.
- Reservar stock al presupuestar.

---

## 5. Open Questions para el PO

### Presupuesto

- **OQ-P1** — ¿El cliente es obligatorio? *Recomendación*: sí (el pedido dice "para un cliente" y sin cliente no hay teléfono para WhatsApp). Alta inline de cliente desde el formulario, reutilizando el componente que ya existe.
- **OQ-P2** — ¿Número visible (P-00000001) por cuenta, único para todas las sucursales? *Recomendación*: sí, correlativo por cuenta.
- **OQ-P3** — Al convertir, ¿precio del presupuesto o precio actual del catálogo? *Recomendación*: el del presupuesto (lo prometido). Si el precio cambió, se edita el presupuesto antes de convertir.
- **OQ-P4** — Validez por defecto. *Recomendación*: 15 días, configurable por cuenta y editable en cada presupuesto.
- **OQ-P5** — ¿Se puede vender un presupuesto vencido? *Recomendación*: no directamente; "Duplicar" (precios de hoy) o extender la validez mientras siga en `draft|sent`.
- **OQ-P6** — ¿Envío v1 sólo por WhatsApp y descarga (sin link público ni email)? *Recomendación*: sí; el link público y la aceptación online van en un change posterior.
- **OQ-P7** — ¿Acción "Nuevo presupuesto" desde la ficha del cliente? *Recomendación*: sí, es barata.
- **OQ-P8** — ¿Disponible en todos los planes? *Recomendación*: sí, sin gate (igual que ventas).

### Remito

- **OQ-R1** — ¿Alcanza con un remito **interno / "X"** ("documento no válido como factura") o necesitás el remito legal "R" (con CAI o electrónico de ARCA) para el traslado de mercadería? *Recomendación*: v1 interno; el legal es un change aparte con ARCA.
- **OQ-R2** — ¿El remito muestra precios en el PDF? *Recomendación*: los precios se guardan siempre (hacen falta para convertirlo en venta/compra); el PDF sale **sin precios por defecto**, con la opción "mostrar precios".
- **OQ-R3** — Anular un remito devuelve el stock. ¿Se exige motivo? *Recomendación*: sí (RN-A5).
- **OQ-R4** — ¿Se puede editar un remito emitido? *Recomendación*: no en v1: se anula y se rehace (un solo camino de reversión de stock).
- **OQ-R5** — ¿Qué pasa al borrar la venta/compra nacida del remito? *Recomendación*: el remito vuelve a "pendiente de facturar" y el stock **no** vuelve (la mercadería ya se entregó o recibió). Para devolver stock se anula el remito.
- **OQ-R6** — Anular un remito de compra cuya mercadería ya se vendió puede dejar stock negativo. *Recomendación*: bloquearlo con el mismo gate `P0409` (no se puede sacar lo que no hay).
- **OQ-R7** — Roles: ¿quién puede emitir remitos? *Recomendación*: venta `seller/stock/admin/owner`; compra `stock/admin/owner`; anular, sólo `admin/owner`.
- **OQ-R8** — ¿Remito parcial, o varios remitos en una sola venta/factura? *Recomendación*: no en v1 (1 remito → 1 venta con todas las líneas).

---

## 6. Riesgos y verificaciones

### Riesgos

1. **Doble movimiento de stock** (remito + venta/compra). Mitigación: el salto se deriva de la FK de origen dentro del núcleo, nunca de un parámetro, y un gate SQL con matriz de evasión cubre estos casos: llamar a la RPC pública de venta/compra con un remito ajeno, con uno `canceled`, con uno ya `invoiced`, y dos conversiones concurrentes del mismo remito.
2. **Reescritura de `_c29_confirm_order_core` y de `rpc_create_purchase_operation`** (hot path del POS y de compras). Mitigación:
   - partir del `pg_get_functiondef` vivo, comparando por líneas con `\r` quitado (gotcha CRLF);
   - conservar el `COMMENT`;
   - re-`REVOKE`/`GRANT` después de `DROP+CREATE`;
   - gate de integridad de función;
   - sin overloads (`42725`).
3. **Orden de locks**: las conversiones toman `quotes`/`delivery_notes` (`FOR UPDATE`) **antes** de `sales` → `sales_orders` → `fiscal_documents`. El orden nuevo se documenta junto a la regla global.
4. **Conversión concurrente** (dos clics o dos pestañas): `FOR UPDATE` sobre el documento origen + chequeo de estado + `Idempotency-Key` por header (estándar `v3-api-standards`).
5. **Presupuesto con un producto dado de baja** (soft delete) o sin stock al convertir: el core falla con `P0409`/`P0404` y se revierte todo. Hacen falta mensajes accionables en `operation-errors.ts`.
6. **Consumidores de `stock_movements.type='sale'`** que asuman una fila en `sales`: grep en el propose antes de elegir el `type`.
7. **`CHECK` cerrados** de `document_status_history.document_type`, `document_status_transitions.document_type` y `stock_movements.reference_type`: ampliaciones aditivas, con un gate que verifique el conjunto completo.
8. **Gate de ACLs**: las RPCs nuevas sin `EXECUTE` para `anon`; los núcleos internos (`_purchase_operation_core`) sin `authenticated`.
9. **Candados existentes de venta**: el `P0423` fiscal/dinero y el de "venta nacida de remito" tienen que convivir en el mismo predicado sin romper `venta-editable-sin-cae`.

### Verificaciones

- **Gates SQL nuevos**, cableados a `KPI_Validation.yml`:
  - `test_presupuesto_a_venta.sql`: ejecuta la conversión de verdad y verifica stock, caja, cuenta corriente, el historial de ambos documentos, el rollback ante `P0409`, el rechazo de un vencido y la tenencia.
  - `test_remitos_venta.sql` y `test_remitos_compra.sql`: stock al crear; contramovimiento al anular; conversión sin segundo movimiento (contar `stock_movements` por `reference_id`); el borrado de la venta devuelve el remito a `issued` sin tocar stock; `P0423` de edición; matriz de evasión.
  - Numeración concurrente sin huecos ni duplicados.
  - `test_function_acl_gate.sql` actualizado.
- **Backend** (TDD con pytest):
  - routers, services y repositories nuevos, con tenencia explícita;
  - PDF, leído con `pypdf`: "PRESUPUESTO", "REMITO", "no válido como factura", ítems y total;
  - 404 RFC 7807 cross-tenant.
- **Frontend** (vitest):
  - formularios;
  - `DocumentShareMenu` (con y sin teléfono, con y sin Web Share);
  - diálogo de conversión;
  - invalidación de queries (`quotes`, `sales`, `stock`, `cash`, `receivables`, `delivery-notes`).
- **Visual**: desktop + mobile (375 px) × claro + oscuro en `/presupuestos`, `/remitos` y los diálogos.
- **Humo del PO en prod**, en cada change:
  - Presupuesto → PDF → WhatsApp desde el celular → Venta. Verificar que aparece en `/ventas` y que se puede facturar.
  - Remito de venta → el stock baja → Venta → el stock no vuelve a bajar → borrar la venta → el remito queda pendiente.
  - Remito de compra → el stock sube → Compra a crédito → cuenta corriente del proveedor.
