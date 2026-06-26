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
