## Context

El pedido, las decisiones firmadas (R1–R8) y el alcance están en `proposal.md`. El mapa de lo que existe está en el explore (`openspec/changes/presupuestos-modulo/research/explore-presupuestos-remitos.md`, §1.5, §2.2, §3 (d)–(h), §4–§6) y en el change hermano `presupuestos-modulo` (D3, D6, D8, D9, D11, D12, D14). Este documento cubre **sólo** `remitos-venta`. El remito de compra es `remitos-compra`: acá se deja el modelo de datos listo para los dos sentidos, sin diseñar la conversión a compra ni su pantalla.

### Lo que ya existe (verificado en `main` `95eb8dd7`, 2026-10-02)

| Pieza | Dónde (última definición) | Relevante para este change |
|---|---|---|
| `_c29_confirm_order_core` | `20261062000001_ventas_unidades_conversion.sql:1118-1583` | Recorre `sales_order_items` en orden de `id`. Por cada línea con producto: `FOR UPDATE` del producto (`:1388`), `_uom_normalize_quantity` (`:1402`), gate `branch_stock >= qty` con `P0409 'stock_insuficiente para producto %: disponible %, solicitado %'` (`:1404-1415`), `c21_apply_branch_stock_delta` (`:1421`), fila legacy `sales` (`:1428`), `sale_items` con `v_product.cost` (`:1441`) y `stock_movements(type='sale', reference_type='sale', reference_id = sales.id)` (`:1451`). Después: caja, cuenta corriente, banco, fiscal, `SaleConfirmed` y `draft→confirmed`. **No filtra `products.deleted_at`.** |
| `rpc_delete_sale_operation` | `20261061000001_venta_editable_vs_promocion_legacy.sql:1078-1297` | Lock de `sales` → orden → guard fiscal → cuenta corriente → caja → banco → `rpc_reverse_stock_movement(sale_id,'sale')` por fila (`:1257`) → `SaleOperationDeleted` → orden `confirmed→canceled` (`:1276-1285`) → `DELETE`. |
| `rpc_reverse_stock_movement` | `20260828000001_v31_rls_collision_rpcs.sql` | Revierte los movimientos **existentes** con ese `reference_id`/`reference_type`. Sin movimientos no hace nada y no da error. Sólo admite `purchase`/`sale`. |
| `rpc_atomic_update_sale_operation` | `20261062000001:1594-2262` | Lock de `sales` (`:1687`) → guard de cliente → anulación fiscal → tres `P0423` de dinero → REVERSE por el delta guardado + APPLY normalizado. Para una venta sin movimientos propios, la REVERSE no devuelve nada y la APPLY **descontaría por segunda vez**. |
| `_uom_normalize_quantity` | `20261062000001:207-320` | Definición única de RN-24. Interna. |
| `c21_apply_branch_stock_delta` | `20260625000002_c26_fix_helper_upsert_check.sql` | Delta sobre `branch_stock`. Es la usada por el núcleo. |
| Guards de unidad | `fn_product_base_unit_guard` (`20261062000001:3585-3785`, listas de líneas en `:3748-3754`), `fn_uom_in_use_guard` (`:3814-3839`, lista en `:3829-3832`) y `_GROUP_HAS_LINES_IN_OTHER_UNIT_SQL` (`backend/repositories/product_repository.py`) | Enumeran las tablas de líneas (`sales`, `purchases`, `sale_items`, `purchase_items`, `sales_order_items`, `quote_items`). Una tabla de líneas nueva **tiene que sumarse a las tres** o el guard queda evadible. |
| `fn_guard_branch_decommission` | `20261014000001_sucursal_guard_vaciado_auditoria.sql` | Tres condiciones (existencias ≠ 0, caja abierta, transferencias en vuelo) → `P0428`. |
| Numeración interna | `20261067000001_presupuestos_modulo.sql:140-290` | `internal_document_sequences` con `CHECK (document_type IN ('quote'))`, `_next_internal_document_number`, `_assign_internal_document_number` y el disparador genérico `trg_assign_internal_document_number(TG_ARGV[0])`. |
| Escritura del presupuesto | `20261067000001:346-632` | `_quote_assert_can_write`, `_quote_validate_items` (el guard de producto vivo, de la cuenta y no padre vive embebido en `:439-450`), `_quote_insert_items`, `_quote_payload`, `rpc_create_quote`: el molde de las RPCs de este change. |
| Conversión del presupuesto | worktree `opsx/presupuestos-modulo-apply-b`, `20261068000001_presupuestos_conversion_venta.sql:284-458` (sin mergear) | Molde exacto de la conversión: lock del origen → idempotencia bajo lock → estado, vencimiento y versión → guards → núcleo → `RAISE` si el núcleo devuelve `replayed`. |
| FSM | `trg_enforce_status_transition(TG_ARGV)` (`20260816000001:159-205`), `record_status_transition` (`20261048000001`), creación por disparador (`trg_quote_record_creation`, `20260807000001:393-421`) | El remito suma su enforcement y su registro de creación sin lógica nueva. |
| PDF y compartir | `backend/services/commercial_documents/{view,pdf,issuer,numbering}.py`, `frontend/components/shared/DocumentShareMenu.tsx`, `frontend/lib/document-share.ts` | `CommercialDocumentView` ya tiene `show_prices` y el render ya lo respeta (`pdf.py:158-194`). El comentario de `view.py:7-8` anuncia el remito. |
| Editor de líneas | `frontend/lib/cart-utils.ts` (`exceedsStock` `:185`, que excluye las líneas `source: "persisted"`; `addManualLineToCart` `:341`; `applyScanToCart` `:410`; reductores `:456-492`), `QuoteForm.tsx` | El presupuesto pasa `enforceStock: false`. El remito pasa `true`. |
| Cierre de venta | worktree de la tanda B: `components/ventas/SaleCheckoutFields.tsx` (props `branchId`/`onBranchChange`/forma de pago/banco/`checkout`) y `SaleCheckoutSuccess.tsx` | El remito los compone; la sucursal no se elige al convertir (D7). |
| RBAC | `backend/core/rbac.py` (`CAN_SELL = {owner, admin, seller, cashier}`, `CAN_STOCK`, `CAN_QUOTE`, `CAN_CONFIGURE`, `SENSITIVE_CAPABILITIES`), `frontend/lib/rbac-capabilities.ts` | Capacidades nuevas en las dos capas. |
| Panel de movimientos | `frontend/components/stock/stock-movements-panel.tsx:62-90` | Rotula por `type` (`sale` → "Venta"). Un remito con `type='sale'` aparecería como "Venta" si no se rotula por `reference_type`. |

### Medido en prod (2026-10-02, sólo lectura, `mcp__supabase__execute_sql`)

- `MAX(version) = 20261067000001`, 314 migraciones. La tanda A de presupuestos está aplicada; la B todavía no.
- **0** tablas, **0** funciones y **0** columnas con `delivery`/`remito` en el nombre: greenfield confirmado.
- `CHECK` vivos:
  - `stock_movements.type`: `purchase, sale, adjustment, return, initial, sale_return, purchase_return, physical_count, loss, damage, expiry, transfer_out, transfer_in`.
  - `stock_movements.reference_type`: `sale, purchase, adjustment, initial, sale_update, purchase_update, transfer, sale_reversal, purchase_reversal`.
  - `document_status_history.document_type` = `document_status_transitions.document_type`: `quote, sales_order, fiscal_document, cash_session, reconciliation_session, stock_transfer`.
  - `internal_document_sequences.document_type`: `'quote'`.
  - `sales_orders.status`: `draft, confirmed, canceled`.
- **Consumidores de `stock_movements.type = 'sale'`** (la pregunta del explore §3(d)): ninguna función viva lo lee asumiendo que existe una fila en `sales`. La única que filtra por tipo y referencia es `rpc_atomic_update_sale_operation`, y lo hace por `reference_id = ANY(<ids de sales>)`, así que un movimiento con `reference_id` = id de remito nunca coincide. En el código de aplicación, el único lector es el panel de movimientos (rotulado, D4). → Se reutilizan `type = 'sale'`/`'sale_return'` y el remito se distingue por `reference_type`.
- **Productos vivos**: 5.414.
  - Por control de stock: 4.770 `tracked` (2.438 son variantes) y 644 `variant_only`. **0** `untracked`, aunque el `CHECK` lo admite.
  - Sin unidad base: 4.660 de los `tracked` y los 644 `variant_only`.
  - 491 padres con variantes.
- **Cuentas**: 41; **1** con más de una sucursal activa.
- Volumen: 4.925 `stock_movements` (1.204 `sale/sale`), 133 `sales_orders`, 0 `quotes`.
- Políticas de escritura: `sales_orders` y `sales_order_items` sólo tienen `SELECT`, así que la orden sólo se crea por RPCs `SECURITY DEFINER`. `stock_movements` y `branch_stock` tienen `INSERT`/`UPDATE` para `authenticated` (preexistente, fuera de alcance; ver Riesgos).

## Goals / Non-Goals

