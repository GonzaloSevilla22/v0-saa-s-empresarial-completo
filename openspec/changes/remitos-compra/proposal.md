## Why

El PO pidió (2026-09-29), textual: *«el módulo remito tanto de venta como de compra y el módulo presupuesto […] quiero lo mismo para remito pero que éste sí baje de stock; cuando se crea el presupuesto no.»* Y después: *«no necesito el remito legal. Andá con todo lo recomendado»* y *«quiero que tanto el remito como los presupuestos se puedan modificar»*.

Este change es el tercero y último del split del explore (`openspec/changes/archive/2026-10-02-presupuestos-modulo/research/explore-presupuestos-remitos.md` §4): `presupuestos-modulo` (archivado) → `remitos-venta` (tanda A ya en `main`, PR #612) → **`remitos-compra`**. Cubre el sentido que el explore llama "de un solo paso": la mercadería que **entra** desde un proveedor.

Hoy la única forma de registrar mercadería que entra es la compra (`rpc_create_purchase_operation`), que suma stock **y** mueve dinero en el mismo acto. El comercio que recibe la mercadería con el remito del proveedor y paga después (la factura llega días más tarde, se paga a fin de mes o el precio se confirma con la factura) tiene dos malas opciones:

- **cargar la compra al recibir**: registra un pago o una deuda antes de tiempo, con un precio que todavía no conoce;
- **no cargar nada hasta pagar**: el stock queda en cero mientras la mercadería ya está en el depósito, y el POS rechaza las ventas por falta de stock.

Medido en prod (2026-10-03, sólo lectura): **0** remitos de compra ni filas `delivery_note_purchase` (las tablas de `remitos-venta` ya están aplicadas, `MAX(version) = 20261069000001`); 127 operaciones de compra (33 en los últimos 30 días, 32 de ellas con proveedor); 19 proveedores vivos en 8 cuentas, **2** con teléfono.

## What Changes

- **Remito de compra interno ("X")** sobre el modelo que `remitos-venta` ya dejó preparado: `delivery_notes.direction = 'purchase'`, con `supplier_id` obligatorio y `supplier_reference` (número del remito del proveedor, texto opcional). Ninguna tabla nueva.
  - Proveedor vivo de la cuenta y sucursal de destino activa y no cerrada, **obligatorios**.
  - Líneas sólo con producto, con precio de compra por unidad de la línea. El precio **puede ser 0** al recibir (la factura del proveedor todavía no llegó); la conversión exige que todos los precios sean mayores que 0.
  - Leyenda *"Remito — documento no válido como factura"*; sin ARCA ni CAI (R1).
- **Numeración propia `RC-00000001`**, correlativa por cuenta y por sentido (tipo `delivery_note_purchase` en `internal_document_sequences`), con el disparador genérico de numeración reutilizado tal cual.
- **Máquina de estados `delivery_note_purchase`**, gemela de la de venta y sembrada aparte (`issued → converted | canceled`, más `converted → issued` al borrar la compra), con sus roles.
- **Stock**:
  - **Emitir el remito suma stock** a la sucursal de destino (es la recepción), con la normalización de unidad única (RN-24) y un movimiento `type = 'purchase'`, `reference_type = 'delivery_note'`. Emisión idempotente (`Idempotency-Key`).
  - **Editarlo** mientras esté pendiente aplica el par espejo sólo en los pares producto-sucursal que cambian, con control de faltante **sobre el neto**: bajar una cantidad que ya se vendió o se transfirió falla con `P0409`.
  - **Anularlo** exige motivo, resta todo lo que el remito sumó y **se bloquea con `P0409`** si esa mercadería ya se consumió (R6). Sólo administrador y dueño.
  - Lo que el remito aportó se lee de sus líneas (`quantity_base`), nunca del ledger, igual que en venta.
  - La recepción **no** actualiza `products.cost`: la compra directa tampoco lo hace hoy (verificado en el cuerpo vivo y en los disparadores de `purchases`).
- **Botón "Compra"**: RPC atómica `rpc_convert_delivery_note_to_purchase` que crea la compra con **todas** las líneas del remito y **no vuelve a sumar stock**.
  - Se extrae un núcleo interno `_purchase_operation_core` desde el cuerpo vivo de `rpc_create_purchase_operation`. La RPC pública queda como wrapper con la misma firma, la misma ACL y sin `COMMENT` (hoy no tiene).
  - El salto de stock lo decide el servidor: el núcleo recibe el remito **sólo** desde la conversión (es interno, sin `EXECUTE` para roles de aplicación), lo revalida bajo bloqueo, lee las líneas del propio remito y persiste el origen en `purchases.source_delivery_note_id`. Ningún parámetro público pide "no sumes stock".
  - La compra mueve el dinero exactamente como una compra directa: caja con las tres condiciones, banco, cuenta corriente del proveedor con vencimiento por cascada, evento `PurchaseCreated` y asiento.
  - `purchases` admite escritura por PostgREST, así que un disparador impide que los roles de aplicación fijen, cambien o limpien `source_delivery_note_id`, o borren filas con origen por fuera del borrado.
- **Vida posterior de la compra nacida de un remito**:
  - **No se edita** desde `/compras` (`P0423 delivery_note_purchase_locked`): la edición volvería a mover stock.
  - **Borrarla** compensa el dinero como siempre, **no toca stock** y devuelve el remito a pendiente (R5 aplicado a compra). El borrado bloquea el remito antes de compensar, así que dos borrados o un borrado contra una reconversión no lo reabren dos veces.
  - Anular un remito convertido está prohibido (`P0423`).
- **PDF** del remito de compra con el constructor compartido: "Recibido de" (proveedor), "Ingresa a" (sucursal), número del remito del proveedor, bloque de firma de quien recibe, sin precios por defecto y con "Mostrar precios" (R2).
- **Envío** con `DocumentShareMenu`: descarga y WhatsApp **al proveedor** si tiene teléfono; sin teléfono, el selector de contacto de WhatsApp.
- **Reutilización de `remitos-venta`**: los helpers `_delivery_note_*` pasan a decidir el sentido del movimiento leyendo `direction` del remito (misma firma, desde el cuerpo vivo), la edición se extrae a un único núcleo compartido por los dos sentidos y la anulación (`rpc_cancel_delivery_note`) sirve a los dos.
- **Superficie frontend**:
  - **`/remitos`** gana las pestañas **De venta** / **De compra** (`?sentido=venta|compra`), con búsqueda por proveedor, número `RC-…` o número del proveedor.
  - **`/remitos/nuevo?tipo=compra`** y **`/remitos/[id]/editar`**: el formulario del remito parametrizado por sentido, con **proveedor obligatorio y alta inline** (selector extraído del formulario de compra a un componente compartido), número del remito del proveedor y sucursal de destino.
  - **`/remitos/[id]`** de compra: Compartir (con "Mostrar precios"), Editar, **Compra** y Anular con motivo.
  - Diálogo **"Convertir en compra"**: forma de pago, cuenta bancaria, caja, fecha, vencimiento y centro de costo, con los campos de cierre extraídos del formulario de compra.
  - **`/compras`**: badge **"Desde remito RC-…"** con enlace, "Editar" deshabilitado con su motivo, el diálogo de borrado sin la reversa de stock y con la explicación del remito, y "Eliminar" deshabilitado con su motivo para quien no puede reabrir el remito o si su sucursal está inactiva.
  - **Aviso contra la doble suma**: "Nueva compra" y Factura IA avisan, con enlace, cuando hay remitos de compra pendientes (del proveedor elegido, o de la cuenta si el flujo no identifica proveedor).
  - **Proveedores**: acción "Nuevo remito de compra" en el listado y "Nuevo remito" / "Ver remitos" en la cuenta corriente del proveedor.
  - **`/stock`**: el panel ya rotula los remitos por `reference_type` y formatea el número por sentido; muestra `RC-…` sin cambios de lógica.
  - **Diálogo de baja de sucursal**: un enlace por sentido a los remitos pendientes.
- **Sin gate de plan** (todos los tiers).

**BREAKING** (interno): ninguno para clientes de la API. Las reescrituras (`rpc_create_purchase_operation`, `rpc_delete_purchase_operation`, `rpc_atomic_update_purchase_operation`, los helpers `_delivery_note_*`, `rpc_update_delivery_note`, `rpc_cancel_delivery_note`) conservan firma y comportamiento para todo lo que no es un remito de compra.

## Decisiones firmadas por el PO (2026-09-29)

«no necesito el remito legal. Andá con todo lo recomendado» + «quiero que tanto el remito como los presupuestos se puedan modificar», aplicadas al sentido compra:

- **R1**: remito interno "X", sin ARCA.
- **R2**: PDF sin precios por defecto, con opción; los precios se guardan siempre.
- **R3**: anular exige motivo y **resta** el stock que el remito sumó.
- **R4**: editable mientras no esté convertido, con espejo de stock en los pares que cambian y control de faltante sobre el neto (bajar una cantidad ya vendida → `P0409`). Convertido → inmutable.
- **R5**: borrar la compra nacida del remito lo devuelve a pendiente; el stock **no** se toca.
- **R6**: anular un remito de compra cuya mercadería ya se consumió se bloquea con `P0409`.
- **R7**: emitir un remito de compra: `stock`/`admin`/`owner`. Anular: `admin`/`owner`. (Quién **convierte** no estaba en OQ-R7: es la recomendación de OQ-RC6, `purchases`/`stock`/`admin`/`owner`.)
- **R8**: 1 remito → 1 compra con todas sus líneas; sin gate de plan; descarga y WhatsApp, sin link público ni email. Proveedor obligatorio y número del remito del proveedor opcional.

## Qué se reutiliza

| Pieza | Origen | Uso en el remito de compra |
|---|---|---|
| `delivery_notes`/`delivery_note_items`, `CHECK` de contraparte, `supplier_reference`, índice por `supplier_id` | `remitos-venta` D1 (tanda A) | El modelo, sin `ALTER TABLE` |
| Helpers `_delivery_note_lock_products`, `_delivery_note_validate_items`, `_delivery_note_insert_items`, `_delivery_note_held_pairs` | `remitos-venta` D4–D6 | Sin cambios |
| `_delivery_note_apply_stock`, `_delivery_note_reverse_held`, `_delivery_note_assert_role`, `_delivery_note_payload` | `remitos-venta` D4/D13 | Pasan a leer el sentido del remito (desde el cuerpo vivo) |
| `trg_assign_internal_document_number`, `trg_delivery_note_record_creation`, `trg_enforce_status_transition` | `presupuestos-modulo` D3, `remitos-venta` D2/D3 | Disparadores gemelos con `WHEN (direction = 'purchase')` |
| `_branch_pending_delivery_notes` | `remitos-venta` D10 | Ya cuenta los dos sentidos: sin cambios |
| `build_commercial_document_pdf` + `build_delivery_note_view` | `presupuestos-modulo` D8, `remitos-venta` D8 | Vista por sentido |
| `DocumentShareMenu`, `DeliveryNoteForm`, `CancelDeliveryNoteDialog`, `DeliveryNoteStatusBadge`, `StagedProductLine`, `CartItemList` | `presupuestos-modulo` D9/D12, `remitos-venta` D11 | Parametrizados por sentido |
| `PaymentMethodSelect`, `BankAccountDestinationSelect`, `useCashOptin`, selector de proveedor con alta inline | formulario de compra | Extraídos a la capa canónica para el diálogo de conversión y el formulario del remito |
| `_pay_register_party_charge`, `_pay_register_operation_bank_movement`, `c28_register_cash_movement` | cuentas corrientes, banco, caja | Sin cambios, vía el núcleo de compra |

## Non-goals

- **Remito legal "R"** con CAI o remito electrónico de ARCA (R1).
- **Remito parcial** y varios remitos → una compra (R8).
- **Devoluciones a proveedor** como documento propio (nota de crédito del proveedor con egreso de stock). La devolución total de un remito pendiente es "anular"; la parcial, "editar".
- **Orden de compra** formal y el circuito pedido → recepción.
- **Link público** y envío por **email**.
- **Costeo por lote** o por compra: ni la recepción ni la conversión actualizan `products.cost` ni cambian la valuación del stock (que sigue el costo de catálogo, como la compra directa).
- Editar una compra nacida de un remito desde `/compras`.
- Importador CSV de remitos.
- KPI de mercadería recibida sin facturar en el Tablero.

## Capabilities

### New Capabilities

Ninguna. El remito de compra extiende la capability `delivery-note` que crea `remitos-venta` (todavía en su delta activo; este change le suma requirements con `ADDED`).

### Modified Capabilities

- `delivery-note`: remito de compra (sentido `purchase`): modelo, emisión que suma stock, edición con espejo y faltante sobre el neto, anulación bloqueada si la mercadería se consumió, conversión atómica a compra sin doble suma, vida posterior, PDF, envío al proveedor, pantallas y permisos.
- `purchase-operation`: la compra nacida de un remito no vuelve a sumar stock, decidido por el servidor; la compra expone su remito de origen.
- `operation-delete-compensation`: borrar una compra nacida de un remito compensa el dinero, no toca stock y devuelve el remito a pendiente.
- `operation-edit-context`: la compra nacida de un remito es inmutable (`P0423`) y el listado lo expone.
- `supplier-account`: la compra a crédito nacida de un remito postea su cargo como cualquier compra a crédito.
- `supplier-directory`: el selector de proveedor con alta inline se comparte con el remito; acceso a los remitos desde el proveedor.
- `internal-document-numbering`: tipo `delivery_note_purchase` con prefijo `RC`.
- `commercial-document-pdf`: el constructor admite el remito de compra.
- `inventory-single-ledger`: movimientos del remito de compra en el ledger y exención de la reversa al borrar una compra nacida de un remito.
- `document-status-history`: tipo `delivery_note_purchase` y su máquina de estados en el catálogo.

## Impact

- **Base de datos**: dos migraciones (tandas A y B), con el **siguiente número libre** al momento de cada apply (`remitos-venta` tanda A tomó `20261069000001`; su tanda B probablemente tome `20261070000001`).
  - Tanda A: `CHECK` ampliados por agregado al vivo (`internal_document_sequences`, los dos de FSM, `operation_idempotency`); filas del catálogo; disparadores gemelos; helpers reescritos desde el cuerpo vivo; núcleo de edición extraído; `rpc_create_purchase_delivery_note`, `rpc_update_purchase_delivery_note` y `rpc_cancel_delivery_note` generalizada; **retiro del paso de reaplicación de `20261069000001`** en `KPI_Validation.yml` (sus `CHECK` de lista fija abortarían con las filas `delivery_note_purchase`), con reconvergencia por `db reset`.
  - Tanda B: `purchases.source_delivery_note_id` y su disparador de integridad; filas de conversión del catálogo; `_purchase_operation_core` + wrapper; `rpc_convert_delivery_note_to_purchase`; `rpc_delete_purchase_operation` y `rpc_atomic_update_purchase_operation` desde el cuerpo vivo; retiro del bloque de reaplicación de `20261062000001` en `KPI_Validation.yml` si sigue ahí.
- **Backend**: `delivery_notes` (schemas con unión discriminada por `direction`, repositorio, service, router, `POST /delivery-notes/{id}/convert-to-purchase`), `core/rbac.py` (`CAN_RECEIVE_PURCHASE`, `CAN_CONVERT_PURCHASE_DELIVERY_NOTE`), vista PDF por sentido, read model de compras con el remito de origen, numeración `RC`.
- **Frontend**: `/remitos` (pestañas), `DeliveryNoteForm` por sentido, `components/suppliers/SupplierSelect.tsx` (extraído de `purchase-form.tsx`), `components/compras/PurchaseCheckoutFields.tsx` (extraído), `ConvertPurchaseDeliveryNoteDialog`, `purchase-operations-list.tsx` y diálogo de borrado de compra, `/proveedores` y su cuenta corriente, `DeactivateBranchDialog`, `lib/internal-document-number.ts`, `lib/operation-errors.ts`, `lib/rbac-capabilities.ts`, `lib/query-invalidation.ts`, `components/shared/StagedProductLine.tsx` y `lib/cart-utils.ts` (fuente de precio por sentido), `hooks/` (cascada del vencimiento extraída de `sale-form.tsx`), `components/invoice/InvoiceAIButton.tsx` (aviso).
- **Gates**: `test_remitos_compra.sql` (A), `test_remito_a_compra.sql` (B) y `test_remitos_compra_race.sh`; actualizados `test_remitos_venta.sql` (regresión de los helpers compartidos), `test_document_status_transition_role_matrix.sql`, `test_function_acl_gate.sql` y los gates de compras (`test_purchase_cash_optin.sql`, `test_purchase_delete_cash_compensation.sql`, `test_compras_proveedor_cuenta_corriente.sql`, `test_stock_movements_edicion.sql`, `test_delete_guard_ledgers.sql`, `test_edicion_preserva_contexto.sql`), todos cableados en `KPI_Validation.yml`.
- **Governance: MEDIA con tramo ALTO.** Escribe el ledger de stock en tres caminos nuevos, reescribe helpers que `remitos-venta` acaba de mergear y extrae el núcleo de la compra, que mueve caja, banco y cuenta corriente. Checkpoints de cuerpo vivo, gate con matriz de evasión contra la doble suma y revisión adversarial antes de cada merge.
- **Riesgos principales**: doble suma de stock al convertir o por una compra directa de la misma mercadería; puente remito ↔ compra escribible por PostgREST; regresión de la compra directa por la extracción del núcleo; regresión del remito de venta por los helpers compartidos; anulación o edición que deja stock negativo (la tabla lo prohíbe con un `CHECK`: sin gate, fallaría con un `23514` ilegible); choque de orden con la tanda B de `remitos-venta` y con el PR #607.
