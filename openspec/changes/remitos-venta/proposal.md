## Why

El PO pidió (2026-09-29), textual: *«el módulo remito tanto de venta como de compra y el módulo presupuesto […] quiero lo mismo para remito [crearlo para un cliente, descargarlo o mandarlo por WhatsApp, y un botón "Venta" que lo pasa a venta con todos los productos] pero que éste sí baje de stock; cuando se crea el presupuesto no.»* Y después: *«no necesito el remito legal. Andá con todo lo recomendado»* y *«quiero que tanto el remito como los presupuestos se puedan modificar»*.

Hoy el remito **no existe** en Aliadata. `rg -il "remito|delivery_note"` sobre `supabase/`, `backend/`, `frontend/` y `openspec/specs` no encuentra nada relacionado, y en prod no hay ninguna tabla, función ni columna con esos nombres (medido el 2026-10-02). El comercio que entrega mercadería y cobra después (entrega en obra, reparto, cuenta corriente al mes) tiene dos malas opciones:

- **registrar la venta en el momento**: cobra o carga deuda antes de tiempo y el precio queda congelado antes de acordarlo;
- **no registrar nada hasta cobrar**: el stock queda inflado mientras la mercadería ya no está en el depósito.

Este change es el segundo del split del explore (`openspec/changes/presupuestos-modulo/research/explore-presupuestos-remitos.md` §4): `presupuestos-modulo` → **`remitos-venta`** → `remitos-compra`. Reutiliza las tres piezas compartidas que dejó `presupuestos-modulo`: numeración interna, PDF de documento comercial y menú de compartir. También reutiliza los campos de cierre de venta de su tanda B.

## What Changes

- **Documento nuevo: remito de venta interno ("X").** Leyenda *"Remito — documento no válido como factura"*, sin ARCA ni CAI (R1).
  - Tablas `delivery_notes` + `delivery_note_items`, con `direction` (`'sale'` en este change; `'purchase'` queda admitido por el modelo para `remitos-compra`, sin ninguna operación que lo escriba).
  - Cliente y sucursal de origen **obligatorios**.
  - Líneas **sólo con producto**: un remito documenta mercadería que sale del depósito, así que no admite líneas de servicio.
  - Snapshots de nombre, SKU, costo y alícuota de IVA en el mismo `INSERT`. Precio y subtotal se guardan siempre, aunque el PDF no los muestre (R2).
  - Domicilio de entrega opcional y notas.
  - Columnas del sentido compra (`supplier_id`, `supplier_reference`) ya presentes y sin escritor, para que `remitos-compra` no altere la tabla.
- **Numeración interna visible `R-00000001`**, correlativa por cuenta y por sentido, sobre `internal_document_sequences`. Se amplía el `CHECK` de `document_type` de forma aditiva.
- **Máquina de estados** `delivery_note_sale` (un tipo de documento por sentido: el catálogo admite una sola transición de creación por tipo, y venta y compra tienen roles distintos): `issued` (pendiente de convertir) → `converted` | `canceled`, más la vuelta `converted → issued` cuando se borra la venta nacida del remito. Sin borrador: el remito se emite directo, porque el PO pidió que baje stock al crearse. Historial append-only en `document_status_history`.
- **Stock**:
  - **Emitir el remito descuenta stock** de su sucursal, con la misma normalización de unidad (RN-24) y el mismo control de faltante (`P0409`) que la venta. El ledger registra el movimiento con `reference_type = 'delivery_note'` (valor aditivo nuevo del `CHECK`). La emisión es **idempotente** (`Idempotency-Key`): un doble clic no descuenta dos veces.
  - Lo que el remito retiene se lee de sus **líneas** (cantidad base guardada al emitir o editar, escrita sólo por sus RPCs), no sumando el ledger, que los roles de aplicación pueden insertar por PostgREST.
  - **Editarlo** (líneas, cantidades, precios, cliente, sucursal, notas) mientras esté `issued` ajusta el stock con el **par espejo REVERSE+APPLY**, sólo en los pares producto-sucursal que cambian, con control de faltante sobre el neto (R4, decisión del PO que anula la recomendación del explore).
  - **Anularlo** exige motivo, repone el stock con contramovimiento y lo pueden hacer sólo administrador y dueño (R3, R7).
  - Remito `converted` → inmutable y no anulable (`P0423`).
- **Botón "Venta"**: RPC atómica `rpc_convert_delivery_note_to_sale`, que crea la orden con todas las líneas del remito y la confirma con el núcleo del POS en **una** transacción (R8):
  - La venta resultante maneja caja, banco, cuenta corriente y outbox, y **es facturable**, como cualquier venta.
  - **No vuelve a mover stock.** El núcleo `_c29_confirm_order_core` lo decide por el **origen persistido** de la orden (`sales_orders.source_delivery_note_id`), nunca por un parámetro que el cliente pueda enviar, y revalida el remito de origen y sus líneas como defensa en profundidad.
  - Idempotente por `Idempotency-Key`, con versión esperada (`expected_revision`).