**Goals:**
- Remito de venta interno de punta a punta: crear para un cliente → el stock baja → descargar o mandar por WhatsApp → editar con ajuste de stock → anular con motivo (repone) → convertir en venta con un toque, **sin** doble descuento.
- Que "esta orden no mueve stock" lo decidan sólo los datos persistidos de la orden, de modo que ningún caller pueda pedirlo.
- Escritura del remito sólo por RPC, con tenencia, rol, historial, numeración, normalización de unidad y control de faltante en el mismo camino para cualquier escritor.
- Modelo listo para `direction = 'purchase'` sin rediseño.
- Reutilizar las piezas de `presupuestos-modulo` sin copiar lógica.

**Non-Goals:** los de `proposal.md` §Non-goals. Además:
- no se cambia el comportamiento del POS, del formulario de venta ni de la conversión de presupuestos;
- no se toca la RLS preexistente de `stock_movements`/`branch_stock`;
- no hay pestaña "De compra".

## Decisions

### D1 — Modelo de datos: una tabla para los dos sentidos, cliente y sucursal obligatorios, líneas sólo con producto

**`delivery_notes`**

| Columna | Tipo | Regla |
|---|---|---|
| `id` | `uuid PK DEFAULT gen_random_uuid()` | |
| `account_id` | `uuid NOT NULL → accounts` | |
| `direction` | `text NOT NULL CHECK (direction IN ('sale','purchase'))` | Este change sólo escribe `'sale'`. Ninguna RPC de este change acepta `'purchase'`. |
| `branch_id` | `uuid NOT NULL → branches` | Sucursal de la que sale (o, en compra, a la que entra) el stock. |
| `client_id` | `uuid NULL → clients` | |
| `supplier_id` | `uuid NULL → suppliers` | Lo usará `remitos-compra`. |
| — | `CHECK ((direction = 'sale' AND client_id IS NOT NULL AND supplier_id IS NULL) OR (direction = 'purchase' AND supplier_id IS NOT NULL AND client_id IS NULL))` | Coherencia de la contraparte. |
| `number` | `bigint NULL` + `UNIQUE (account_id, direction, number)` | Lo asigna el disparador de D2. Nullable por el mismo motivo que `quotes.number` (fixtures en modo réplica). |
| `status` | `text NOT NULL CHECK (status IN ('issued','converted','canceled'))` | D3. |
| `issued_on` | `date NOT NULL` | Día ART de la emisión (`reporting_local_today()`), sin edición (OQ-RV9). Es fecha de negocio: se compara con `::date` pelado, nunca con `AT TIME ZONE`. |
| `delivery_address` | `text NULL`, `CHECK (char_length <= 500)` | Domicilio de entrega (OQ-RV7). |
| `notes` | `text NULL`, `CHECK (char_length <= 2000)` | |
| `total` | `numeric(15,2) NOT NULL DEFAULT 0` | `round(Σ subtotal, 2)` calculado en el servidor (RN-24-bis). |
| `revision` | `integer NOT NULL DEFAULT 1` | Versión del contenido (molde de `quotes.revision`). |
| `created_by`, `created_at`, `updated_by`, `updated_at` | | |

Índices:
- `(account_id, direction, status, issued_on DESC)` para el listado;
- `(client_id)` y `(branch_id)` parciales (`WHERE status = 'issued'`) para el guard de baja de sucursal (D10) y la ficha del cliente.

**`delivery_note_items`**:
- `id`, `delivery_note_id → delivery_notes ON DELETE CASCADE`, `account_id NOT NULL`, `line_no integer NOT NULL`;
- `product_id uuid NOT NULL → products`, `unit_id uuid NULL → units_of_measure`;
- `quantity numeric(15,4) NOT NULL CHECK (> 0)`;
- `price numeric NOT NULL CHECK (>= 0)`: precio por unidad de la línea, sin escala (RN-24-bis, igual que `quote_items.price`); `subtotal numeric(15,2) NOT NULL CHECK (>= 0)`;
- snapshots: `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` (NULL = sin costo cargado, `productos-costo-nullable`) e `iva_rate_snapshot` (NULL, D3 de `v3-snapshot-pattern`), en el **mismo** `INSERT … SELECT` desde `products` filtrado por `account_id` (spec `document-snapshots`);
- `quantity_base numeric(15,4) NOT NULL`: la cantidad normalizada a la unidad base que la línea retiene del stock. Es un derivado de `_uom_normalize_quantity` guardado por línea, para que el detalle y el form de edición sepan cuánto "aporta" cada línea sin recalcularlo. **La verdad del stock es el ledger** (D4); esta columna no se usa para revertir.

RLS: `SELECT` para los miembros de la cuenta en las dos tablas; **ninguna** política de escritura. `REVOKE ALL … FROM anon`.

- **Líneas sólo con producto** (OQ-RV11): un remito documenta mercadería que sale del depósito. Así la conversión no hereda los problemas de las líneas de servicio de la venta (OQ-P15/P16 de presupuestos). `P0400 delivery_note_product_required`.
- **Sin tabla de cabecera por sentido.** `remitos-compra` suma su RPC de alta, su disparador de número y su conversión sobre las mismas tablas.
  - *Rechazado*: `sales_delivery_notes` + `purchase_delivery_notes`. Duplicaría FSM, numeración, PDF, listado y guards de unidad para dos documentos con la misma forma (explore §3(d)).
- **Sin columna `show_prices`.** Mostrar precios es una decisión de cada descarga o envío, no un atributo del documento (D8).
  - *Rechazado*: guardarla. Obligaría a editar el remito, con revisión y lock, para cambiar cómo se imprime.
- **Sin columnas `canceled_at`/`cancel_reason`.** El motivo y el actor viven en `document_status_history`, que es la fuente única (RN-A5). El read model los lee de ahí.
- **Puente remito ↔ venta**: `sales_orders.source_delivery_note_id uuid NULL → delivery_notes ON DELETE RESTRICT` (tanda B). Lleva un índice único **parcial** `(source_delivery_note_id) WHERE source_delivery_note_id IS NOT NULL AND status <> 'canceled'`: a lo sumo una orden viva por remito, y una orden cancelada (venta borrada) no impide reconvertir. El remito no guarda el id de la venta: se deriva.

### D2 — Numeración `R-…` por cuenta y por sentido

- Se amplía `internal_document_sequences_document_type_check` a `('quote', 'delivery_note_sale')`. Es aditivo e idempotente (`DROP CONSTRAINT IF EXISTS` + `ADD`). `remitos-compra` sumará `'delivery_note_purchase'`.
- Disparador `delivery_notes_assign_number_sale`: `BEFORE INSERT … FOR EACH ROW WHEN (NEW.direction = 'sale') EXECUTE FUNCTION trg_assign_internal_document_number('delivery_note_sale')`.
  - Reutiliza **sin cambios** la función genérica de D3 de presupuestos. La cláusula `WHEN` resuelve que una tabla lleve dos sentidos con tipos de secuencia distintos.
  - `remitos-compra` suma su gemelo con `WHEN (NEW.direction = 'purchase')` y `'delivery_note_purchase'`.
  - No hay función nueva ni lógica copiada.
  - *Rechazado*: una función propia que calcule `'delivery_note_' || NEW.direction`. Contradice el requirement de la capability (una sola función genérica parametrizada por tipo) sin ganar nada sobre el `WHEN`.
  - Por eso la unicidad es `UNIQUE (account_id, direction, number)`: los dos sentidos comparten tabla y cada uno numera desde 1.
- Formato: prefijo `R` + 8 dígitos (`R-00000012`). Se suma a la única definición por lenguaje (`frontend/lib/internal-document-number.ts`, `backend/services/commercial_documents/numbering.py`) y al fixture compartido `backend/tests/fixtures/internal_document_number_cases.json`. La búsqueda acepta "R-12", "12" o "00000012".
- **Por qué una secuencia por sentido** (OQ-RV1): el comercio espera que sus remitos de venta salgan correlativos y sin huecos. Los de compra se identifican sobre todo por el número del proveedor, y compartir la secuencia intercalaría números que nunca entregó.
  - *Rechazado*: una sola secuencia `'delivery_note'`.
- Las propiedades de la capability (sin huecos, sin repetidos, un alta revertida no consume número, serializa sólo las altas de la misma cuenta y tipo) se heredan sin cambios.

### D3 — Máquina de estados: `issued → converted | canceled`, más la vuelta `converted → issued`

`document_type = 'delivery_note'` se suma a los dos `CHECK` (`document_status_history`, `document_status_transitions`), de forma aditiva. Filas del catálogo, cada una en la tanda que trae la operación que la usa (regla del seed: no se siembra una transición sin productor):

| Transición | `allowed_role` | `requires_reason` | `is_terminal_to` | Productor | Tanda |
|---|---|---|---|---|---|
| `NULL → issued` | `{seller, stock, admin, owner}` | no | no | disparador de creación (`trg_delivery_note_record_creation`, molde de `trg_quote_record_creation`) | A |
| `issued → canceled` | `{admin, owner}` | **sí** | **sí** | `rpc_cancel_delivery_note` | A |
| `issued → converted` | `{seller, cashier, admin, owner}` | no | no | `rpc_convert_delivery_note_to_sale` | B |
| `converted → issued` | `NULL` (sistema) | no | no | `rpc_delete_sale_operation`, al borrar la venta nacida del remito | B |

