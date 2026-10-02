## Context

El pedido, las decisiones firmadas (R1–R8) y el alcance están en `proposal.md`. El mapa de lo que existe está en el explore (`openspec/changes/presupuestos-modulo/research/explore-presupuestos-remitos.md`, §1.5, §2.2, §3 (d)–(h), §4–§6) y en el change hermano `presupuestos-modulo` (D3, D6, D8, D9, D11, D12, D14). Este documento cubre **sólo** `remitos-venta`. El remito de compra es `remitos-compra`: acá se deja el modelo de datos listo para los dos sentidos, sin diseñar la conversión a compra ni su pantalla.

### Lo que ya existe (verificado en `main` `95eb8dd7`, 2026-10-02)

| Pieza | Dónde (última definición) | Relevante para este change |
|---|---|---|
| `_c29_confirm_order_core` | `20261062000001_ventas_unidades_conversion.sql:1118-1583` | Recorre `sales_order_items` en orden de `id`. Por cada línea con producto: `FOR UPDATE` del producto (`:1388`), `_uom_normalize_quantity` (`:1402`), gate `branch_stock >= qty` con `P0409 'stock_insuficiente para producto %: disponible %, solicitado %'` (`:1404-1415`), `c21_apply_branch_stock_delta` (`:1421`), fila legacy `sales` (`:1428`), `sale_items` con `v_product.cost` (`:1441`) y `stock_movements(type='sale', reference_type='sale', reference_id = sales.id)` (`:1451`). Después: caja, cuenta corriente, banco, fiscal, `SaleConfirmed` y `draft→confirmed`. **No filtra `products.deleted_at`.** |
| `rpc_delete_sale_operation` | `20261061000001_venta_editable_vs_promocion_legacy.sql:1078-1297` | Lock de `sales` → orden → guard fiscal → cuenta corriente → caja → banco → `rpc_reverse_stock_movement(sale_id,'sale')` por fila (`:1257`) → `SaleOperationDeleted` → orden `confirmed→canceled` (`:1276-1285`) → `DELETE`. |
| `rpc_reverse_stock_movement` | `20260828000001_v31_rls_collision_rpcs.sql` | Revierte los movimientos **existentes** con ese `reference_id`/`reference_type`. Sin movimientos no hace nada y no da error. Sólo admite `purchase`/`sale`. |
| `rpc_atomic_update_sale_operation` | `20261062000001:1594-2262` | Lock de `sales` (`:1687`) → guard de cliente → anulación fiscal → tres `P0423` de dinero → REVERSE por el delta guardado + APPLY normalizado. La REVERSE **no** es un no-op sin movimiento propio: busca el último movimiento `reference_type='sale'` de la fila y, si no lo hay, **cae a `_uom_normalize_quantity` de la línea y devuelve esa cantidad al stock** (`:1975-1990`). Para una venta nacida de un remito, una edición repondría stock que el remito sigue reteniendo y la APPLY lo descontaría de nuevo; una reducción dejaría reposición de más, que la anulación posterior del remito duplicaría. |
| `_uom_normalize_quantity` | `20261062000001:207-320` | Definición única de RN-24. Interna. |
| `c21_apply_branch_stock_delta` | `20260625000002_c26_fix_helper_upsert_check.sql` | Delta sobre `branch_stock`. Es la usada por el núcleo. |
| Guards de unidad | `fn_product_base_unit_guard` (`20261062000001:3585-3785`, listas de líneas en `:3748-3754`), `fn_uom_in_use_guard` (`:3814-3839`, lista en `:3829-3832`) y `_GROUP_HAS_LINES_IN_OTHER_UNIT_SQL` (`backend/repositories/product_repository.py`) | Enumeran las tablas de líneas (`sales`, `purchases`, `sale_items`, `purchase_items`, `sales_order_items`, `quote_items`). Una tabla de líneas nueva **tiene que sumarse a las tres** o el guard queda evadible. |
| Guard de baja de sucursal | `20261014000001_sucursal_guard_vaciado_auditoria.sql` (ninguna migración posterior las redefine) | El predicado vive en **`_branch_blocking_content(uuid) RETURNS TABLE (total_qty, product_count, cash_session_open, pending_transfers, other_active_branches)`** (`:254`, "una sola definición del predicado"). El orden de evaluación y los `RAISE … P0428` con token de texto (`branch_has_stock`, `branch_has_open_cash_session`, `branch_has_pending_transfers`) viven en **`_branch_assert_empty(uuid)`** (`:343-386`). `fn_guard_branch_decommission` sólo hace `PERFORM _branch_assert_empty(OLD.id)` (`:433`), y `rpc_deactivate_branch` (`:614`) y `rpc_close_branch` (`:694`) la llaman directo. La introspección exige exactamente 7 definiciones (`:852-857`). El frontend discrimina los `P0428` por token en `frontend/hooks/data/use-branches.ts::translateRpcError` (`:55-60`). Gate: `supabase/tests/test_sucursal_guard_vaciado.sql`. |
| Numeración interna | `20261067000001_presupuestos_modulo.sql:140-290` | `internal_document_sequences` con `CHECK (document_type IN ('quote'))`, `_next_internal_document_number`, `_assign_internal_document_number` y el disparador genérico `trg_assign_internal_document_number(TG_ARGV[0])`. |
| Escritura del presupuesto | `20261067000001:346-632` | `_quote_assert_can_write`, `_quote_validate_items` (el guard de producto vivo, de la cuenta y no padre vive embebido en `:439-450`), `_quote_insert_items`, `_quote_payload`, `rpc_create_quote`: el molde de las RPCs de este change. |
| Conversión del presupuesto | worktree `opsx/presupuestos-modulo-apply-b`, `20261068000001_presupuestos_conversion_venta.sql:284-458` (sin mergear) | Molde exacto de la conversión: lock del origen → idempotencia bajo lock → estado, vencimiento y versión → guards → núcleo → `RAISE` si el núcleo devuelve `replayed`. |
| FSM | `trg_enforce_status_transition(TG_ARGV)` (`20260816000001:159-205`), `record_status_transition` (`20261048000001`), creación por disparador (`trg_quote_record_creation`, `20260807000001:393-421`) | El remito suma su enforcement y su registro de creación sin lógica nueva. |
| PDF y compartir | `backend/services/commercial_documents/{view,pdf,issuer,numbering}.py`, `frontend/components/shared/DocumentShareMenu.tsx`, `frontend/lib/document-share.ts` | `CommercialDocumentView` ya tiene `show_prices` y el render ya lo respeta (`pdf.py:158-194`). El comentario de `view.py:7-8` anuncia el remito. |
| Editor de líneas | `frontend/lib/cart-utils.ts` (`exceedsStock` `:185`, que excluye las líneas `source: "persisted"`; `addManualLineToCart` `:341`; `applyScanToCart` `:410`; reductores `:456-492`), `QuoteForm.tsx` | El presupuesto pasa `enforceStock: false`. El remito pasa `true`. |
| Cierre de venta | worktree de la tanda B: `components/ventas/SaleCheckoutFields.tsx` (props `branchId`/`onBranchChange`/forma de pago/banco/`checkout`) y `SaleCheckoutSuccess.tsx` | El remito los compone; la sucursal no se elige al convertir (D7). |
| RBAC | `backend/core/rbac.py` (`CAN_SELL = {owner, admin, seller, cashier}`, `CAN_STOCK`, `CAN_QUOTE`, `CAN_CONFIGURE`, `SENSITIVE_CAPABILITIES`), `frontend/lib/rbac-capabilities.ts` | Capacidades nuevas en las dos capas. |
| Panel de movimientos | `frontend/components/stock/stock-movements-panel.tsx:62-90`, `:250-262` | Rotula por `type` (`sale` → "Venta"). Un remito con `type='sale'` aparecería como "Venta" si no se rotula por `reference_type`. **No consume el backend ni React Query**: lee `stock_movements` directo por supabase-js (`select("*, products(name)")`) con estado local (`useState` + `useEffect`), y `reference_id` es polimórfico, sin FK que permita embeber el remito. |
| Selector de sucursal | `frontend/components/branches/BranchSelect.tsx:29-40` | `return null` si el plan no tiene `hasBranchesModule` (3 de los 4 planes, `lib/constants.ts:49/69/89`), y siempre ofrece la opción "Sin sucursal". El formulario de venta manda `null` y deja resolver al servidor (`sale-form.tsx:152`). |
| Domicilio del cliente | `backend/main.py:182` (router `client_addresses`), `frontend/lib/types.ts:948` | El frontend **no** tiene hook ni cliente API de `/clients/{id}/addresses`: sólo el tipo. |
| Borrado de venta en el frontend | `frontend/hooks/data/use-sales.ts:299-329` | `deleteSaleMutation` y `deleteSalesByOperationMutation` invalidan `sales`, `customerAccounts` y `receivables`. Nada más. |

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
  - Sin unidad base **propia** (`base_unit_id` nulo crudo): 4.660 de los `tracked` y los 644 `variant_only`. Sin unidad base **efectiva** (`COALESCE(p.base_unit_id, padre.base_unit_id)`, el criterio que usa D4): 4.486 de los `tracked`.
  - 491 padres distintos referenciados por al menos una variante viva (`COUNT(DISTINCT parent_id)` sobre variantes con `deleted_at IS NULL`, sin filtrar el estado del padre).
- **Unidades del sistema**: Unidad, Kilogramo, Litro y Metro son base (factor 1, sin `base_unit_id`). Gramo, Tonelada, Mililitro, Docena, Caja x 6 y Centímetro tienen `base_unit_id`, así que un producto **sin** unidad base no las admite (`unit_requires_base_unit`, `20261062000001:271-277`).
- **Cuentas**: 41; **1** con más de una sucursal activa.
- Volumen: 4.925 `stock_movements` (1.204 `sale/sale`), 133 `sales_orders`, 0 `quotes`.
- Políticas de escritura (`pg_policies`):
  - `sales_orders` y `sales_order_items` sólo tienen `SELECT`, así que la orden sólo se crea por RPCs `SECURITY DEFINER`.
  - `stock_movements`: `INSERT` para **cualquier miembro** de la cuenta (`stock_movements_account_insert WITH CHECK (account_id IN current_account_ids())`, sin `is_account_writer`); `UPDATE` y `DELETE` con `qual = false` (append-only).
  - `branch_stock`: `INSERT`/`UPDATE` para `is_account_writer`.
  - Consecuencia de diseño: **el ledger es escribible por PostgREST**, así que ningún cálculo que devuelva stock a `branch_stock` desde una función definer puede salir de sumar `stock_movements` (D4). La RLS en sí es preexistente y queda fuera de alcance (ver Riesgos).
- **Funciones públicas que ya mueven stock sin guard de rol** (`pg_proc`, 2026-10-02):
  - `rpc_reverse_stock_movement(p_reference_id, p_reference_type, p_reason)`: `SECURITY DEFINER`, `EXECUTE` para `authenticated`, sin `is_account_writer` ni rol. Devuelve `-quantity_delta` a `branch_stock` por cada fila de `stock_movements` con esa referencia (`'sale'`/`'purchase'`) en la cuenta actual. Combinada con la política de `INSERT` de arriba, **una fila forjada en el ledger ya se convierte hoy en stock**: un miembro cualquiera inserta una fila `reference_type='sale'` de `-1000` y llama a la función.
  - `rpc_apply_product_stock_delta(...)`: `SECURITY DEFINER`, `EXECUTE` para `authenticated`, sin `is_account_writer`: un miembro mueve stock directo.
  - Las dos son preexistentes y quedan fuera de alcance (candidato en la tarea 9.1). `rpc_reverse_stock_movement` sólo admite `sale`/`purchase`, así que no alcanza a los movimientos `delivery_note*` del remito.