- **Vida posterior de la venta nacida de un remito**:
  - **No se edita** desde `/ventas` (`P0423 delivery_note_sale_locked`): la edición volvería a mover stock.
  - **Borrarla** compensa el dinero como siempre, **no toca stock** y devuelve el remito a "pendiente" (R5). Para devolver la mercadería al stock se anula el remito.
- **PDF** con `build_commercial_document_pdf` (tipo `delivery_note`):
  - sin precios por defecto, con la opción "Mostrar precios" (R2);
  - bloque de firma de recepción (firma, aclaración, DNI, fecha);
  - sello "ANULADO" cuando corresponde.
  - Endpoint `GET /delivery-notes/{id}/pdf`.
- **Envío**: `DocumentShareMenu` (ver, descargar, WhatsApp), sin link público ni email.
- **Guards de unidad**: `delivery_note_items` se suma a los guards de unidad base y de unidad en uso. Sin esto, un remito de 12 unidades de un producto sin unidad base quedaría reinterpretado como 12 kg al asignarle "Kilogramo".
- **Baja de sucursal**: un remito pendiente bloquea la baja de su sucursal (cuarta condición del predicado único de baja, `_branch_blocking_content`/`_branch_assert_empty`, `P0428` con token propio). Una sucursal dada de baja dejaría el remito sin forma de convertirse ni de anularse sin devolver stock a una sucursal muerta. El diálogo de desactivación lo detecta antes y enlaza a los remitos pendientes.
- **Superficie frontend**:
  - **`/remitos`**: listado con filtros por estado, búsqueda por cliente o número y resumen de pendientes.
  - **`/remitos/nuevo`**: alta con el editor de líneas compartido (`StagedProductLine`/`ProductPicker`, `CartItemList`, lector de códigos y balanza), mostrando y **haciendo cumplir** el stock de la sucursal elegida, con la sucursal obligatoria y visible en todos los planes, y avisos de cuándo se mueve el stock.
  - **`/remitos/[id]`**: detalle con Compartir (con "Mostrar precios"), Editar, **Venta** y Anular con motivo.
  - **`/remitos/[id]/editar`**.
  - **Sidebar**: entrada **"Remitos"** en el grupo *Operaciones*, después de "Presupuestos".
  - **Ficha del cliente**: acción **"Nuevo remito"**.
  - **`/ventas`**: badge **"Desde remito R-…"**, con enlace y "Editar" deshabilitado con su motivo.
  - **`/stock`**: el panel de movimientos rotula "Remito", "Edición de remito" y "Anulación de remito".
  - **Pestañas De venta / De compra: no se construyen en este change.** La de compra la suma `remitos-compra`, cuando tenga contenido (D11).
- **Sin gate de plan** (todos los tiers).

**BREAKING** (interno): ninguno para clientes de la API. Las reescrituras de `_c29_confirm_order_core`, `rpc_delete_sale_operation`, `rpc_atomic_update_sale_operation`, `fn_product_base_unit_guard`, `fn_uom_in_use_guard`, `_branch_assert_empty` y `_quote_validate_items` conservan firma y comportamiento para todo lo que no es un remito. `_branch_blocking_content` (interna, sin `EXECUTE` para roles de aplicación) suma una columna a su `RETURNS TABLE`.

## Decisiones firmadas por el PO (2026-09-29)

«no necesito el remito legal. Andá con todo lo recomendado» + «quiero que tanto el remito como los presupuestos se puedan modificar»:

- **R1**: remito **interno "X"** con la leyenda "documento no válido como factura". Nada de ARCA ni CAI.
- **R2**: el PDF sale **sin precios por defecto**, con la opción "mostrar precios". Los precios se guardan siempre.
- **R3**: anular un remito **repone el stock** y exige **motivo**.
- **R4** (**anula la recomendación del explore**): el remito **es editable** mientras no esté convertido. Editar las líneas ajusta el stock con el espejo REVERSE+APPLY y control de faltante. Convertido → inmutable (`P0423`).
- **R5**: si se borra la venta nacida de un remito, el remito vuelve a "pendiente" y el stock **no** se toca. Para devolver stock se anula el remito.
- **R6** (aplica a compra, change siguiente): anular un remito de compra cuyo stock ya se consumió se bloquea con `P0409`.
- **R7**: emitir un remito de venta: `seller`/`stock`/`admin`/`owner`. Anular: sólo `admin`/`owner`.
- **R8**: 1 remito → 1 venta con todas sus líneas (sin parciales ni agrupados en v1). Sin gate de plan. Envío por descarga y WhatsApp (mismo `DocumentShareMenu`), sin link público ni email.