- **Sin `draft`.** El PO pidió que el remito "baje de stock cuando se crea". Un borrador sin stock sería un presupuesto con otro nombre.
- **`converted` no es terminal**: la vuelta a `issued` la hace cumplir R5. `canceled` sí es terminal.
- **`converted → issued` sin rol** (exención 2 del helper). La dispara el borrado de una venta, y quién puede borrar ventas ya lo decide `rpc_delete_sale_operation`. Exigir además un rol del remito haría que un vendedor que puede borrar su venta reciba un `P0403` por un documento que no tocó. El actor registrado es el usuario que borró; el motivo, `"Venta eliminada (operación …)"`.
- Enforcement: disparador `delivery_notes_enforce_status_transition … EXECUTE FUNCTION trg_enforce_status_transition('delivery_note')`. Ningún `UPDATE` de estado fuera del catálogo prospera, venga de donde venga.
- **Editar no cambia el estado ni escribe historial.** El rastro de una edición es el par espejo en el ledger (D5) más `updated_at`/`updated_by`/`revision`.
- *Rechazado*: estado `invoiced`. "Convertido en venta" no implica comprobante fiscal: la venta se factura después, o nunca. La UI lo muestra como "Convertido en venta".

### D4 — Stock en la emisión: mismo camino que la venta, movimientos por par producto-sucursal, `reference_type` propio

**`rpc_create_sale_delivery_note(p_client_id uuid, p_branch_id uuid, p_delivery_address text, p_notes text, p_items jsonb) → jsonb`**, `SECURITY DEFINER`, `SET search_path = public`:

1. `auth.uid()` no nulo.
2. **Cuenta**, resuelta igual que `rpc_create_quote`: la del cliente, entre las del usuario (`client_not_found` P0404 si es ajeno o no existe; vivo). Es determinista aunque el usuario tenga varias membresías.
3. `_delivery_note_assert_role(v_account_id, 'issue')`: `is_account_writer` (P0401) y roles activos ∩ `{seller, stock, admin, owner}` (P0403 `insufficient_role`). Mismo predicado que `record_status_transition`, antes de escribir.
4. Sucursal obligatoria (`P0400 delivery_note_branch_required`), de la cuenta, activa (`P0404`) y no cerrada (`P0422 branch_closed`).
5. `_delivery_note_validate_items(v_account_id, p_items)` → total del servidor. Valida, por línea:
   - `product_id` obligatorio;
   - producto **vivo, de la cuenta, no padre** (por el helper compartido de D12);
   - unidad del sistema o de la cuenta;
   - `quantity > 0`, `price ≥ 0`, `subtotal ≥ 0`;
   - tope de 500 líneas.
6. `INSERT delivery_notes` (`status='issued'`, `issued_on = reporting_local_today()`). El disparador numera y registra `NULL → issued`, validando el rol.
7. `INSERT delivery_note_items` con snapshots (`_delivery_note_insert_items`, molde de `_quote_insert_items`, filtrado por cuenta). Deja `quantity_base` en NULL hasta el paso 8.
8. **`_delivery_note_apply_stock(v_dn_id, v_op_group)`**, el único lugar donde el remito escribe stock (lo reutilizan la emisión y la edición):
   - **Lock de productos en orden ascendente de `product_id`**: `SELECT … FROM products WHERE id IN (<productos de las líneas>) ORDER BY id FOR UPDATE`. Es un orden determinista entre remitos concurrentes. El núcleo de venta lockea por orden de línea; el riesgo de interbloqueo entre un remito y una venta ya existe hoy entre dos ventas y se cubre con reintento del cliente (`40P01`), igual que hoy.
   - Por línea: `quantity_base := _uom_normalize_quantity(product_id, unit_id, quantity)`, **después** del `FOR UPDATE` (regla TOCTOU de `units-of-measure`).
   - Por **par** `(product_id, branch_id)`: requerido = `Σ quantity_base` de sus líneas. Disponible = `branch_stock.quantity` (0 si no hay fila). Si disponible < requerido → `RAISE 'stock_insuficiente para producto %: disponible %, solicitado %' USING ERRCODE = 'P0409'`, el **mismo literal** que el núcleo, que la UI ya traduce, con su acción "transferir stock".
   - `c21_apply_branch_stock_delta(account, product, branch, -requerido)`.
   - `INSERT stock_movements`:
     - `type='sale'`, `reference_type='delivery_note'`, `reference_id = delivery_note.id`;
     - `quantity_delta = -requerido`, `quantity_before/after`, `branch_id`, `product_name`, `performed_by`;
     - `operation_group_id = v_op_group` (uno por transacción);
     - `unit_cost_snapshot` = el `unit_cost_snapshot` de la línea (congelado en el paso 7);
     - `metadata = {delivery_note_item_ids: [...]}`.
9. `UPDATE delivery_notes SET total`.
10. Devuelve `_delivery_note_payload(id)`: cabecera, líneas, número formateable, nombre del cliente y de la sucursal, `converted_sales_order_id`/`operation_id` (NULL en A) y el historial.

Puntos de diseño:

- **Por qué movimientos por par y no por línea.** El remito se edita (R4), y una línea editada cambia de id (reemplazo completo, D5). Con `reference_id` = id del remito y un movimiento por par:
  - el **stock que retiene el remito** en cada par es exactamente `-Σ quantity_delta` de sus movimientos (emisión + ediciones + anulación), sin depender de ids de línea;
  - la anulación y la edición revierten por ese neto, sin reconstruir nada desde las líneas, que es la misma regla de `inventory-single-ledger` ("la reversa lee el ledger, no las líneas").

  La venta escribe un movimiento por línea porque su `reference_id` es la fila de `sales`, que el remito no tiene. Las dos líneas del mismo producto quedan trazables en `metadata.delivery_note_item_ids`.
- **`type` existentes, `reference_type` nuevos.** `type = 'sale'` (sale) y `'sale_return'` (vuelve). `reference_type` en el `CHECK`, aditivos: `'delivery_note'` (emisión y pata de aplicación de una edición), `'delivery_note_update'` (pata de reversa de una edición) y `'delivery_note_reversal'` (anulación).
  - *Rechazado*: `type` nuevos (`delivery_out`/`delivery_in`). Medido: ningún consumidor asume que `type='sale'` implica una fila en `sales` (§Context). Tipos nuevos obligarían a tocar el `CHECK` de `type`, `MovementType`, `MOVEMENT_META` y los filtros entrante/saliente del panel, sin ganar nada que `reference_type` no dé. Para `remitos-compra` valen `type='purchase'`/`'purchase_return'` con los mismos `reference_type`.
- **`stock_control_type` y variantes.** Se reproduce exactamente lo que hace la venta: todo producto vendible, que no sea padre con variantes ni `variant_only`, se descuenta y se controla (en prod hay 0 `untracked`, y el núcleo tampoco los distingue). Una variante se remite como producto propio y su unidad base efectiva es la del padre (helper de RN-24). Un producto sin unidad base sólo admite unidades base, con factor 1 (`unit_requires_base_unit`).
- **Costo congelado.** El movimiento lleva el costo de la línea en el momento en que la mercadería salió. Es el que usará la venta al convertir (D7).

### D5 — Edición: reemplazo atómico con par espejo sólo en los pares que cambian, control de faltante sobre el neto

**`rpc_update_delivery_note(p_delivery_note_id uuid, p_expected_revision integer, p_client_id uuid, p_branch_id uuid, p_delivery_address text, p_notes text, p_items jsonb) → jsonb`**:

1. `SELECT … FROM delivery_notes WHERE id = $1 AND account_id IN (SELECT current_account_ids()) AND direction = 'sale' FOR UPDATE`. Sin fila → `P0404 delivery_note_not_found` (inexistente y ajeno son indistinguibles).
2. Rol `issue` (P0401/P0403).
3. Estado:
   - `converted` → `P0423 delivery_note_locked_converted` ("el remito ya se convirtió en la venta …: para corregirlo, eliminá la venta y el remito vuelve a quedar pendiente");
   - `canceled` → `P0409 delivery_note_invalid_state`.
4. `p_expected_revision` obligatorio. Si difiere de `revision` → `P0409 delivery_note_changed`.
5. Cliente vivo de la cuenta; sucursal de la cuenta, activa y no cerrada; líneas validadas como en el alta. Reemplazo completo: `p_delivery_address`/`p_notes` NULL significan vacío, y la UI manda siempre el valor vigente.
6. **Lock de productos**: unión de los productos de los movimientos del remito y de las líneas nuevas, en orden de `id`, `FOR UPDATE`.
7. **Neto retenido por par**: `held(product, branch) = -Σ quantity_delta FROM stock_movements WHERE reference_id = dn.id AND reference_type IN ('delivery_note','delivery_note_update','delivery_note_reversal') AND account_id = dn.account_id GROUP BY product_id, branch_id`.
8. **Requerido nuevo por par**: `Σ _uom_normalize_quantity(...)` de las líneas nuevas, agrupado por `(product_id, p_branch_id)`.
9. Para cada par cuyo retenido difiere del requerido (incluye el caso de cambiar la sucursal: todos los pares de la vieja retienen > 0 y los de la nueva requieren > 0):
   - **pata de reversa** (si retenido > 0): `c21_apply_branch_stock_delta(+retenido)` + movimiento `type='sale_return'`, `reference_type='delivery_note_update'`, `quantity_delta = +retenido`, `unit_cost_snapshot` = el del movimiento que se devuelve, `metadata.reverses = 'delivery_note_edit'`;
   - **pata de aplicación** (si requerido > 0): gate `branch_stock (ya con la reversa aplicada) >= requerido`, si no `P0409 stock_insuficiente…`; luego `c21_apply_branch_stock_delta(-requerido)` + movimiento `type='sale'`, `reference_type='delivery_note'`, `quantity_delta = -requerido`, con el costo de D6.

   Los pares con retenido igual al requerido **no escriben nada**: una edición de precio, cliente o notas no ensucia el kardex.