- `operation_idempotency`: `operation_kind_check` con 13 tipos (sin ninguno de remito), `operation_id_contract` (`operation_id` obligatorio salvo `event_consumer`/`subscription_webhook`) y `UNIQUE (user_id, operation_kind, idempotency_key)`.

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
| `account_id` | `uuid NOT NULL → accounts ON DELETE CASCADE` | Convención de la casa (`quotes`, `sales_orders`, `internal_document_sequences`). |
| `direction` | `text NOT NULL CHECK (direction IN ('sale','purchase'))` | Este change sólo escribe `'sale'`. Ninguna RPC de este change acepta `'purchase'`. |
| `branch_id` | `uuid NOT NULL → branches` | Sucursal de la que sale (o, en compra, a la que entra) el stock. |
| `client_id` | `uuid NULL → clients` | |
| `supplier_id` | `uuid NULL → suppliers` | Lo usará `remitos-compra`. |
| `supplier_reference` | `text NULL`, `CHECK (char_length <= 100)`, `CHECK (direction = 'purchase' OR supplier_reference IS NULL)` | Número del remito del proveedor (explore §3, sentido compra). Ninguna RPC de este change lo escribe: queda listo para que `remitos-compra` no tenga que alterar la tabla. |
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
- `(client_id)` y `(branch_id)` parciales (`WHERE status = 'issued'`) para el guard de baja de sucursal (D10) y la ficha del cliente;
- `(supplier_id)` parcial (`WHERE status = 'issued'`), el gemelo de `client_id` para `remitos-compra`.

**`delivery_note_items`**:
- `id`, `delivery_note_id → delivery_notes ON DELETE CASCADE`, `account_id NOT NULL → accounts ON DELETE CASCADE`, `line_no integer NOT NULL`;
- `product_id uuid NOT NULL → products`, `unit_id uuid NULL → units_of_measure`;
- `quantity numeric(15,4) NOT NULL CHECK (> 0)`;
- `price numeric NOT NULL CHECK (>= 0)`: precio por unidad de la línea, sin escala (RN-24-bis, igual que `quote_items.price`); `subtotal numeric(15,2) NOT NULL CHECK (>= 0)`;
- snapshots: `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` (NULL = sin costo cargado, `productos-costo-nullable`) e `iva_rate_snapshot` (NULL, D3 de `v3-snapshot-pattern`), en el **mismo** `INSERT … SELECT` desde `products` filtrado por `account_id` (spec `document-snapshots`);
- `quantity_base numeric(15,4) NOT NULL`: la cantidad normalizada a la unidad base que la línea retiene del stock, calculada con `_uom_normalize_quantity` **después** del lock del producto y escrita en el mismo `INSERT` de la línea (D4, nunca queda nula). **Es la fuente de lo que el remito retiene** (D4 "Lo retenido"): la edición y la anulación revierten por `Σ quantity_base` de las líneas vigentes, agrupado por producto, en la sucursal vigente del remito. La escriben sólo las RPCs del remito (tabla sin políticas de escritura) y queda estable mientras el remito exista: el factor de su unidad no puede cambiar (`unit_in_use`, D14) ni la unidad base del producto reasignarse (`base_unit_locked`, D14).

Las demás FK (`branch_id`, `client_id`, `supplier_id`, `product_id`, `unit_id`) quedan con la acción por defecto (`NO ACTION`): el remito nunca se borra físicamente, y `NO ACTION` se verifica al final de la sentencia, así que no traba un borrado de cuenta en cascada que alcance varias tablas a la vez.

RLS: `SELECT` para los miembros de la cuenta en las dos tablas; **ninguna** política de escritura. `REVOKE ALL … FROM anon`.

- **Líneas sólo con producto** (OQ-RV11): un remito documenta mercadería que sale del depósito. Así la conversión no hereda los problemas de las líneas de servicio de la venta (OQ-P15/P16 de presupuestos). `P0400 delivery_note_product_required`.
- **Sin tabla de cabecera por sentido.** `remitos-compra` suma su RPC de alta, su disparador de número y su conversión sobre las mismas tablas.
  - *Rechazado*: `sales_delivery_notes` + `purchase_delivery_notes`. Duplicaría FSM, numeración, PDF, listado y guards de unidad para dos documentos con la misma forma (explore §3(d)).
- **Sin columna `show_prices`.** Mostrar precios es una decisión de cada descarga o envío, no un atributo del documento (D8).
  - *Rechazado*: guardarla. Obligaría a editar el remito, con revisión y lock, para cambiar cómo se imprime.
- **Sin columnas `canceled_at`/`cancel_reason`.** El motivo y el actor viven en `document_status_history`, que es la fuente única (RN-A5). El read model los lee de ahí.
- **Puente remito ↔ venta**: `sales_orders.source_delivery_note_id uuid NULL → delivery_notes ON DELETE NO ACTION` (tanda B). En la práctica equivale a `RESTRICT` (el remito nunca se borra), pero `RESTRICT` se verifica de inmediato y podría hacer fallar, según el orden de los disparadores de integridad, un borrado de cuenta que cascadea a la vez sobre `delivery_notes` y `sales_orders` (los gates limpian borrando cuentas); `NO ACTION` se difiere al final de la sentencia. Lleva un índice único **parcial** `(source_delivery_note_id) WHERE source_delivery_note_id IS NOT NULL AND status <> 'canceled'`: a lo sumo una orden viva por remito, y una orden cancelada (venta borrada) no impide reconvertir. El remito no guarda el id de la venta: se deriva.

### D2 — Numeración `R-…` por cuenta y por sentido

- Se amplía `internal_document_sequences_document_type_check` a `('quote', 'delivery_note_sale')`. Es aditivo e idempotente (`DROP CONSTRAINT IF EXISTS` + `ADD`). `remitos-compra` sumará `'delivery_note_purchase'`.
- Disparador `delivery_notes_assign_number_sale`: `BEFORE INSERT … FOR EACH ROW WHEN (NEW.direction = 'sale') EXECUTE FUNCTION trg_assign_internal_document_number('delivery_note_sale')`.
  - Reutiliza **sin cambios** la función genérica de D3 de presupuestos. La cláusula `WHEN` resuelve que una tabla lleve dos sentidos con tipos de secuencia distintos.
  - `remitos-compra` suma su gemelo con `WHEN (NEW.direction = 'purchase')` y `'delivery_note_purchase'`.
  - No hay función nueva ni lógica copiada.
  - *Rechazado*: una función propia que calcule `'delivery_note_' || NEW.direction`. Contradice el requirement de la capability (una sola función genérica parametrizada por tipo) sin ganar nada sobre el `WHEN`.
  - Por eso la unicidad es `UNIQUE (account_id, direction, number)`: los dos sentidos comparten tabla y cada uno numera desde 1.
- Formato: prefijo `R` + 8 dígitos (`R-00000012`). Se suma a la única definición por lenguaje (`frontend/lib/internal-document-number.ts`, `backend/services/commercial_documents/numbering.py`) y al fixture compartido `backend/tests/fixtures/internal_document_number_cases.json`, **indexado por tipo de secuencia** (`delivery_note_sale` → `R`), no por tabla. La búsqueda acepta "R-12", "12" o "00000012".
- **El prefijo `R` es sólo del sentido venta.** Como cada sentido numera desde 1, el remito de compra **no** puede usar `R` (los dos mostrarían `R-00000001`). `remitos-compra` elige su prefijo propio, distinto de `R` (recomendado: `RC`), y lo suma a las mismas definiciones. Toda superficie que muestra el número de un remito lo formatea desde `direction` (o el tipo de secuencia), nunca con el prefijo fijo: el listado, el detalle, el PDF y el panel de `/stock` (D11) ya lo hacen así en este change.
- **Por qué una secuencia por sentido** (OQ-RV1): el comercio espera que sus remitos de venta salgan correlativos y sin huecos. Los de compra se identifican sobre todo por el número del proveedor, y compartir la secuencia intercalaría números que nunca entregó.
  - *Rechazado*: una sola secuencia `'delivery_note'`.
- Las propiedades de la capability (sin huecos, sin repetidos, un alta revertida no consume número, serializa sólo las altas de la misma cuenta y tipo) se heredan sin cambios.

### D3 — Máquina de estados: `issued → converted | canceled`, más la vuelta `converted → issued`

`document_type = 'delivery_note_sale'` se suma a los dos `CHECK` (`document_status_history`, `document_status_transitions`), de forma aditiva.

**Un tipo de documento por sentido, no uno solo `'delivery_note'`.** El catálogo tiene dos índices únicos: `(document_type, from_status, to_status) WHERE from_status IS NOT NULL` y `(document_type, to_status) WHERE from_status IS NULL` (`20260807000001:150-155`). Con un único tipo para los dos sentidos, `remitos-compra` no podría sembrar su propia fila `NULL → issued`, y la de venta (que incluye a `seller`) habilitaría a un vendedor a emitir remitos de compra. R7 exige roles distintos por sentido. Por eso:
- el tipo de este change es `'delivery_note_sale'`, el mismo literal que la secuencia de D2;
- los disparadores de creación y de enforcement llevan `WHEN (NEW.direction = 'sale')` (y `OLD.direction`/`NEW.direction` en el de `UPDATE`), igual que el de numeración;
- `remitos-compra` sumará `'delivery_note_purchase'` con sus filas y sus disparadores gemelos condicionados a `'purchase'`, sin tocar los de venta.

Filas del catálogo, cada una en la tanda que trae la operación que la usa (regla del seed: no se siembra una transición sin productor):

| Transición | `allowed_role` | `requires_reason` | `is_terminal_to` | Productor | Tanda |
|---|---|---|---|---|---|
| `NULL → issued` | `{seller, stock, admin, owner}` | no | no | disparador de creación (`trg_delivery_note_record_creation`, molde de `trg_quote_record_creation`) | A |
| `issued → canceled` | `{admin, owner}` | **sí** | **sí** | `rpc_cancel_delivery_note` | A |
| `issued → converted` | `{seller, cashier, admin, owner}` | no | no | `rpc_convert_delivery_note_to_sale` | B |
| `converted → issued` | `NULL` (sistema) | no | no | `rpc_delete_sale_operation`, al borrar la venta nacida del remito | B |

- **Sin `draft`.** El PO pidió que el remito "baje de stock cuando se crea". Un borrador sin stock sería un presupuesto con otro nombre.
- **`converted` no es terminal**: la vuelta a `issued` la hace cumplir R5. `canceled` sí es terminal.
- **`converted → issued` sin rol** (`allowed_role NULL` con fila existente: es la **tercera** exención de `record_status_transition`; la segunda es "sin fila en la matriz", que no aplica). La dispara sólo el borrado de la venta, y ese borrado ya está restringido a `admin`/`owner` por la transición `sales_order confirmed → canceled` que `rpc_delete_sale_operation` registra antes (`20261048000001:411`, `20261061000001:1281`). Todo usuario que llega a reabrir el remito tiene, por lo tanto, un rol del remito. Repetir el rol en esta fila sería redundante y haría que la autoridad del borrado se definiera en dos lugares. El actor registrado es el usuario que borró; el motivo, `"Venta eliminada (operación …)"`.
- Enforcement: disparador `delivery_notes_enforce_status_transition … WHEN (NEW.direction = 'sale') EXECUTE FUNCTION trg_enforce_status_transition('delivery_note_sale')`. Ningún `UPDATE` de estado fuera del catálogo prospera, venga de donde venga. La creación: `trg_delivery_note_record_creation`, también con `WHEN (NEW.direction = 'sale')`, que registra con `'delivery_note_sale'`.
- **Editar no cambia el estado ni escribe historial.** El rastro de una edición es el par espejo en el ledger (D5) más `updated_at`/`updated_by`/`revision`.
- *Rechazado*: estado `invoiced`. "Convertido en venta" no implica comprobante fiscal: la venta se factura después, o nunca. La UI lo muestra como "Convertido en venta".

### D4 — Stock en la emisión: mismo camino que la venta, movimientos por par producto-sucursal, `reference_type` propio

**`rpc_create_sale_delivery_note(p_idempotency_key text, p_client_id uuid, p_branch_id uuid, p_delivery_address text, p_notes text, p_items jsonb) → jsonb`**, `SECURITY DEFINER`, `SET search_path = public`:

1. `auth.uid()` no nulo; `p_idempotency_key` no vacía (`P0400 idempotency_key_required`). **La emisión mueve stock, así que es idempotente** (spec `api-standards`: `Idempotency-Key` en toda mutación no idempotente por naturaleza; es lo que ya exigen compras, gastos, caja y cuentas corrientes). **Molde DEC-06 exacto**, el de `_c29_confirm_order_core` (`20261062000001:1350-1358`), que `test_idempotency.sql:218` ya controla en las RPCs vivas:
   - `v_dn_id := gen_random_uuid()`;
   - `INSERT INTO operation_idempotency (user_id, operation_kind, idempotency_key, operation_id) VALUES (auth.uid(), 'delivery_note_sale', key, v_dn_id) ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING; GET DIAGNOSTICS v_inserted = ROW_COUNT;`
   - si `v_inserted = 0`: se lee el `operation_id` existente. Si es un remito de venta de las cuentas del usuario → devuelve `_delivery_note_payload(operation_id)` con `replayed = true`, sin efectos. Si no lo es → `P0409 idempotency_key_conflict`;
   - un envío concurrente con la misma clave espera en el `ON CONFLICT` a que el primero termine: si el primero commitea, el segundo cae en `DO NOTHING` y se resuelve como replay; si revierte, el segundo inserta su fila y emite. **Nunca** se deja escapar un `23505` (dentro de plpgsql abortaría la transacción y el doble clic recibiría un 500);
   - la fila de idempotencia se inserta **antes** de escribir el remito y revierte con él;
   - `operation_idempotency_operation_kind_check` suma `'delivery_note_sale'` (aditivo, `DROP`/`ADD`, desde el `CHECK` vivo). `operation_idempotency_operation_id_contract` no cambia: `operation_id` siempre viene poblado.
2. **Cuenta**, resuelta igual que `rpc_create_quote`: la del cliente, entre las del usuario (`client_not_found` P0404 si es ajeno o no existe; vivo). Es determinista aunque el usuario tenga varias membresías.
3. `_delivery_note_assert_role(v_account_id, 'issue')`: `is_account_writer` (P0401) y roles activos ∩ `{seller, stock, admin, owner}` (P0403 `insufficient_role`). Mismo predicado que `record_status_transition`, antes de escribir.
4. Sucursal obligatoria (`P0400 delivery_note_branch_required`), de la cuenta, activa (`P0404`) y no cerrada (`P0422 branch_closed`).
5. **`_delivery_note_lock_products(v_account_id, <productos del payload>)`**: `SELECT … FROM products WHERE id = ANY(…) AND account_id = v_account_id ORDER BY id FOR UPDATE`, en orden ascendente de `id`. Es el único helper de lock de productos del remito y lo reutilizan la emisión, la edición y la anulación (orden determinista entre remitos concurrentes). Va **antes** de validar: una baja del producto, o un producto que pasa a ser padre, entre el chequeo y el lock no puede colarse (regla TOCTOU de `units-of-measure`; es la misma corrección que la tanda B de presupuestos hizo en `20261068000001`). Un id inexistente o ajeno simplemente no se bloquea, y la validación del paso siguiente lo rechaza.
6. `_delivery_note_validate_items(v_account_id, p_items, NULL)` sobre las filas **ya bloqueadas** → líneas normalizadas y total del servidor. Valida, por línea:
   - `product_id` obligatorio;
   - producto **vivo, de la cuenta, no padre** (por el helper compartido de D12);
   - unidad del sistema o de la cuenta;
   - `quantity > 0`, `price ≥ 0`, `subtotal ≥ 0`;
   - tope de 500 líneas.

   Devuelve, por línea, `quantity_base := _uom_normalize_quantity(product_id, unit_id, quantity)` (calculado con el lock puesto) y, agrupado, el conjunto de pares requeridos `(product_id, branch_id, required)`. El tercer parámetro es el retenido por producto que trae la edición (D5); en la emisión es `NULL`.
7. `INSERT delivery_notes` (`id = v_dn_id`, `status='issued'`, `issued_on = reporting_local_today()`). El disparador numera y registra `NULL → issued` con `'delivery_note_sale'`, validando el rol.
8. `INSERT delivery_note_items` con snapshots (`_delivery_note_insert_items`, molde de `_quote_insert_items`, filtrado por cuenta) y con el `quantity_base` del paso 6 escrito en el mismo `INSERT`. La columna nunca queda nula.
9. **`_delivery_note_apply_stock(v_account_id, v_dn_id, v_op_group, v_pairs)`**, el único lugar donde el remito descuenta stock. **No lee las líneas**: recibe explícitamente el conjunto de pares a aplicar, un `jsonb` de `{product_id, branch_id, required, unit_cost}`. La emisión le pasa **todos** los pares; la edición, **sólo** los pares que cambian (D5). Por cada par:
   - disponible = `branch_stock.quantity` (0 si no hay fila). Si disponible < requerido → `RAISE 'stock_insuficiente para producto %: disponible %, solicitado %' USING ERRCODE = 'P0409'`, el **mismo literal** que el núcleo, que la UI ya traduce, con su acción "transferir stock". El `RAISE` revierte todo: remito, líneas, número e idempotencia.
   - `c21_apply_branch_stock_delta(account, product, branch, -requerido)`.
   - `INSERT stock_movements`:
     - `type='sale'`, `reference_type='delivery_note'`, `reference_id = delivery_note.id`;
     - `quantity_delta = -requerido`, `quantity_before/after`, `branch_id`, `product_name`, `performed_by`;
     - `operation_group_id = v_op_group` (uno por transacción);
     - `unit_cost_snapshot` = el del par (el `unit_cost_snapshot` de las líneas del producto, congelado en el paso 8; es el mismo para todas las líneas de un producto, D6);
     - `metadata = {delivery_note_item_ids: [...]}`.
10. `UPDATE delivery_notes SET total`.
11. Devuelve `_delivery_note_payload(id)` con `replayed = false`: cabecera, líneas, número formateable, nombre del cliente y de la sucursal, `converted_sales_order_id`/`operation_id` (NULL en A) y el historial.

**Contrato de los helpers de stock** (una sola definición de cada cosa):
- **`_delivery_note_held_pairs(p_dn_id) → jsonb`**: la **única** definición de lo retenido. Lee las líneas **vigentes** del remito y devuelve, por producto, `{product_id, branch_id = dn.branch_id, held = Σ quantity_base, unit_cost}`. La usan la edición y la anulación.
- **`_delivery_note_apply_stock(account, dn, op_group, pairs)`**: gate + delta negativo + movimiento `sale`/`delivery_note`, sólo sobre los pares recibidos.
- **`_delivery_note_reverse_held(account, dn, op_group, pairs, p_reference_type, p_reverses)`**: delta positivo + movimiento `sale_return` con `reference_type` = `'delivery_note_update'` (edición) o `'delivery_note_reversal'` (anulación), sólo sobre los pares recibidos. La anulación le pasa **todos** los pares de `_delivery_note_held_pairs`; la edición, **sólo** los que cambian.
- Ninguno de los tres lee `stock_movements`.

**Interbloqueo con una venta concurrente.** El remito lockea productos en orden de `id`; el núcleo de venta, en el orden de `sales_order_items.id`. Una venta y un remito sobre dos productos en común pueden interbloquearse (`40P01`), el mismo riesgo que ya existe hoy entre dos ventas. **No hay reintento automático**: hoy ningún código del backend ni del frontend reintenta un `40P01`, y el usuario recibe un error. Se acota así:
- la conversión de un remito **no** lockea productos (D7), así que no compite con el remito;
- el service de remitos mapea `asyncpg.DeadlockDetectedError` a un `409` RFC 7807 `concurrent_update_retry` ("Otra operación tocó los mismos productos al mismo tiempo. Volvé a intentarlo"): como la transacción revirtió entera y la emisión es idempotente, reintentar con la misma clave es seguro;
- el riesgo residual queda declarado en Riesgos, no como "cubierto".

Puntos de diseño:

- **Lo retenido sale de las líneas, no del ledger.** El stock que un remito retiene en cada par es `held(product, branch) = Σ quantity_base` de sus líneas **vigentes** con ese producto, en la sucursal **vigente** del remito (0 en cualquier otra sucursal). La edición y la anulación revierten por ese valor, que calcula sólo `_delivery_note_held_pairs`.
  - *Por qué no el ledger*: en prod, `stock_movements` acepta `INSERT` por PostgREST de cualquier miembro de la cuenta (§Context). Si lo retenido fuera `-Σ quantity_delta` de los movimientos con `reference_id` = remito, un miembro sin permiso de escritura podría insertar una fila `reference_type='delivery_note'` de `-1000` contra un remito pendiente (su id es legible), y la anulación o la edición, desde una función definer, devolvería `+1000` a `branch_stock`: stock fantasma.
  - **No es una superficie nueva, pero este change no la agranda.** Hoy una fila forjada **ya** se convierte en stock por un camino preexistente: `rpc_reverse_stock_movement` es pública para `authenticated`, sin `is_account_writer` ni rol, y devuelve a `branch_stock` lo que diga el ledger para una referencia `sale`/`purchase`; y `rpc_apply_product_stock_delta` deja a cualquier miembro mover stock directo (§Context). Cerrarlas es un candidato aparte (tarea 9.1). Lo que este change promete es **no sumar un segundo amplificador**: ninguna función del remito calcula lo que devuelve desde el ledger, y `rpc_reverse_stock_movement` no alcanza a los movimientos `delivery_note*` (sólo admite `sale`/`purchase`).
  - `delivery_note_items` no tiene políticas de escritura, y `quantity_base` es estable mientras el remito exista (D1). Es una fuente que sólo escriben las RPCs del remito.
  - Es la misma idea que la regla vigente de `inventory-single-ledger` ("la reversa no reconvierte las líneas"): se revierte lo que **efectivamente se descontó** (`quantity_base`, ya normalizado al emitir o editar), nunca una reconversión.
  - El ledger queda como **auditoría**: el gate verifica el invariante `Σ quantity_delta` de los movimientos del remito por par `= -held` (y `= 0` tras anular), y que una fila forjada por PostgREST no cambia lo que devuelve la anulación. En runtime no se compara contra el ledger: una fila forjada no tiene que poder bloquear una anulación legítima.
- **Por qué movimientos por par y no por línea.** El remito se edita (R4), y una línea editada cambia de id (reemplazo completo, D5). Con `reference_id` = id del remito y un movimiento por par, el kardex del remito se lee por producto sin depender de ids de línea que la edición reemplaza. La venta escribe un movimiento por línea porque su `reference_id` es la fila de `sales`, que el remito no tiene. Las dos líneas del mismo producto quedan trazables en `metadata.delivery_note_item_ids`.
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
5. Cabecera: cliente vivo de la cuenta; sucursal **nueva** de la cuenta, activa y no cerrada. La sucursal **vigente** del remito también tiene que estar activa y no cerrada (`P0422 delivery_note_branch_inactive`), porque la pata de reversa escribe en ella; el guard de baja (D10) ya lo impide, pero la edición no delega en él. Reemplazo completo: `p_delivery_address`/`p_notes` NULL significan vacío, y la UI manda siempre el valor vigente.
6. **Lock de productos** con `_delivery_note_lock_products` (D4): la unión de los productos de las líneas vigentes y de las nuevas, en orden de `id`, **antes** de validar.
7. **Retenido**: `v_held := _delivery_note_held_pairs(dn.id)`, calculado sobre las líneas **vigentes**, antes de tocarlas: `held(product, dn.branch_id) = Σ quantity_base`; 0 en cualquier otra sucursal.
8. **Validación y requerido nuevo**: `_delivery_note_validate_items(v_account_id, p_items, v_held)` sobre las filas ya bloqueadas. Normaliza cada línea con `_uom_normalize_quantity` (con el lock puesto) y agrupa el requerido por `(product_id, p_branch_id)`. Por línea:
   - un producto que **no** estaba en el remito se valida como en el alta (vivo, de la cuenta, no padre, `_assert_document_product`);
   - un producto que **ya** estaba en el remito y hoy está dado de baja (`deleted_at IS NOT NULL`) **se acepta sin revalidar el catálogo vivo** (sigue siendo de la cuenta), acarreando su snapshot (D6), siempre que su cantidad base requerida **total** (sumando sus líneas nuevas) no supere su retenido **total** (sumando sus pares, sea cual sea la sucursal). La comparación es por producto y **no** por par: cambiar la sucursal de un remito con un producto dado de baja, conservando la cantidad, se acepta y traslada su stock (el gate de faltante de la sucursal nueva se aplica igual, paso 10). Conservarla o reducirla funciona; aumentarla da `P0400 delivery_note_product_unavailable`. Es la consecuencia de OQ-RV3: la mercadería ya se entregó, y obligar a quitar la línea devolvería al depósito stock que está en manos del cliente. La comparación usa la cantidad **normalizada**, por eso vive acá y no antes del lock.