## Qué se reutiliza de `presupuestos-modulo`

| Pieza | Origen | Uso en el remito |
|---|---|---|
| `internal_document_sequences` + `_assign_internal_document_number` | D3, tanda A (en `main`) | Número `R-…`; se amplía el `CHECK` y se suma un disparador por sentido |
| `build_commercial_document_pdf` + `rpc_commercial_issuer` + `resolve_commercial_issuer` | D8, tanda A | PDF del remito, con `show_prices` y bloque de firma (extensión aditiva del render) |
| `DocumentShareMenu`, `lib/document-share.ts`, `lib/api/document-pdf.ts` | D9, tanda A | Compartir el remito |
| Editor de líneas: `lib/cart-utils.ts` (`addManualLineToCart`, `applyScanToCart`, `exceedsStock`, reductores), `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput` | D12, tanda A | Alta y edición del remito, con `enforceStock: true` |
| `SaleCheckoutFields` / `SaleCheckoutSuccess` | D12, tanda B (worktree `opsx/presupuestos-modulo-apply-b`, todavía sin mergear) | Diálogo "Convertir en venta" |
| Patrón de conversión atómica: lock del origen → idempotencia bajo lock → estado y versión → núcleo → `RAISE` ante replay ajeno | D6, tanda B | `rpc_convert_delivery_note_to_sale` |
| `lib/rbac-capabilities.ts` + `hasCapability(roles, cap, rolesResolved)` | D11, tanda A | `CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE`, `CAN_SELL` |
| `invalidateAfterSale` | D12, tanda A | Invalidación tras convertir |

## Non-goals

- **Remito legal "R"** con CAI o remito electrónico de ARCA (R1).
- **Remito de compra** (`direction = 'purchase'`): conversión a compra, pantalla, pestaña "De compra", proveedor obligatorio, número del proveedor y extracción del núcleo de compra. Es el change siguiente, `remitos-compra`. Este change sólo deja el modelo de datos admitiendo los dos sentidos.
- Remito **parcial**, varios remitos → una venta, presupuesto → remito y venta → remito (R8).
- **Link público**, aceptación online o envío por **email**.
- **Devoluciones como documento propio** (devolución parcial de mercadería de un remito). En v1, la devolución total es "anular", y la parcial es "editar el remito" mientras esté pendiente.
- **Borrador** de remito sin stock.
- Editar una venta nacida de un remito desde `/ventas`.
- Indicador de "mercadería entregada sin facturar" en el Tablero (OQ-RV12).
- Importador CSV de remitos.

## Capabilities

### New Capabilities

- `delivery-note`: remito de venta interno. Modelo de datos con sentido, número `R-…`, máquina de estados con historial, emisión que descuenta stock, edición con par espejo, anulación con motivo que repone stock, conversión atómica a venta sin doble descuento, PDF sin o con precios, envío por WhatsApp, pantallas, permisos y errores accionables.

### Modified Capabilities

- `internal-document-numbering`: se suma el tipo `delivery_note_sale` (prefijo `R`), con secuencia propia por sentido.
- `commercial-document-pdf`: el constructor admite el remito (`show_prices`, bloque de firma de recepción, leyenda propia).
- `sales-order`: la orden nacida de un remito se confirma sin mover stock, decidido por su origen persistido. La venta expone su remito de origen.
- `inventory-single-ledger`: movimientos del remito en el ledger (`delivery_note`, `delivery_note_update`, `delivery_note_reversal`). La reversa al borrar una venta y el invariante de no-orfandad exceptúan las filas de una venta nacida de un remito, cuyo stock vive en el remito.
- `operation-delete-compensation`: borrar una venta nacida de un remito compensa el dinero, no toca stock y devuelve el remito a pendiente. El diálogo lo explica.
- `operation-edit-context`: la venta nacida de un remito es inmutable (`P0423`) y el listado lo expone.
- `units-of-measure`: las líneas de remito usan la definición única de normalización y participan de los guards de unidad base y de unidad en uso.
- `branch-decommission-guard`: un remito de venta pendiente es contenido operativo que bloquea la baja de su sucursal.
- `document-status-history`: tipo de documento `delivery_note_sale` y su máquina de estados en el catálogo (requirement nuevo, sin tocar el del seed que modifica `presupuestos-modulo`).

## Impact

