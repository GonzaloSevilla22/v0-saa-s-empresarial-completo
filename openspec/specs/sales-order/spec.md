# sales-order

> Synced from change `v21-quote-salesorder` (C-29) — 2026-06-17; updated from `v21-customer-supplier-accounts` (C-30) — 2026-06-20 (agrega `credit` a `payment_method`); updated from `facturar-venta-afip` — 2026-06-26 (desacopla emisión de comprobante del confirm)

## Purpose

Agregado `SalesOrder` que representa una orden de venta transaccional. Centraliza el hot path de confirmación: descuento de `branch_stock` (C-21/C-26), registro de caja (C-28), numeración fiscal (C-27) e inserción en el outbox — todo en una sola transacción atómica. Reemplaza el flujo disperso de `rpc_create_sale_operation_v2` como punto de entrada principal. Incluye `quickSale()` para el punto de venta (POS). Retrocompatible: escribe también en `sales`/`sale_items` para que los listados y Edge Functions existentes sigan funcionando sin cambios.
## Requirements
### Requirement: Agregado SalesOrder con líneas
El sistema SHALL proveer un agregado `SalesOrder` (tabla `sales_orders`) con `id`, `account_id` (tenancy), `branch_id` (FK→`branches`, nullable — el RPC resuelve y persiste la branch efectiva), `client_id` (FK→`clients`, nullable), `source_quote_id` (FK→`quotes`, nullable), `status` (CHECK `draft|confirmed|canceled`), `payment_method` (CHECK `cash|other|credit`), `total numeric(15,2)`, `sale_operation_id` (puente a la venta legacy generada), `fiscal_document_id` (FK→`fiscal_documents`, nullable), `created_by`, `created_at`. Las líneas viven en `sales_order_items` con `sales_order_id`, `product_id` (nullable), `account_id`, `quantity numeric(15,4)`, `unit_id` (nullable), `price`, `subtotal`. Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER` (sin INSERT/UPDATE directo del rol `authenticated`).

#### Scenario: orden creada en draft no descuenta stock
- **WHEN** se crea un `SalesOrder` en estado `draft` (por ejemplo desde `Quote.accept()`)
- **THEN** existe la fila en `sales_orders` con `status = 'draft'` y `branch_stock` no cambia

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `sales_orders`
- **THEN** solo ve las órdenes cuyo `account_id` pertenece a su cuenta (política SELECT con `account_id IN (SELECT current_account_ids())`)

#### Scenario: payment_method credit es aceptado por el CHECK
- **WHEN** se inserta (vía RPC) un `SalesOrder` con `payment_method = 'credit'`
- **THEN** el CHECK lo acepta (el dominio admitido es `cash|other|credit`); este escenario fue agregado en C-30 que amplió el CHECK originalmente definido en C-29 como `cash|other`

### Requirement: SalesOrder.confirm() es transaccional y atómico
El sistema SHALL proveer `confirm()` mediante un único RPC `SECURITY DEFINER` (`rpc_confirm_sales_order`, wrapper del helper interno `_c29_confirm_order_core`) que, en UNA sola transacción, ejecuta: (a) valida permiso de escritura (`is_account_writer`) y que la branch efectiva esté operativa; (b) por cada línea con producto, valida stock disponible per-branch y descuenta `branch_stock` vía la mecánica de C-21/C-26, registrando el `stock_movements` con `reference_type = 'sale'`; (c) si `payment_method = 'cash'`, invoca el helper intra-transacción `c28_register_cash_movement(session_id, total, 'sale', sales_order_id)`; **(c-bis) si `payment_method = 'credit'`, resuelve o crea la `CustomerAccount` del cliente e invoca `c30_register_customer_account_movement(customer_account_id, total, 'sale', sales_order_id)` (cargo positivo) en el mismo commit, sin movimiento de caja; una venta a crédito SHALL exigir `client_id` (sino `P0400`);** (d) si se indicó tipo de comprobante, reserva número fiscal e inserta el `fiscal_documents` en `pending_cae` vía la maquinaria de C-27; (e) inserta el hecho `SaleConfirmed` en el outbox (`events`); (f) transiciona la orden a `confirmed`. Si CUALQUIER paso falla, la transacción entera SHALL hacer rollback, sin efectos parciales en stock, caja, cuenta corriente, numeración ni outbox. El `payment_method` admitido SHALL ser `cash|other|credit`.

#### Scenario: confirm descuenta stock atómicamente
- **WHEN** se confirma una orden de 2 unidades de un producto con `branch_stock = 5` en la branch de la operación
- **THEN** tras el commit `branch_stock` es 3 y existe un `stock_movements` con `quantity_delta = -2` y `reference_type = 'sale'`

#### Scenario: stock insuficiente aborta la confirmación
- **WHEN** se confirma una orden de un producto cuyo `branch_stock` en la branch de la operación es 0
- **THEN** la operación falla con error de stock insuficiente (ERRCODE P0409) y la orden permanece en `draft`

#### Scenario: pago en efectivo registra movimiento de caja en la misma transacción
- **WHEN** se confirma una orden con `payment_method = 'cash'` y una sesión de caja abierta
- **THEN** se crea un `cash_movements` con `movement_type = 'sale'`, `amount = total` y `reference_id = sales_order_id`, dentro del mismo commit que el descuento de stock

#### Scenario: venta a crédito postea cargo en la cuenta corriente del cliente
- **WHEN** se confirma una orden con `payment_method = 'credit'` y `client_id` indicado, sobre un cliente con `CustomerAccount.balance = 0`
- **THEN** en el mismo commit que el descuento de stock se crea un `customer_account_movement` de tipo `sale` con `amount = total` y `balance_after = total`, la `CustomerAccount.balance` queda en `total`, y NO se crea ningún `cash_movements`

#### Scenario: venta a crédito sin cliente es rechazada
- **WHEN** se confirma una orden con `payment_method = 'credit'` pero sin `client_id`
- **THEN** la operación falla con `P0400` antes de tocar stock

#### Scenario: venta a crédito crea la CustomerAccount si no existe (lazy)
- **WHEN** se confirma una venta a crédito para un cliente que aún no tiene `CustomerAccount`
- **THEN** la cuenta se materializa (lazy auto-create idempotente) y el cargo se postea sobre ella en el mismo commit

#### Scenario: pago en efectivo sin sesión abierta aborta todo
- **WHEN** se confirma una orden con `payment_method = 'cash'` sobre una sesión de caja inexistente o cerrada
- **THEN** el helper de caja lanza `no_open_session` (P0409), la transacción hace rollback total y `branch_stock` no cambia

#### Scenario: cash sin session_id es rechazado
- **WHEN** se confirma una orden con `payment_method = 'cash'` pero sin `cash_session_id`
- **THEN** la operación falla con P0400 antes de tocar stock

#### Scenario: comprobante fiscal reserva número pending_cae sin tocar AFIP
- **WHEN** se confirma una orden indicando un tipo de comprobante y la cuenta tiene perfil fiscal con un PV activo
- **THEN** se crea un `fiscal_documents` en estado `pending_cae` con número reservado y la orden referencia ese `fiscal_document_id`, sin que el hot path llame a AFIP

#### Scenario: rollback total ante fallo a mitad
- **WHEN** la confirmación falla después de descontar stock de la primera línea (por ejemplo, la segunda línea no tiene stock)
- **THEN** ni el descuento de la primera línea, ni el movimiento de caja, ni el cargo de cuenta corriente, ni la numeración, ni el evento de outbox quedan persistidos (cero efectos parciales)

#### Scenario: evento SaleConfirmed insertado en el outbox
- **WHEN** se confirma una orden exitosamente
- **THEN** existe una fila en `events` que representa el hecho `SaleConfirmed` para esa orden, escrita dentro del mismo commit

### Requirement: quickSale() crea y confirma en un solo paso
El sistema SHALL proveer el comando `quickSale()` (RPC `rpc_quick_sale`, `SECURITY DEFINER`) que, en una única llamada y transacción, crea un `SalesOrder` con sus líneas y lo confirma (ejecutando todos los efectos de `confirm()`). Es el camino del punto de venta (POS). El resultado SHALL incluir el `sales_order_id` y el `operation_id` de la venta legacy generada.

#### Scenario: quickSale de 2 unidades descuenta stock −2
- **WHEN** se ejecuta `quickSale()` por 2 unidades de un producto con `branch_stock = 10`
- **THEN** tras el commit `branch_stock` es 8 y la orden queda en `status = 'confirmed'`

#### Scenario: quickSale con stock 0 falla
- **WHEN** se ejecuta `quickSale()` de un producto sin stock en la branch
- **THEN** la operación falla con "stock insuficiente" (P0409) y no se crea ninguna orden confirmada

### Requirement: Idempotencia de confirm() y quickSale()
El sistema SHALL garantizar que `confirm()` y `quickSale()` son idempotentes por `idempotency_key` (DEC-06), reusando `operation_idempotency` con `operation_kind = 'sale'`. Una segunda invocación con la misma clave SHALL devolver el resultado original sin volver a descontar stock, registrar caja ni reservar número fiscal.

#### Scenario: doble quickSale con la misma clave no duplica
- **WHEN** se llama `quickSale()` dos veces con la misma `idempotency_key`
- **THEN** se crea una sola orden, el `branch_stock` se descuenta una sola vez, hay un solo `cash_movements` y la segunda llamada devuelve la orden original con `replayed = true`

### Requirement: Retrocompatibilidad con ventas legacy
El sistema SHALL, al confirmar un `SalesOrder` (vía `confirm()` o `quickSale()`), escribir también la venta en el formato legacy (`sales` + `sale_items`, con `operation_id`, `branch_id`, `canal`) en la misma transacción, de modo que los listados, reportes y Edge Functions que leen `sales`/`sale_items` sigan funcionando. El `SalesOrder` SHALL guardar el puente `sale_operation_id`. Las ventas legacy históricas (tabla `sales`) SHALL permanecer accesibles sin cambios.

#### Scenario: confirm genera la fila sales/sale_items puente
- **WHEN** se confirma una orden de un producto
- **THEN** existe una fila en `sales` con su `sale_items` correspondiente (`reference_type='sale'` en el `stock_movements`), y `sales_orders.sale_operation_id` apunta a ese `operation_id`

#### Scenario: listados de ventas existentes incluyen las nuevas órdenes
- **WHEN** el endpoint de listado de ventas pagina tras una `quickSale`
- **THEN** la venta aparece en el listado leyendo de `sales`/`sale_items` como cualquier venta legacy

### Requirement: La confirmación de venta no emite comprobante inline; la facturación es una acción posterior explícita

El sistema SHALL desacoplar la emisión del comprobante fiscal del momento de confirmar la venta. El punto de venta (POS) y el flujo de confirmación NO SHALL emitir un comprobante de forma inline: `quickSale()` y `confirm()` SHALL invocarse sin `comprobante_type` (o con `comprobante_type = NULL`), de modo que la `sales_order` resultante nazca con `fiscal_document_id IS NULL`. La emisión del comprobante SHALL realizarse mediante la acción posterior dedicada (capability `afip-fiscal-document`, "Emisión posterior de comprobante para una SalesOrder confirmada"), tanto para una venta recién confirmada como para una histórica.

El RPC de confirmación (`rpc_confirm_sales_order` / `rpc_quick_sale` vía `_c29_confirm_order_core`) SHALL conservar el parámetro `p_comprobante_type` opcional por retrocompatibilidad, pero el cliente del POS SHALL dejar de proveerlo. El frontend SHALL deshabilitar la acción "Facturar" mientras la orden tenga una emisión `pending_cae` o ya esté facturada (`fiscal_document_id IS NOT NULL`).

#### Scenario: quickSale del POS confirma sin comprobante

- **WHEN** el POS confirma una venta vía `quickSale()` sin pasar `comprobante_type`
- **THEN** la `sales_order` queda `confirmed` con `fiscal_document_id IS NULL` y no se reserva número fiscal en el hot path

#### Scenario: La venta confirmada sin comprobante puede facturarse después

- **GIVEN** una `sales_order` confirmada con `fiscal_document_id IS NULL`
- **WHEN** el usuario presiona "Facturar"
- **THEN** se dispara la emisión posterior (capability `afip-fiscal-document`) y la orden queda asociada al comprobante emitido

#### Scenario: El botón Facturar se deshabilita cuando ya hay comprobante

- **GIVEN** una `sales_order` con un comprobante `pending_cae` o ya autorizado (`fiscal_document_id IS NOT NULL`)
- **WHEN** se muestra la venta en el detalle o el listado
- **THEN** la acción "Facturar" está deshabilitada y se muestra el `FiscalDocumentBadge` con el estado del comprobante

### Requirement: Promoción de una venta legacy a SalesOrder facturable

El sistema SHALL proveer una RPC `SECURITY DEFINER` `rpc_promote_legacy_sale_to_order(p_operation_id uuid)` que materialice una `SalesOrder` con `status = 'confirmed'` a partir de una venta legacy ya existente (filas `sales` con `operation_id = p_operation_id`), de modo que esa venta cargada a mano pueda facturarse reusando el flujo `emit-invoice` (capability `afip-fiscal-document`). La RPC SHALL ser **side-effect-free respecto de stock, caja y outbox**: por tratarse de la materialización fiscal de una venta que **ya ocurrió** (su stock ya fue descontado al crearse), la promoción NO SHALL descontar `branch_stock`, NO SHALL registrar `cash_movement`, NO SHALL emitir el evento `SaleConfirmed` en el outbox (`events`), y NO SHALL invocar el helper interno `_c29_confirm_order_core`.

La RPC SHALL:
- (a) Validar autenticación (`auth.uid()`) y permiso de escritura sobre la cuenta de la operación (`is_account_writer(account_id)`), y validar la **tenencia** de la operación (existe al menos una fila `sales` con ese `operation_id` perteneciente a una cuenta del usuario); si la operación no existe o no pertenece al usuario SHALL fallar con `P0404`; si no hay permiso de escritura SHALL fallar con `P0401`.
- (b) Resolver la branch efectiva como `COALESCE(MIN(sales.branch_id) de la operación, c26_default_branch(account_id))`; si no hay branch resoluble SHALL fallar con `P0422`.
- (c) Insertar una fila en `sales_orders` con `account_id`, `branch_id` (resuelto en (b)), `client_id` (de la venta legacy), `status = 'confirmed'`, `payment_method = 'other'`, `sale_operation_id = p_operation_id`, `total = Σ subtotales reconstruidos`, `fiscal_document_id = NULL`, `created_by = auth.uid()`.
- (d) Reconstruir `sales_order_items` a partir de `sale_items` de la operación; para ventas pre-backfill sin `sale_items`, reconstruir desde el header plano de `sales` (`product_id`, `quantity`, `amount`, `total`) vía `COALESCE`. Las líneas de servicio (`product_id IS NULL`) SHALL promoverse sin error (la columna `sales_order_items.product_id` es nullable).
- (e) Devolver el `sales_order_id` (y `sale_operation_id`), indicando si fue una promoción nueva o una idempotente (`promoted` / `replayed`).

La RPC SHALL ser idempotente por `sale_operation_id` (ver requisito "Idempotencia de la promoción legacy"). Toda la escritura de `sales_orders` / `sales_order_items` SHALL ocurrir vía la RPC `SECURITY DEFINER` (la RLS de esas tablas no admite INSERT directo del rol `authenticated`).

#### Scenario: promoción exitosa materializa una SalesOrder confirmada

- **GIVEN** una venta legacy con `operation_id = OP` que tiene 2 líneas en `sale_items` (productos P1 y P2) y `branch_id = B`
- **WHEN** se invoca `rpc_promote_legacy_sale_to_order(OP)`
- **THEN** se crea exactamente una fila en `sales_orders` con `status = 'confirmed'`, `sale_operation_id = OP`, `branch_id = B`, `payment_method = 'other'`, `fiscal_document_id = NULL` y `total` igual a la suma de los subtotales
- **AND** existen 2 filas en `sales_order_items` reconstruidas desde las líneas de `sale_items` de OP
- **AND** la orden queda lista para `emit-invoice` (capability `afip-fiscal-document`)

#### Scenario: la promoción NO re-descuenta stock

- **GIVEN** una venta legacy de 3 unidades de un producto con `branch_stock = 4` en su branch (ya descontado al crear la venta)
- **WHEN** se promueve esa venta a SalesOrder vía `rpc_promote_legacy_sale_to_order`
- **THEN** `branch_stock` permanece en 4 (sin cambio) y NO se crea ningún `stock_movements` nuevo para la promoción

#### Scenario: la promoción NO registra caja

- **WHEN** se promueve una venta legacy a SalesOrder
- **THEN** NO se crea ningún `cash_movement` ni se exige una `cash_session` abierta (la promoción no toca caja, independientemente de cómo se haya cobrado la venta original)

#### Scenario: la promoción NO dispara el outbox SaleConfirmed

- **WHEN** se promueve una venta legacy a SalesOrder
- **THEN** NO se inserta ninguna fila `SaleConfirmed` en `events` para esa orden (evita un asiento contable fantasma vía el Consumer 3 del outbox / journal-entry V2.5)

#### Scenario: idempotencia en doble clic devuelve la orden existente

- **GIVEN** una venta legacy `OP` ya promovida (existe una `sales_orders` con `sale_operation_id = OP`)
- **WHEN** se invoca `rpc_promote_legacy_sale_to_order(OP)` por segunda vez (doble clic en "Facturar")
- **THEN** NO se crea una segunda `sales_orders` y la llamada devuelve el `sales_order_id` ya existente marcado como idempotente (`replayed`)

#### Scenario: línea de servicio sin producto se promueve sin error

- **GIVEN** una venta legacy cuya operación tiene una línea de servicio (`sale_items.product_id IS NULL` o header con `product_id NULL`)
- **WHEN** se promueve esa venta
- **THEN** la `sales_order_items` correspondiente se crea con `product_id = NULL`, `quantity`, `price` y `subtotal` preservados, sin fallar

#### Scenario: reconstrucción desde el header plano para ventas pre-backfill

- **GIVEN** una venta legacy cuya operación NO tiene filas en `sale_items` (cargada antes del backfill de C-29) pero sí header plano en `sales` (`product_id`, `quantity`, `amount`, `total`)
- **WHEN** se promueve esa venta
- **THEN** las `sales_order_items` se reconstruyen desde el header plano vía `COALESCE`, con la misma cantidad, precio y subtotal

#### Scenario: validación de tenencia rechaza una operación ajena o inexistente

- **WHEN** se invoca `rpc_promote_legacy_sale_to_order` con un `operation_id` que no existe o pertenece a otra cuenta
- **THEN** la RPC falla con `P0404` y no crea ninguna `sales_orders`

#### Scenario: sin permiso de escritura es rechazada

- **GIVEN** un usuario sin permiso de escritura sobre la cuenta de la operación (`is_account_writer` falso)
- **WHEN** intenta promover una venta de esa cuenta
- **THEN** la RPC falla con `P0401` y no crea ninguna `sales_orders`

### Requirement: Idempotencia de la promoción legacy

El sistema SHALL garantizar la unicidad de la `SalesOrder` materializada por operación legacy mediante un índice único parcial `CREATE UNIQUE INDEX ... ON public.sales_orders (sale_operation_id) WHERE sale_operation_id IS NOT NULL`. La RPC `rpc_promote_legacy_sale_to_order` SHALL, antes de insertar, buscar una `sales_orders` existente con ese `sale_operation_id` y, si existe, devolverla sin crear una nueva (replay). El índice parcial SHALL además impedir que el hot path POS (que también persiste `sale_operation_id`) y la promoción colisionen sobre la misma operación legacy.

#### Scenario: el índice único parcial impide dos órdenes para la misma operación

- **GIVEN** una `sales_orders` con `sale_operation_id = OP`
- **WHEN** se intenta insertar una segunda `sales_orders` con `sale_operation_id = OP`
- **THEN** la base rechaza el INSERT por violación de unicidad (la RPC absorbe ese caso devolviendo la orden existente)

#### Scenario: las órdenes sin operación legacy no se ven afectadas por el índice

- **GIVEN** múltiples `sales_orders` con `sale_operation_id IS NULL` (p.ej. órdenes en `draft` desde `Quote.accept()`)
- **WHEN** coexisten en la cuenta
- **THEN** el índice parcial las permite todas (solo indexa filas con `sale_operation_id IS NOT NULL`)

## Implementation Notes

- **Tablas**: `sales_orders` + `sales_order_items` (migración `20260702000001_c29_quote_salesorder.sql`)
- **Hotfix**: migración `20260702000002` hace nullable `events.company_id` y `events.entity_type` para que el INSERT de outbox funcione en prod (drift de schema: prod tiene esas columnas NOT NULL; C-25 debe reconciliar)
- **RPCs**: `rpc_confirm_sales_order(p_idempotency_key, p_sales_order_id, p_payment_method, p_cash_session_id, p_comprobante_type, p_point_of_sale_id, p_branch_id, p_canal)` y `rpc_quick_sale(...)` — ambos SECURITY DEFINER via helper interno `_c29_confirm_order_core`
- **Helpers usados**: `c28_register_cash_movement` (C-28), `c21_apply_branch_stock_delta` (C-21), `c26_default_branch` (C-26), `rpc_emit_pending_cae` (C-27), `rpc_next_document_number` (C-27), `c30_register_customer_account_movement` + `c30_get_or_create_customer_account` (C-30 — rama `payment_method='credit'`)
- **Outbox columns**: `(account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at, processed_at)` — columnas nullable en prod vía hotfix; C-25 formaliza el schema completo
- **RLS**: sin INSERT/UPDATE policies para `authenticated` (solo RPC definer); SELECT con `account_id IN (SELECT current_account_ids())`
- **Backend**: `backend/schemas/sales_orders.py`, `backend/repositories/sales_order_repository.py`, `backend/services/sales_orders.py`, `backend/routers/sales_orders.py`
- **Frontend**: `hooks/use-sales-orders.ts` (React Query, confirm + quickSale, invalida queries de ventas/stock)
- **Smoke prod**: 2026-06-17 — 4/4 casos OK (quickSale −2, stock 0 → P0409, accept→SalesOrder, rollback total), cero residuo