10. `DELETE delivery_note_items` + `INSERT` de las líneas nuevas con snapshots (D6). `UPDATE delivery_notes SET client_id, branch_id, delivery_address, notes, total, updated_at, updated_by, revision = revision + 1`.

- **Por qué espejo y no un único movimiento neto**: es la regla vigente de `inventory-single-ledger` para la edición de operaciones (el kardex se lee como la secuencia real de hechos). Se aplica igual, sólo que restringida a los pares que cambian. La venta reversa y aplica todas sus líneas porque sus ids de fila cambian; el remito no tiene esa restricción.
- **Control de faltante sobre el neto**: la reversa se aplica antes del gate. Reducir una cantidad siempre funciona aunque la sucursal esté en 0, y aumentarla exige sólo la diferencia.
- *Rechazado* (recomendación original del explore, anulada por R4): no editar, sino anular y rehacer.
- *Rechazado*: un `PATCH` por línea. El form edita el carrito completo, igual que el presupuesto.

### D6 — Snapshots en la edición: política canónica de operaciones (acarreo por producto)

A diferencia del presupuesto (D5 de `presupuestos-modulo`, que re-toma todo), el remito ya movió mercadería: es una operación, no una cotización. Se aplica la política canónica de `document-snapshots`:
- la línea cuyo `product_id` ya estaba en el remito **acarrea** `name_snapshot`, `sku_snapshot` y `unit_cost_snapshot` de la línea vieja (emparejando por `product_id`; ante varias, la de menor `line_no`);
- la línea con un producto nuevo los congela desde el maestro vigente filtrado por cuenta.

El costo de la pata de aplicación sigue la misma decisión: corregir una cantidad no re-valúa el stock que ya salió.

### D7 — Conversión atómica `rpc_convert_delivery_note_to_sale` y cambio mínimo al núcleo (tanda B)

**RPC**:

```
rpc_convert_delivery_note_to_sale(
  p_idempotency_key   text,
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_canal             text DEFAULT NULL
) RETURNS jsonb  -- {delivery_note_id, delivery_note_number, sales_order_id, operation_id, total, replayed}
```

Sin `p_branch_id`: la venta se imputa a la sucursal del remito, que es de donde salió el stock. Una venta en otra sucursal desalinearía la caja de su stock.

Orden (molde exacto de `rpc_convert_quote_to_sale`):

1. Entrada: `auth.uid()`; clave no vacía (P0400); `p_payment_method_id` obligatorio (`P0400 payment_method_required`); `p_expected_revision` obligatorio.
2. **Lock del origen primero**: `SELECT … FROM delivery_notes WHERE id = $1 AND account_id IN (SELECT current_account_ids()) AND direction = 'sale' FOR UPDATE` (P0404). Después, rol `convert`: `is_account_writer` + roles ∩ `{seller, cashier, admin, owner}` (P0401/P0403).
3. **Idempotencia bajo el lock**:
   - si existe `operation_idempotency(user, 'sale', key)` y su orden tiene `source_delivery_note_id = p_delivery_note_id` → replay `{…, replayed: true}`;
   - si existe para otra orden → `P0409 idempotency_key_conflict`.
4. Estado `issued`; si no, `P0409 delivery_note_invalid_state` (un `converted` responde por su estado). Revisión: `P0409 delivery_note_changed`.
5. **Cliente vivo** (`clients.deleted_at IS NULL`): si no, `P0404 delivery_note_client_unavailable` ("editá el remito y elegí un cliente vigente"). Es la misma razón que en el presupuesto: una venta a crédito postearía deuda contra un cliente que cobranzas excluye.
   - **Productos dados de baja después de emitir: se convierten** (OQ-RV3). La mercadería ya se entregó: la venta registra un hecho consumado y el nombre viaja en el snapshot. Por la misma razón no se revalida "padre con variantes".
6. `INSERT sales_orders` (`status='draft'`, `account_id`, `branch_id = dn.branch_id`, `client_id = dn.client_id`, `source_delivery_note_id = dn.id`, `total = dn.total`) con historial `NULL → draft`, y `INSERT sales_order_items` copiando del remito `product_id, unit_id, quantity, price, subtotal` y los cuatro snapshots, **sin re-leer el maestro**.
7. `v_sale := _c29_confirm_order_core(p_idempotency_key, v_order, NULL, p_cash_session_id, NULL, NULL, p_canal, p_payment_method_id, p_bank_account_id)`. Si `v_sale.replayed` → `RAISE 'idempotency_key_conflict' P0409` (la misma clave usada en paralelo sobre otro documento; ver D6 de presupuestos).
8. `record_status_transition(account, 'delivery_note', id, 'issued', 'converted', uid, NULL)` + `UPDATE delivery_notes SET status = 'converted'`. **No** incrementa `revision`: no cambia el contenido.
9. Devuelve `{…, replayed: false}`.

`REVOKE ALL … FROM PUBLIC, anon`; `GRANT EXECUTE … TO authenticated`.

**Cambio al núcleo `_c29_confirm_order_core`** (desde el `pg_get_functiondef` vivo, checkpoint de cuerpo; diff limitado a esta rama):

- Después de cargar la orden y antes del primer guard que escribe, si `v_order.source_delivery_note_id IS NOT NULL`:
  - `SELECT … FROM delivery_notes WHERE id = v_order.source_delivery_note_id FOR UPDATE`. Es un no-op si la conversión ya la tiene, y bloquea si otro camino la estuviera tocando.
  - Exigir, todo a la vez: `account_id = v_account_id`, `direction = 'sale'`, `status = 'issued'`, `client_id IS NOT DISTINCT FROM v_order.client_id` y `branch_id = v_order.branch_id`.
  - Exigir que el multiconjunto de líneas de la orden `(product_id, unit_id, quantity)` sea **idéntico** al del remito (dos `EXCEPT ALL` vacíos).
  - Si algo no cumple → `RAISE 'delivery_note_order_mismatch: …' USING ERRCODE = 'P0409'`.
  - Fija `v_from_delivery_note := true`.
- En el loop de líneas con producto, con `v_from_delivery_note`:
  - **se saltean** la normalización, el gate de stock, `c21_apply_branch_stock_delta` y el `INSERT stock_movements`;
  - se conservan el `FOR UPDATE` del producto (para nombre y SKU), la fila legacy `sales` y `sale_items`, con `unit_cost_snapshot = v_item.unit_cost_snapshot` (el costo congelado del remito, OQ-RV4) en lugar de `v_product.cost`.
- Caja, cuenta corriente, banco, fiscal, outbox, historial y `UPDATE` de la orden: **sin cambios**.

Por qué así:

- **La decisión la toma la columna persistida de la orden, nunca un parámetro.** La firma del núcleo no cambia: no hay `p_skip_stock` que un caller pueda pasar. `sales_orders` no tiene políticas de escritura para `authenticated`, y las RPCs definer que crean órdenes hoy (`rpc_quick_sale`, `_quote_accept_core`, la promoción legacy) no conocen la columna. Igual, la revalidación del remito y de las líneas es **autosuficiente** (lección de `tenancy-guard-caja-outbox`: un guard que delega no es guard): una orden fabricada en el futuro con un `source_delivery_note_id` válido, pero con líneas o cliente distintos, o apuntando a un remito ya convertido o anulado, rebota con `P0409` en lugar de regalar mercadería.
- **Una orden sin origen sigue exactamente igual**: el gate exige el diff contra el cuerpo vivo y que `rpc_quick_sale` siga descontando.
- *Rechazado*: un núcleo paralelo `_c29_confirm_order_core_no_stock`. Duplicaría caja, cuenta corriente, banco, fiscal y outbox, que son exactamente lo que no tiene que divergir.
- *Rechazado*: crear la venta con `rpc_create_sale_operation_v2`. Pierde la orden (no sería facturable con `/emit-invoice` sin promoción) y es el camino que el PR #607 está reescribiendo.

**Orden de locks**: `delivery_notes` (FOR UPDATE) → `products` (dentro del núcleo) → inserciones de `sales_orders`/`sales`. La conversión **crea** filas de venta y no bloquea filas existentes de `sales`, así que tomar el remito primero no invierte el orden global `sales → sales_orders → fiscal_documents`. El borrado de la venta (D9) toma el remito **al final** (`sales → sales_orders → fiscal_documents → delivery_notes`). No hay ciclo: la conversión nunca espera un lock de `sales`, y ante un remito `converted` falla de inmediato con `delivery_note_invalid_state`. Se documenta junto a la regla global en `CHANGES.md`; `CLAUDE.md` no se toca en este change.