- **Base de datos**: dos migraciones (tandas A y B), con el **siguiente número libre ≥ `20261069000001`** al momento de cada apply (`20261068000001` es la tanda B de `presupuestos-modulo`).
  - Tablas nuevas y columna `sales_orders.source_delivery_note_id`.
  - `CHECK` ampliados: `internal_document_sequences.document_type`, `document_status_history.document_type`, `document_status_transitions.document_type`, `stock_movements.reference_type` y `operation_idempotency.operation_kind`.
  - Funciones nuevas, en todos los casos `SECURITY DEFINER` con guards: emisión, edición, anulación, conversión y payload.
  - Reescrituras desde el `pg_get_functiondef` **vivo**: `_c29_confirm_order_core` (hot path del POS), `rpc_delete_sale_operation`, `rpc_atomic_update_sale_operation`, `fn_product_base_unit_guard`, `fn_uom_in_use_guard`, `_branch_blocking_content`, `_branch_assert_empty` y `_quote_validate_items` (extracción del guard de producto compartido).
- **Coordinación**: el PR abierto **#607 `ventas-sucursal-por-defecto`** reescribirá `rpc_create_sale_operation_v2`, la rama legacy de `rpc_create_sale_operation` y `rpc_atomic_update_sale_operation`. **Quien llegue segundo parte del cuerpo vivo** de la que llegó primero; este change no toca las dos primeras. La tanda B depende de que la tanda B de `presupuestos-modulo` (`SaleCheckoutFields`/`SaleCheckoutSuccess`, `20261068000001`) esté mergeada.
- **Backend**:
  - Router, service, repository y schemas nuevos: `delivery_notes` (emisión con `Idempotency-Key`; `40P01` mapeado a `409` reintentable).
  - `core/rbac.py`: `CAN_DELIVER_SALE` y `CAN_VOID_DELIVERY_NOTE`.
  - `services/commercial_documents/` (vista del remito; render con firma).
  - `services/products.py`/`repositories/product_repository.py`: el chequeo de líneas en otra unidad suma `delivery_note_items`.
  - Read model de ventas: `source_delivery_note_id` y `source_delivery_note_number`.
  - Mapeo de errores RFC 7807.
- **Frontend**:
  - `app/(dashboard)/remitos/**` y `components/delivery-notes/*`.
  - `hooks/data/use-delivery-notes.ts`.
  - `lib/internal-document-number.ts` (tipo `R`), `lib/delivery-note-share.ts`, `lib/rbac-capabilities.ts`, `lib/operation-errors.ts`.
  - `app-sidebar.tsx`, `breadcrumb-nav.tsx`, `ClientDetailHeader`, listado y detalle de `/ventas` (`SourceQuoteBadge` generalizado a `SourceDocumentBadge`).
  - Piezas compartidas extendidas sin romper a sus usuarios: `BranchSelect` (`required`/`alwaysVisible`), `lib/cart-utils.ts` (`availableFor`), `lib/operation-errors.ts` (contexto `documentLabel`), `QuotePageStates` → `components/shared/DocumentPageStates`, `lib/query-invalidation.ts` (`invalidateAfterSaleDelete` incluye remitos).
  - Nuevo hook `hooks/data/use-client-addresses.ts` (domicilio de entrega).
  - `use-branches.ts` (token de baja) y `DeactivateBranchDialog` (remitos pendientes).
  - `stock-movements-panel.tsx`.
  - `SaleCheckoutFields`: prop aditiva para sucursal fija.
- **Gates y CI**:
  - Nuevos: `test_remitos_venta.sql` (A), `test_remito_a_venta.sql` (B) y `test_remitos_venta_race.sh`.
  - Actualizados: `test_function_acl_gate.sql`, `test_document_status_transition_role_matrix.sql` (en cada tanda) y los gates de unidades y de baja de sucursal.
  - Todos cableados en `KPI_Validation.yml`, junto con la cadena de reaplicación.
- **Governance: MEDIA con tramo ALTO.** Escribe el ledger de stock en tres caminos nuevos y reescribe el núcleo de confirmación de venta, que comparten el POS y la conversión de presupuestos. Hacen falta checkpoints de cuerpo vivo, un gate de matriz de evasión contra el doble descuento y revisión adversarial antes de cada merge.
- **Riesgos principales**:
  - **doble descuento de stock**: mitigado porque el origen se decide por la columna persistida y el núcleo revalida el remito y sus líneas;
  - **regresión del POS** por tocar el núcleo: mitigada con el diff contra el cuerpo vivo, limitado a la rama nueva, y el gate de que una orden sin origen sigue descontando;
  - **kardex ruidoso** por ediciones de sólo precio: mitigado porque el espejo sólo cubre los pares que cambian;
  - **orden de locks** nuevo (`delivery_notes` primero): documentado y cubierto por el gate de carrera.