9. **Pares que cambian**: los de la unión de retenido y requerido cuyo retenido difiere del requerido (incluye el caso de cambiar la sucursal: todos los pares de la vieja retienen > 0 y los de la nueva requieren > 0). Los pares con retenido igual al requerido **no escriben nada**: una edición de precio, cliente o notas no ensucia el kardex, y un producto que no cambia no recibe movimientos aunque otro producto del remito sí cambie.
10. Sobre los pares que cambian, en este orden:
    - **patas de reversa**: `_delivery_note_reverse_held(…, <pares que cambian con retenido > 0>, 'delivery_note_update', 'delivery_note_edit')`: `c21_apply_branch_stock_delta(+retenido)` + movimiento `type='sale_return'`, `reference_type='delivery_note_update'`, `quantity_delta = +retenido`, `unit_cost_snapshot` = el de las líneas vigentes de ese producto, `metadata.reverses = 'delivery_note_edit'`;
    - **patas de aplicación**: `_delivery_note_apply_stock(…, <pares que cambian con requerido > 0>)`: gate `branch_stock (ya con la reversa aplicada) >= requerido`, si no `P0409 stock_insuficiente…`; luego `c21_apply_branch_stock_delta(-requerido)` + movimiento `type='sale'`, `reference_type='delivery_note'`, `quantity_delta = -requerido`, con el costo de D6.
11. `DELETE delivery_note_items` + `INSERT` de las líneas nuevas con snapshots (D6) y su `quantity_base` (el mismo valor normalizado del paso 8). `UPDATE delivery_notes SET client_id, branch_id, delivery_address, notes, total, updated_at, updated_by, revision = revision + 1`.

- **Por qué espejo y no un único movimiento neto**: es la regla vigente de `inventory-single-ledger` para la edición de operaciones (el kardex se lee como la secuencia real de hechos). Se aplica igual, sólo que restringida a los pares que cambian. La venta reversa y aplica todas sus líneas porque sus ids de fila cambian; el remito no tiene esa restricción.
- **Control de faltante sobre el neto**: la reversa se aplica antes del gate. Reducir una cantidad siempre funciona aunque la sucursal esté en 0, y aumentarla exige sólo la diferencia.
- *Rechazado* (recomendación original del explore, anulada por R4): no editar, sino anular y rehacer.
- *Rechazado*: un `PATCH` por línea. El form edita el carrito completo, igual que el presupuesto.

### D6 — Snapshots en la edición: política canónica de operaciones (acarreo por producto)

A diferencia del presupuesto (D5 de `presupuestos-modulo`, que re-toma todo), el remito ya movió mercadería: es una operación, no una cotización. Se aplica la política canónica de `document-snapshots`:
- la línea cuyo `product_id` ya estaba en el remito **acarrea** `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot` e `iva_rate_snapshot` de la línea vieja (emparejando por `product_id`; ante varias, la de menor `line_no`), las cuatro columnas que la política canónica exige conservar (`openspec/specs/document-snapshots/spec.md:45`);
- la línea con un producto nuevo las congela desde el maestro vigente filtrado por cuenta.

Consecuencia: todas las líneas vigentes de un mismo producto tienen el mismo `unit_cost_snapshot`, que es el que usan los movimientos por par (D4, D5, anulación).

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
   - **Sucursal del remito activa y no cerrada**: si no, `P0422 branch_closed`. El núcleo sólo rechaza `status = 'closed'`, no `is_active = false` (`20261062000001:1334-1344`). El guard de baja (D10) ya impide dar de baja una sucursal con remitos pendientes, pero la conversión no delega en él (un guard que delega no es guard): un camino futuro o una fixture que lo evada no convierte en una sucursal desactivada.
   - **Productos dados de baja después de emitir: se convierten** (OQ-RV3). La mercadería ya se entregó: la venta registra un hecho consumado y el nombre viaja en el snapshot. Por la misma razón no se revalida "padre con variantes".
6. `INSERT sales_orders` (`status='draft'`, `account_id`, `branch_id = dn.branch_id`, `client_id = dn.client_id`, `source_delivery_note_id = dn.id`, `total = dn.total`) con historial `NULL → draft`, y `INSERT sales_order_items` copiando del remito `product_id, unit_id, quantity, price, subtotal` y los cuatro snapshots, **sin re-leer el maestro**.
7. `v_sale := _c29_confirm_order_core(p_idempotency_key, v_order, NULL, p_cash_session_id, NULL, NULL, p_canal, p_payment_method_id, p_bank_account_id)`. Si `v_sale.replayed` → `RAISE 'idempotency_key_conflict' P0409` (la misma clave usada en paralelo sobre otro documento; ver D6 de presupuestos).
8. `record_status_transition(account, 'delivery_note_sale', id, 'issued', 'converted', uid, NULL)` + `UPDATE delivery_notes SET status = 'converted'`. **No** incrementa `revision`: no cambia el contenido.
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
  - **se saltean** el `SELECT … FROM products … FOR UPDATE`, la normalización, el gate de stock, `c21_apply_branch_stock_delta` y el `INSERT stock_movements`. Sin stock que proteger, el lock del producto no aporta nada y sólo agregaría superficie de interbloqueo contra emisiones y ediciones de otros remitos (D4). La existencia del producto la garantiza la FK de `delivery_note_items.product_id` (sin borrado físico posible mientras haya líneas);
  - se conservan la fila legacy `sales` y `sale_items`, pero `sale_items` toma **los cuatro snapshots de la línea de la orden** (`v_item.name_snapshot`, `sku_snapshot`, `unit_cost_snapshot`, `iva_rate_snapshot`, copiados del remito en el paso 6) en lugar de `v_product.*` (`20261062000001:1388-1391`, `:1441-1448`; la fila `sales` no lleva nombre ni costo, así que no cambia). Así un producto renombrado entre la emisión y la conversión conserva el nombre del remito, y el costo es el congelado del remito (OQ-RV4).
- Caja, cuenta corriente, banco, fiscal, outbox, historial y `UPDATE` de la orden: **sin cambios**.

Por qué así:

- **La decisión la toma la columna persistida de la orden, nunca un parámetro.** La firma del núcleo no cambia: no hay `p_skip_stock` que un caller pueda pasar. `sales_orders` no tiene políticas de escritura para `authenticated`, y las RPCs definer que crean órdenes hoy (`rpc_quick_sale`, `_quote_accept_core`, la promoción legacy) no conocen la columna. Igual, la revalidación del remito y de las líneas es **autosuficiente** (lección de `tenancy-guard-caja-outbox`: un guard que delega no es guard): una orden fabricada en el futuro con un `source_delivery_note_id` válido, pero con líneas o cliente distintos, o apuntando a un remito ya convertido o anulado, rebota con `P0409` en lugar de regalar mercadería.
- **Una orden sin origen sigue exactamente igual**: el gate exige el diff contra el cuerpo vivo y que `rpc_quick_sale` siga descontando.
- *Rechazado*: un núcleo paralelo `_c29_confirm_order_core_no_stock`. Duplicaría caja, cuenta corriente, banco, fiscal y outbox, que son exactamente lo que no tiene que divergir.
- *Rechazado*: crear la venta con `rpc_create_sale_operation_v2`. Pierde la orden (no sería facturable con `/emit-invoice` sin promoción) y es el camino que el PR #607 está reescribiendo.

**Orden de locks**: `delivery_notes` (FOR UPDATE) → inserciones de `sales_orders`/`sales` (en modo remito, el núcleo no lockea `products`). La conversión **crea** filas de venta y no bloquea filas existentes de `sales`, así que tomar el remito primero no invierte el orden global `sales → sales_orders → fiscal_documents`. El borrado de la venta (D9) toma el remito **al final** (`sales → sales_orders → fiscal_documents → delivery_notes`). No hay ciclo: la conversión nunca espera un lock de `sales`, y ante un remito `converted` falla de inmediato con `delivery_note_invalid_state`. Se documenta junto a la regla global en `CHANGES.md`; `CLAUDE.md` no se toca en este change.

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
- **Sucursal del remito viva, antes de cualquier efecto.** Si la orden tiene `source_delivery_note_id`, inmediatamente después de los locks de `sales`/`sales_orders` y **antes** del guard fiscal y de cualquier compensación, se lee la sucursal del remito (`= sales_orders.branch_id`) con `FOR SHARE` (una desactivación concurrente espera al commit). Si está desactivada o cerrada → `RAISE 'delivery_note_branch_inactive: la sucursal del remito R-… está desactivada o cerrada — reactivala antes de eliminar la venta' USING ERRCODE = 'P0422'`, sin ningún efecto.
  - Por qué: el guard de baja (D10) no cuenta los remitos `converted`, así que una sucursal se puede vaciar y desactivar con un remito convertido. Sin este guard, borrar la venta devolvería el remito a `issued` en una sucursal muerta: la conversión rechazaría (`branch_closed`) y la anulación devolvería stock a una sucursal que no opera, el incidente del 22-08 que D10 evita.
  - `rpc_cancel_delivery_note` y `rpc_update_delivery_note` repiten el chequeo sobre la sucursal vigente del remito (D5, D16) de forma autosuficiente: un remito `issued` en una sucursal inactiva que llegue por otro camino (fixture, camino futuro) no repone stock en ella. Se destraba reactivando la sucursal.
- Después de cancelar la orden: `SELECT … FROM delivery_notes WHERE id = v_source_dn FOR UPDATE`, `record_status_transition(…, 'delivery_note_sale', …, 'converted', 'issued', v_uid, 'Venta eliminada (operación …)')` y `UPDATE status = 'issued'`. El índice único parcial de D1 queda libre (la orden pasó a `canceled`), así que el remito se puede volver a convertir.
- El **diálogo de borrado** suma la línea: "El stock no vuelve: la mercadería quedó entregada con el remito R-…, que vuelve a quedar pendiente. Para devolverla al stock, anulá el remito." El read model expone `source_delivery_note_id`/`source_delivery_note_number` (D13).

**Edición** (`rpc_atomic_update_sale_operation`, desde el cuerpo vivo):
- Inmediatamente después del lock de las filas `sales` y del guard de cliente, y **antes** de la anulación fiscal y de cualquier reversa, si alguna orden de la operación tiene `source_delivery_note_id` → `RAISE 'delivery_note_sale_locked: la venta nació del remito R-…: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo' USING ERRCODE = 'P0423'`.
- Va antes del bloque fiscal para no anular un comprobante pendiente por una edición que igual se rechaza.
- Bloquea la operación **entera**, también la cabecera. El editor de ventas no tiene un camino de "sólo cabecera": siempre reemplaza líneas (REVERSE+APPLY). Sin el guard, la REVERSE **repondría** la cantidad de cada línea por su fallback a `_uom_normalize_quantity` (las filas `sales` no tienen movimiento propio, §Context) y la APPLY la descontaría de nuevo. Cualquier reducción dejaría stock repuesto de más, y la anulación posterior del remito lo devolvería otra vez (doble reposición). El gate asserta que, ante el `P0423`, `branch_stock` y `stock_movements` (`sale_update`/`sale`) del par quedan sin cambios.
- En la UI, "Editar" queda deshabilitado con ese motivo.

**Anular un remito convertido**: `P0423 delivery_note_locked_converted` (primero se borra la venta).

**Remito convertido cuya venta ya tiene comprobante autorizado**: la venta es inmutable e imborrable (regla de comprobante fiscal emitido, `P0423`), así que el remito queda **cerrado**: no se puede reabrir, anular ni devolver su stock por este camino. La devolución de mercadería facturada es una nota de crédito con reingreso de stock, fuera del alcance de v1 (candidato, tarea 9.1). La UI del remito convertido lo dice cuando la venta tiene comprobante autorizado: "La venta ya está facturada: para devolver mercadería se necesita una nota de crédito".

### D10 — Baja de sucursal: el remito pendiente es contenido operativo

La cuarta condición entra en las **dos** funciones donde vive el predicado (§Context), nunca en el disparador:

