# sales-order

## ADDED Requirements

### Requirement: Agregado SalesOrder con líneas
El sistema SHALL proveer un agregado `SalesOrder` (tabla `sales_orders`) con `id`, `account_id` (tenancy), `branch_id` (FK→`branches`, nullable — el RPC resuelve y persiste la branch efectiva), `client_id` (FK→`clients`, nullable), `source_quote_id` (FK→`quotes`, nullable), `status` (CHECK `draft|confirmed|canceled`), `payment_method` (CHECK `cash|other`), `total numeric(15,2)`, `sale_operation_id` (puente a la venta legacy generada), `fiscal_document_id` (FK→`fiscal_documents`, nullable), `created_by`, `created_at`. Las líneas viven en `sales_order_items` con `sales_order_id`, `product_id` (nullable), `account_id`, `quantity numeric(15,4)`, `unit_id` (nullable), `price`, `subtotal`. Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER` (sin INSERT/UPDATE directo del rol `authenticated`).

#### Scenario: orden creada en draft no descuenta stock
- **WHEN** se crea un `SalesOrder` en estado `draft` (por ejemplo desde `Quote.accept()`)
- **THEN** existe la fila en `sales_orders` con `status = 'draft'` y `branch_stock` no cambia

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `sales_orders`
- **THEN** solo ve las órdenes cuyo `account_id` pertenece a su cuenta (política SELECT con `account_id IN (SELECT current_account_ids())`)

### Requirement: SalesOrder.confirm() es transaccional y atómico
El sistema SHALL proveer `confirm()` mediante un único RPC `SECURITY DEFINER` (`rpc_confirm_sales_order`) que, en UNA sola transacción, ejecuta: (a) valida permiso de escritura (`is_account_writer`) y que la branch efectiva esté operativa; (b) por cada línea con producto, valida stock disponible per-branch y descuenta `branch_stock` vía la mecánica de C-21/C-26, registrando el `stock_movements` con `reference_type = 'sale'`; (c) si `payment_method = 'cash'`, invoca el helper intra-transacción `c28_register_cash_movement(session_id, total, 'sale', sales_order_id)`; (d) si se indicó tipo de comprobante, reserva número fiscal e inserta el `fiscal_documents` en `pending_cae` vía la maquinaria de C-27; (e) inserta el hecho `SaleConfirmed` en el outbox (`events`); (f) transiciona la orden a `confirmed`. Si CUALQUIER paso falla, la transacción entera SHALL hacer rollback, sin efectos parciales en stock, caja, numeración ni outbox.

#### Scenario: confirm descuenta stock atómicamente
- **WHEN** se confirma una orden de 2 unidades de un producto con `branch_stock = 5` en la branch de la operación
- **THEN** tras el commit `branch_stock` es 3 y existe un `stock_movements` con `quantity_delta = -2` y `reference_type = 'sale'`

#### Scenario: stock insuficiente aborta la confirmación
- **WHEN** se confirma una orden de un producto cuyo `branch_stock` en la branch de la operación es 0
- **THEN** la operación falla con error de stock insuficiente (ERRCODE P0409) y la orden permanece en `draft`

#### Scenario: pago en efectivo registra movimiento de caja en la misma transacción
- **WHEN** se confirma una orden con `payment_method = 'cash'` y una sesión de caja abierta
- **THEN** se crea un `cash_movements` con `movement_type = 'sale'`, `amount = total` y `reference_id = sales_order_id`, dentro del mismo commit que el descuento de stock

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
- **THEN** ni el descuento de la primera línea, ni el movimiento de caja, ni la numeración, ni el evento de outbox quedan persistidos (cero efectos parciales)

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
