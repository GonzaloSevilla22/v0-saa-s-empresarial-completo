## Context

El pedido, las decisiones firmadas (R1–R8 aplicadas a compra) y el alcance están en `proposal.md`. El mapa de partida está en el explore (`openspec/changes/archive/2026-10-02-presupuestos-modulo/research/explore-presupuestos-remitos.md` §1.3, §2.3, §3 (d)–(e), §4–§6). El molde de este documento es el change hermano `remitos-venta` (`openspec/changes/remitos-venta/`, D1–D16), que dejó el modelo de datos preparado para los dos sentidos y cuya tanda A ya está en `main` (PR #612, `1be4aa27`, migración `20261069000001_remitos_venta.sql`, aplicada en prod al 2026-10-03). Las citas de líneas de `20261069000001` son del archivo en `main`. Este documento cubre **sólo** `remitos-compra`.

### Lo que ya existe

| Pieza | Dónde (última definición) | Relevante para este change |
|---|---|---|
| `rpc_create_purchase_operation` | `20261062000001_ventas_unidades_conversion.sql:700-1115`. **`md5(prosrc)` de prod = el del archivo** (`0366977251522a469d123c4d143f42f9`, medido el 2026-10-03). `SECURITY DEFINER`, `EXECUTE` para `authenticated`, **sin `COMMENT`** | Operación plana de un paso, sin ningún documento previo. Cuenta = `current_account_ids() LIMIT 1` (`:787`). Idempotencia DEC-06 con `operation_kind = 'purchase'` (`:876-905`). Loop por línea en orden de `product_id` (`:907`): `FOR UPDATE` del producto (`:925`), chequeo **por usuario** `v_product.user_id <> v_uid` → `P0403` (`:934`), padre con variantes → `P0422` (`:938-944`), `_uom_normalize_quantity` después del lock (`:951`), `purchases` + `purchase_items` con `unit_cost_snapshot = products.cost` (`:953-977`), **suma** stock con `c21_apply_branch_stock_delta` y movimiento `type = 'purchase'`, `reference_type = 'purchase'`, `reference_id` = fila de `purchases` (`:979-1000`). Líneas sin producto admitidas (`:1002-1016`). Total = `round(Σ amount × quantity, 2)` (`:1027`). Caja con las tres condiciones (`:1043-1067`), banco (`:1072-1076`), cuenta corriente del proveedor con vencimiento si `kind = 'credit'` (`:1081-1086`), `PurchaseCreated` (`:1089-1107`). **No toca `products.cost`.** |
| `rpc_atomic_update_purchase_operation` | `20261062000001:2263-2626` (`md5(prosrc)` igual a prod: `23558c07…`) | Sin lock de filas. Tres `P0423` de dinero (cuenta corriente, banco, caja). Después, REVERSE por fila: busca el último movimiento `reference_type = 'purchase'` de la fila y, si no lo hay, **cae a `_uom_normalize_quantity` de la línea y resta esa cantidad** (`op_stock_movement(…, 'purchase_return', 'purchase_update', …)`); borra las filas y re-inserta con un `operation_id` **nuevo** y una APPLY normalizada. Para una compra nacida de un remito (sin movimientos propios), una edición restaría stock que el remito sigue aportando y la APPLY lo sumaría de nuevo; una reducción dejaría stock restado de más, y la anulación posterior del remito lo restaría otra vez. |
| `rpc_delete_purchase_operation` | `20261018000001_caja_compras_cobranzas.sql:1009` (`md5(prosrc)` igual a prod: `368120a0…`) | Orden: cuenta corriente → caja (`P0426` sin sesión abierta) → banco → `rpc_reverse_stock_movement(purchase_id, 'purchase')` por fila → `PurchaseDeleted` → `DELETE purchases` → `DELETE operation_idempotency`. Sin lock explícito de filas ni guard de rol (preexistente). |
| `rpc_reverse_stock_movement` | `20260828000001_v31_rls_collision_rpcs.sql` | Revierte los movimientos **existentes** con ese `reference_id`/`reference_type`. Sin movimientos, no hace nada y no da error. |
| Helpers de dinero | `_pay_register_party_charge` (`20261022000001`), `_pay_register_operation_bank_movement` (`20261002000001`), `c28_register_cash_movement` (`20261013000001`) | Se usan sin cambios, vía el núcleo de compra. |
| Modelo del remito | `main` (PR #612), `20261069000001:50-160` | `delivery_notes` con `direction IN ('sale','purchase')`, `delivery_notes_counterparty_check` (compra ⇒ `supplier_id NOT NULL` y `client_id NULL`), `supplier_reference text` (≤ 100, sólo en compra), `UNIQUE (account_id, direction, number)`, índice parcial por `supplier_id` (`WHERE status = 'issued'`), `delivery_note_items.quantity_base NOT NULL`. RLS sólo `SELECT`. **Ninguna operación de `remitos-venta` escribe `'purchase'`.** |
| Disparadores del remito | `20261069000001:234-276` | `delivery_notes_assign_number_sale` (genérico `trg_assign_internal_document_number('delivery_note_sale')`), `delivery_notes_record_status_creation_sale` (`trg_delivery_note_record_creation(TG_ARGV[0])`, parametrizado) y `delivery_notes_enforce_status_transition_sale`, los tres con `WHEN (… direction = 'sale')`. |
| Helpers `_delivery_note_*` | `20261069000001:404-852` | **Agnósticos del sentido**: `_delivery_note_lock_products`, `_delivery_note_validate_items` (admite `price ≥ 0`), `_delivery_note_insert_items` (`unit_cost_snapshot = products.cost`), `_delivery_note_held_pairs` (agrupa por la sucursal **leída de `delivery_notes.branch_id`** con un `JOIN`, `:649-672`: no recibe sucursal, así que el retenido nuevo de una edición sólo es correcto si la cabecera ya tiene la sucursal nueva). **Casados con venta**: `_delivery_note_assert_role` (lee `document_type = 'delivery_note_sale'`, `:430`), `_delivery_note_apply_stock` (gate + delta **negativo** + `type = 'sale'`, `:687-738`), `_delivery_note_reverse_held` (delta **positivo** + `type = 'sale_return'`, sin gate, `:751-801`), `_delivery_note_payload` (sólo nombres de cliente, `:812-846`). |
| RPCs del remito | `20261069000001:860-1319` | `rpc_create_sale_delivery_note` y `rpc_update_delivery_note` (contraparte cliente + domicilio), `rpc_cancel_delivery_note` (filtra `direction = 'sale'`, `:1221`), `rpc_get_delivery_note` (agnóstica). En la edición, el orden vivo es: lock de la unión de productos → `v_old` → validación → acarreo de snapshots → `DELETE` de líneas (`:1137`) → **`UPDATE delivery_notes` con `branch_id = p_branch_id`, `total = v_valid->>'total'` y la cabecera de venta** (`:1139-1148`) → `INSERT` de líneas → `v_new := _delivery_note_held_pairs` (`:1152`) → pares que cambian → **reversa primero, aplicación después** (`:1154-1176`). |
| Guard de baja de sucursal | `_branch_pending_delivery_notes` (`20261069000001:1568`) | Cuenta remitos `issued` **sin filtrar `direction`**: un remito de compra pendiente ya bloquea la baja sin tocar nada. |
| Backend del remito | `main`: `backend/{routers,services,repositories,schemas}/delivery_notes*.py` | `GET /delivery-notes` ya acepta `direction=sale|purchase`; `DeliveryNoteCreateIn.direction: Literal["sale"]`. `DeliveryNoteOut` **ya declara** `supplier_id`, `supplier_reference` (`schemas/delivery_notes.py:179-180`) y el campo genérico `converted_operation_id` (`:196`), que `_delivery_note_payload` emite en `NULL` (`20261069000001:826`). `CAN_DELIVER_SALE`, `CAN_VOID_DELIVERY_NOTE`. |
| Frontend del remito | `main`: `app/(dashboard)/remitos/**`, `components/delivery-notes/*`, `lib/delivery-note-*.ts` | El listado pide siempre `direction: "sale"`. Los textos están escritos para venta: `DELIVERY_NOTE_STATUS_LABELS.converted = "Convertido en venta"` (`lib/delivery-note-status.ts:14`), "Sale de:" y los avisos del detalle (`remitos/[id]/page.tsx:131,161,175`), `describeEmitNotice`/`describeRemovalReturn` (`lib/delivery-note-stock.ts`), "Elegí un cliente" (`lib/delivery-note-form.ts`), `deliveryNoteFileName` → `remito-R-….pdf` (`lib/delivery-note-share.ts:43-47`) y "Volver al listado" fijo a `/remitos` (`remitos/[id]/page.tsx:109`). `StagedProductLine` y `applyScanToCart` precargan **`products.price`** (precio de venta, `StagedProductLine.tsx:95,125`, `lib/cart-utils.ts:264`). | `formatDeliveryNoteNumber(direction, n)` ya formatea por sentido y deja el de compra **sin prefijo** hasta este change (`lib/internal-document-number.ts`). El panel de `/stock` rotula por `reference_type` y formatea por `direction`. |
| Formulario de compra | `frontend/components/forms/purchase-form.tsx` (1.172 líneas) | Contiene **embebidos** el selector de proveedor con alta inline (`useSuppliers().addSupplier`, `:582-593`), la forma de pago (`PaymentMethodSelect` + `BankAccountDestinationSelect`), el opt-in de caja (`useCashOptin({ kind, branchId, date, document: "compra" })`, `:214`), el saldo del proveedor a crédito (`useSupplierAccount`, `:244`), el bloqueo de crédito sin proveedor y la fecha. **No tiene campo de vencimiento**: la RPC acepta `p_due_date`, pero ni el formulario, ni `hooks/data/use-purchases.ts`, ni `schemas/purchases.py` lo transportan (la cascada del plazo vive en `sale-form.tsx:200-216`). La forma de pago es **opcional** (`PaymentMethodSelect` ofrece "Sin especificar"). El alta inline del proveedor sólo pide el nombre (`phone: ""`, `:588`). El listado de compras (`purchase-operations-list.tsx:356,446`) arma el diálogo de borrado con `reversesStock: true` fijo. `InvoiceAIButton` ("Factura IA", montado en `/compras`, `page.tsx:65`) crea compras directas con `addPurchaseOperation` (`InvoiceAIButton.tsx:146`), sin proveedor. |
| Proveedores | `/proveedores` (listado) y `/proveedores/[id]/cuenta` | No hay ficha de proveedor aparte de su cuenta corriente. |
| RBAC | `backend/core/rbac.py:37` | `CAN_PURCHASE = {owner, admin, purchases}` **existe pero ningún router lo usa**: hoy cualquier miembro escritor registra compras (`routers/purchases.py` sin guard de rol; `rpc_create_purchase_operation` tampoco lo tiene). Roles vigentes: `owner, admin, seller, cashier, stock, purchases, accountant, viewer`. |
| Reaplicación en CI | `.github/workflows/KPI_Validation.yml:1005-1022` y `:1209-1252` (en `main`) | El bloque de `20261062000001` exige que **diez** funciones sigan con su cuerpo, entre ellas `rpc_create_purchase_operation` y `rpc_atomic_update_purchase_operation`. Su "REGLA PARA EL PR SIGUIENTE" manda retirarlo en el mismo PR que redefina cualquiera. El bloque de **`20261069000001`** la reaplica **sin tolerancia** después de un `supabase db reset` que ya incluye toda la historia, y restaura cuerpos que los reapply previos dejan viejos (guards de unidad de `20261062000001`, `_quote_validate_items` de `20261067000001`). Pero esa migración hace `DROP CONSTRAINT IF EXISTS` + `ADD` con **listas fijas** (sin guard contra `pg_constraint`) en `internal_document_sequences`, los dos `CHECK` de FSM y `operation_idempotency` (`20261069000001:172-209`), y su introspección exige **una sola definición por `proname`** de `_delivery_note_assert_role` y de los demás helpers (`:1790-1803`). |
| Escritura de `purchases` | prod (SELECT 2026-10-03) | `authenticated` tiene `INSERT`/`UPDATE`/`DELETE` a nivel tabla y políticas `purchases_writer_insert/update/delete` con `is_account_writer` (`20260606010000_roles_internos.sql:452-463`); sin privilegios por columna. A diferencia de `sales_orders` (que `remitos-venta` D8 usa como ancla porque no tiene políticas de escritura), **cualquier escritor puede escribir `purchases` por PostgREST**. |

### Medido en prod (2026-10-03, sólo lectura, `mcp__supabase__execute_sql`)

- Al escribir el propose: `MAX(version) = 20261068000001`, 315 migraciones, sin tablas de remito. **Re-medido en la ronda 1 de revisión (2026-10-03)**: `MAX(version) = 20261069000001`, 316 migraciones, `delivery_notes` existe y el catálogo `document_status_transitions` tiene 24 filas (22 + las 2 de `delivery_note_sale`). Ninguna fila `delivery_note_purchase`.
- **Compras**: 663 filas en 127 operaciones.
  - Con proveedor: 44 operaciones; sin proveedor: 83. En los últimos 30 días: 33 operaciones, **32 con proveedor**. El proveedor obligatorio del remito acompaña el uso real.
  - Sin sucursal: 106 operaciones (12 de las 33 de los últimos 30 días). El remito exige sucursal (stock por sucursal), así que la compra nacida de un remito siempre la tiene.
  - Con alguna línea sin producto: 7 operaciones. El remito no las admite (D1 de venta).
  - Forma de pago por operación: sin forma 81, `wallet` 18, `transfer` 14, `cash` 11, `card` 1, `check` 1, `credit` 1. Cargos de compra en cuenta corriente del proveedor: 2. Caja `purchase_payment`: 6. Banco con `source_doc_type = 'purchase'`: 28.
  - Filas con `amount = 0`: **0** (el núcleo exige `amount > 0`).
- **Proveedores**: 19 vivos en 8 cuentas; **2** con teléfono. El WhatsApp sin número abre el selector de contactos.
- `branch_stock` tiene `CHECK (quantity >= 0)`, con 0 filas negativas. **Consecuencia de diseño**: toda pata que resta stock necesita un gate explícito antes del delta; sin él, el `CHECK` aborta con `23514` y el usuario recibe un 500 ilegible (D4, D5, D6).
- Disparadores no internos sobre `purchases`: sólo `trg_analytics_operation_created`. **Ninguno actualiza `products.cost`.**
- Productos vivos: 5.414; con `cost NULL`: 2.681.
- `stock_movements` con `reference_type = 'purchase'`: 735.
- Catálogo `document_status_transitions`: 22 filas antes de `remitos-venta`, 24 después.
- Cuentas con más de un miembro: 0 (el chequeo por usuario del producto en la compra no afecta a nadie hoy; ver Riesgos).

## Goals / Non-Goals

**Goals:**
- Remito de compra interno de punta a punta: recibir mercadería de un proveedor → el stock sube → descargar o mandar por WhatsApp → editar con ajuste de stock → anular con motivo (si la mercadería no se consumió) → convertir en compra con un toque, **sin** doble suma.
- Que "esta compra no suma stock" lo decida el servidor desde el remito validado bajo bloqueo, de modo que ningún caller de la API pueda pedirlo.
- Reutilizar el modelo, los helpers, las pantallas y el PDF de `remitos-venta` sin copiar lógica: los helpers aprenden el sentido leyéndolo del remito.
- No cambiar el comportamiento de la compra directa, del remito de venta ni del POS.

**Non-Goals:** los de `proposal.md` §Non-goals. Además:
- no se activa `CAN_PURCHASE` en `/compras` (hallazgo lateral, candidato);
- no se corrige el chequeo por usuario del producto en la compra (`v_product.user_id <> v_uid`, preexistente, candidato);
- no se toca la RLS preexistente de `stock_movements`/`branch_stock`.

## Decisions

### D1 — Modelo: `direction = 'purchase'` sobre las tablas de `remitos-venta`, sin `ALTER TABLE`

- El remito de compra es una fila de `delivery_notes` con `direction = 'purchase'`, `supplier_id` (obligatorio por el `CHECK` de contraparte), `client_id NULL`, `supplier_reference` (número del remito del proveedor, texto opcional ≤ 100) y `branch_id` = **sucursal de destino** (a la que entra la mercadería).
- `delivery_address` queda `NULL` en compra: el remito de compra no tiene domicilio de entrega. La RPC de compra no lo recibe.
- Líneas: las mismas de venta (`product_id` obligatorio, `quantity > 0`, `price ≥ 0`, `subtotal`, `quantity_base`, snapshots).
  - **`price` = precio de compra por unidad de la línea**, que la conversión usará como `purchases.amount`.
  - **Precio 0 admitido al recibir** (OQ-RC1): el proveedor suele mandar la mercadería con un remito sin precios y la factura después. El remito se emite y suma stock igual; los precios se completan editando. La conversión exige `price > 0` en todas las líneas (`P0400 delivery_note_price_required`, D8), porque el núcleo de compra rechaza `amount ≤ 0`.
  - **`subtotal` lo calcula el servidor** en compra: `round(price × quantity, 2)` por línea, ignorando el que mande el cliente. El **total** del remito de compra es `round(Σ price × quantity, 2)`, la misma regla que el núcleo usa para el total de la compra (`20261062000001:1027`): la compra nacida del remito tiene el mismo total por construcción, y el gate lo asserta. Las RPCs de compra normalizan `subtotal` en el payload antes de llamar a `_delivery_note_validate_items` (sin tocar el helper) y fijan el total con esa regla.
  - **`unit_cost_snapshot` = costo de catálogo** (`products.cost`), igual que `rpc_create_purchase_operation` hoy y que `_delivery_note_insert_items` (OQ-RC2). El costo de la compra queda en `price`. *Rechazado*: congelar `price` como costo. El costo del ledger está en unidad **base** y `price` en unidad de la **línea** (una "Caja x 6" a $600 no cuesta $600 por unidad), puede ser 0 al recibir y haría que la compra nacida de un remito valuara el stock distinto que una compra directa. Valuar por costo de compra es el non-goal "costeo por lote".
- **Puente remito ↔ compra** (tanda B): `purchases.source_delivery_note_id uuid NULL → delivery_notes ON DELETE NO ACTION` en **cada** fila de la operación, con índice parcial `(source_delivery_note_id) WHERE source_delivery_note_id IS NOT NULL`. `purchases` tiene una fila por línea, así que no admite un índice único por remito: la unicidad "1 remito → 1 compra" la garantiza el estado del remito (`issued → converted` bajo `FOR UPDATE`) más un chequeo en el núcleo de que no exista ninguna fila de `purchases` con ese origen. El borrado de la compra es físico, así que no hay "compra cancelada" que excluir.
  - **La columna no es escribible por los roles de aplicación** (D9, "Integridad del puente"): `purchases` sí admite escritura por PostgREST, así que sin un guard un escritor podría forjar, limpiar o apuntar a otra cuenta el origen, o borrar las filas por fuera del borrado.
  - *Rechazado*: `delivery_notes.purchase_operation_id`. La compra se edita (cambia de `operation_id`) y se borra físicamente: el remito tendría que mantener un puntero que otra RPC invalida. Se deriva (`SELECT DISTINCT operation_id FROM purchases WHERE source_delivery_note_id = …`), igual que venta deriva la orden.

### D2 — Numeración `RC-…`, secuencia propia

- `internal_document_sequences_document_type_check` suma `'delivery_note_purchase'` (aditivo, `DROP CONSTRAINT IF EXISTS` + `ADD`, desde el `CHECK` vivo).
- Disparador gemelo `delivery_notes_assign_number_purchase`: `BEFORE INSERT … FOR EACH ROW WHEN (NEW.direction = 'purchase') EXECUTE FUNCTION trg_assign_internal_document_number('delivery_note_purchase')`. Reutiliza sin cambios la función genérica.
- **Prefijo `RC`** (OQ-RC3): cada sentido numera desde 1, así que el de compra no puede usar `R` (D2 de venta). Se suma a la única definición por lenguaje (`frontend/lib/internal-document-number.ts`: `PREFIX_BY_TYPE`, `QUERY_PATTERN_BY_TYPE`, `formatDeliveryNoteNumber`, que deja de devolver el número sin prefijo; `backend/services/commercial_documents/numbering.py`) y al fixture compartido `internal_document_number_cases.json`. La búsqueda en la pestaña de compra acepta `RC-12`, `12` o `00000012`; `R-12` no es de esa pestaña y se busca como texto.
  - *Rechazado*: secuencia compartida con venta (D2 de venta ya lo rechazó: intercalaría números que el comercio nunca entregó).

### D3 — Máquina de estados `delivery_note_purchase`, sembrada aparte

`'delivery_note_purchase'` se suma a los dos `CHECK` (`document_status_history`, `document_status_transitions`), de forma aditiva. Un tipo por sentido es lo que exige el catálogo (un solo `NULL → x` por tipo) y R7 (roles distintos por sentido), igual que en venta.

| Transición | `allowed_role` | `requires_reason` | `is_terminal_to` | Productor | Tanda |
|---|---|---|---|---|---|
| `NULL → issued` | `{stock, admin, owner}` (R7) | no | no | disparador de creación (`trg_delivery_note_record_creation('delivery_note_purchase')`) | A |
| `issued → canceled` | `{admin, owner}` | **sí** | **sí** | `rpc_cancel_delivery_note` | A |
| `issued → converted` | `{purchases, stock, admin, owner}` (`CAN_CONVERT_PURCHASE_DELIVERY_NOTE`; **recomendación de OQ-RC6, no firmada**: R7 sólo cubre emitir y anular) | no | no | `rpc_convert_delivery_note_to_purchase` | B |
| `converted → issued` | `NULL` (sistema) | no | no | `rpc_delete_purchase_operation`, al borrar la compra nacida del remito | B |

- Disparadores gemelos con `WHEN (NEW.direction = 'purchase')` (y `OLD`/`NEW` en el de `UPDATE`): `delivery_notes_record_status_creation_purchase` y `delivery_notes_enforce_status_transition_purchase` (`trg_enforce_status_transition('delivery_note_purchase')`). Los de venta no se tocan.
- **`converted → issued` sin rol**: la dispara sólo el borrado de la compra. A diferencia de la venta, el borrado de una compra **no** registra una transición con rol (no hay `purchase_order`) y hoy no tiene guard de rol en la base (preexistente). Por eso el borrado con origen de remito **exige el rol `void` del remito de compra** (`admin`/`owner`) antes de cualquier efecto (D9): reabrir un remito y dejarlo anulable es tan sensible como anularlo. Esa exigencia vive en la RPC, no en la fila del catálogo, porque `record_status_transition` evalúa `allowed_role` contra el actor y la fila de sistema existe justamente para que la transición no dependa de un rol propio del remito.
- `canceled` es terminal; `converted` no. Editar no cambia el estado ni escribe historial.

### D4 — Stock en la emisión: la recepción suma, con el mismo camino que la venta

**`rpc_create_purchase_delivery_note(p_idempotency_key text, p_supplier_id uuid, p_branch_id uuid, p_supplier_reference text, p_notes text, p_items jsonb) → jsonb`**, `SECURITY DEFINER`, molde exacto de `rpc_create_sale_delivery_note`:

1. `auth.uid()`; clave no vacía (`P0400 idempotency_key_required`); DEC-06 con `operation_kind = 'delivery_note_purchase'` (aditivo en `operation_idempotency_operation_kind_check`, desde el `CHECK` vivo): `INSERT … ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS`; replay si el `operation_id` es un remito de **compra** de las cuentas del usuario, si no `P0409 idempotency_key_conflict`.
2. Proveedor obligatorio (`P0400 delivery_note_supplier_required`); **cuenta = la del proveedor** entre las del usuario (`P0404 supplier_not_found` si es ajeno o no existe): determinista aunque el usuario tenga varias membresías, a diferencia de la compra directa (`LIMIT 1`).
3. `_delivery_note_assert_role_dir(v_account_id, 'issue', 'purchase')` (D7): `is_account_writer` y roles ∩ `{stock, admin, owner}` (`P0401`/`P0403`).
4. Proveedor vivo (`deleted_at IS NULL`, `P0404 supplier_not_found`). Sucursal obligatoria (`P0400 delivery_note_branch_required`, texto "la sucursal a la que entra la mercadería"), de la cuenta, activa (`P0404`) y no cerrada (`P0422 branch_closed`).
5. `supplier_reference` y notas: `btrim`, vacío → `NULL`, topes 100 y 2.000 (`P0400`).
6. Subtotales y total del servidor (D1), `_delivery_note_lock_products` (orden de `id`, antes de validar) y `_delivery_note_validate_items(v_account_id, p_branch_id, items_normalizados, NULL)`: producto vivo, de la cuenta y no padre (`_assert_document_product`, el mismo guard que venta), unidad, topes, `quantity_base` con el lock puesto.
7. `INSERT delivery_notes` (`direction = 'purchase'`, `client_id NULL`, `delivery_address NULL`, `issued_on = reporting_local_today()`). Los disparadores gemelos numeran y registran `NULL → issued` con `'delivery_note_purchase'`.
8. `_delivery_note_insert_items` (sin cambios) y `_delivery_note_apply_stock(account, dn, op_group, _delivery_note_held_pairs(dn))`.
9. Devuelve `_delivery_note_payload(id) || {replayed: false}`.

**Helpers de stock por sentido** (desde el cuerpo vivo de `20261069000001`, `CREATE OR REPLACE` con **la misma firma**, `COMMENT` re-declarado extendiendo el vivo, ACL re-asertada):

- `_delivery_note_apply_stock(account, dn, op_group, pairs)` y `_delivery_note_reverse_held(account, dn, op_group, pairs, reference_type, reverses)` leen `direction` de `delivery_notes WHERE id = p_dn_id` (el caller ya tiene el remito bloqueado o recién insertado). El "efecto del remito" sobre el stock es **−held en venta y +held en compra**:

| Helper | Venta (sin cambios) | Compra |
|---|---|---|
| `_delivery_note_apply_stock` (pone el efecto) | gate `disponible ≥ requerido` (`P0409 stock_insuficiente…`), delta **−**, `type = 'sale'`, `reference_type = 'delivery_note'` | **sin gate**, delta **+**, `type = 'purchase'`, `reference_type = 'delivery_note'` |
| `_delivery_note_reverse_held` (quita el efecto) | delta **+**, `type = 'sale_return'`, `delivery_note_update`/`delivery_note_reversal` | **gate `disponible ≥ retenido`** (`P0409 delivery_note_stock_consumed`), delta **−**, `type = 'purchase_return'`, `delivery_note_update`/`delivery_note_reversal` |

- El gate de la pata que resta en compra usa un literal propio, **`delivery_note_stock_consumed: de % ya salieron % (vendidas o transferidas): en la sucursal quedan %, el remito necesita restar %`**, `P0409`. Es más preciso que "stock insuficiente" para quien anula una recepción y le dice qué hacer (D11). Sin el gate, el `CHECK (quantity >= 0)` de `branch_stock` abortaría con `23514`.
- Se reutilizan `type = 'purchase'`/`'purchase_return'` y los tres `reference_type` de venta (`delivery_note`, `delivery_note_update`, `delivery_note_reversal`). El sentido del movimiento (ícono y signo en `/stock`) sale del `type`; el rótulo, del `reference_type`. **Ningún valor nuevo en los `CHECK` de `stock_movements`.**
  - **A verificar en la tarea 0.5** que ningún lector asume `type = 'purchase'` ⇒ fila en `purchases`. Evidencia parcial de la ronda 1: un grep de `type = 'purchase'` en `backend/`, `frontend/{lib,components,hooks}` y `supabase/functions/` sólo encuentra `source_doc_type = 'purchase'` de `bank_movements` en `purchase_repository.py` (no es `stock_movements`); falta `pg_proc.prosrc` de prod. `rpc_atomic_update_purchase_operation` filtra por `reference_id = <fila de purchases>` y `reference_type = 'purchase'`, así que un movimiento con `reference_id` = remito nunca coincide.
- **Por qué reescribir los helpers y no crear gemelos de compra**: los gemelos duplicarían la forma exacta del movimiento (columnas, metadatos, costo, `quantity_before/after`), que es justo lo que no tiene que divergir entre sentidos. Decidir el signo por la columna persistida del remito cumple además la regla de "decidido por los datos, nunca por un parámetro".
  - *Rechazado*: sumar un parámetro `p_direction`. Cambia la firma (`DROP`+`CREATE`, ACL reseteada) y, si alguna vez se volviera a reaplicar `20261069000001` (recrea la de 4/6 argumentos), dejaría vivas dos firmas (`42725`) y rompería su chequeo de una definición por `proname`. Esa reaplicación se retira en esta misma tanda (D16), pero la firma estable sigue siendo la opción que no depende de eso.
- **Lo aportado sale de las líneas**, igual que en venta: `_delivery_note_held_pairs` (sin cambios) devuelve `Σ quantity_base` por producto en la sucursal vigente. Una fila forjada en el ledger no cambia lo que la anulación resta.
- **Costo del producto**: la recepción **no** actualiza `products.cost`, porque la compra directa tampoco lo hace (verificado en el cuerpo vivo y en los disparadores de `purchases`). *Rechazado*: actualizarlo "como lo hace la compra". No hay tal comportamiento, e inventarlo acá cambiaría márgenes y valuación de todo el catálogo por un documento que todavía no tiene precio confirmado. Queda como candidato junto con el costeo por compra.

### D5 — Edición: núcleo compartido por los dos sentidos, patas que suman primero

**Extracción**: el cuerpo de reemplazo de `rpc_update_delivery_note` (de "lock de la unión de productos" a "aplicación de los pares que cambian", `20261069000001:1110-1176`) se extrae, **desde el cuerpo vivo**, a un helper interno:

`_delivery_note_replace_content(p_dn_id uuid, p_branch_id uuid, p_items jsonb) RETURNS jsonb` (devuelve el `v_valid` de `_delivery_note_validate_items`, con `lines` y `total`)

En el **mismo orden que el cuerpo vivo** (`20261069000001:1110-1176`), que es el que hace correcto el cambio de sucursal:

1. bloquea la unión de productos (vigentes + nuevos) en orden de `id`;
2. calcula lo retenido de las líneas vigentes (`v_old := _delivery_note_held_pairs`, con la sucursal **vieja** todavía en la cabecera);
3. valida y normaliza (`_delivery_note_validate_items` con `p_held = v_old`);
4. acarrea los cuatro snapshots por producto (D6 de venta) y borra las líneas;
5. **`UPDATE delivery_notes SET branch_id = p_branch_id`** (sólo esa columna genérica): `_delivery_note_held_pairs` lee la sucursal de la cabecera, así que tiene que estar fijada **antes** de recalcular lo retenido nuevo;
6. inserta las líneas y calcula `v_new := _delivery_note_held_pairs` (ya con la sucursal nueva);
7. calcula los pares que cambian (retenido ≠ requerido por producto-sucursal);
8. **sólo en compra**, chequeo del **neto por par** antes de escribir cualquier pata: para cada (producto, sucursal), `neto = nuevo − viejo`; si `neto < 0` y el stock de la sucursal es menor que `−neto` → `P0409 delivery_note_stock_consumed` con el stock **anterior a la edición** y lo que el usuario realmente resta (`−neto`). Así el mensaje coincide con lo que se ve en `/stock` y con el mínimo que muestra el cliente (D11), y no con un disponible inflado por la pata que suma. El gate de `_delivery_note_reverse_held` queda como respaldo (inalcanzable tras este chequeo en la edición; es el que actúa en la anulación, donde neto = −retenido);
9. aplica las patas **en el orden que hace que el gate vea el neto**: primero las que **suman** stock, después las que **restan**. En venta: reversa (suma) → aplicación (resta, con gate), que es el orden vivo. En compra: aplicación (suma) → reversa (resta).

Cada RPC hace después **su propio** `UPDATE delivery_notes` con la cabecera de su sentido, el total, `notes`, `updated_at`, `updated_by` y `revision = revision + 1`. En venta: `client_id`, `delivery_address` y `total = v_valid->>'total'`. En compra: `supplier_id`, `supplier_reference` y el total de la regla de compra (D1).

`rpc_update_delivery_note` (venta) se reescribe desde su cuerpo vivo para llamar al helper. El único cambio de forma es que el `UPDATE` vivo de `:1139-1148` se parte en dos (el `branch_id` lo fija el helper en el paso 5; el resto, la RPC después de llamarlo): conserva firma, `COMMENT`, ACL, validaciones de cabecera, mensajes y efectos observables. `test_remitos_venta.sql` es el safety net y tiene que seguir verde sin tocarlo; el gate de compra suma además el **cambio de sucursal con cantidades iguales en los dos sentidos**, assertando el stock por sucursal (−retenido/+retenido en X/Y según el sentido) y que el remito queda en Y.

**`rpc_update_purchase_delivery_note(p_delivery_note_id uuid, p_expected_revision integer, p_supplier_id uuid, p_branch_id uuid, p_supplier_reference text, p_notes text, p_items jsonb) → jsonb`**:

1. `SELECT … FROM delivery_notes WHERE id = $1 AND account_id IN (current_account_ids()) AND direction = 'purchase' FOR UPDATE` (`P0404 delivery_note_not_found`; un remito de venta por esta RPC también es "no encontrado").
2. Rol `issue` de compra.
3. Estado: `converted` → `P0423 delivery_note_locked_converted` ("el remito ya se convirtió en la compra …: para corregirlo, eliminá la compra y el remito vuelve a quedar pendiente"); `canceled` → `P0409 delivery_note_invalid_state`. Versión: `P0409 delivery_note_changed`.
4. Proveedor vivo de la cuenta (`P0404 supplier_not_found`); sucursal **vigente** activa y no cerrada (`P0422 delivery_note_branch_inactive`); sucursal **nueva** de la cuenta, activa y no cerrada.
5. `supplier_reference`/notas (reemplazo completo) y subtotales del servidor.
6. `v_valid := _delivery_note_replace_content(dn, p_branch_id, items)` (fija `branch_id` antes de recalcular lo retenido nuevo) y después `UPDATE delivery_notes SET supplier_id, supplier_reference, notes, total, updated_at, updated_by, revision = revision + 1`.

Consecuencias en compra:
- **Subir** una cantidad suma sólo la diferencia (par espejo: `purchase`/`delivery_note` de +nuevo y `purchase_return`/`delivery_note_update` de −viejo).
- **Bajar** una cantidad exige que la sucursal tenga lo que se resta **sobre el neto**: con 10 recibidas, 7 vendidas y la sucursal en 3, bajar a 8 funciona (resta 2) y bajar a 5 falla con `P0409 delivery_note_stock_consumed` ("en la sucursal quedan 3, el remito necesita restar 5"). Es R4/R6 tal como lo firmó el PO.
- **Cambiar la sucursal** suma en la nueva y resta en la vieja: funciona sólo si la vieja todavía tiene **todo** lo aportado.
- Editar sólo precios, proveedor, número del proveedor o notas **no** escribe movimientos.
- Un producto dado de baja después de recibir se conserva sin revalidar el catálogo y se puede conservar o reducir, no aumentar (`P0400 delivery_note_product_unavailable`), con el mismo helper de venta.

*Rechazado*: copiar la lógica de edición en la RPC de compra. Son ~60 líneas con el cálculo de pares, el acarreo de snapshots y el orden de patas, que es exactamente lo que no tiene que divergir.
*Rechazado*: generalizar `rpc_update_delivery_note` a los dos sentidos. Su firma tiene `p_client_id` y `p_delivery_address`; el sentido compra necesita `p_supplier_id` y `p_supplier_reference`.

### D6 — Anulación: `rpc_cancel_delivery_note` sirve a los dos sentidos

`rpc_cancel_delivery_note(p_delivery_note_id, p_expected_revision, p_reason)` se reescribe **desde su cuerpo vivo**, con la misma firma (`CREATE OR REPLACE`, ACL y `COMMENT` re-declarados):

- deja de filtrar `direction = 'sale'`;
- el rol `void`, el tipo de documento del historial (`'delivery_note_' || direction`) y el texto de `P0423` ("primero eliminá la venta" / "primero eliminá la compra") salen del sentido del remito;
- el resto queda igual: lock del remito, estado, versión, motivo, sucursal viva (`P0422 delivery_note_branch_inactive`), lock de productos antes de leer el stock, `_delivery_note_reverse_held(…, todos los pares, 'delivery_note_reversal', 'delivery_note_cancel')`, historial `issued → canceled` con el motivo.

En compra, la reversa resta lo que el remito sumó y su gate rechaza con `P0409 delivery_note_stock_consumed` si algún par ya no tiene la mercadería (R6). El `RAISE` revierte todo: ningún par queda restado a medias. La UI enumera lo que sale del stock y, ante el rechazo, explica que hay que editar el remito (reducir lo que sí está) o hacer un ajuste de stock (D11).

*Rechazado*: `rpc_cancel_purchase_delivery_note`. Su firma sería idéntica y su cuerpo, una copia que divergiría.

### D7 — Escritura sólo por RPC; helpers con el sentido del remito

- **`_delivery_note_assert_role_dir(p_account_id uuid, p_mode text, p_direction text)`**, función **nueva con nombre propio** (no un overload), con la lógica de hoy parametrizada por `'delivery_note_' || p_direction` y rótulos por sentido ("emitir o editar remitos de compra (requiere depósito, administrador o dueño)", "convertir remitos en compra (requiere compras, depósito, administrador o dueño)"). La `_delivery_note_assert_role(uuid, text)` de venta se reescribe desde su cuerpo vivo como `PERFORM _delivery_note_assert_role_dir(p_account_id, p_mode, 'sale')`.
  - *Rechazado*: un overload `_delivery_note_assert_role(uuid, text, text)`. La introspección de `20261069000001` exige una sola definición por `proname` (`:1790-1803`) y toda introspección futura que copie ese molde caería igual; un nombre propio evita la ambigüedad por construcción.
- **`_delivery_note_payload`** (desde el cuerpo vivo): suma `supplier_name`, `supplier_phone`, `supplier_deleted` y `missing_price_count` (líneas con `price = 0`, D11) y, en la tanda B, **completa el campo genérico ya existente `converted_operation_id`** para el sentido compra (derivado de `purchases.source_delivery_note_id` con `account_id` en el filtro); `converted_sales_order_id` queda `NULL` en compra. Ningún campo paralelo: el frontend lee "Ver compra"/"Ver venta" del mismo campo según el sentido. `remitos-venta` tanda B también lo reescribe (`converted_sales_order_id`/`converted_operation_id` de venta): **quien llegue segundo parte del cuerpo vivo** del primero.
- Sin cambios: `_delivery_note_lock_products`, `_delivery_note_validate_items`, `_delivery_note_insert_items`, `_delivery_note_held_pairs`, `rpc_get_delivery_note`, `_branch_pending_delivery_notes`.
- Todos los helpers siguen sin `EXECUTE` para `anon`/`authenticated` (chequeo (4) del gate de ACLs). Las RPCs nuevas: `REVOKE ALL … FROM PUBLIC, anon` + `GRANT EXECUTE … TO authenticated`, con `COMMENT`.

### D8 — Conversión: núcleo de compra extraído y `rpc_convert_delivery_note_to_purchase` (tanda B)

**Núcleo**: `_purchase_operation_core(p_account_id uuid, p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid, p_cost_center_id uuid, p_payment_method_id uuid, p_bank_account_id uuid, p_supplier_id uuid, p_cash_session_id uuid, p_due_date date, p_source_delivery_note_id uuid) RETURNS jsonb`, `SECURITY DEFINER`, **sin `EXECUTE` para `anon` ni `authenticated`**, extraído **desde el `pg_get_functiondef` vivo** de `rpc_create_purchase_operation` (checkpoint de cuerpo, diff adjunto).

- **`rpc_create_purchase_operation` queda como wrapper**: misma firma de 11 parámetros, misma ACL, sin `COMMENT` (hoy no tiene; si al momento del apply lo tuviera, se conserva). Hace `auth.uid()`, resuelve la cuenta como hoy (`current_account_ids() LIMIT 1`, `P0403` sin cuenta) y llama al núcleo con `p_source_delivery_note_id = NULL`. Para una compra directa el comportamiento es **idéntico**: el gate re-ejecuta los gates de compras vigentes sin tocarlos y compara una compra antes y después de la extracción (filas, movimientos, caja, banco, cuenta corriente, evento).
- **Modo remito** (`p_source_delivery_note_id IS NOT NULL`), autosuficiente aunque hoy sólo lo use la conversión (un guard que delega no es guard):
  - `p_items` tiene que venir `NULL` (`P0400 delivery_note_items_from_source`): las líneas salen **del remito**, nunca del request.
  - `SELECT … FROM delivery_notes WHERE id = p_source_delivery_note_id FOR UPDATE` (no-op si la conversión ya lo tiene) y exigir, todo a la vez: `account_id = p_account_id`, `direction = 'purchase'`, `status = 'issued'`, `supplier_id = p_supplier_id`, `branch_id = p_branch_id`, y que **no exista** ninguna fila de `purchases` con ese origen. Si algo no cumple → `RAISE 'delivery_note_purchase_mismatch: …' USING ERRCODE = 'P0409'`.
  - Arma `p_items` desde `delivery_note_items` (`product_id`, `amount = price`, `quantity`, `unit_id` y los cuatro snapshots), en orden de `product_id` como el loop vivo.
  - En el loop, por línea con producto: **se saltean** el `FOR UPDATE` del producto, el chequeo por usuario, el de padre con variantes, la normalización, `c21_apply_branch_stock_delta` y el `INSERT stock_movements`. Sin stock que mover, el lock del producto no protege nada y sólo agregaría superficie de interbloqueo con remitos y ventas. La existencia del producto la garantiza la FK de `delivery_note_items.product_id`.
  - `purchases` y `purchase_items` toman los **cuatro snapshots de la línea del remito** (no `v_product.*`) y `purchases.source_delivery_note_id = p_source_delivery_note_id`. Un producto renombrado o dado de baja entre la recepción y la conversión conserva el nombre del remito.
  - Total, caja, banco, cuenta corriente, evento `PurchaseCreated` e idempotencia: **sin cambios**.
- **Por qué la decisión es del servidor y no de un parámetro**: la RPC pública no tiene ningún parámetro de origen. El núcleo es interno: sólo una función definer lo invoca, y la única que pasa un origen es la conversión, que lo toma del remito que ella misma bloqueó. Aun así, el núcleo revalida el remito completo y lee sus líneas, así que un caller futuro que le pase un remito ajeno, anulado, ya convertido, de otro proveedor o de otra sucursal rebota con `P0409` en lugar de crear una compra sin sumar stock. El origen queda persistido en `purchases.source_delivery_note_id`, que es lo que después leen el borrado y la edición.
- *Rechazado*: sumar `p_source_delivery_note_id` a la firma pública de `rpc_create_purchase_operation`. Es exactamente el "no muevas stock" pedible por cualquier caller que el explore prohíbe.
- *Rechazado*: que la conversión cree la compra con la RPC pública y después revierta los movimientos de stock. Dejaría en el kardex una suma y una resta que nunca ocurrieron, y una ventana con stock duplicado dentro de la transacción que otro lector `READ COMMITTED` no ve, pero el gate de faltante del propio remito sí.
- *Rechazado*: que la conversión escriba `purchases`, caja, banco y cuenta corriente por su cuenta. Duplicaría exactamente lo que no tiene que divergir (es la misma razón por la que venta reutiliza `_c29_confirm_order_core`).
- *Rechazado*: una variable de sesión (`set_config`) que el núcleo lea para saltear el stock. Es un parámetro escondido, y un `SET` previo en la misma transacción lo dejaría activo para la próxima llamada.

**RPC**:

```
rpc_convert_delivery_note_to_purchase(
  p_idempotency_key   text,
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
  p_date              date DEFAULT NULL,   -- NULL = hoy (ART)
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_cost_center_id    uuid DEFAULT NULL,
  p_due_date          date DEFAULT NULL,
  p_description       text DEFAULT NULL
) RETURNS jsonb  -- {delivery_note_id, delivery_note_number, operation_id, total, replayed}
```

Sin `p_branch_id` ni `p_supplier_id`: la compra se imputa a la sucursal y al proveedor del remito (la mercadería entró ahí, y la deuda es con ese proveedor).

Orden (molde de `rpc_convert_quote_to_sale` y de D7 de venta):

1. Entrada: `auth.uid()`; clave no vacía (`P0400`); `p_payment_method_id` obligatorio (`P0400 payment_method_required`, OQ-RC4); `p_expected_revision` obligatorio.
2. **Lock del origen primero**: `SELECT … FROM delivery_notes WHERE id = $1 AND account_id IN (current_account_ids()) AND direction = 'purchase' FOR UPDATE` (`P0404`). Rol `convert` de compra (`P0401`/`P0403`).
3. **Idempotencia bajo el lock**: si existe `operation_idempotency(user, 'purchase', key)` y su operación tiene filas con `source_delivery_note_id = p_delivery_note_id` → replay `{…, replayed: true}`; si existe para otra operación → `P0409 idempotency_key_conflict`.
4. Estado `issued` (`P0409 delivery_note_invalid_state`), versión (`P0409 delivery_note_changed`).
5. Guards propios, antes de cualquier efecto:
   - proveedor vivo (`P0404 delivery_note_supplier_unavailable`, "editá el remito y elegí un proveedor vigente"): una compra a crédito cargaría deuda contra un proveedor que el directorio ya no muestra;
   - sucursal del remito activa y no cerrada (`P0422 branch_closed`);
   - **todas las líneas con `price > 0`** (`P0400 delivery_note_price_required`, "cargá el precio de compra de todas las líneas antes de convertir el remito");
   - productos dados de baja después de recibir: **se convierten** (la mercadería ya entró).
6. `v_result := _purchase_operation_core(v_account_id, p_idempotency_key, COALESCE(p_date, reporting_local_today()), COALESCE(p_description, 'Remito ' || RC-…), NULL, dn.branch_id, p_cost_center_id, p_payment_method_id, p_bank_account_id, dn.supplier_id, p_cash_session_id, p_due_date, dn.id)`. Si `v_result.replayed` → `RAISE 'idempotency_key_conflict' P0409` (la misma clave usada en paralelo para otra compra).
7. `record_status_transition(account, 'delivery_note_purchase', id, 'issued', 'converted', uid, NULL)` + `UPDATE delivery_notes SET status = 'converted'` (sin incrementar `revision`).
8. Devuelve `{…, replayed: false}`.

Dinero, exactamente como una compra directa (es el mismo núcleo):
- **Caja**: con `p_cash_session_id`, exige `kind = 'cash'`, sesión abierta de la sucursal del remito y fecha de la compra = hoy (las tres condiciones, mismos tokens `P0422`).
- **Banco**: `_pay_register_operation_bank_movement` con destino del catálogo o `p_bank_account_id`.
- **Cuenta corriente del proveedor**: si `kind = 'credit'`, `_pay_register_party_charge(…, 'supplier', dn.supplier_id, total, op, op, p_date, p_due_date)`, con vencimiento por la cascada del plazo del proveedor.
- **Evento** `PurchaseCreated` (asiento por el consumidor contable) e idempotencia `'purchase'`.

**Fecha de la compra** (OQ-RC5): `p_date`, por defecto hoy, editable en el diálogo como en el formulario de compra (la factura del proveedor puede tener otra fecha, y el vencimiento de la cascada se cuenta desde ella). No puede ser anterior a la fecha del remito (`P0400 delivery_note_purchase_date_before_receipt`): la compra no puede preceder a la recepción que documenta. La caja sigue exigiendo hoy.

**Orden de locks**: `delivery_notes` (FOR UPDATE) → inserciones de `purchases`/`purchase_items` → cuenta corriente / caja / banco (el núcleo, en modo remito, no bloquea `products` ni filas existentes de `purchases`). El borrado de la compra (D9) toma el remito **apenas detecta el origen, antes de cualquier compensación**, y recién después las filas de la compra y los libros de dinero: el mismo orden que la conversión (remito → dinero), así que no hay ciclo. *Rechazado*: tomar el remito al final del borrado. No serializa dos borrados de la misma compra ni un borrado viejo contra una reconversión (un segundo borrado que esperó al primero reabriría un remito ya reconvertido con otra compra viva), y en la variante a crédito invierte el orden respecto de la conversión (cuenta corriente → remito contra remito → cuenta corriente): interbloqueo.

### D9 — Vida posterior de la compra nacida de un remito (tanda B)

**Borrado** (`rpc_delete_purchase_operation`, desde el cuerpo vivo, misma firma, `COMMENT` y ACL re-declarados; R5):

- Después de resolver las filas de la operación y **antes** de cualquier compensación, si alguna fila tiene `source_delivery_note_id`:
  - todas las filas de la operación tienen que tener el mismo origen (`P0409 delivery_note_purchase_mismatch` si no; inalcanzable por construcción, defensa en profundidad);
  - **lock del remito de origen primero**: `SELECT … FROM delivery_notes WHERE id = v_source AND account_id = v_account_id AND direction = 'purchase' FOR UPDATE`. Sin fila → `P0409 delivery_note_purchase_mismatch` (un origen de otra cuenta o de venta nunca se reabre). **Bajo ese lock**, se vuelven a leer las filas de la operación (`FOR UPDATE`): si ya no existen (otro borrado ganó), la RPC termina sin efectos con el mismo resultado que hoy para una operación inexistente; y se exige `status = 'converted'` (si no, `P0409 delivery_note_purchase_mismatch`);
  - **rol `void` del remito de compra** (`admin`/`owner`): `RAISE 'delivery_note_purchase_delete_forbidden: borrar esta compra reabre el remito RC-… y lo deja anulable: requiere administrador o dueño' USING ERRCODE = 'P0403'`. Literal propio para que la UI lo traduzca (D11);
  - **sucursal del remito activa y no cerrada**, leída con `FOR SHARE` (`P0422 delivery_note_branch_inactive: la sucursal del remito RC-… está desactivada o cerrada — reactivala antes de eliminar la compra`), sin ningún efecto. El guard de baja no cuenta los remitos `converted`: sin esto, borrar la compra reabriría el remito en una sucursal muerta, que es el incidente que `remitos-venta` D9 evita.
- Cuenta corriente, caja, banco, evento y `DELETE`: **sin cambios** (corren con el remito ya bloqueado).
- **Stock**: el loop de `rpc_reverse_stock_movement` **se saltea explícitamente** cuando hay origen. Ya sería un no-op (las filas de la compra no tienen movimientos propios), pero no se depende de esa casualidad; el gate asserta que el stock no cambia.
- Después del `DELETE` (con el remito todavía bloqueado desde el principio): `record_status_transition(…, 'delivery_note_purchase', …, 'converted', 'issued', v_uid, 'Compra eliminada (operación …)')` y `UPDATE status = 'issued'`. Sin filas con ese origen, el remito se puede volver a convertir.
- El diálogo de borrado **reemplaza** la línea de reversa de stock (`reversesStock: false`) por: "El stock no vuelve: la mercadería quedó recibida con el remito RC-…, que vuelve a quedar pendiente. Para sacarla del stock, anulá el remito." (D11).

**Integridad del puente** (tanda B): `purchases.source_delivery_note_id` decide que una compra no sumó stock, que no se edita, que su borrado no revierte stock y que reabre un remito. Como `purchases` admite escritura por PostgREST (Context), la columna se protege en la base:

- disparador `BEFORE INSERT OR UPDATE OR DELETE ON purchases FOR EACH ROW` (`trg_purchases_guard_delivery_note_source`) que, cuando el `current_user` es un rol de aplicación (`anon`, `authenticated`), rechaza con `P0403 delivery_note_source_protected`: (a) un `INSERT` con `source_delivery_note_id` no nulo; (b) un `UPDATE` que cambie la columna (forjar, limpiar o apuntar a otro remito); (c) un `DELETE` de una fila con origen. Dentro de las funciones `SECURITY DEFINER` (núcleo, borrado) el `current_user` es el dueño de la función y el guard no actúa. Con la Paso 2 del pool (`SET LOCAL ROLE authenticated`), el backend también entra por las RPC definer, así que sigue sin actuar sobre los caminos legítimos;
- *Rechazado*: privilegios por columna (`REVOKE UPDATE (source_delivery_note_id)`). No cubren el `DELETE` directo de las filas con origen (que dejaría el remito `converted` para siempre, sin compra que borrar ni forma de anularlo), y el `INSERT` a nivel tabla seguiría admitiendo la columna salvo una allow-list de todas las demás, que cambiaría el permiso de la tabla entera;
- el gate B y el red-team (8.4) atacan los tres caminos por PostgREST con un escritor real (`seller`), cada uno con su control positivo (la misma escritura sobre una compra directa, sin origen, sigue funcionando como hoy), más un origen apuntado a un remito de otra cuenta insertado como `postgres`, que el borrado rechaza sin reabrirlo.

**Edición** (`rpc_atomic_update_purchase_operation`, desde el cuerpo vivo, misma firma):

- Inmediatamente después del chequeo de existencia de las filas y **antes** de los tres `P0423` de dinero y de cualquier reversa, si alguna fila tiene `source_delivery_note_id` → `RAISE 'delivery_note_purchase_locked: la compra nació del remito RC-…: para corregirla, eliminá la compra, editá el remito y volvé a convertirlo' USING ERRCODE = 'P0423'`.
- Bloquea la operación **entera**, también la cabecera: el editor de compras siempre reemplaza líneas (REVERSE+APPLY), y la REVERSE restaría stock por su caída a `_uom_normalize_quantity`. **Esto va más allá de lo firmado** (el PO firmó "no permite editar líneas"): se declara como **OQ-RC10**, con el bloqueo total como recomendación. El gate asserta que, ante el `P0423`, `branch_stock` y `stock_movements` (`purchase_update`/`purchase`) quedan sin cambios.
- Va primero porque es el motivo más específico: una compra de remito a crédito recibiría, si no, el `P0423` de cuenta corriente, que manda a "borrar y volver a cargar" sin explicar el remito.

**Anular un remito convertido**: `P0423 delivery_note_locked_converted` (D6). Primero se borra la compra.

### D10 — PDF del remito de compra

- `build_delivery_note_view` (de `remitos-venta` D8) se parametriza por `direction`, sin otra vista:
  - título **"REMITO DE COMPRA"**, número `RC-…`;
  - `recipient` → bloque **"Recibido de"**: proveedor, CUIT si tiene y **"Remito del proveedor N° …"** si hay `supplier_reference`;
  - `origin_label` → **"Ingresa a: Sucursal Centro"**;
  - tabla de descripción y cantidad con unidad; precios y total sólo con `show_prices` (R2);
  - bloque de firma "Recibí conforme" (Firma, Aclaración, DNI, Fecha): firma **quien recibe** en el comercio;
  - sello "ANULADO" si `canceled`;
  - leyenda **"Remito — documento no válido como factura."**
- Endpoint `GET /delivery-notes/{id}/pdf` sin cambios de contrato: 200 en cualquier estado y sentido, 404 ajeno o inexistente, 422 en parámetros inválidos. Archivo `remito-compra-RC-00000012.pdf` (`-con-precios` con precios).
- Emisor: `rpc_commercial_issuer` + `resolve_commercial_issuer`, sin cambios.

### D11 — UI

- **`/remitos`** gana las pestañas **De venta** / **De compra** (`?sentido=venta|compra`, default `venta`, combinable con el contrato de `remitos-venta`: `?estado=`, `?sucursal=`, `?cliente=`, y el nuevo `?proveedor=`):
  - la pestaña De compra pide `GET /delivery-notes?direction=purchase&…` (el endpoint ya lo acepta) con búsqueda por proveedor, número `RC-…` o **número del proveedor**;
  - columnas: número, proveedor, número del proveedor, fecha, sucursal de destino, ítems, total y estado; tarjetas en móvil. Un remito pendiente con alguna línea en precio 0 lleva el badge **"Sin precio"** (de `missing_price_count`, derivado en el read model del listado), porque su total subestima lo recibido y todavía no se puede convertir;
  - resumen "N remitos de compra pendientes por $ X (M sin precio)" (mercadería recibida sin comprar; el "sin precio" aclara que el importe está incompleto);
  - CTA "Nuevo remito de compra" con `CAN_RECEIVE_PURCHASE`; estado vacío: "El remito de compra suma stock al recibir la mercadería y se convierte en compra cuando llega la factura";
  - las dos pestañas se muestran a todo miembro de la cuenta (la lectura es libre, como en venta); lo que se habilita por rol son las acciones de cada sentido.
- **`/remitos/nuevo?tipo=compra`** (y `?proveedor=<id>`) y **`/remitos/[id]/editar`**: `DeliveryNoteForm` gana la prop `direction` (default `"sale"`, retrocompatible).
  - Contraparte: en compra, **`SupplierSelect`**, componente nuevo en `components/suppliers/SupplierSelect.tsx` **extraído** de `purchase-form.tsx` (selector buscable + "Nuevo proveedor" en el lugar, que queda seleccionado); `purchase-form.tsx` pasa a usarlo sin cambiar lo que muestra (su test sigue verde). La prop `askPhone` (default `false`, lo que hoy muestra `purchase-form`) suma un teléfono **opcional** al alta inline; el formulario del remito la activa, porque el WhatsApp al proveedor depende de ese número (hoy 2 de 19 proveedores lo tienen).
  - Campo "N° de remito del proveedor" (opcional). Sin domicilio de entrega.
  - Sucursal de destino obligatoria y visible en todos los planes (`BranchSelect required alwaysVisible`, de `remitos-venta`), rotulada "Ingresa a".
  - Editor de líneas compartido con `enforceStock: false` en el alta (entra mercadería, no hay faltante que controlar).
  - **Fuente del precio por sentido**: `StagedProductLine`, `addManualLineToCart` y `applyScanToCart` ganan `priceSource: "price" | "cost"` (default `"price"`, retrocompatible). En compra (`"cost"`): la línea precarga `products.cost` convertido a la unidad de la línea (con la misma conversión que hoy aplica al precio); `cost NULL` → 0 con el aviso "Sin precio: lo vas a poder cargar antes de convertir el remito en compra"; el aviso "Cat." compara contra el costo; el descuento se oculta (la compra no lo tiene). Sin esto, la línea nacería con el precio de **venta** y la compra convertida, el cargo al proveedor y el total quedarían a precio de venta.
  - En la edición, **mínimo por producto** calculado en el cliente con la misma contabilidad que el servidor (neto por par, D5): `mínimo = max(0, aportado − stock vigente de la sucursal)`. El texto no atribuye origen, porque el stock de la sucursal mezcla otras entradas: "En Centro quedan 3: este remito no puede bajar de 7". Si se cambia la sucursal de destino, avisa cuando la vieja tiene menos que **todo** lo aportado ("En Centro quedan 3 de las 10 que entraron con este remito: no se puede mover a otra sucursal"). El servidor lo rechaza igual con `delivery_note_stock_consumed`.
  - Avisos de stock: junto a Emitir, "Al emitir, se suma al stock de {sucursal}."; en la edición, el resumen del ajuste ("Entran 4 × A a Centro · Salen 2 × A de Centro" o "Este cambio no mueve stock").
  - Proveedor dado de baja después de recibir: el formulario lo muestra congelado con el aviso "Proveedor dado de baja — elegí uno vigente para guardar"; en el detalle, "Compra" queda deshabilitado con ese motivo.
  - **Regreso**: el detalle, el alta y la edición de compra vuelven a `/remitos?sentido=compra` con un helper puro `deliveryNoteListHref(direction)` en `lib/`, no al `/remitos` fijo de hoy (que abre "De venta").
- **Textos por sentido** (una sola tabla en la capa canónica, `lib/delivery-note-status.ts` / `lib/delivery-note-stock.ts` / `lib/delivery-note-form.ts`; ninguna pantalla arma su propio texto):

| Pieza | Venta (sin cambios) | Compra |
|---|---|---|
| `DELIVERY_NOTE_STATUS_LABELS[direction].converted` (badge en listado y detalle; `DeliveryNoteStatusBadge` recibe `direction`) | "Convertido en venta" | "Convertido en compra" |
| Rótulo de la sucursal en el detalle | "Sale de:" | "Ingresa a:" |
| Aviso de anulado | "el stock volvió a …" | "el stock salió de …" |
| Aviso de convertido | "se convirtió en una venta. El stock ya se había descontado" | "se convirtió en una compra; el stock ya se había sumado al recibirlo" |
| `describeEmitNotice` | "se descuenta del stock de …" | "se suma al stock de …" |
| `describeRemovalReturn` / `describeHeldReturn` | "Vuelven a …" | "Salen de …" |
| Validación de contraparte (`validateDeliveryNoteDraft`) | "Elegí un cliente" | "Elegí un proveedor" |
| Toast y placeholder de anulación (`CancelDeliveryNoteDialog`) | "el stock volvió a …" | "el stock salió de …" / "Ej.: el proveedor se llevó la mercadería" |
| `DeactivateBranchDialog` | "remitos pendientes que retienen stock" | "remitos de compra pendientes que aportaron stock" |
| `deliveryNoteFileName(direction, número, conPrecios)` | `remito-R-….pdf` | `remito-compra-RC-….pdf` (igual que el backend, D10) |

  Cada fila lleva su caso de test puro.
- **`/remitos/[id]`** de compra:
  - cabecera: número `RC-…`, estado, proveedor (enlace a su cuenta corriente), teléfono, número del proveedor, sucursal de destino, fecha;
  - acciones:

| Estado | Acciones |
|---|---|
| `issued` | Compartir (`DocumentShareMenu` + "Mostrar precios"; sin teléfono del proveedor, junto al menú: "Agregá el teléfono del proveedor para enviárselo por WhatsApp" con enlace a `/proveedores`) · Editar (`CAN_RECEIVE_PURCHASE`) · **Compra** (`CAN_CONVERT_PURCHASE_DELIVERY_NOTE`, tanda B; deshabilitada con motivo si falta algún precio o el proveedor fue dado de baja) · Anular (`CAN_VOID_DELIVERY_NOTE`) |
| `converted` | Compartir · Ver compra. Leyenda: "Para corregirlo, eliminá la compra: el remito vuelve a quedar pendiente" |
| `canceled` | Compartir (con sello ANULADO). Muestra el motivo |

- **`CancelDeliveryNoteDialog`** por sentido: en compra enumera lo que **sale** del stock ("Salen de Sucursal Centro: 10 × Producto A") y, ante `delivery_note_stock_consumed`, muestra el disponible y dos caminos: "Editar el remito" (reducir a lo que sigue en el depósito) o "Ajustar stock" (`/stock`).
- **`ConvertPurchaseDeliveryNoteDialog`** (tanda B):
  - resumen de líneas y total en sólo lectura; línea fija: "El stock ya se sumó al recibir el remito RC-…: esta compra no lo vuelve a sumar.";
  - proveedor y sucursal fijos (los del remito);
  - **`PurchaseCheckoutFields`**, componente nuevo en `components/compras/PurchaseCheckoutFields.tsx` **extraído** de `purchase-form.tsx`: forma de pago (`PaymentMethodSelect`), cuenta bancaria (`BankAccountDestinationSelect`), opt-in de caja (`useCashOptin({ kind, branchId: dn.branch_id, date, document: "compra" })`), fecha, centro de costo y saldo del proveedor si es a crédito. `purchase-form.tsx` pasa a usarlo sin cambiar lo que muestra. Dos props nuevas:
    - `showDueDate` (default `false`): el **vencimiento** no existe hoy en el formulario de compra. Se construye reutilizando la cascada del plazo de `sale-form.tsx:200-216`, **extraída** a un hook compartido (`useDueDateCascade` en `hooks/`) en vez de copiarla; `sale-form` pasa a usarlo sin cambios visibles, el diálogo de conversión lo muestra cuando la forma de pago es de cuenta corriente, y `purchase-form` **no** lo gana en este change (candidato, 9.1);
    - `paymentRequired` (default `false`): oculta "Sin especificar" de `PaymentMethodSelect` y deshabilita "Convertir" sin forma de pago (OQ-RC4);
  - `useIdempotencyKey("delivery-note-purchase-convert:" + id)`, que se resetea en cada éxito;
  - éxito con enlace a la compra en `/compras`;
  - ante `delivery_note_changed`, recarga sin cerrar.
  - **Cáscara compartida**: con `ConvertQuoteDialog`, el `ConvertDeliveryNoteDialog` de venta (tanda B de `remitos-venta`) y éste, el resumen de líneas, el manejo de errores y el estado de éxito tienen **tres** consumidores: se extrae `components/shared/ConvertDocumentDialogShell.tsx` (Regla de Tres) en la tanda B de este change, o en la de venta si llega segunda. Los campos de cierre siguen siendo propios de cada sentido (venta y compra no comparten semántica de cobro).
- **`/compras`** (`purchase-operations-list.tsx` y diálogo de borrado):
  - badge **"Desde remito RC-…"** con enlace, con `SourceDocumentBadge` (lo generaliza `remitos-venta` tanda B desde `SourceQuoteBadge`; si este change llega antes, la generalización la hace él, sin gemelo);
  - "Editar" deshabilitado con el motivo de D9; con origen, ese motivo tiene **precedencia** sobre `PAYMENT_LOCKED_REASON` (mismo orden que el servidor, D9);
  - diálogo de borrado: `getDeleteCompensation({ ...op, reversesStock: !op.source_delivery_note_id }, …)` (hoy `true` fijo, `:356`/`:446`) y, con origen, la línea de D9 en lugar de la de reversa de stock;
  - "Eliminar" con origen de remito: deshabilitado con su motivo si el usuario no tiene `CAN_VOID_DELIVERY_NOTE` ("borrar esta compra reabre el remito RC-…: requiere administrador o dueño") o si la sucursal del remito está inactiva (`source_delivery_note_branch_active = false`, derivado en el servidor con el mismo predicado que el borrado: "la sucursal del remito está desactivada o cerrada — reactivala antes de eliminar la compra"). Es lo que exige la spec vigente de exposición de borrabilidad en el listado;
  - el read model `GET /purchases` expone `source_delivery_note_id`, `source_delivery_note_number` y `source_delivery_note_branch_active` (`JOIN` con `account_id`).
- **Aviso contra la doble suma fuera de la conversión**: el escenario que justifica el change ("recibo con remito, la factura llega después") tiene otros dos caminos que vuelven a sumar el stock, porque crean compras directas: "Nueva compra" en `/compras` y **Factura IA** (`InvoiceAIButton`, RN-53).
  - en `purchase-form.tsx`, al elegir un proveedor con remitos de compra pendientes: "Este proveedor tiene N remitos de compra pendientes. Si esta factura es de uno de ellos, convertilo desde el remito para no sumar el stock dos veces" con enlace a `/remitos?sentido=compra&estado=pendientes&proveedor=<id>`;
  - en el flujo de Factura IA, que no identifica proveedor: si la cuenta tiene remitos de compra pendientes, el mismo aviso antes de confirmar, con enlace a la pestaña De compra filtrada por pendientes;
  - es un aviso, no un bloqueo (una compra directa puede ser legítimamente otra mercadería). La conversión "factura OCR → remito pendiente" queda como candidato (9.1).
- **Proveedores**: acción "Nuevo remito de compra" por fila en `/proveedores` (`/remitos/nuevo?tipo=compra&proveedor=<id>`); en `/proveedores/[id]/cuenta`, botones "Nuevo remito" y "Ver remitos" (`/remitos?sentido=compra&proveedor=<id>`).
- **`DeactivateBranchDialog`**: hoy cuenta los pendientes sin filtrar sentido y enlaza a `/remitos?estado=pendientes&sucursal=<id>`. Con las pestañas, muestra **un enlace por sentido con pendientes** (`&sentido=venta` / `&sentido=compra`), consultando el total de cada uno.
- **`/stock`**: el panel ya rotula por `reference_type` y formatea el número por sentido; con el prefijo `RC` en `formatDeliveryNoteNumber`, las filas dicen "Remito RC-…", "Edición de remito RC-…" y "Anulación de remito RC-…", con el ícono de entrada o salida según el `type`. Se suma un caso de test por fila y por CSV; la lógica no cambia.
- **Compartir**: `buildDeliveryNoteShareText` por sentido; compra: "Hola {proveedor}, te confirmo la recepción de la mercadería del remito RC-00000012 (tu remito N° {número del proveedor}) el 03/10/2026. {negocio}". El destinatario es el teléfono del proveedor; sin teléfono, `wa.me/?text=`.
- **Errores** (`lib/operation-errors.ts`, contexto `documentLabel: "remito"`): `delivery_note_supplier_required`, `delivery_note_supplier_unavailable`, `delivery_note_stock_consumed`, `delivery_note_price_required`, `delivery_note_purchase_locked`, `delivery_note_purchase_mismatch`, `delivery_note_purchase_date_before_receipt`, `delivery_note_items_from_source`, `delivery_note_source_protected`, y `supplier_not_found` en contexto remito. `delivery_note_locked_converted` se traduce según el sentido ("eliminá la venta" / "eliminá la compra"). En el **contexto de borrado de compra**: `delivery_note_purchase_delete_forbidden` y `delivery_note_branch_inactive` ("la sucursal del remito RC-… está desactivada o cerrada — reactivala antes de eliminar la compra").
- **Invalidación**: crear, editar y anular un remito de compra invalidan `deliveryNotes.*`, `branchStock` y `products`. El alta de compra y la conversión comparten **`invalidateAfterPurchaseCreate`**, extraída a `lib/query-invalidation.ts` (molde de `invalidateAfterSale`) desde el conjunto que hoy invalida `addPurchaseOperation` (`use-purchases.ts:238-254`: compras, productos, cuentas corrientes de proveedores, **`payables`** —la conversión a crédito crea deuda y la pestaña "Por pagar" de `/cobranzas` quedaría vieja—, sesiones y movimientos de caja), más banco y `deliveryNotes.*`. Borrar una compra usa `invalidateAfterPurchaseDelete` (el conjunto vigente del borrado, `payables` incluido, más `deliveryNotes.*`: sin esto, `/remitos` mostraría "Convertido" con un enlace a una compra borrada).
- **Design system**: tokens semánticos, `cva`, `ResponsiveModal`; verificación en desktop y 375 px × claro y oscuro.

### D12 — Permisos

- **Backend** (`core/rbac.py`) y **frontend** (`lib/rbac-capabilities.ts`):
  - `CAN_RECEIVE_PURCHASE = {owner, admin, stock}` (emitir y editar remitos de compra, R7). Tiene el mismo contenido que `CAN_STOCK`, pero va con **nombre propio por acción**, igual que `CAN_DELIVER_SALE` y `CAN_VOID_DELIVERY_NOTE` (cuyo comentario en `rbac.py:57` ya explica la misma coincidencia con `CAN_CONFIGURE`): el test de contrato lo ata a la fila `NULL → issued` de `delivery_note_purchase`, y si un día "depósito" y "recepción" divergen, cambia una constante y no todas las pantallas de stock;
  - anular: `CAN_VOID_DELIVERY_NOTE` (ya existe, `{owner, admin}`; sensible por contenido igual a `CAN_CONFIGURE`);
  - convertir: **`CAN_CONVERT_PURCHASE_DELIVERY_NOTE = {owner, admin, purchases, stock}`** (recomendación de OQ-RC6; R7 no firmó la conversión).
- **Por qué la conversión suma `stock`** (OQ-RC6): hoy ni `routers/purchases.py` ni `rpc_create_purchase_operation` tienen guard de rol, así que `stock` (y `seller`/`cashier`) registra compras directas que mueven stock **y** dinero. Si la conversión —que sólo mueve dinero— quedara en `CAN_PURCHASE`, el usuario `stock` con la factura en la mano sólo tendría la compra directa, que **vuelve a sumar el stock**: la restricción empujaría justo a la doble suma que el change existe para evitar. Con `stock` incluido, quien recibe puede cerrar el ciclo; `purchases` convierte aunque no reciba. Se combina con el aviso de D11 en la compra directa.
- Un test lee las migraciones y falla si estas capacidades divergen de los `allowed_role` de `delivery_note_purchase` (molde de `TestCanQuote`).
- **Hallazgo lateral**: `CAN_PURCHASE` existe y ningún router lo exige; hoy cualquier miembro escritor (incluidos `seller` y `cashier`) registra compras. Este change **no** lo activa en `/compras` (cambiaría el permiso de una pantalla en uso); queda como candidato (tarea 9.1) y como alternativa de OQ-RC6.

### D13 — Backend 3 capas

- **`schemas/delivery_notes.py`**: la alta y la edición pasan a una **unión discriminada por `direction`** (`Annotated[Union[SaleDeliveryNoteCreateIn, PurchaseDeliveryNoteCreateIn], Field(discriminator="direction")]`). `PurchaseDeliveryNoteCreateIn`: `direction: Literal["purchase"]`, `supplier_id`, `branch_id`, `supplier_reference?` ≤ 100, `notes?` ≤ 2.000, `items` de 1 a 500 (`price ≥ 0`, `subtotal` ignorado). `DeliveryNoteOut` ya tiene `supplier_id`, `supplier_reference` y `converted_operation_id` (`schemas/delivery_notes.py:179-180,196`); suma sólo `supplier_name`, `supplier_phone`, `supplier_deleted` y `missing_price_count`, y en compra la tanda B completa `converted_operation_id` (D7), sin campo paralelo. El ítem del listado suma `missing_price_count`. `PurchaseDeliveryNoteConvertIn`: `expected_revision`, `payment_method_id`, `date?`, `cash_session_id?`, `bank_account_id?`, `cost_center_id?`, `due_date?`, `description?`.
- **Router**: `POST /delivery-notes` (con `require_idempotency_key`) despacha por `direction`; `PUT /delivery-notes/{id}` valida que el cuerpo coincida con el sentido guardado (si no, `409 delivery_note_direction_mismatch`); `POST /delivery-notes/{id}/cancel` y `GET …/pdf` sin cambios de contrato; **`POST /delivery-notes/{id}/convert-to-purchase`** (tanda B, `require_idempotency_key`). Una ruta propia evita acoplar el contrato de conversión a compra con el de venta, que todavía no existe (`remitos-venta` tanda B).
- **Service**: guards de capacidad por sentido, mapeo RFC 7807 de cada literal, `40P01` → `409 concurrent_update_retry` (ya existe).
- **Repository**: todo por RPC o `SELECT` con `account_id` explícito; el listado suma la búsqueda por nombre del proveedor y `supplier_reference`, y el filtro `supplier_id`.
- **Read model de compras** (`repositories/purchase_repository.py`): `source_delivery_note_id`, `source_delivery_note_number` y `source_delivery_note_branch_active` por operación (D11).
- **Vista PDF** por sentido (D10) y numeración `RC` en `services/commercial_documents/numbering.py`.

### D14 — Reporting

- **Un remito de compra pendiente no es compra**: ningún KPI de compras, gastos, ganancia neta, cuenta corriente del proveedor ni caja lo cuenta, porque todos leen `purchases`, `supplier_account_movements` y `cash_movements`. La compra convertida entra con su fecha (`p_date`, D8).
- **El stock sí sube al recibir**: `branch_stock`, stock crítico y las alertas lo reflejan desde la emisión. La valuación sigue el costo de catálogo congelado en el movimiento (D1).
- La "mercadería recibida sin comprar" se ve en el resumen de la pestaña De compra. Sin KPI en el Tablero.

### D15 — Coordinación y dependencias

- **`remitos-venta` tanda A (PR #612)**: este change **no se aplica antes** de que esté mergeada y en prod (las tablas, los helpers y los disparadores que reutiliza nacen ahí). El checkpoint de la tanda A (tarea 0.3) parte del cuerpo vivo de prod, no del archivo del PR.
- **`remitos-venta` tanda B**: reescribe `_delivery_note_payload` y retira (o no) el bloque de reaplicación de `20261062000001`; generaliza `SourceQuoteBadge` → `SourceDocumentBadge`. **Quien llegue segundo parte del cuerpo vivo del primero** y lo anota en su checkpoint; si la tanda B de venta todavía no mergeó cuando llega la tanda B de compra, la de compra hace la generalización del badge y extrae la cáscara del diálogo de conversión, y la de venta las reutiliza.
- **Reaplicación de `20261069000001` en CI**: la tanda A la retira (D16). Si la tanda B de venta llega antes y suma su propio paso después de ése, la tanda A lo re-evalúa contra el workflow vivo; si llega después, parte del workflow que deja la tanda A (paso de compra al final) y suma el suyo después.
- **PR #607 `ventas-sucursal-por-defecto`**: toca RPCs de venta, no de compra. Comparte la obligación de retirar el bloque de reaplicación de `20261062000001` (redefine tres de sus diez funciones). El primero que llegue lo retira; los demás lo verifican con un grep.
- **Compras archivadas**: `stock-movements-edicion` (espejo de la edición de compra), `operation-delete-compensation` (borrado de compra), `caja-compras-cobranzas` (caja), `compras-proveedor-cuenta-corriente` (cargo del proveedor): sus gates se re-ejecutan sin tocarlos como safety net de la extracción del núcleo y de las dos reescrituras.

### D16 — Migraciones, gates y tandas

Números: **el siguiente libre** al momento de cada apply (se re-mide `ls supabase/migrations`, `gh pr list` y `MAX(version)` de prod en el checkpoint).

**Tanda A** — documento + stock + PDF + UI (sin conversión):

- **DDL**: `CHECK` ampliados (`internal_document_sequences` con `delivery_note_purchase`, los dos de FSM con `delivery_note_purchase`, `operation_idempotency.operation_kind` con `delivery_note_purchase`); las dos filas de la tanda A del catálogo; los tres disparadores gemelos con `WHEN (… direction = 'purchase')`.
  - **Los `CHECK` se amplían agregando el valor al vivo, nunca con una lista fija**: un bloque `DO` lee `pg_get_constraintdef` y sólo hace `DROP` + `ADD` si el valor no está, con la lista viva más `delivery_note_purchase`. Así, reaplicar esta migración después de otro change que sume valores (la tanda B de venta, u otro) no los borra. Es exactamente el defecto de `20261069000001:172-209` que obliga a retirar su reaplicación (abajo).
- **Funciones**:
  - nuevas: `_delivery_note_assert_role_dir(uuid, text, text)` (nombre propio, sin overload), `_delivery_note_replace_content`, `rpc_create_purchase_delivery_note`, `rpc_update_purchase_delivery_note`;
  - reescritas desde el cuerpo vivo con la misma firma: `_delivery_note_assert_role(uuid, text)` (delega), `_delivery_note_apply_stock`, `_delivery_note_reverse_held`, `_delivery_note_payload`, `rpc_update_delivery_note` (llama al núcleo de edición), `rpc_cancel_delivery_note` (dos sentidos).
- **Introspección** (bloque `DO`): `CHECK` (que contienen `delivery_note_purchase` **y** todos los valores previos), disparadores gemelos (y que los de venta siguen intactos), catálogo `delivery_note_purchase` validado **por presencia** de las dos filas de la tanda A con sus `allowed_role`, `requires_reason` e `is_terminal_to` (nunca por conteo: cuando CI la reaplique sobre un estado con la tanda B, habrá 4 filas; es la lección F2 de `remitos-venta`), una definición de cada función reescrita o nueva, ACLs (RPCs sin `anon`, helpers sin `authenticated`), cuerpos: los dos helpers de stock leen `direction`, `rpc_update_delivery_note` llama a `_delivery_note_replace_content`, `rpc_cancel_delivery_note` no filtra `direction = 'sale'`, `_delivery_note_assert_role` delega en `_delivery_note_assert_role_dir`.
- **Reaplicación en CI** (verificado en `main`: `KPI_Validation.yml:1209-1252` reaplica `20261069000001` sin tolerancia, al final de la cadena y después del `supabase db reset` de `:973`, que ya incluye esta migración). Esa reaplicación **no puede convivir** con la tanda A:
  - su `ADD CONSTRAINT document_status_transitions_document_type_check` con lista fija valida las filas existentes y las dos `delivery_note_purchase` de esta tanda la hacen abortar con `23514`; sus otros tres `CHECK` fijos dejarían `internal_document_sequences` y `operation_idempotency` sin `delivery_note_purchase` (el diff de schema daría `NOT IDEMPOTENT`);
  - y la reescritura de `_delivery_note_assert_role` quedaría pisada por su cuerpo sólo-venta (equivalente, pero ya no delegaría).

  **Decisión**: el PR de la tanda A **retira el paso de reaplicación de `20261069000001`** (mismo criterio que la "REGLA PARA EL PR SIGUIENTE" del bloque de `20261062000001`) y, en el comentario del paso que lo reemplaza, deja la regla escrita para el PR siguiente. Como ese paso además restauraba cuerpos que los reapply anteriores de la cadena dejan viejos (guards de unidad de `20261062000001`, `_quote_validate_items` de `20261067000001`), la cadena cierra con:
  1. un `supabase db reset` de reconvergencia (el mismo mecanismo de `:973`), después de los reapply de `20261062000001`…`20261068000001`;
  2. la reaplicación de la migración de compra (sin tolerancia, exige el OK de su introspección);
  3. el chequeo `RV_BODIES` heredado (los cuatro cuerpos que `20261069000001` reescribió siguen siendo los suyos) más los cuerpos de esta tanda;
  4. el diff de schema contra `schema_before_reapply`.

  El costo es un `db reset` más por corrida (se mide en el apply; la alternativa, si resultara inaceptable, es una migración de reconvergencia que re-declare los cuatro cuerpos, documentada en el mismo PR). Si al llegar el apply la tanda B de venta ya cambió ese paso, se re-evalúa contra el workflow vivo (checkpoint 1.9).

**Tanda B** — núcleo de compra + conversión + borrado/edición:

- `purchases.source_delivery_note_id` + índice parcial; las dos filas de la tanda B del catálogo.
- `_purchase_operation_core` (nuevo, interno) + `rpc_create_purchase_operation` como wrapper, `rpc_convert_delivery_note_to_purchase`, `rpc_delete_purchase_operation` y `rpc_atomic_update_purchase_operation` desde el cuerpo vivo, `_delivery_note_payload` (compra convertida).
- **Bloque de reaplicación de `20261062000001`** en `KPI_Validation.yml`: esta tanda redefine dos de sus diez funciones (`rpc_create_purchase_operation`, `rpc_atomic_update_purchase_operation`). Si sigue en el workflow (tarea 6.0), se **retira en el mismo PR** y su control pasa a `test_remito_a_compra.sql` + la introspección; si ya lo retiró otro PR, se anota.
- `trg_purchases_guard_delivery_note_source` (D9, integridad del puente).
- Introspección: una definición por función, ACL de las tres reescritas idéntica a la previa, núcleo sin `authenticated` (chequeo (4)), cuerpos con la rama de origen, el salto de reversa, el lock del remito antes de las compensaciones, el guard de sucursal y el `P0423`; disparador del puente presente; las dos filas de la tanda B del catálogo por presencia.
- **Reaplicación en CI**: paso propio **después** del de la tanda A y del último eslabón de `remitos-venta` (tanda B incluida), con las mismas reglas: `CHECK` por agregado, sin tolerancia, diff de schema.

**Gates** (se ejecutan de verdad):

- **`supabase/tests/test_remitos_compra.sql` (A)**:
  - dos cuentas; owner, admin, stock, purchases, seller y cashier reales; fixtures propios y cleanup asertado;
  - emisión: stock **+** por par, movimiento `purchase`/`delivery_note` con `quantity_before/after` y costo, normalización 450 g → 0,45 kg, número `RC` correlativo e independiente del `R` de venta y de otra cuenta, historial `NULL → issued` con `delivery_note_purchase`, subtotal y total del servidor con un subtotal falso del cliente, precio 0 admitido;
  - rechazos con su código y cero efectos: sin proveedor, proveedor ajeno o dado de baja, sin sucursal, sucursal ajena o cerrada, línea sin producto, producto ajeno, dado de baja o padre, unidad incompatible, `supplier_reference` de más de 100;
  - idempotencia (misma clave → un remito y una sola suma, `replayed = true`; clave de otro `operation_kind` no choca; fila `delivery_note_purchase` que no es un remito de compra de sus cuentas → `P0409`);
  - roles: `seller`, `cashier` y `purchases` no emiten (`P0403`); `stock` emite y edita pero no anula;
  - edición: sólo precio → 0 movimientos; A=10/B=2 → A=10/B=5 → un solo par espejo sobre B, cero sobre A; **bajar con la mercadería vendida** (10 recibidas, 7 vendidas por el POS, bajar a 8 funciona y a 5 → `P0409 delivery_note_stock_consumed` con cero efectos y el **texto** del error con el stock anterior a la edición (3) y lo que se resta (5)); subir; cambio de producto; **cambio de sucursal con cantidades iguales**, assertando el stock por sucursal (X baja lo aportado, Y lo sube) y que el remito queda en Y, y cambio con la vieja sin toda la mercadería (`P0409`); el mismo cambio de sucursal sobre un remito de **venta** (regresión del núcleo extraído); snapshot acarreado; producto dado de baja conservado, reducido y aumentado (`P0400`); sucursal vigente desactivada → `P0422`; versión vieja; editar un anulado; un remito de **venta** por `rpc_update_purchase_delivery_note` → `P0404`;
  - anulación: sin motivo → `P0400`; `stock` → `P0403`; admin con la mercadería en el depósito → stock restado con `purchase_return`/`delivery_note_reversal` e historial con motivo; **con parte vendida → `P0409 delivery_note_stock_consumed`, cero efectos y el remito sigue `issued`**; segunda anulación → `P0409`; sucursal desactivada → `P0422`;
  - invariante Σ `quantity_delta` por par = Δ `branch_stock`, = `+held` antes de anular y 0 después;
  - fila forjada en el ledger por PostgREST: la anulación resta exactamente lo aportado por las líneas;
  - PostgREST sin escritura directa en las tablas ni ejecución de los helpers;
  - baja de sucursal con un remito de compra pendiente → `P0428 branch_has_pending_delivery_notes` (sin cambios en el guard);
  - guards de unidad con una línea de remito de compra (unidad base y unidad en uso).
- **`test_remitos_venta.sql` re-ejecutado sin cambios** después de la tanda A: es la prueba de que los helpers reescritos y el núcleo de edición no cambiaron el sentido venta.
- **`supabase/tests/test_remito_a_compra.sql` (B)**, con **matriz de evasión**:
  - conversión `cash` (caja con las tres condiciones, `PurchaseCreated`, filas de `purchases` con origen, remito `converted`, historial), `credit` (cargo en la cuenta corriente del proveedor con vencimiento por la cascada desde `p_date`) y `transfer` (`bank_movements`);
  - **stock idéntico antes y después de convertir**; **0** `stock_movements` con `reference_id` en las filas de la compra; `purchases`/`purchase_items` con los cuatro snapshots del remito (producto renombrado entre la recepción y la conversión incluido); total de la compra = total del remito;
  - precio 0 en una línea → `P0400 delivery_note_price_required` y cero efectos; proveedor dado de baja → `P0404 delivery_note_supplier_unavailable`; sucursal desactivada o cerrada → `P0422`; fecha anterior al remito → `P0400`; producto dado de baja después de recibir → convierte;
  - replay; misma clave sobre otro remito → `P0409`; segunda conversión con otra clave → `P0409 delivery_note_invalid_state`; versión vieja; `seller` y `cashier` → `P0403`; `purchases` y `stock` convierten; `cash` sin sesión o con fecha distinta de hoy → `P0422`;
  - **núcleo con origen inválido** (llamado como `postgres` en el gate): remito de otra cuenta, de venta, `canceled`, `converted`, de otro proveedor, de otra sucursal, con `p_items` no nulo, con filas de compra ya existentes → `P0409 delivery_note_purchase_mismatch` / `P0400`, sin compra, stock ni evento;
  - **compra directa sin cambios**: `rpc_create_purchase_operation` antes y después de la extracción produce las mismas filas, movimientos, caja, banco, cargo y evento; los gates de compras vigentes, re-ejecutados sin tocarlos;
  - **borrar la compra**: dinero compensado (caja con `purchase_payment_reversal`, banco, cuenta corriente), stock idéntico, remito `issued` con historial `converted → issued` y motivo; reconvertir funciona; un `stock` o `purchases` que borra la compra de un remito → `P0403 delivery_note_purchase_delete_forbidden` sin efectos; origen apuntado (como `postgres`) a un remito de **otra cuenta** → el borrado rechaza con `P0409` y el remito ajeno sigue `converted`;
  - **integridad del puente** por PostgREST con un `seller` real: `INSERT` de una compra con origen, `UPDATE` que forja, limpia o cambia el origen, y `DELETE` de una fila con origen → `P0403 delivery_note_source_protected`, sin efectos; control positivo: la misma escritura sobre una compra directa sigue como hoy; sucursal del remito desactivada después de convertir → `P0422` sin efectos;
  - editar la compra → `P0423 delivery_note_purchase_locked` antes del `P0423` de dinero, con `branch_stock` y `stock_movements` sin cambios;
  - anular un remito convertido → `P0423`;
  - el `P0423` de dinero de una compra directa no cambia (regresión).
- **`supabase/tests/test_remitos_compra_race.sh`** (molde de `test_presupuesto_a_venta_race.sh`): dos conversiones del mismo remito → una compra; conversión contra anulación → gana una, nunca compra con remito `canceled`; edición contra conversión; dos emisiones con la misma clave → un remito, nunca un 500; **anulación contra una venta del POS** que consume la última unidad recibida → o la anulación resta todo y la venta rechaza por stock, o la venta descuenta y la anulación rechaza con `delivery_note_stock_consumed`; nunca stock negativo ni `23514`; borrado de la compra contra reconversión y contra anulación del remito convertido → sin interbloqueo ni doble efecto; **dos borrados concurrentes de la misma compra de remito** → una sola compensación de dinero y una sola transición `converted → issued`; **borrado viejo contra reconversión** (T1 borra, T3 reconvierte, T2 —que esperó a T1— sigue) → T2 termina sin efectos y el remito queda `converted` con la compra de T3 viva; variante a crédito sin `40P01`.
- **Gates existentes actualizados por tanda**: `test_document_status_transition_role_matrix.sql` (tamaño del catálogo, llamadores, pares producidos), `test_function_acl_gate.sql` (funciones nuevas; `_purchase_operation_core` en el chequeo (4)), `test_internal_document_numbering_race.sh` parametrizado con `delivery_note_purchase`.
- Todos cableados en `KPI_Validation.yml`, en el orden real del workflow.

**Dos PRs** (A, luego B), con CI verde y revisión adversarial antes de cada merge. La tanda A entrega valor sola (recibir, editar, anular, compartir). En A, el botón "Compra" no se muestra.

## Risks / Trade-offs

- **[Doble suma por fuera de la conversión]** → quien recibió con remito puede cargar la factura como compra directa ("Nueva compra" o Factura IA, RN-53), que vuelve a sumar el stock. Mitigación: aviso con enlace a los remitos pendientes en los dos caminos (D11) y conversión habilitada para `stock`, que es quien recibe (D12, OQ-RC6). No se bloquea: una compra directa puede ser otra mercadería. La conversión OCR → remito pendiente queda como candidato.
- **[Puente escribible por PostgREST]** → `purchases` admite escritura de `authenticated`; sin guard, un escritor forjaría, limpiaría o desviaría `source_delivery_note_id` (stock inflado al borrar, reversa indebida al editar, remito ajeno reabierto) o borraría las filas dejando el remito `converted` para siempre. Mitigación: disparador del puente (D9) y lectura del remito con `account_id` y `direction` en el borrado, con gate y red-team.
- **[Doble borrado o borrado viejo contra reconversión]** → el borrado bloquea el remito antes de compensar y revalida filas y estado bajo el lock (D8, D9); gate de carreras.
- **[Reaplicación de `20261069000001` en CI]** → sus `CHECK` de lista fija y su chequeo de una definición por `proname` son incompatibles con la tanda A: se retira ese paso en el mismo PR, con reconvergencia por `db reset` (D16), y las migraciones de compra amplían los `CHECK` por agregado.
- **[Doble suma al convertir]** → el núcleo decide por el remito validado bajo bloqueo (sin parámetro público), lee las líneas del remito y persiste el origen; la matriz de evasión cubre remito ajeno, de venta, anulado, convertido, de otro proveedor, de otra sucursal, con líneas del request y con compra existente, más dos conversiones concurrentes.
- **[Regresión de la compra directa por la extracción del núcleo]** → checkpoint de cuerpo vivo (`md5(prosrc)` hoy igual al archivo), diff adjunto limitado a la extracción y a la rama de origen, gate de equivalencia antes/después y re-ejecución de los gates de compras sin tocarlos.
- **[Regresión del remito de venta por los helpers compartidos]** → firma intacta, el sentido se lee del remito, `test_remitos_venta.sql` re-ejecutado sin cambios y revisión del diff de cada helper.
- **[Stock negativo al anular o editar]** → gate explícito `delivery_note_stock_consumed` antes del delta en toda pata que resta; sin él, el `CHECK (quantity >= 0)` de `branch_stock` abortaría con `23514`. Carrera anulación-contra-venta en el gate.
- **[Edición de la compra sumaría o restaría de nuevo]** → `P0423 delivery_note_purchase_locked` antes de cualquier escritura, con gate de cero efectos.
- **[Borrado de la compra repone o resta stock por error]** → salto explícito de la reversa y gate de stock idéntico.
- **[Borrado de la compra reabre el remito sin autoridad]** → el borrado con origen exige el rol de anular el remito de compra (D9); el borrado de compras sin origen no cambia (sigue sin guard de rol, preexistente, candidato).
- **[Remito reabierto en una sucursal dada de baja]** → guard de sucursal viva en el borrado, autosuficiente en la anulación y la edición.
- **[Interbloqueo entre un remito y una venta o compra concurrente]** → riesgo residual, igual que en venta: el remito bloquea productos en orden de `id`; la conversión no bloquea productos; `40P01` → `409 concurrent_update_retry` y la emisión es idempotente.
- **[Chequeo por usuario del producto en la compra]** (`v_product.user_id <> v_uid`, preexistente) → en una cuenta con varios miembros, una compra directa de un producto creado por otro usuario falla con `P0403`. La conversión no lo hereda (no bloquea ni revalida productos en modo remito). Hoy hay 0 cuentas con más de un miembro; candidato aparte.
- **[Precio 0 al recibir]** → la conversión lo rechaza con un mensaje accionable y el detalle deshabilita "Compra" con el motivo; el listado marca cada remito con el badge "Sin precio" y el resumen cuenta cuántos lo tienen, porque su total suma $0 y no se distinguiría.
- **[Precio de venta precargado en la línea de compra]** → `priceSource: "cost"` en el editor compartido (D11), con tests de alta manual y de escaneo.
- **[Valuación por costo de catálogo]** → deliberado (OQ-RC2); es el comportamiento de la compra directa. El costeo por compra es un non-goal.
- **[Choques de orden con `remitos-venta` tanda B y con #607]** → "quien llega segundo parte del cuerpo vivo", anotado en cada checkpoint; el bloque de reaplicación de `20261062000001` lo retira el primero.
- **[RLS preexistente del ledger y RPCs públicas que mueven stock]** → fuera de alcance, igual que en venta; este change no suma amplificadores (lo aportado sale de las líneas).

## Migration Plan

1. **Tanda A** (después del merge de `remitos-venta` tanda A):
   - merge → CI/CD aplica la migración y despliega (verificar `GET /deploys` de Render y Vercel);
   - verificación post-merge (sólo lectura): `MAX(version)`, `CHECK` con `delivery_note_purchase`, disparadores gemelos, las dos filas de la tanda A de `delivery_note_purchase` presentes, ACLs, una definición de cada función reescrita, cuerpos;
   - humo del PO: recibir un remito de un proveedor → el stock sube en `/stock` con el rótulo "Remito RC-…" → editar (subir, bajar, cargar precios) → compartir con y sin precios → vender parte por el POS → intentar anular (rechazo explicado) → reducir y anular el resto.
2. **Tanda B**:
   - merge → verificación: columna e índice, catálogo con 4 filas, núcleo sin `authenticated`, wrapper con la misma ACL, cuerpos con la rama de origen; control: las compras directas de las últimas horas siguen teniendo su movimiento `purchase/purchase`;
   - humo del PO: remito → Compra (efectivo con caja abierta y a crédito) → el stock **no** vuelve a subir → badge en `/compras` → cuenta corriente del proveedor → borrar la compra → el remito vuelve a pendiente y el stock no cambia → reconvertir.
3. **Rollback**:
   - A: una migración nueva re-aplica los cuerpos previos de los helpers y de las dos RPCs de venta (capturados en el checkpoint) y hace `DROP` de las RPCs de compra. Los remitos de compra emitidos se anulan antes desde la UI (resta el stock).
   - B: una migración nueva re-aplica los cuerpos previos de las tres funciones de compra y hace `DROP` de la conversión y del núcleo. Las compras ya convertidas siguen siendo compras válidas sin movimientos propios; su stock vive en el remito.

## Sign-off del PO

**Decisiones firmadas (2026-09-29), textuales**: «no necesito el remito legal. Andá con todo lo recomendado» y «quiero que tanto el remito como los presupuestos se puedan modificar». Cubren R1–R8 del explore (OQ-R1..R8) aplicadas al sentido compra, con R4 cambiado por el PO respecto de la recomendación del explore (el remito es editable):

- **R1** (interno "X") → D10, Non-goals.
- **R2** (PDF sin precios por defecto; precios siempre guardados) → D1, D10, D11.
- **R3** (anular con motivo; resta stock) → D3, D6.
- **R4** (editable mientras no esté convertido; espejo; faltante sobre el neto) → D5.
- **R5** (borrar la compra devuelve el remito a pendiente sin tocar stock) → D9.
- **R6** (anular con mercadería consumida → `P0409`) → D4, D6.
- **R7** (emitir `stock`/`admin`/`owner`; anular `admin`/`owner`) → D3, D12. **Quién convierte no está firmado** (OQ-R7 sólo cubrió emitir y anular): es la recomendación de OQ-RC6.
- **R8** (1 remito → 1 compra; sin gate de plan; descarga y WhatsApp; proveedor obligatorio y número del proveedor) → D1, D8, D11.

**Las OQ-RC de abajo son nuevas de este propose.** Se adoptan por su recomendación como default declarado, salvo que el PO elija otra alternativa antes del apply (tarea 0.1).

## Open Questions

- **OQ-RC1 — Remito de compra sin precio.**
  - *Recomendado*: admitir precio 0 al recibir; la conversión exige todos los precios mayores que 0 (D1, D8).
  - *Alternativa*: exigir precio al emitir (obliga a esperar la factura o a inventar un precio).
- **OQ-RC2 — Costo congelado en las líneas y en el ledger.**
  - *Recomendado*: costo de catálogo, igual que la compra directa; el precio de compra queda en `price` (D1).
  - *Alternativa*: congelar el precio de compra normalizado a la unidad base (cambia la valuación respecto de la compra directa y no funciona con precio 0).
- **OQ-RC3 — Prefijo del número.**
  - *Recomendado*: `RC-00000001` (D2).
  - *Alternativa*: `RCP-` u otro prefijo, siempre distinto de `R`.
- **OQ-RC4 — Forma de pago al convertir.**
  - *Recomendado*: obligatoria (como en la conversión de venta), aunque la compra directa la admita vacía (81 de 127 operaciones no la tienen): la compra nacida del remito es justamente el momento de decir cómo se paga.
  - *Alternativa*: opcional, como la compra directa.
- **OQ-RC5 — Fecha de la compra al convertir.**
  - *Recomendado*: editable, por defecto hoy, no anterior a la fecha del remito; la caja exige hoy (D8).
  - *Alternativa*: siempre la fecha de la conversión, como la venta.
- **OQ-RC6 — Quién convierte** (emitir y anular están firmados en R7).
  - *Recomendado*: convertir `purchases`/`stock`/`admin`/`owner` (`CAN_CONVERT_PURCHASE_DELIVERY_NOTE`), sin activar `CAN_PURCHASE` en `/compras` en este change (D12). Razón: hoy cualquier escritor, `stock` incluido, registra compras directas que mueven stock y dinero; si `stock` recibiera pero no pudiera convertir, su único camino con la factura en la mano sería la compra directa, que vuelve a sumar el stock.
  - *Alternativa A*: sólo `CAN_PURCHASE` (`purchases`/`admin`/`owner`), combinada con el aviso de D11 en la compra directa; deja a `stock` empujado a la doble suma.
  - *Alternativa B*: activar `CAN_PURCHASE` también en `/compras` (cambia el permiso de una pantalla en uso) y sumar `purchases` a la emisión.
- **OQ-RC7 — Borrar una compra nacida de un remito.**
  - *Recomendado*: exige el rol de anular el remito (`admin`/`owner`), porque lo reabre (D9).
  - *Alternativa*: dejarlo como el borrado de cualquier compra (sin guard de rol).
- **OQ-RC8 — Pestañas por sentido en `/remitos`.**
  - *Recomendado*: "De venta" / "De compra" con `?sentido=`, default venta (D11).
  - *Alternativa*: una ruta aparte (`/remitos-compra`) o una entrada propia en el menú.
- **OQ-RC10 — Alcance del bloqueo de la compra nacida de un remito.** El PO firmó "no permite editar líneas"; el design bloquea la operación entera, cabecera incluida (fecha, descripción, centro de costo, forma de pago).
  - *Recomendado*: bloqueo total (D9). El editor de compras siempre reemplaza líneas (REVERSE+APPLY) y su REVERSE restaría stock que aporta el remito; corregir la cabecera es borrar la compra (el remito vuelve a pendiente) y reconvertir, que además re-postea el dinero con la forma de pago correcta.
  - *Alternativa*: permitir editar la cabecera sin dinero posteado por un camino nuevo que no haga REVERSE/APPLY (otra RPC, más superficie).
- **OQ-RC9 — Remitos desde el proveedor.**
  - *Recomendado*: acción "Nuevo remito de compra" en el listado y botones en la cuenta corriente, sin pantalla de ficha nueva.
  - *Alternativa*: una ficha de proveedor con pestaña de remitos.