- **`_branch_blocking_content(uuid)` no se toca.** Cambiarle el `RETURNS TABLE` obligaría a `DROP`+`CREATE`, y la cadena de reaplicación de `KPI_Validation.yml` vuelve a aplicar `20261014000001` sin tolerancia (`:512`, `ON_ERROR_STOP=1` + `set -e`): su `CREATE OR REPLACE` con el `RETURNS TABLE` de 5 columnas fallaría con `42P13 cannot change return type` y pondría `validate-kpis` en rojo (el mismo choque que el workflow ya tuvo que tolerar a mano para `get_dashboard_critical_stock_items`, `:750`). Con la firma intacta, el reapply no choca.
- **`_branch_pending_delivery_notes(p_branch_id uuid) RETURNS bigint`** (nueva, interna, `STABLE`, `REVOKE ALL … FROM PUBLIC, anon, authenticated`): la **única** definición del predicado "remito pendiente en la sucursal" = `count(*)` de `delivery_notes` con `branch_id` = la sucursal y `status = 'issued'`, **sin filtrar `direction`**. Un remito de compra pendiente (`remitos-compra`) tiene el mismo problema de stock en una sucursal muerta, así que el contador ya nace agnóstico del sentido y `remitos-compra` no tiene que reescribir el guard de sucursal.
- **`_branch_assert_empty(uuid)`** (orden y `RAISE`) se reescribe con `CREATE OR REPLACE` (misma firma) desde el cuerpo vivo y suma un cuarto `IF`, **después** de transferencias, con token propio y mensaje neutro respecto del sentido: `RAISE 'branch_has_pending_delivery_notes: la sucursal tiene % remito(s) pendiente(s) — convertilos o anulalos antes de darla de baja' USING ERRCODE = 'P0428'`.
- `fn_guard_branch_decommission`, `rpc_deactivate_branch` y `rpc_close_branch` **no se tocan**: los tres ya delegan en `_branch_assert_empty`, así que el disparador y los dos comandos rechazan con el mismo motivo.
- La introspección de `20261014000001` cuenta 7 definiciones por **lista de nombres** (`:852-857`), así que la función nueva no la altera. El bloque `DO` de este change verifica una sola definición de `_branch_assert_empty` y de `_branch_pending_delivery_notes`, que el cuerpo de `_branch_assert_empty` contiene el token nuevo y llama a `_branch_pending_delivery_notes`, que la firma y el `RETURNS TABLE` de `_branch_blocking_content` no cambiaron, y que el disparador sigue apuntando a `fn_guard_branch_decommission`. `frontend/lib/database.types.ts` no cambia.
- **Reaplicación en CI**: el reapply de `20261014000001` vuelve a dejar `_branch_assert_empty` con el cuerpo de 3 tokens, y los de `20261062000001`/`20261067000001` hacen lo mismo con `fn_product_base_unit_guard`, `fn_uom_in_use_guard` y `_quote_validate_items`. Por eso la migración de este change entra en la cadena **después** de esos tres eslabones, y el paso asserta, después de reconverger, que `_branch_assert_empty` contiene `branch_has_pending_delivery_notes`, que los dos guards de unidad nombran `delivery_note_items` y que `_quote_validate_items` llama a `_assert_document_product` (D16, tarea 1.13).
- **Frontend**: `use-branches.ts::translateRpcError` suma el token ("La sucursal tiene remitos pendientes. Convertilos o anulalos antes de darla de baja."), con su caso de test. `DeactivateBranchDialog` (que hoy sólo pre-chequea existencias y dice "La sucursal está vacía…") consulta además los remitos pendientes de la sucursal (`GET /delivery-notes?status=issued&branch_id=…&page_size=1`, **sin** filtro de `direction`, que trae `total`) y, si hay, no ofrece "Desactivar": muestra el aviso con el enlace "Ver remitos pendientes" (`/remitos?estado=pendientes&sucursal=<id>`, contrato de D11). Por eso el listado suma el filtro `branch_id` (D11, D13).

Por qué:
- Con la sucursal **desactivada**, el remito queda en una sucursal que desaparece de los selectores y de la resolución de la sucursal por defecto; con la sucursal **cerrada**, la conversión rechaza (`branch_closed`, en el núcleo y en la propia conversión, D7). En los dos casos, anular el remito devolvería stock a una sucursal que no opera, que es el incidente del 22-08 al revés.
- El remito `converted` no bloquea (su vida en la sucursal terminó). Si después se borra su venta, el remito volvería a `issued` en esa sucursal: por eso el borrado exige la sucursal viva (D9). El gate `test_sucursal_guard_vaciado.sql` se re-ejecuta sin cambios (los tres tokens previos no se mueven) y el caso nuevo vive en `test_remitos_venta.sql`.

### D11 — UI

- **Sidebar**: `{ title: "Remitos", href: "/remitos", icon: PackageCheck }` en *Operaciones*, después de "Presupuestos". Sin gate de plan. `Truck` ya lo usa "Proveedores". Breadcrumb: `/remitos` "Remitos", `/remitos/nuevo` "Nuevo remito", `/remitos/<id>` "Detalle de remito", `/remitos/<id>/editar` "Editar remito", con el mismo mecanismo que presupuestos.
- **Pestañas De venta / De compra: ausentes en este change** (OQ-RV6). Una pestaña deshabilitada "Próximamente" anuncia una función sin fecha y ocupa espacio en móvil. El listado ya filtra por `direction` en la API, así que `remitos-compra` agrega la pestaña sin cambiar el contrato.
- **`/remitos`** (listado):
  - `GET /delivery-notes?direction=sale&status=&q=&client_id=&branch_id=&page=&page_size=`, paginado `{items,total,page,pages}` (`branch_id` lo usa el diálogo de baja de sucursal, D10; `direction` es opcional y, sin él, trae los dos sentidos);
  - **contrato único de query params de la página** (en castellano, como el `?cliente=` que ya usa `/presupuestos/nuevo`): `?estado=todos|pendientes|convertidos|anulados`, `?sucursal=<id>` y `?cliente=<id>`, combinables. La página los lee de la URL: `estado` preselecciona la pestaña, y `sucursal`/`cliente` aplican el filtro y se muestran como chips removibles. Los únicos enlaces que llegan filtrados usan este contrato: el de `DeactivateBranchDialog` (`?estado=pendientes&sucursal=<id>`) y el "Ver remitos" de `ClientDetailHeader` (`?cliente=<id>`);
  - pestañas de estado: Todos, Pendientes, Convertidos, Anulados;
  - búsqueda por cliente o número;
  - columnas: número, cliente, fecha, sucursal, cantidad de ítems, total y estado (`DeliveryNoteStatusBadge`, tokens semánticos). En móvil, tarjetas;
  - encabezado con el resumen "N remitos pendientes por $ X" (OQ-RV12);
  - CTA "Nuevo remito" con `CAN_DELIVER_SALE` y estado vacío con explicación ("El remito descuenta stock al emitirse y se convierte en venta cuando cobrás").
- **`/remitos/nuevo`** (`?cliente=<id>`) y **`/remitos/[id]/editar`**: `DeliveryNoteForm`.
  - Se compone de las piezas que usa `QuoteForm`: `StagedProductLine` (que encapsula `ProductPicker`), `CartItemList`, `ScrollableCartShell`, `BarcodeScannerInput` + `resolveScan`, unidades y `lib/cart-utils` con **`enforceStock: true`**. Sin "Agregar concepto".
  - **Sucursal obligatoria, visible en todos los planes.** `BranchSelect` no sirve tal cual: devuelve `null` en 3 de los 4 planes y ofrece "Sin sucursal" (§Context). Se le suman dos props aditivas, `required` (sin la opción "Sin sucursal") y `alwaysVisible` (se muestra aunque el plan no tenga módulo de sucursales), con default retrocompatible para los usos actuales. Precarga en el cliente: `lib/default-branch.ts` si el PR #607 ya está en `main`; si no, la sucursal activa y no cerrada más antigua de `useBranches()` (`createdAt` ascendente), el mismo criterio que `c26_default_branch` en el servidor (`20260625000001:143-144`). Con una sola sucursal activa, se muestra como texto ("Sale de: Sucursal Centro"), sin selector. Mientras no haya sucursal elegida, no se pueden agregar líneas.
  - **Disponible por sucursal, en la capa canónica** (decisión, no checkpoint): `CartStockOptions` de `lib/cart-utils.ts` suma una opción `availableFor?: (productId: string) => number`. Cuando está presente, `addManualLineToCart`, `applyScanToCart` y el control de cantidad la usan **en lugar de** `product.stock`. El formulario de venta y el presupuesto no la pasan y siguen igual. El remito la arma con `useBranchStock(branchId)` + lo retenido (abajo). **Prohibido usar el agregado `product.stock`** para el remito: con stock en otra sucursal, dejaría pasar lo que el servidor rechaza.
  - **Una sola contabilidad en la edición.** `exceedsStock` hoy excluye las líneas `source: "persisted"` porque en la venta su cantidad "ya salió de `product.stock`"; mezclar eso con un disponible que suma lo retenido contaría lo retenido dos veces (3 retenidas, sucursal en 0, una línea nueva de 2 pasaría en el cliente y el servidor la rechazaría). Por eso:
    - las líneas rehidratadas del remito **no** llevan `source: "persisted"`: entran como líneas comunes con su `quantityBase`, y **todas** las líneas cuentan contra el disponible;
    - disponible del producto = `branch_stock(sucursal elegida) + retenido(producto, sucursal elegida)`, con retenido = `Σ quantity_base` de las líneas guardadas del remito si la sucursal elegida es la guardada, y 0 si no (el mismo criterio que el servidor, D5);
    - al cambiar de sucursal, todas las líneas se re-validan contra la nueva y se marcan las que no alcanzan, sin borrarlas;
    - el input de cantidad del carrito no puede superar el disponible: `CartItemList` recibe `maxQtyMap` (la prop ya existe, `cart-item-list.tsx:49`), y `onUpdateQty` re-valida.
  - **Rechazo accionable en el cliente**: muestra el disponible **de la sucursal elegida** y el enlace "Transferir stock" (`/stock?product=<id>`), con el mismo texto que el `P0409` del servidor.
  - **Avisos de stock** (la diferencia central con el presupuesto):
    - junto al botón Emitir: "Al emitir, se descuenta del stock de {sucursal}.";
    - en la edición, antes de guardar, un resumen del ajuste por producto y sucursal ("Vuelven 2 × A a Centro · Salen 4 × A de Centro"), calculado en el cliente con el retenido de las líneas guardadas; si no cambia nada de stock, "Este cambio no mueve stock";
    - en `ConvertDeliveryNoteDialog`, una línea fija: "El stock ya se descontó al emitir el remito R-…: esta venta no lo vuelve a descontar."
  - Cliente: `SearchableSelect` + "Nuevo cliente" en el lugar, el mismo patrón que `QuoteForm`.
  - **Cliente dado de baja después de emitir** (en la edición): el selector lista sólo clientes vivos (RN-B1), así que no puede preseleccionarlo. El formulario muestra el cliente congelado del remito (nombre, de solo lectura) con el aviso "Cliente dado de baja — elegí uno vigente para guardar" y no deja guardar hasta que se elija otro (el servidor lo rechazaría con `client_not_found`). En el detalle, "Venta" queda deshabilitado con el motivo "El cliente fue dado de baja: editá el remito y elegí uno vigente" (la conversión daría `delivery_note_client_unavailable`, D7). `client_not_found` en contexto remito se traduce con ese mismo texto.
  - Domicilio de entrega, precargado con el domicilio principal del cliente y editable, y notas. El dato sale de un hook nuevo en la capa canónica, `hooks/data/use-client-addresses.ts` (`GET /clients/{id}/addresses`, que el backend ya expone): hoy no existe ningún hook ni cliente API de direcciones (§Context).
  - Avisos accionables de `P0409 stock_insuficiente`, con la acción "Transferir stock" que ya existe.
  - La edición manda la `revision`; ante `delivery_note_changed`, ofrece recargar.
  - **Producto dado de baja después de emitir** (D5): la línea se muestra "Producto dado de baja — se conserva lo entregado", **no** bloquea el guardado y no admite aumentar la cantidad. Si el usuario la quita, el diálogo de confirmación avisa: "Quitarla devuelve N × {producto} al stock de {sucursal}."
  - **Estados de página** (`/remitos/nuevo`, `/remitos/[id]` y `/remitos/[id]/editar`): sin permiso (`CAN_DELIVER_SALE` para alta y edición), cargando, error o no encontrado, y no editable (convertido: "Para corregirlo, eliminá la venta: el remito vuelve a quedar pendiente", con enlace a la venta; anulado: el motivo). `QuotePageStates` se generaliza a `components/shared/DocumentPageStates.tsx` con textos parametrizados por documento, y `QuotePageStates` pasa a usarlo sin cambiar lo que muestra (su test sigue verde).
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
  - la línea fija "El stock ya se descontó al emitir el remito R-…: esta venta no lo vuelve a descontar.";
  - **sucursal fija** (la del remito; `SaleCheckoutFields` gana la prop aditiva `branchReadOnly`, que muestra el **nombre** de la sucursal aunque el plan no tenga módulo de sucursales);
  - forma de pago, cuenta bancaria y caja con la semántica del POS, que vive en **`useSaleCheckout({ paymentMethodId, branchId, clientId })`** (tanda B de presupuestos, el mismo hook que consume `ConvertQuoteDialog`), con `branchId = dn.branch_id`: con efectivo, la sesión abierta de esa sucursal es obligatoria y, si falta, "Venta" se deshabilita con un enlace a `/caja`;
  - saldo del cliente si es a crédito;
  - `useIdempotencyKey("delivery-note-convert:" + id)`, que se resetea en cada éxito;
  - éxito con `SaleCheckoutSuccess` (Facturar y Ver venta);
  - ante `delivery_note_changed`, recarga sin cerrar.