### D8 — PDF: `build_delivery_note_view` + render con firma; `GET /delivery-notes/{id}/pdf`

- `CommercialDocumentView` suma dos campos opcionales, con default retrocompatible para el presupuesto:
  - `signature_block: bool = False`;
  - `origin_label: str | None = None` ("Sale de: Sucursal Centro").
- `build_commercial_document_pdf` dibuja, si `signature_block`, un recuadro "Recibí conforme" con líneas para Firma, Aclaración, DNI y Fecha, que no se parte entre páginas.
- **Vista** `build_delivery_note_view(dn, lines, client, branch, issuer, show_prices, today)`, función pura:
  - `kind='delivery_note'`, `title='REMITO'`, `number_label='R-…'`, `issued_on`;
  - `recipient` (cliente + `delivery_address` si hay), líneas con cantidad y símbolo de unidad;
  - `show_prices` según el parámetro: sin precios, la tabla muestra sólo descripción y cantidad, y no hay total;
  - `status_stamp`: "ANULADO" si `canceled`; ninguno si `issued` o `converted`. El remito convertido no es un documento distinto: es la misma entrega;
  - `notes`, `signature_block=True`;
  - leyenda: **"Remito — documento no válido como factura."**
- Emisor: `rpc_commercial_issuer` + `resolve_commercial_issuer`, sin cambios (nunca bloquea).
- **Endpoint** `GET /delivery-notes/{id}/pdf?disposition=inline|attachment&show_prices=false`:
  - 200 `application/pdf` en cualquier estado;
  - otra cuenta o inexistente → 404 `delivery_note_not_found` (RFC 7807); `disposition`/`show_prices` inválidos → 422;
  - archivo `remito-R-00000012.pdf`;
  - lectura para cualquier miembro de la cuenta.
- *Rechazado*: render propio del remito. El constructor compartido ya existe para esto (`view.py:7-8`).

### D9 — Vida posterior de la venta nacida de un remito (tanda B)

**Borrado** (`rpc_delete_sale_operation`, desde el cuerpo vivo; R5):
- Todo lo actual queda igual (guard fiscal, cuenta corriente, caja, banco, outbox, cancelación de la orden). La reversa de stock por fila **ya es un no-op por construcción**: las filas `sales` de esa venta no tienen movimientos propios. Para que no dependa de esa casualidad:
  - si la orden tiene `source_delivery_note_id`, el loop de `rpc_reverse_stock_movement` **se saltea explícitamente**;
  - el gate asserta que el stock no cambia.
- Después de cancelar la orden: `SELECT … FROM delivery_notes WHERE id = v_source_dn FOR UPDATE`, `record_status_transition(…, 'converted', 'issued', v_uid, 'Venta eliminada (operación …)')` y `UPDATE status = 'issued'`. El índice único parcial de D1 queda libre (la orden pasó a `canceled`), así que el remito se puede volver a convertir.
- El **diálogo de borrado** suma la línea: "El stock no vuelve: la mercadería quedó entregada con el remito R-…, que vuelve a quedar pendiente. Para devolverla al stock, anulá el remito." El read model expone `source_delivery_note_id`/`source_delivery_note_number` (D13).

**Edición** (`rpc_atomic_update_sale_operation`, desde el cuerpo vivo):
- Inmediatamente después del lock de las filas `sales` y del guard de cliente, y **antes** de la anulación fiscal y de cualquier reversa, si alguna orden de la operación tiene `source_delivery_note_id` → `RAISE 'delivery_note_sale_locked: la venta nació del remito R-…: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo' USING ERRCODE = 'P0423'`.
- Va antes del bloque fiscal para no anular un comprobante pendiente por una edición que igual se rechaza.
- Bloquea la operación **entera**, también la cabecera. El editor de ventas no tiene un camino de "sólo cabecera": siempre reemplaza líneas (REVERSE+APPLY), y la APPLY volvería a descontar stock.
- En la UI, "Editar" queda deshabilitado con ese motivo.

**Anular un remito convertido**: `P0423 delivery_note_locked_converted` (primero se borra la venta).

### D10 — Baja de sucursal: el remito pendiente es contenido operativo

`fn_guard_branch_decommission` (desde el cuerpo vivo de `20261014000001`) suma una **cuarta** condición, evaluada después de las tres existentes: remitos de venta `issued` con `branch_id` = la sucursal → `P0428`. El mensaje nombra la cantidad y la acción: "tiene N remitos pendientes de convertir: convertilos en venta o anulalos".

- Por qué: con la sucursal cerrada, la conversión falla (`branch_closed`, P0422, en el núcleo). Anular el remito devolvería stock a una sucursal muerta, que es el incidente del 22-08 al revés.
- El remito `converted` no bloquea (su vida en la sucursal terminó). El gate `test_sucursal_guard_vaciado_auditoria.sql` se re-ejecuta y suma este caso.

### D11 — UI

- **Sidebar**: `{ title: "Remitos", href: "/remitos", icon: PackageCheck }` en *Operaciones*, después de "Presupuestos". Sin gate de plan. `Truck` ya lo usa "Proveedores". Breadcrumb: `/remitos` "Remitos", `/remitos/nuevo` "Nuevo remito", `/remitos/<id>` "Detalle de remito", `/remitos/<id>/editar` "Editar remito", con el mismo mecanismo que presupuestos.
- **Pestañas De venta / De compra: ausentes en este change** (OQ-RV6). Una pestaña deshabilitada "Próximamente" anuncia una función sin fecha y ocupa espacio en móvil. El listado ya filtra por `direction` en la API, así que `remitos-compra` agrega la pestaña sin cambiar el contrato.
- **`/remitos`** (listado):
  - `GET /delivery-notes?direction=sale&status=&q=&client_id=&page=&page_size=`, paginado `{items,total,page,pages}`;
  - pestañas de estado: Todos, Pendientes, Convertidos, Anulados;
  - búsqueda por cliente o número;
  - columnas: número, cliente, fecha, sucursal, cantidad de ítems, total y estado (`DeliveryNoteStatusBadge`, tokens semánticos). En móvil, tarjetas;
  - encabezado con el resumen "N remitos pendientes por $ X" (OQ-RV12);
  - CTA "Nuevo remito" con `CAN_DELIVER_SALE` y estado vacío con explicación ("El remito descuenta stock al emitirse y se convierte en venta cuando cobrás").
