## ADDED Requirements

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