- **`DocumentShareMenu`** + switch "Mostrar precios" (default apagado, R2):
  - el switch es un **control hermano**, fuera del desplegable, con su `Label` asociado. No va dentro del menú: `DocumentShareMenu` precarga el blob una sola vez al abrirse (`DocumentShareMenu.tsx:93-108`, `:126`) y WhatsApp/Descargar usan ese blob, así que cambiar el switch con el menú abierto compartiría la variante anterior;
  - `fetchPdf(disposition)` cierra sobre el estado del switch, y `DocumentShareMenu` se monta con `key={showPrices}`, de modo que cambiar el switch descarta la precarga;
  - el archivo con precios se llama `remito-R-00000012-con-precios.pdf` para no confundir las dos variantes;
  - test: "cambiar el switch y enviar comparte la variante elegida". `buildDeliveryNoteShareText` (`lib/delivery-note-share.ts`): "Hola {nombre}, te envío el remito R-00000012 de la mercadería entregada el 02/10/2026. {negocio}". `onShared` no cambia el estado: el remito no tiene "enviado".
- **Ficha del cliente**: botón "Nuevo remito" en `ClientDetailHeader` → `/remitos/nuevo?cliente=<id>`, y enlace "Ver remitos" → `/remitos?cliente=<id>` (contrato de query params de arriba). Sin pestaña nueva (OQ-RV10).
- **`/ventas`** (listado y detalle): badge "Desde remito R-…" con enlace. `SourceQuoteBadge` (tanda B de presupuestos) es específico del presupuesto, así que se generaliza a **`components/ventas/SourceDocumentBadge.tsx`** (`kind`, número formateado y `href`), y los dos orígenes lo usan; nada de un `SourceDeliveryNoteBadge` gemelo. "Editar" deshabilitado con el motivo de D9. El diálogo de borrado suma la línea de D9.
  - **Invalidación**: borrar una venta nacida de un remito devuelve el remito a `issued` (R5). `deleteSaleMutation`, `deleteSalesByOperationMutation` y el borrado de orden invalidan también `queryKeys.deliveryNotes.all()`, a través de una función compartida en `lib/query-invalidation.ts` (`invalidateAfterSaleDelete`), con test de hook. Sin esto, `/remitos` mostraría "Convertido" con "Ver venta" apuntando a una orden cancelada hasta recargar.
- **`/stock`** (panel de movimientos): con `reference_type` `delivery_note*`, la etiqueta pasa a "Remito R-…", "Edición de remito R-…" o "Anulación de remito R-…", con enlace al remito (`/remitos/<reference_id>`, que no depende del número). El ícono y el sentido siguen saliendo del `type`.
  - El panel lee `stock_movements` directo por supabase-js (§Context), así que el número se resuelve **en el panel**: después de cada página, una segunda consulta `delivery_notes.select("id, number, direction").in("id", refIds)` sobre los `reference_id` con `reference_type` `delivery_note*` (la RLS de `SELECT` de miembros ya la permite y la acota a la cuenta). El número se formatea **según `direction`** con la definición única de `lib/internal-document-number.ts` (D2), nunca con un prefijo `R` fijo, así que los remitos de compra se rotularán bien sin tocar el panel. Si la consulta falla, la fila dice "Remito" sin número, sin romper el panel. No hay endpoint de backend nuevo ni JOIN polimórfico.
  - **Un solo rótulo para la fila y para la exportación.** La exportación CSV del panel (`exportCsv`, `stock-movements-panel.tsx:175-181`, columna "Tipo" = `MOVEMENT_META[m.type].label`) hoy rotula por `type`, así que el kardex exportado diría "Venta" y "Devolución de venta". El rótulo (`type` + `reference_type` + número resuelto) se extrae a un helper del panel (`movementLabel`) que usan `MovementRow` y `exportCsv`.
  - El panel no usa React Query: se recarga al abrirse, así que ninguna mutación del remito tiene una clave de kardex que invalidar. Migrarlo a `useQuery` es un candidato aparte, ya anotado en su propio comentario (`:44-46`).
- **Errores**: `lib/operation-errors.ts` suma traducciones accionables para:
  - `delivery_note_not_found`, `delivery_note_changed`, `delivery_note_invalid_state`, `delivery_note_locked_converted`;
  - `delivery_note_client_unavailable`, `delivery_note_product_required`, `delivery_note_branch_required`;
  - `delivery_note_sale_locked`, `delivery_note_order_mismatch`, `delivery_note_cancel_reason_required`;
  - `delivery_note_product_unavailable`, `delivery_note_branch_inactive` y `concurrent_update_retry`.
  
  Reutiliza `stock_insuficiente`, `insufficient_role`, `cash_requires_session`, `idempotency_key_conflict` y `payment_method_required`. El texto de `stock_insuficiente` hoy dice "cambiá la sucursal de la venta" y "la sucursal de esta operación" (`operation-errors.ts:279-283`). `humanizeOperationError` suma un parámetro de contexto `documentLabel: "venta" | "remito"` (default `"venta"`, retrocompatible), con un caso de test para el remito.
  El token `branch_has_pending_delivery_notes` se traduce en `use-branches.ts` (D10), no acá.
- **Verificación visual**: además de las pantallas nuevas, las superficies existentes que el change modifica: la cabecera de la ficha del cliente a 375 px (`ClientDetailHeader` ya usa botones de sólo ícono en móvil: los dos nuevos llevan `aria-label` distintos y no desbordan), las filas de remito del panel de `/stock` y `DeactivateBranchDialog` con remitos pendientes, en los dos temas.
- **Design system**: tokens semánticos, `cva`, `ResponsiveModal`. Verificación en desktop y 375 px × claro y oscuro.

### D12 — Reutilización en SQL: guard de producto compartido

El predicado "producto vivo, de la cuenta y no padre con variantes ni `variant_only`" vive hoy embebido en `_quote_validate_items` (`20261067000001:439-450`), y el remito lo necesita idéntico. Se extrae a `_assert_document_product(p_account_id uuid, p_product_id uuid) RETURNS public.products`: interno, `STABLE`, sin `EXECUTE` para roles de aplicación, mismos literales (`product_not_found` P0404, `product_is_parent` P0400).

- `_quote_validate_items` se reescribe **desde su cuerpo vivo** para llamarlo, sin otro cambio. `test_presupuestos_modulo.sql` es el safety net y tiene que seguir verde sin tocarlo.
- `_delivery_note_validate_items` lo llama también.
- *Rechazado*: copiar el predicado. Es la regla del proyecto, "reutilización antes que repetición", y `remitos-compra` sería el tercer consumidor.
- Los demás helpers del remito son propios (`_delivery_note_assert_role`, `_delivery_note_validate_items`, `_delivery_note_lock_products`, `_delivery_note_insert_items`, `_delivery_note_held_pairs`, `_delivery_note_apply_stock`, `_delivery_note_reverse_held`, `_delivery_note_payload`), más `_branch_pending_delivery_notes` (D10), con el mismo régimen de ACL: sin `authenticated`, cubiertos por el chequeo (4) del gate de ACLs por la convención `_*`.

### D13 — Backend 3 capas

- **`schemas/delivery_notes.py`**:
  - `DeliveryNoteItemIn` (`product_id` obligatorio, `unit_id?`, `quantity > 0`, `price ≥ 0`, `subtotal ≥ 0`);
  - `DeliveryNoteCreateIn` (`direction: Literal["sale"]`, `client_id`, `branch_id`, `delivery_address?` ≤ 500, `notes?` ≤ 2000, `items` de 1 a 500);
  - `DeliveryNoteUpdateIn` (+ `revision`), `DeliveryNoteCancelIn` (`reason` de 3 a 500, `revision`);
  - `DeliveryNoteConvertIn` (`expected_revision`, `payment_method_id`, `cash_session_id?`, `bank_account_id?`, `canal?`);
  - la clave de idempotencia viaja siempre por el header `Idempotency-Key` (DEC de `v3-api-standards`), nunca en el cuerpo;
  - `DeliveryNoteOut`, `DeliveryNoteListItemOut`, `DeliveryNoteConvertOut`.