- **`/remitos/nuevo`** (`?cliente=<id>`) y **`/remitos/[id]/editar`**: `DeliveryNoteForm`.
  - Se compone de las piezas que usa `QuoteForm`: `ProductPicker`, `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput` + `resolveScan`, unidades y `lib/cart-utils` con **`enforceStock: true`**. Sin "Agregar concepto".
  - **Stock de la sucursal elegida**, leído de `useBranchStock(branchId)`, no de `product.stock` (que es el agregado): checkpoint 9.1 verifica qué fuente usa el formulario de venta tras el PR #606 y la reutiliza.
  - **En la edición**, las líneas rehidratadas llevan `source: "persisted"`, así que `exceedsStock` no las suma. El disponible mostrado es `stock de la sucursal + lo que retiene este remito` en esa sucursal (el `quantity_base` de las líneas persistidas). Si cambia la sucursal, lo retenido deja de sumarse.
  - Cliente: `SearchableSelect` + "Nuevo cliente" en el lugar, el mismo patrón que `QuoteForm`.
  - Sucursal obligatoria (`BranchSelect`); por defecto, la principal de la cuenta (la definición de `lib/default-branch.ts` si el PR #607 ya está en `main`; si no, la misma resolución que el formulario de venta).
  - Domicilio de entrega, precargado con el domicilio principal del cliente (`client-addresses`), y notas.
  - Avisos accionables de `P0409 stock_insuficiente`, con la acción "Transferir stock" que ya existe.
  - La edición manda la `revision`; ante `delivery_note_changed`, ofrece recargar.
  - Una línea cuyo producto ya no está en el catálogo vivo se marca "Producto no disponible — quitalo" y bloquea el guardado, igual que el presupuesto. Quitarla devuelve su stock.
- **`/remitos/[id]`** (detalle):
  - Cabecera: número, estado, cliente (enlace), teléfono, sucursal de origen, fecha, domicilio y "Modificado el …" si `revision > 1`.
  - Líneas con cantidad y unidad, precios y total. Notas. Historial de estados, con el motivo de la anulación.
  - Si está `converted`: "Venta generada" con enlace a `/ventas/ordenes/<id>` y el estado de su comprobante.
  - Acciones:

| Estado | Acciones |
|---|---|
| `issued` | Compartir (`DocumentShareMenu` + switch "Mostrar precios") · Editar (`CAN_DELIVER_SALE`) · **Venta** (`CAN_SELL`, tanda B) · Anular (`CAN_VOID_DELIVERY_NOTE`) |
| `converted` | Compartir · Ver venta. Leyenda: "Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente" |
| `canceled` | Compartir (PDF con sello ANULADO). Muestra el motivo |

- **`CancelDeliveryNoteDialog`**: motivo obligatorio (textarea, 3–500 caracteres). Enumera lo que vuelve al stock ("Vuelven a Sucursal Centro: 3 × Producto A, 0,450 kg de Producto B"). Manda la `revision`.
- **`ConvertDeliveryNoteDialog`** (tanda B):
  - resumen de líneas y total en sólo lectura;
  - **sucursal fija** (la del remito; `SaleCheckoutFields` gana la prop aditiva `branchReadOnly`);
  - forma de pago, cuenta bancaria y caja con la semántica del POS: con efectivo, la sesión abierta de esa sucursal es obligatoria y, si falta, "Venta" se deshabilita con un enlace a `/caja`;
  - saldo del cliente si es a crédito;
  - `useIdempotencyKey("delivery-note-convert:" + id)`, que se resetea en cada éxito;
  - éxito con `SaleCheckoutSuccess` (Facturar y Ver venta);
  - ante `delivery_note_changed`, recarga sin cerrar.
- **`DocumentShareMenu`**: `fetchPdf(disposition)` cierra sobre el estado del switch "Mostrar precios" (default apagado, R2). `buildDeliveryNoteShareText` (`lib/delivery-note-share.ts`): "Hola {nombre}, te envío el remito R-00000012 de la mercadería entregada el 02/10/2026. {negocio}". `onShared` no cambia el estado: el remito no tiene "enviado".
- **Ficha del cliente**: botón "Nuevo remito" en `ClientDetailHeader` → `/remitos/nuevo?cliente=<id>`, y enlace "Ver remitos" → `/remitos?cliente=<id>`. Sin pestaña nueva (OQ-RV10).
- **`/ventas`** (listado y detalle): badge "Desde remito R-…" con enlace. "Editar" deshabilitado con el motivo de D9. El diálogo de borrado suma la línea de D9.
- **`/stock`** (panel de movimientos): con `reference_type` `delivery_note*`, la etiqueta pasa a "Remito R-…", "Edición de remito R-…" o "Anulación de remito R-…", con enlace al remito. El ícono y el sentido siguen saliendo del `type`. El número se resuelve en el read model del kardex.
- **Errores**: `lib/operation-errors.ts` suma traducciones accionables para:
  - `delivery_note_not_found`, `delivery_note_changed`, `delivery_note_invalid_state`, `delivery_note_locked_converted`;
  - `delivery_note_client_unavailable`, `delivery_note_product_required`, `delivery_note_branch_required`;
  - `delivery_note_sale_locked`, `delivery_note_order_mismatch`, `delivery_note_cancel_reason_required`.
  
  Reutiliza `stock_insuficiente`, `insufficient_role`, `cash_requires_session`, `idempotency_key_conflict` y `payment_method_required`.
- **Design system**: tokens semánticos, `cva`, `ResponsiveModal`. Verificación en desktop y 375 px × claro y oscuro.

### D12 — Reutilización en SQL: guard de producto compartido

El predicado "producto vivo, de la cuenta y no padre con variantes ni `variant_only`" vive hoy embebido en `_quote_validate_items` (`20261067000001:439-450`), y el remito lo necesita idéntico. Se extrae a `_assert_document_product(p_account_id uuid, p_product_id uuid) RETURNS public.products`: interno, `STABLE`, sin `EXECUTE` para roles de aplicación, mismos literales (`product_not_found` P0404, `product_is_parent` P0400).

- `_quote_validate_items` se reescribe **desde su cuerpo vivo** para llamarlo, sin otro cambio. `test_presupuestos_modulo.sql` es el safety net y tiene que seguir verde sin tocarlo.
- `_delivery_note_validate_items` lo llama también.
- *Rechazado*: copiar el predicado. Es la regla del proyecto, "reutilización antes que repetición", y `remitos-compra` sería el tercer consumidor.
- Los demás helpers del remito son propios (`_delivery_note_assert_role`, `_delivery_note_insert_items`, `_delivery_note_apply_stock`, `_delivery_note_reverse_held`, `_delivery_note_payload`), con el mismo régimen de ACL: sin `authenticated`, cubiertos por el chequeo (4) del gate de ACLs por la convención `_*`.

### D13 — Backend 3 capas

- **`schemas/delivery_notes.py`**:
  - `DeliveryNoteItemIn` (`product_id` obligatorio, `unit_id?`, `quantity > 0`, `price ≥ 0`, `subtotal ≥ 0`);
  - `DeliveryNoteCreateIn` (`direction: Literal["sale"]`, `client_id`, `branch_id`, `delivery_address?` ≤ 500, `notes?` ≤ 2000, `items` de 1 a 500);
  - `DeliveryNoteUpdateIn` (+ `revision`), `DeliveryNoteCancelIn` (`reason` de 3 a 500, `revision`);
  - `DeliveryNoteConvertIn` (`expected_revision`, `payment_method_id`, `cash_session_id?`, `bank_account_id?`, `canal?`, `idempotency_key?`);
  - `DeliveryNoteOut`, `DeliveryNoteListItemOut`, `DeliveryNoteConvertOut`.
- **`repositories/delivery_note_repository.py`**: todo por RPC o por `SELECT` con `account_id` explícito (regla dura #446).
- **`services/delivery_notes.py`**: guards de capacidad y mapeo a RFC 7807 con el literal SQL como `code`.
- **`routers/delivery_notes.py`**:
  - `GET /delivery-notes`, `POST /delivery-notes`, `GET /delivery-notes/{id}`, `PUT /delivery-notes/{id}`, `POST /delivery-notes/{id}/cancel`, `GET /delivery-notes/{id}/pdf`;
  - tanda B: `POST /delivery-notes/{id}/convert`, con `require_idempotency_key`.
- **`core/rbac.py`**:
  - `CAN_DELIVER_SALE = frozenset({"owner","admin","seller","stock"})`;
  - `CAN_VOID_DELIVERY_NOTE = frozenset({"owner","admin"})`. Su contenido coincide con `CAN_CONFIGURE`, así que `is_sensitive_capability` lo trata como sensible: la autoridad es la base y no el claim. Es deliberado para una acción que devuelve stock (el error queda del lado seguro);
  - la conversión usa `CAN_SELL`.
  - Un test lee las migraciones y falla si estas capacidades divergen de los `allowed_role` del catálogo (molde de `TestCanQuote`).
- **Read model de ventas**: `source_delivery_note_id` y `source_delivery_note_number`, derivados de `sales_orders.source_delivery_note_id → delivery_notes` con `account_id` en el `JOIN` (molde de `source_quote_number`). `/ventas/ordenes` también.
- **`product_repository._GROUP_HAS_LINES_IN_OTHER_UNIT_SQL`** suma `delivery_note_items` (D14).

### D14 — Unidades: el remito entra a la definición única y a los dos guards

- **Normalización**: la emisión y la edición usan `_uom_normalize_quantity` (D4/D5). El delta de la anulación y de la reversa sale del ledger, nunca de reconvertir líneas. El escenario "las funciones que escriben stock no conservan una conversión propia" se extiende a las funciones del remito.
- **Guard de unidad base** (`fn_product_base_unit_guard`, cuerpo vivo): la rama "asignar una unidad sobre historia en otra unidad" suma `delivery_note_items` a su `UNION` de líneas (`:3748-3754`). Ídem `_GROUP_HAS_LINES_IN_OTHER_UNIT_SQL`. Sin esto, un remito de 450 g de un producto sin unidad base quedaría reinterpretado como 450 kg al asignarle "Kilogramo".
- **Guard de unidad en uso** (`fn_uom_in_use_guard`, cuerpo vivo): suma `OR EXISTS (SELECT 1 FROM delivery_note_items WHERE unit_id = OLD.id)`.
- El gate de unidades suma los dos casos con una línea de remito.

### D15 — Reporting

- **Un remito pendiente no es venta**: ninguna métrica de ventas, ranking, estadísticas ni Tablero lo cuenta, porque todos leen `sales`/`reporting_sales_lines_in_window`. Al convertir, la venta entra con la fecha **de la conversión** (`reporting_local_today()` del núcleo), que es cuando se cobró o se cargó la deuda.
- **El stock sí baja al emitir**: `branch_stock`, stock crítico y valuación lo reflejan desde ese momento. La valuación del costo del stock que salió está en `stock_movements.unit_cost_snapshot`.
- **El margen de la venta convertida** usa el costo congelado del remito (D7, OQ-RV4), no el del día de la conversión.
- **En `/stock`** el movimiento aparece rotulado como remito (D11), y el kardex reconstruye el stock porque el ledger tiene las tres patas (`delivery_note`, `delivery_note_update`, `delivery_note_reversal`).
- La "mercadería entregada sin facturar" se ve en el resumen del listado de `/remitos`. No hay KPI en el Tablero (OQ-RV12).

### D16 — Migraciones, gates y tandas

Números: **el siguiente libre ≥ `20261069000001`** al momento de cada apply (se re-mide `ls supabase/migrations` y `MAX(version)` de prod en el checkpoint; `20261068000001` es la tanda B de presupuestos).

**Tanda A** — documento + stock + PDF + UI (sin conversión):

- **DDL**:
  - tablas, índices y RLS de sólo lectura;
  - `CHECK` ampliados: `internal_document_sequences`, los dos de FSM y `stock_movements.reference_type` con sus tres valores;
  - las dos filas del catálogo de la tanda A;
  - disparadores de número, creación y enforcement.
- **Funciones**:
  - `_assert_document_product` + `_quote_validate_items` reescrita;
  - los helpers `_delivery_note_*`;
  - `rpc_create_sale_delivery_note`, `rpc_update_delivery_note`, `rpc_cancel_delivery_note(p_delivery_note_id, p_expected_revision, p_reason)` y `rpc_get_delivery_note(p_id)` (payload para el endpoint).
- **Reescrituras desde el cuerpo vivo**: `fn_product_base_unit_guard`, `fn_uom_in_use_guard` y `fn_guard_branch_decommission`, conservando cada `COMMENT` y re-aplicando `REVOKE`/`GRANT` tras cualquier `DROP`. Se prefiere `CREATE OR REPLACE` con la misma firma.
- **Introspección final** (bloque `DO`):
  - columnas, `CHECK`, índice único y disparadores;
  - ninguna política de escritura;
  - ACLs: RPCs sin `anon`, helpers sin `authenticated`;
  - una sola definición de cada función reescrita;
  - el cuerpo de `_quote_validate_items` llama al helper;
  - el cuerpo de los guards de unidad nombra `delivery_note_items`.

`rpc_cancel_delivery_note`:
1. lock;
2. rol `void` (admin/owner, P0403);
3. estado: `converted` → `P0423`; `canceled` → `P0409`;
4. revisión;
5. motivo no vacío (`P0400 delivery_note_cancel_reason_required`; `record_status_transition` lo exige igual por el catálogo);
6. por cada par con retenido > 0: `c21_apply_branch_stock_delta(+retenido)` + movimiento `type='sale_return'`, `reference_type='delivery_note_reversal'`, con el costo del movimiento original y `metadata.reverses = 'delivery_note_cancel'`;
7. historial `issued → canceled` con el motivo + `UPDATE status`.

**Tanda B** — conversión:

- `sales_orders.source_delivery_note_id` + índice único parcial;
- las dos filas del catálogo de la tanda B;
- `_c29_confirm_order_core`, `rpc_delete_sale_operation` y `rpc_atomic_update_sale_operation` desde el cuerpo vivo, cada una con el `COMMENT` vivo re-declarado;
- `rpc_convert_delivery_note_to_sale`;
- introspección: una definición por función, las ACLs vivas idénticas a las previas en las tres reescritas, y los cuerpos contienen la rama de origen, el salto de reversa y el `P0423`.

**Gates** (se ejecutan de verdad; "toda RPC que otras invocan necesita un gate que la EJECUTE"):

- **`supabase/tests/test_remitos_venta.sql` (A)**:
  - dos cuentas; owner, admin, seller, stock y cashier reales (molde de `test_document_status_transition_role_matrix.sql`); fixtures propios y cleanup asertado;
  - emisión: stock − por par, movimiento `sale/delivery_note` con `quantity_before/after` y costo, normalización 450 g → 0,45 kg, número `R` correlativo e independiente del `P` de presupuestos y de otra cuenta, historial `NULL → issued` con el creador;
  - rechazos con su código: sin cliente, cliente ajeno o dado de baja, sin sucursal, sucursal ajena o cerrada, línea sin producto, producto ajeno, dado de baja o padre, unidad incompatible, unidad de otra cuenta;
  - faltante → `P0409` con **cero** efectos (sin fila de remito, número no consumido, stock intacto);
  - roles: el cashier no emite (`P0403`); el stock emite y edita pero no anula;
  - edición:
    - sólo precio → 0 movimientos nuevos;
    - aumento con stock → par espejo en ese producto; aumento sin stock → `P0409` y cero efectos;
    - reducción con la sucursal en 0 → funciona;
    - cambio de producto → reversa del viejo y aplicación del nuevo;
    - cambio de sucursal → pares en dos sucursales;
    - snapshot acarreado para el producto que sigue;
    - versión vieja → `P0409 delivery_note_changed`;
    - editar un anulado → `P0409`;
  - anulación: sin motivo → `P0400`; seller → `P0403`; admin → stock repuesto con `delivery_note_reversal` y historial con el motivo; segunda anulación → `P0409`;
  - **invariante**: después de emisión, ediciones y anulación, Σ `quantity_delta` por par = cambio de `branch_stock` y el neto final es 0;
  - PostgREST (`SET ROLE authenticated`) no puede `INSERT`/`UPDATE` en `delivery_notes`/`delivery_note_items` ni ejecutar los helpers;
  - guards de unidad: asignar Kilogramo a un producto sin base con una línea de remito en Gramo → `P0409 base_unit_locked`; cambiar el factor de una unidad usada sólo en un remito → `P0409 unit_in_use`;
  - baja de sucursal con un remito pendiente → `P0428` que nombra los remitos; anulado el remito, la baja procede;
  - `_quote_validate_items` sigue rechazando con los mismos literales (regresión).
- **`supabase/tests/test_remito_a_venta.sql` (B)**, con **matriz de evasión**:
  - conversión `cash` (caja, `SaleConfirmed`, orden `confirmed` con `source_delivery_note_id`, remito `converted`, historial de los dos documentos), `credit` (cargo con vencimiento por cascada) y `transfer` (`bank_movements`);
  - **stock idéntico antes y después de convertir**; **0** `stock_movements` con `reference_id` en las filas `sales` de la venta; `sale_items.unit_cost_snapshot` = el costo del remito;
  - producto dado de baja después de emitir → convierte; cliente dado de baja → `P0404 delivery_note_client_unavailable` y cero efectos;
  - replay → `replayed = true`; misma clave sobre otro remito → `P0409 idempotency_key_conflict`; segunda conversión con otra clave → `P0409 delivery_note_invalid_state`; versión vieja → `P0409`;
  - roles: el cashier convierte; el stock → `P0403`;
  - `cash` sin sesión → `P0400 cash_requires_session` y cero efectos;
  - **una orden sin origen sigue descontando** (`rpc_quick_sale` de regresión, con su movimiento `sale/sale`);
  - **núcleo con un origen inválido** (orden armada como `postgres` en el gate): remito de otra cuenta, `canceled`, `converted`, de otro cliente o de otra sucursal, y líneas distintas en producto, unidad o cantidad → `P0409 delivery_note_order_mismatch`, sin stock, venta ni evento;
  - **borrar la venta**: dinero compensado, stock idéntico, orden `canceled`, remito `issued` con historial `converted → issued` y motivo; reconvertir funciona (índice parcial);
  - editar la venta → `P0423 delivery_note_sale_locked` y cero efectos, incluido un comprobante pendiente **no** anulado;
  - anular un remito convertido → `P0423`;
  - el `P0423` de dinero de una venta POS común no cambia (regresión).
- **`supabase/tests/test_remitos_venta_race.sh`** (molde: `test_presupuesto_a_venta_race.sh`):
  - dos conversiones del mismo remito → una venta;
  - conversión contra anulación → gana una; nunca venta con remito `canceled`;
  - edición contra conversión → la segunda recibe `delivery_note_changed` o `invalid_state`;
  - dos emisiones por la última unidad → una `P0409`;
  - borrado de la venta contra reconversión → sin interbloqueo.
  
  La numeración concurrente reutiliza `test_internal_document_numbering_race.sh`, parametrizado por tipo.
- **Gates existentes actualizados por tanda**:
  - `test_document_status_transition_role_matrix.sql`: tamaño del catálogo, llamadores de `record_status_transition` y pares producidos;
  - `test_function_acl_gate.sql`: clasificación de las funciones nuevas;
  - el gate de unidades de `ventas-unidades-conversion` y `test_sucursal_guard_vaciado_auditoria.sql`;
  - `test_presupuestos_modulo.sql`, `test_presupuesto_a_venta.sql` y `test_operacion_party_guard.sql`, re-ejecutados.
- Todos cableados en `KPI_Validation.yml`, en el orden real del workflow, y las dos migraciones al final de la cadena de reaplicación.

**Dos PRs** (A, luego B), con CI verde y revisión adversarial antes de cada merge. La tanda A entrega valor sola (crear, editar, anular, compartir). En A, el botón "Venta" no se muestra.

## Coordinación con otros changes

- **PR #607 `ventas-sucursal-por-defecto`** (sólo docs al 2026-10-02): reescribirá `rpc_create_sale_operation_v2`, la rama legacy de `rpc_create_sale_operation` y `rpc_atomic_update_sale_operation`. Este change reescribe `rpc_atomic_update_sale_operation` (tanda B). **Dependencia de orden: quien llegue segundo parte del `pg_get_functiondef` vivo** que dejó el primero, y lo verifica en su checkpoint de cuerpo (hash por líneas sin `\r`). Las otras dos funciones no se tocan acá. `lib/default-branch.ts` (D10 de #607) se reutiliza si ya está en `main`.
- **`presupuestos-modulo` tanda B** (`20261068000001`, sin mergear): la tanda B de este change depende de `SaleCheckoutFields`/`SaleCheckoutSuccess` y del molde de `rpc_convert_quote_to_sale`. Si al momento del apply de B no está mergeada, B espera. La tanda A no depende de ella.
- **`remitos-compra`** (siguiente): sumará `'delivery_note_purchase'`, su RPC de alta (stock +), la conversión a compra y la pestaña "De compra", sobre las mismas tablas, FSM y helpers. Las filas del catálogo de compra las siembra ese change.

## Risks / Trade-offs

- **[Doble descuento al convertir]** → el núcleo decide por la columna persistida, revalida el remito y sus líneas, y la matriz de evasión del gate cubre: origen ajeno, anulado, convertido, de otro cliente, de otra sucursal, líneas distintas y dos conversiones concurrentes.
- **[Regresión del POS y de la conversión de presupuestos por tocar el núcleo]** → checkpoint de cuerpo vivo, diff limitado a la rama `v_from_delivery_note`, gate de `rpc_quick_sale` y de `rpc_convert_quote_to_sale` re-ejecutados, y revisión adversarial.
- **[Edición de la venta descontaría de nuevo]** → `P0423 delivery_note_sale_locked` antes de cualquier escritura, con gate de cero efectos.
- **[Borrado de la venta devuelve stock por error]** → salto explícito de la reversa (no depende de la ausencia de movimientos) y gate de stock idéntico.
- **[Remito pendiente en una sucursal dada de baja]** → cuarta condición del guard `P0428` (D10).
- **[Guard de unidad evadible por la tabla nueva]** → `delivery_note_items` en los tres puntos (D14), con un caso de gate por cada uno.
- **[Kardex con ruido por ediciones de precio]** → espejo sólo en los pares que cambian (D5).
- **[Interbloqueo entre un remito y una venta concurrente sobre los mismos productos]** → el remito lockea productos en orden de id. El cruce con el núcleo (orden de línea) es el mismo riesgo que ya existe entre dos ventas. `40P01` es reintentable y el gate de carrera mide que dos emisiones por el mismo stock no se interbloquean.
- **[Orden nuevo de locks con `delivery_notes` primero]** → justificado en D7 (la conversión no bloquea `sales` existentes) y cubierto por el gate de carrera borrado contra reconversión.
- **[Costo de la venta distinto del costo de catálogo del día]** → es deliberado (OQ-RV4): el margen refleja el costo con el que salió la mercadería.
- **[RLS preexistente de `stock_movements`/`branch_stock` con `INSERT`/`UPDATE` para `authenticated`]** → no la abre este change y tampoco la cierra (fuera de alcance). Queda anotado como candidato en `CHANGES.md`: un escritor por PostgREST podría alterar el stock sin pasar por el remito, igual que hoy sin el remito.
- **[Choque con el PR #607 sobre `rpc_atomic_update_sale_operation`]** → dependencia de orden declarada; el segundo parte del cuerpo vivo.
- **[Producto dado de baja que sigue en un remito pendiente]** → se convierte igual (D7). Al editar, la línea se marca "no disponible" y quitarla devuelve el stock.

## Migration Plan

1. **Tanda A**:
   - merge → CI/CD aplica la migración y despliega frontend y backend (verificar `GET /deploys` de Render);
   - verificación post-merge (sólo lectura): `MAX(version)`, tablas, `CHECK` (incluidos los tres `reference_type` y `delivery_note_sale`), disparadores, cero políticas de escritura, ACLs, una definición de cada función reescrita, catálogo `delivery_note` con 2 filas;
   - humo del PO: crear un remito → el stock baja en `/stock` con el rótulo "Remito" → editarlo (subir y bajar cantidades, cambiar un precio) → compartir por WhatsApp con y sin precios → anularlo con motivo → el stock vuelve.
2. **Tanda B** (después del merge de la tanda B de presupuestos):
   - merge → verificación post-merge: columna e índice parcial, catálogo con 4 filas, cuerpos vivos con la rama de origen;
   - humo del PO: remito → Venta (efectivo con caja abierta y a crédito) → el stock **no** vuelve a bajar → aparece en `/ventas` con el badge → Facturar → borrar la venta → el remito vuelve a pendiente y el stock no cambia → reconvertir.
3. **Rollback**:
   - A: revertir el PR deja las tablas sin uso. Si hay remitos emitidos, se anulan antes desde la UI para devolver el stock. Las reescrituras de los guards se revierten con una migración nueva desde el cuerpo previo, capturado en el checkpoint.
   - B: una migración nueva re-aplica los cuerpos previos de las tres funciones (capturados en los checkpoints) y hace `DROP FUNCTION rpc_convert_delivery_note_to_sale`. Las ventas ya convertidas siguen siendo ventas válidas; su stock vive en el remito, y un borrado posterior sin la rama de salto sería un no-op igual (no tienen movimientos propios).

## Sign-off del PO

**Decisiones firmadas (2026-09-29), textuales**: «no necesito el remito legal. Andá con todo lo recomendado» y «quiero que tanto el remito como los presupuestos se puedan modificar». Cubren **R1–R8** del explore (OQ-R1..R8), con R4 cambiado por el PO respecto de la recomendación:

- **R1**: remito interno "X", leyenda "documento no válido como factura", sin ARCA ni CAI → D8, Non-goals.
- **R2**: PDF sin precios por defecto, con "mostrar precios"; los precios se guardan siempre → D1, D8, D11.
- **R3**: anular repone stock y exige motivo → D3, D16 (`rpc_cancel_delivery_note`).
- **R4**: editable mientras no esté convertido, con espejo REVERSE+APPLY y control de faltante; convertido → `P0423` → D5, D6.
- **R5**: borrar la venta nacida del remito lo devuelve a pendiente sin tocar stock → D9.
- **R6**: aplica a `remitos-compra`.
- **R7**: emitir: seller/stock/admin/owner; anular: admin/owner → D3, D13.
- **R8**: 1 remito → 1 venta con todas sus líneas; sin gate de plan; descarga + WhatsApp sin link público ni email → D7, D11.

**Las OQ-RV de abajo son nuevas de este propose.** Se adoptan por su recomendación como default declarado, el mismo criterio que los changes anteriores, salvo que el PO elija otra alternativa antes del apply (tarea 0.1).

## Open Questions

- **OQ-RV1 — Secuencia del número.**
  - *Recomendado*: una por sentido (`R-` venta; compra con la suya en `remitos-compra`) (D2).
  - *Alternativa*: una sola secuencia para los dos sentidos.
- **OQ-RV2 — Quién convierte un remito en venta.**
  - *Recomendado*: `CAN_SELL` (vendedor, cajero, administrador y dueño). El cajero cobra cuando el cliente viene a pagar lo que se llevó. El rol `stock` emite pero no cobra.
  - *Alternativa*: sólo los que emiten (`seller/stock/admin/owner`), lo que daría a `stock` un camino a caja.
- **OQ-RV3 — Convertir con productos dados de baja después de emitir.**
  - *Recomendado*: **se convierte** (la mercadería ya se entregó) (D7).
  - *Alternativa*: exigir editar el remito, como el presupuesto. Pero quitar la línea devolvería stock que no está.
- **OQ-RV4 — Costo de la venta convertida.**
  - *Recomendado*: el **congelado en el remito** (costo al salir la mercadería) (D7, D15).
  - *Alternativa*: el del catálogo al convertir, como el núcleo hace hoy.
- **OQ-RV5 — ¿La sucursal es editable?**
  - *Recomendado*: sí, mientras esté pendiente; el espejo traslada el stock entre sucursales (D5).
  - *Alternativa*: fija; para cambiarla se anula y se rehace.
- **OQ-RV6 — Pestañas De venta / De compra.**
  - *Recomendado*: **ausentes** hasta `remitos-compra` (D11).
  - *Alternativa*: mostrar "De compra — próximamente" deshabilitada.
- **OQ-RV7 — Domicilio de entrega.**
  - *Recomendado*: campo opcional de texto, precargado con el domicilio principal del cliente e impreso en el PDF (D1).
  - *Alternativa*: sin campo (va en notas).
- **OQ-RV8 — Remito pendiente y baja de sucursal.**
  - *Recomendado*: bloquea la baja (`P0428`, D10).
  - *Alternativa*: no bloquear y permitir convertir o anular en una sucursal cerrada (reabre el incidente de stock en sucursal muerta).
- **OQ-RV9 — Fecha del remito.**
  - *Recomendado*: hoy (ART), no editable. El stock se mueve ahora y el kardex fecha por instante.
  - *Alternativa*: fecha editable hacia atrás (desalinea documento y ledger).
- **OQ-RV10 — Remitos en la ficha del cliente.**
  - *Recomendado*: botón "Nuevo remito" + enlace al listado filtrado, sin pestaña nueva.
  - *Alternativa*: pestaña "Remitos" con los últimos 5, como presupuestos.
- **OQ-RV11 — Líneas sin producto (servicio, flete).**
  - *Recomendado*: **no** admitidas en v1 (D1).
  - *Alternativa*: admitirlas sin stock. Reabre los problemas de líneas de servicio en `/ventas` (OQ-P15/P16).
- **OQ-RV12 — Indicador de mercadería entregada sin facturar.**
  - *Recomendado*: resumen en el encabezado de `/remitos`; sin KPI en el Tablero en v1.
  - *Alternativa*: tarjeta "Remitos pendientes" en el Tablero.
- **OQ-RV13 — Precio al convertir.**
  - *Recomendado*: el del remito; si cambió, se edita el remito antes de convertir (R4). El diálogo no edita precios.
  - *Alternativa*: precios editables en el diálogo (duplicaría el editor y saltearía la revisión del remito).