- **`repositories/delivery_note_repository.py`**: todo por RPC o por `SELECT` con `account_id` explícito (regla dura #446).
- **`services/delivery_notes.py`**: guards de capacidad y mapeo a RFC 7807 con el literal SQL como `code`. `asyncpg.DeadlockDetectedError` (`40P01`) → `409 concurrent_update_retry` (D4).
- **`routers/delivery_notes.py`**:
  - `GET /delivery-notes` (filtros `direction`, `status`, `q`, `client_id`, `branch_id`), `POST /delivery-notes` **con `require_idempotency_key`** (la emisión mueve stock, D4), `GET /delivery-notes/{id}`, `PUT /delivery-notes/{id}`, `POST /delivery-notes/{id}/cancel`, `GET /delivery-notes/{id}/pdf`;
  - tanda B: `POST /delivery-notes/{id}/convert`, con `require_idempotency_key`.
  - La edición y la anulación no llevan clave: las protege la `revision` esperada (un reenvío llega con la versión vieja y rebota con `delivery_note_changed` sin efectos).
  - En el frontend, `useCreateDeliveryNote` usa `useIdempotencyKey("delivery-note-create")`, que se resetea en cada éxito.
- **`core/rbac.py`**:
  - `CAN_DELIVER_SALE = frozenset({"owner","admin","seller","stock"})`;
  - `CAN_VOID_DELIVERY_NOTE = frozenset({"owner","admin"})`. Su contenido coincide con `CAN_CONFIGURE`, así que `is_sensitive_capability` lo trata como sensible: la autoridad es la base y no el claim. Es deliberado para una acción que devuelve stock (el error queda del lado seguro);
  - la conversión usa `CAN_SELL`.
  - Un test lee las migraciones y falla si estas capacidades divergen de los `allowed_role` del catálogo (molde de `TestCanQuote`).
- **Read model de ventas**: `source_delivery_note_id` y `source_delivery_note_number`, derivados de `sales_orders.source_delivery_note_id → delivery_notes` con `account_id` en el `JOIN` (molde de `source_quote_number`). `/ventas/ordenes` también.
- **`product_repository._GROUP_HAS_LINES_IN_OTHER_UNIT_SQL`** suma `delivery_note_items` (D14).

### D14 — Unidades: el remito entra a la definición única y a los dos guards

- **Normalización**: la emisión y la edición usan `_uom_normalize_quantity` (D4/D5). El delta de la anulación y de la reversa sale del `quantity_base` ya guardado en las líneas (lo que efectivamente se descontó, D4), nunca de reconvertir líneas. El escenario "las funciones que escriben stock no conservan una conversión propia" se extiende a las funciones del remito.
- **Guard de unidad base** (`fn_product_base_unit_guard`, cuerpo vivo): la rama "asignar una unidad sobre historia en otra unidad" suma `delivery_note_items` a su `UNION` de líneas (`:3748-3754`). Ídem `_GROUP_HAS_LINES_IN_OTHER_UNIT_SQL`. Un producto sin unidad base sólo admite líneas en unidades base de factor 1 (Unidad, Kilogramo, Litro, Metro; §Context), así que el caso real es otro: un remito de **12 Unidad** de un producto sin unidad base quedaría reinterpretado como **12 kg** al asignarle "Kilogramo", y lo retenido (`quantity_base = 12`) se devolvería en kilogramos.
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
  - `CHECK` ampliados: `internal_document_sequences` (`delivery_note_sale`), los dos de FSM (`delivery_note_sale`), `stock_movements.reference_type` con sus tres valores y `operation_idempotency.operation_kind` (`delivery_note_sale`);
  - las dos filas del catálogo de la tanda A;
  - disparadores de número, creación y enforcement.
- **Funciones**:
  - `_assert_document_product` + `_quote_validate_items` reescrita;
  - los helpers `_delivery_note_*` y `_branch_pending_delivery_notes`;
  - `rpc_create_sale_delivery_note`, `rpc_update_delivery_note`, `rpc_cancel_delivery_note(p_delivery_note_id, p_expected_revision, p_reason)` y `rpc_get_delivery_note(p_id)` (payload para el endpoint).
- **Reescrituras desde el cuerpo vivo**, todas con `CREATE OR REPLACE` y la misma firma (ninguna cambia su tipo de retorno): `fn_product_base_unit_guard`, `fn_uom_in_use_guard` y `_branch_assert_empty`, conservando cada `COMMENT` y su ACL. `_branch_blocking_content` y `fn_guard_branch_decommission` no se tocan (D10).
- **Introspección final** (bloque `DO`):
  - columnas, `CHECK`, índice único y disparadores;
  - las acciones de las FK: `account_id` `CASCADE` en las dos tablas y `delivery_note_id` `CASCADE` en las líneas (D1);
  - ninguna política de escritura;
  - ACLs: RPCs sin `anon`, helpers sin `authenticated`;
  - una sola definición de cada función reescrita;
  - el cuerpo de `_quote_validate_items` llama al helper;
  - el cuerpo de los guards de unidad nombra `delivery_note_items`;
  - el cuerpo de `_branch_assert_empty` contiene `branch_has_pending_delivery_notes` y llama a `_branch_pending_delivery_notes`, y `_branch_blocking_content` conserva su firma y su `RETURNS TABLE` de 5 columnas.

`rpc_cancel_delivery_note`:
1. lock del remito;
2. rol `void` (admin/owner, P0403);
3. estado: `converted` → `P0423`; `canceled` → `P0409`;
4. revisión;
5. motivo no vacío (`P0400 delivery_note_cancel_reason_required`; `record_status_transition` lo exige igual por el catálogo);
6. **sucursal del remito activa y no cerrada**: si no, `P0422 delivery_note_branch_inactive` ("reactivá la sucursal para anular el remito"), sin efectos. Autosuficiente, no delega en el guard de baja (D9);
7. **lock de los productos** de las líneas vigentes con `_delivery_note_lock_products` (orden ascendente de `id`), el mismo helper que la emisión y la edición, **antes** de leer `branch_stock`. Sin él, una venta o un remito concurrente sobre el mismo producto dejaría `quantity_before`/`quantity_after` del movimiento inconsistentes con el stock real;
8. `_delivery_note_reverse_held(…, _delivery_note_held_pairs(dn.id), 'delivery_note_reversal', 'delivery_note_cancel')`: **todos** los pares con retenido > 0 (D4) reciben `c21_apply_branch_stock_delta(+retenido)` + movimiento `type='sale_return'`, `reference_type='delivery_note_reversal'`, con el `unit_cost_snapshot` de las líneas y `metadata.reverses = 'delivery_note_cancel'`;
9. historial `issued → canceled` (`'delivery_note_sale'`) con el motivo + `UPDATE status`.

**Tanda B** — conversión:

- `sales_orders.source_delivery_note_id` + índice único parcial;
- las dos filas del catálogo de la tanda B;
- `_c29_confirm_order_core`, `rpc_delete_sale_operation` y `rpc_atomic_update_sale_operation` desde el cuerpo vivo, cada una con el `COMMENT` vivo re-declarado;
- `rpc_convert_delivery_note_to_sale`;
- introspección: una definición por función, las ACLs vivas idénticas a las previas en las tres reescritas, y los cuerpos contienen la rama de origen, el salto de reversa, el guard `delivery_note_branch_inactive` del borrado y el `P0423`.
- **Bloque de reaplicación de `20261062000001` en `KPI_Validation.yml`** (`:1003-1022`): exige que **diez** funciones sigan con el cuerpo que esa migración deja (10/10 "ya es el cuerpo de esta migración", sin tolerancia), y dos de ellas (`_c29_confirm_order_core` y `rpc_atomic_update_sale_operation`) las reescribe esta tanda. Su propia regla escrita ("REGLA PARA EL PR SIGUIENTE") manda que la migración posterior que redefina cualquiera de las diez **retire ese bloque en el mismo PR**, porque si no `validate-kpis` queda en rojo. Por eso la tanda B:
  - en el checkpoint (tarea 6.0) verifica con un grep si el bloque sigue en el workflow;
  - si sigue, lo **retira** en su mismo PR, y el control de esas funciones pasa a su gate propio (`test_remito_a_venta.sql`) más la introspección de la tanda B;
  - si ya lo retiró otro PR (el #607 redefine tres de las diez: `rpc_create_sale_operation_v2`, `rpc_create_sale_operation` y `rpc_atomic_update_sale_operation`, y tiene la misma obligación), lo anota en la tarea y no hace nada más.

**Gates** (se ejecutan de verdad; "toda RPC que otras invocan necesita un gate que la EJECUTE"):

- **`supabase/tests/test_remitos_venta.sql` (A)**:
  - dos cuentas; owner, admin, seller, stock y cashier reales (molde de `test_document_status_transition_role_matrix.sql`); fixtures propios y cleanup asertado;
  - emisión: stock − por par, movimiento `sale/delivery_note` con `quantity_before/after` y costo, normalización 450 g → 0,45 kg, número `R` correlativo e independiente del `P` de presupuestos y de otra cuenta, historial `NULL → issued` con el creador;
  - rechazos con su código: sin cliente, cliente ajeno o dado de baja, sin sucursal, sucursal ajena o cerrada, línea sin producto, producto ajeno, dado de baja o padre, unidad incompatible, unidad de otra cuenta;
  - faltante → `P0409` con **cero** efectos (sin fila de remito, número no consumido, stock intacto, sin fila de idempotencia);
  - **idempotencia**: la misma clave dos veces → un solo remito, un solo movimiento por par y la segunda respuesta con `replayed = true`; la misma clave de otro usuario → remito propio (la clave es por usuario);
  - roles: el cashier no emite (`P0403`); el stock emite y edita pero no anula;
  - edición:
    - sólo precio → 0 movimientos nuevos;
    - **cambio en un solo producto**: remito con A=2 y B=1, editado a A=2 y B=3 → exactamente un par espejo sobre B, **cero** movimientos sobre A y Δ `branch_stock(A) = 0` (prueba que la pata de aplicación recibe sólo los pares que cambian y no vuelve a descontar los que siguen igual);
    - aumento con stock → par espejo en ese producto; aumento sin stock → `P0409` y cero efectos;
    - reducción con la sucursal en 0 → funciona;
    - cambio de producto → reversa del viejo y aplicación del nuevo;
    - cambio de sucursal → pares en dos sucursales;
    - snapshot acarreado para el producto que sigue (las cuatro columnas, incluido `iva_rate_snapshot`);
    - producto dado de baja después de emitir: editar otra línea conserva la suya sin revalidar el catálogo y sin movimiento; reducirla funciona; aumentarla → `P0400 delivery_note_product_unavailable`; **cambiar la sucursal conservando su cantidad se acepta y traslada su stock** (reversa en la vieja, aplicación en la nueva); un producto dado de baja **nuevo** en el remito → `P0404 product_not_found`;
    - sucursal vigente del remito desactivada (armada como `postgres`, evadiendo el guard de baja) → `P0422 delivery_note_branch_inactive` y cero efectos;
    - versión vieja → `P0409 delivery_note_changed`;
    - editar un anulado → `P0409`;
  - anulación: sin motivo → `P0400`; seller → `P0403`; admin → stock repuesto con `delivery_note_reversal` y historial con el motivo; segunda anulación → `P0409`; sucursal del remito desactivada o cerrada (armada como `postgres`) → `P0422 delivery_note_branch_inactive`, sin stock repuesto;
  - **idempotencia con clave ajena**: una clave de este usuario ya usada por otro `operation_kind` no choca (la unicidad incluye el tipo); una fila `delivery_note_sale` cuyo `operation_id` no es un remito de sus cuentas → `P0409 idempotency_key_conflict`;
  - **invariante**: después de emisión, ediciones y anulación, Σ `quantity_delta` por par = cambio de `branch_stock`, = `-held` antes de anular, y el neto final es 0;
  - **fila forjada en el ledger**: como `authenticated` miembro sin rol de escritura, `INSERT` por PostgREST de un movimiento `reference_type='delivery_note'` de `-1000` contra un remito pendiente (hoy la política lo admite); la anulación y la edición posteriores devuelven exactamente lo que retienen las líneas, no `+1000` (control positivo: la fila forjada existe);
  - PostgREST (`SET ROLE authenticated`) no puede `INSERT`/`UPDATE` en `delivery_notes`/`delivery_note_items` ni ejecutar los helpers;
  - guards de unidad: un producto sin unidad base, con stock y una única línea de remito en **Unidad**: asignarle Kilogramo → `P0409 base_unit_locked` (y Unidad sí se asigna); cambiar el factor de una unidad de la cuenta usada sólo en un remito → `P0409 unit_in_use`. Las dos líneas se crean por la RPC real, no con filas fabricadas;
  - baja de sucursal con un remito pendiente → `P0428` con el token `branch_has_pending_delivery_notes`, por el disparador y por `rpc_deactivate_branch` y `rpc_close_branch`; anulado el remito, la baja procede; un remito con `direction = 'purchase'` `issued` insertado como `postgres` también bloquea (el contador es agnóstico del sentido);
  - `_quote_validate_items` sigue rechazando con los mismos literales (regresión).
- **`supabase/tests/test_remito_a_venta.sql` (B)**, con **matriz de evasión**:
  - conversión `cash` (caja, `SaleConfirmed`, orden `confirmed` con `source_delivery_note_id`, remito `converted`, historial de los dos documentos), `credit` (cargo con vencimiento por cascada) y `transfer` (`bank_movements`);
  - **stock idéntico antes y después de convertir**; **0** `stock_movements` con `reference_id` en las filas `sales` de la venta; `sale_items` con los cuatro snapshots del remito (costo incluido);
  - producto **renombrado** entre la emisión y la conversión → `sale_items.name_snapshot`/`sku_snapshot` conservan los del remito;
  - producto dado de baja después de emitir → convierte; cliente dado de baja → `P0404 delivery_note_client_unavailable` y cero efectos; sucursal desactivada o cerrada (armada como `postgres`, evadiendo el guard de baja) → `P0422 branch_closed` y cero efectos;
  - replay → `replayed = true`; misma clave sobre otro remito → `P0409 idempotency_key_conflict`; segunda conversión con otra clave → `P0409 delivery_note_invalid_state`; versión vieja → `P0409`;
  - roles: el cashier convierte; el stock → `P0403`;
  - `cash` sin sesión → `P0400 cash_requires_session` y cero efectos;
  - **una orden sin origen sigue descontando** (`rpc_quick_sale` de regresión, con su movimiento `sale/sale`);
  - **núcleo con un origen inválido** (orden armada como `postgres` en el gate): remito de otra cuenta, `canceled`, `converted`, de otro cliente o de otra sucursal, y líneas distintas en producto, unidad o cantidad → `P0409 delivery_note_order_mismatch`, sin stock, venta ni evento;
  - **borrar la venta**: dinero compensado, stock idéntico, orden `canceled`, remito `issued` con historial `converted → issued` y motivo; reconvertir funciona (índice parcial);
  - **borrar la venta con la sucursal del remito desactivada** (venta a crédito o por transferencia, sucursal vaciada y desactivada como `postgres` después de convertir, que el guard de baja admite porque el remito está `converted`) → `P0422 delivery_note_branch_inactive` y cero efectos: sin compensación de dinero, orden `confirmed`, remito `converted`;
  - editar la venta → `P0423 delivery_note_sale_locked` y cero efectos: comprobante pendiente **no** anulado, `branch_stock` del par sin cambios y ningún movimiento `sale_update`/`sale` nuevo;
  - anular un remito convertido → `P0423`;
  - el `P0423` de dinero de una venta POS común no cambia (regresión).
- **`supabase/tests/test_remitos_venta_race.sh`** (molde: `test_presupuesto_a_venta_race.sh`):
  - dos conversiones del mismo remito → una venta;
  - conversión contra anulación → gana una; nunca venta con remito `canceled`;
  - edición contra conversión → la segunda recibe `delivery_note_changed` o `invalid_state`;
  - dos emisiones por la última unidad → una `P0409`;
  - dos emisiones con la **misma** clave de idempotencia → un remito y un solo descuento, y la segunda responde `replayed = true` (nunca un 500 por `23505`);
  - **emisión contra baja del producto**: si la baja gana el lock del producto, la emisión rechaza con `P0404 product_not_found`; si la emisión gana, la baja espera y el remito queda emitido con el producto vivo al momento del lock. Nunca un remito con un producto que estaba dado de baja cuando se validó;
  - borrado de la venta contra reconversión → sin interbloqueo;
  - **borrado de la venta contra anulación del remito convertido** (el borrado toma el remito al final; la anulación, al principio): si la anulación gana el lock, recibe `P0423 delivery_note_locked_converted`; si el borrado commitea primero, la anulación encuentra el remito `issued` y lo anula con su stock repuesto **una sola vez**. Nunca interbloqueo ni doble reposición;
  - **edición contra anulación**: la segunda recibe `delivery_note_changed` o `delivery_note_invalid_state`, y Σ `quantity_delta` del remito = Δ `branch_stock`.
  
  La numeración concurrente reutiliza `test_internal_document_numbering_race.sh`, parametrizado por tipo.
- **Gates existentes actualizados por tanda**:
  - `test_document_status_transition_role_matrix.sql`: tamaño del catálogo, llamadores de `record_status_transition` y pares producidos;
  - `test_function_acl_gate.sql`: clasificación de las funciones nuevas;
  - el gate de unidades de `ventas-unidades-conversion` y `test_sucursal_guard_vaciado.sql` (re-ejecutado sin cambios);
  - `test_presupuestos_modulo.sql`, `test_presupuesto_a_venta.sql` y `test_operacion_party_guard.sql`, re-ejecutados.
- Todos cableados en `KPI_Validation.yml`, en el orden real del workflow, y las dos migraciones al final de la cadena de reaplicación, **después** de los eslabones que vuelven a dejar cuerpos viejos (`20261014000001`, `20261062000001` y `20261067000001`, D10). El paso de la tanda A asserta, después de reaplicar su migración, que `_branch_assert_empty` contiene `branch_has_pending_delivery_notes`, que `fn_product_base_unit_guard`/`fn_uom_in_use_guard` nombran `delivery_note_items` y que `_quote_validate_items` llama a `_assert_document_product`. La tanda B retira el bloque de reaplicación de `20261062000001` si sigue ahí (arriba).

**Dos PRs** (A, luego B), con CI verde y revisión adversarial antes de cada merge. La tanda A entrega valor sola (crear, editar, anular, compartir). En A, el botón "Venta" no se muestra.

## Coordinación con otros changes

- **PR #607 `ventas-sucursal-por-defecto`** (sólo docs al 2026-10-02): reescribirá `rpc_create_sale_operation_v2`, la rama legacy de `rpc_create_sale_operation` y `rpc_atomic_update_sale_operation`. Este change reescribe `rpc_atomic_update_sale_operation` (tanda B). **Dependencia de orden: quien llegue segundo parte del `pg_get_functiondef` vivo** que dejó el primero, y lo verifica en su checkpoint de cuerpo (hash por líneas sin `\r`). Las otras dos funciones no se tocan acá. `lib/default-branch.ts` (D10 de #607) se reutiliza si ya está en `main`.
  - **Bloque de reaplicación de `20261062000001`**: #607 redefine tres de las diez funciones que ese bloque exige intactas, y la tanda B de este change dos (D16). El primero de los dos PRs que llegue lo retira en su mismo PR; el segundo verifica con un grep que ya no está y lo anota (tareas 6.0 y 6.10).
- **`presupuestos-modulo` tanda B** (`20261068000001`, sin mergear): la tanda B de este change depende de `SaleCheckoutFields`/`SaleCheckoutSuccess` y del molde de `rpc_convert_quote_to_sale`. Si al momento del apply de B no está mergeada, B espera. La tanda A no depende de ella.
- **`remitos-compra`** (siguiente): sumará `'delivery_note_purchase'` a la secuencia, a los dos `CHECK` de FSM y a `operation_idempotency`, con sus filas propias del catálogo (sus roles de R7) y sus disparadores de número, creación y enforcement condicionados a `direction = 'purchase'`; su RPC de alta (stock +), la conversión a compra y la pestaña "De compra", sobre las mismas tablas y helpers. `supplier_reference` y el índice por `supplier_id` ya existen (D1). Su prefijo de numeración tiene que ser distinto de `R` (recomendado `RC`, D2).
  - Lo que este change deja listo para no tener que reabrir piezas de venta: el contador de remitos pendientes del guard de sucursal ya es agnóstico del sentido, con mensaje neutro (D10); el número se formatea según `direction` en el listado, el detalle, el PDF y el panel de `/stock` (D2, D11); y el listado acepta `direction`.
  - Lo que `remitos-compra` sí toca de este change es aditivo: sus valores en los `CHECK`, sus filas del catálogo, sus disparadores gemelos y su prefijo en las definiciones de numeración. Si necesitara cambiar un helper `_delivery_note_*` compartido (por ejemplo, el signo del delta en `_delivery_note_apply_stock`), lo hace desde el cuerpo vivo.

## Risks / Trade-offs

- **[Doble descuento al convertir]** → el núcleo decide por la columna persistida, revalida el remito y sus líneas, y la matriz de evasión del gate cubre: origen ajeno, anulado, convertido, de otro cliente, de otra sucursal, líneas distintas y dos conversiones concurrentes.
- **[Regresión del POS y de la conversión de presupuestos por tocar el núcleo]** → checkpoint de cuerpo vivo, diff limitado a la rama `v_from_delivery_note`, gate de `rpc_quick_sale` y de `rpc_convert_quote_to_sale` re-ejecutados, y revisión adversarial.
- **[Edición de la venta descontaría de nuevo]** → `P0423 delivery_note_sale_locked` antes de cualquier escritura, con gate de cero efectos.
- **[Borrado de la venta devuelve stock por error]** → salto explícito de la reversa (no depende de la ausencia de movimientos) y gate de stock idéntico.
- **[Remito pendiente en una sucursal dada de baja]** → cuarta condición del guard `P0428` (D10).
- **[Guard de unidad evadible por la tabla nueva]** → `delivery_note_items` en los tres puntos (D14), con un caso de gate por cada uno.
- **[Kardex con ruido por ediciones de precio]** → espejo sólo en los pares que cambian (D5).
- **[Interbloqueo entre un remito y una venta concurrente sobre los mismos productos]** → **riesgo residual, no cubierto**. El remito lockea productos en orden de id y el núcleo, en orden de línea: el mismo riesgo que ya existe entre dos ventas, sin reintento automático en ningún lado. Se acota: la conversión no lockea productos (D7), el service de remitos devuelve `409 concurrent_update_retry` en lugar de un 500 y la emisión es idempotente, así que reintentar es seguro (D4). El gate de carrera mide que dos emisiones por el mismo stock no se interbloquean.
- **[Doble emisión por doble clic o reintento de red]** → la emisión es idempotente por `Idempotency-Key` (D4), con caso de gate y de carrera.
- **[Orden nuevo de locks con `delivery_notes` primero]** → justificado en D7 (la conversión no bloquea `sales` existentes) y cubierto por el gate de carrera borrado contra reconversión.
- **[Costo de la venta distinto del costo de catálogo del día]** → es deliberado (OQ-RV4): el margen refleja el costo con el que salió la mercadería.
- **[RLS preexistente: `INSERT` en `stock_movements` para cualquier miembro y `INSERT`/`UPDATE` en `branch_stock` para escritores; RPCs públicas `rpc_reverse_stock_movement` y `rpc_apply_product_stock_delta` sin guard de rol]** → no las abre este change y tampoco las cierra (fuera de alcance; candidatos en `CHANGES.md`, tarea 9.1). **Hoy una fila forjada ya se convierte en stock fantasma** por `rpc_reverse_stock_movement` (lee el ledger por referencia `sale`/`purchase` y lo devuelve a `branch_stock`), y `rpc_apply_product_stock_delta` deja a cualquier miembro mover stock directo (§Context). Lo que este change **sí** garantiza es no sumar un segundo amplificador: ninguna función del remito calcula lo que devuelve a `branch_stock` sumando el ledger escribible, sino desde `delivery_note_items.quantity_base`, que sólo escriben sus RPCs (D4), y `rpc_reverse_stock_movement` no admite los `reference_type` del remito. El gate lo prueba con una fila forjada (D16), y el red-team (8.4) suma el control de que la fila forjada contra un remito no se puede revertir por `rpc_reverse_stock_movement`.
- **[Remito reabierto en una sucursal dada de baja]** → el guard de baja no cuenta los remitos convertidos, así que borrar la venta podría reabrir el remito en una sucursal muerta. El borrado de la venta exige la sucursal viva antes de cualquier efecto, y la anulación y la edición lo repiten de forma autosuficiente (`P0422 delivery_note_branch_inactive`, D9).
- **[Reaplicación de migraciones en CI]** → el guard de sucursal no cambia la firma de `_branch_blocking_content` (D10), la migración de A entra en la cadena después de los eslabones que reescriben las mismas funciones, y la tanda B retira el bloque de reaplicación de `20261062000001` (D16).
- **[Choque con el PR #607 sobre `rpc_atomic_update_sale_operation`]** → dependencia de orden declarada; el segundo parte del cuerpo vivo.
- **[Producto dado de baja que sigue en un remito pendiente]** → se convierte igual (D7). Al editar, la línea se conserva sin revalidar el catálogo (se puede conservar o reducir, no aumentar) y no bloquea el guardado; quitarla devuelve su stock, y el diálogo lo avisa (D5, D11).
- **[Remito convertido cuya venta ya está facturada]** → queda cerrado: la venta autorizada es imborrable, así que el remito no se reabre ni se anula. La devolución es una nota de crédito con reingreso de stock, candidato fuera de v1 (D9).

## Migration Plan

1. **Tanda A**:
   - merge → CI/CD aplica la migración y despliega frontend y backend (verificar `GET /deploys` de Render);
   - verificación post-merge (sólo lectura): `MAX(version)`, tablas, `CHECK` (incluidos los tres `reference_type` y `delivery_note_sale`), disparadores, cero políticas de escritura, ACLs, una definición de cada función reescrita, catálogo `delivery_note_sale` con 2 filas, `operation_idempotency.operation_kind` con `delivery_note_sale`;
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

**Registro del apply (tarea 0.1, 2026-10-02)**:
- El PO firmó el 2026-09-29, textual: «no necesito el remito legal. Andá con todo lo recomendado» y «quiero que tanto el remito como los presupuestos se puedan modificar» (R1–R8, arriba).
- **OQ-RV1..OQ-RV13 se adoptan por su recomendación** (default declarado, informado al PO el 2026-10-02). El PO no eligió ninguna alternativa; por lo tanto no cambia ninguna decisión, spec ni tarea.

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
