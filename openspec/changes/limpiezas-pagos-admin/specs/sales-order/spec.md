## MODIFIED Requirements

### Requirement: Agregado SalesOrder con líneas
El sistema SHALL proveer un agregado `SalesOrder` (tabla `sales_orders`) con `id`, `account_id` (tenancy), `branch_id` (FK→`branches`, nullable — el RPC resuelve y persiste la branch efectiva), `client_id` (FK→`clients`, nullable), `source_quote_id` (FK→`quotes`, nullable), `status` (CHECK `draft|confirmed|canceled`), `payment_method_id` (FK→`payment_methods`, nullable — única fuente de la forma de pago de la orden), `total numeric(15,2)`, `sale_operation_id` (puente a la venta legacy generada), `fiscal_document_id` (FK→`fiscal_documents`, nullable), `created_by`, `created_at`. El agregado NO SHALL tener una columna de texto con la forma de pago: el `kind` SHALL obtenerse siempre resolviendo `payment_method_id` contra `payment_methods`. Las líneas viven en `sales_order_items` con `sales_order_id`, `product_id` (nullable), `account_id`, `quantity numeric(15,4)`, `unit_id` (nullable), `price`, `subtotal`. Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER` (sin INSERT/UPDATE directo del rol `authenticated`).

#### Scenario: orden creada en draft no descuenta stock
- **WHEN** se crea un `SalesOrder` en estado `draft` (por ejemplo desde `Quote.accept()`)
- **THEN** existe la fila en `sales_orders` con `status = 'draft'` y `branch_stock` no cambia

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `sales_orders`
- **THEN** solo ve las órdenes cuyo `account_id` pertenece a su cuenta (política SELECT con `account_id IN (SELECT current_account_ids())`)

#### Scenario: la orden no tiene columna de texto de forma de pago
- **WHEN** se inspecciona la definición de la tabla `sales_orders`
- **THEN** no existe la columna `payment_method` ni el CHECK `sales_orders_payment_method_check`, y la forma de pago solo es alcanzable por `payment_method_id`

#### Scenario: la forma de pago de una orden se lee del catálogo
- **GIVEN** una orden confirmada imputada a una forma de pago de `kind = 'credit'`
- **WHEN** un consumidor necesita el `kind` de esa orden
- **THEN** lo obtiene resolviendo `payment_method_id` contra `payment_methods`, y obtiene `credit`

### Requirement: SalesOrder.confirm() es transaccional y atómico
El sistema SHALL proveer `confirm()` mediante un único RPC `SECURITY DEFINER` (`rpc_confirm_sales_order`, wrapper del helper interno `_c29_confirm_order_core`) que, en UNA sola transacción, ejecuta: (a) valida permiso de escritura (`is_account_writer`) y que la branch efectiva esté operativa; **(a-bis) resuelve la forma de pago: si se indicó `payment_method_id`, SHALL validar que pertenezca a la cuenta y esté viva y activa —si no, `P0404 payment_method_not_found` / `P0400 payment_method_inactive`—, SHALL derivar de ella el `kind` efectivo, y si además se envió el texto y difiere del `kind` derivado SHALL fallar con `P0400 payment_method_mismatch`; si no se indicó `payment_method_id`, el `kind` efectivo es el texto recibido y el sistema SHALL intentar resolver la forma de pago viva y activa de la cuenta con ese `kind` (desempate por `sort_order`, luego `id`) para imputarla; si no existe ninguna, la orden SHALL quedar sin forma de pago imputada, sin abortar la confirmación;** (b) por cada línea con producto, valida stock disponible per-branch y descuenta `branch_stock` vía la mecánica de C-21/C-26, registrando el `stock_movements` con `reference_type = 'sale'`; (c) si el `kind` efectivo es `cash`, invoca el helper intra-transacción `c28_register_cash_movement(session_id, total, 'sale', sales_order_id)`; **(c-bis) si el `kind` efectivo es `credit`, resuelve o crea la `CustomerAccount` del cliente e invoca `c30_register_customer_account_movement(customer_account_id, total, 'sale', sales_order_id)` (cargo positivo) en el mismo commit, sin movimiento de caja, e inserta el hecho `CustomerAccountCharged` en el outbox; una venta a crédito SHALL exigir `client_id` (sino `P0400 credit_requires_client`), validado antes de tocar stock;** (d) si se indicó tipo de comprobante, reserva número fiscal e inserta el `fiscal_documents` en `pending_cae` vía la maquinaria de C-27; (e) inserta el hecho `SaleConfirmed` en el outbox (`events`), **cuyo payload SHALL transportar la clave `payment_method` con el `kind` efectivo**; (f) transiciona la orden a `confirmed`, **persistiendo únicamente `payment_method_id`**. **Cada fila legacy de `sales` generada por la confirmación SHALL nacer con el mismo `payment_method_id`.** Si CUALQUIER paso falla, la transacción entera SHALL hacer rollback, sin efectos parciales en stock, caja, cuenta corriente, numeración ni outbox. El `kind` admitido SHALL ser el vocabulario completo del catálogo de formas de pago (`cash`, `transfer`, `card`, `check`, `wallet`, `credit`, `other`); los `kind` sin cableado SHALL persistirse como imputación sin efectos sobre caja, cuenta corriente ni movimientos bancarios.

#### Scenario: confirm descuenta stock atómicamente
- **WHEN** se confirma una orden de 2 unidades de un producto con `branch_stock = 5` en la branch de la operación
- **THEN** tras el commit `branch_stock` es 3 y existe un `stock_movements` con `quantity_delta = -2` y `reference_type = 'sale'`

#### Scenario: stock insuficiente aborta la confirmación
- **WHEN** se confirma una orden de un producto cuyo `branch_stock` en la branch de la operación es 0
- **THEN** la operación falla con error de stock insuficiente (ERRCODE P0409) y la orden permanece en `draft`

#### Scenario: pago en efectivo registra movimiento de caja en la misma transacción
- **WHEN** se confirma una orden con una forma de pago de `kind = 'cash'` y una sesión de caja abierta
- **THEN** se crea un `cash_movements` con `movement_type = 'sale'`, `amount = total` y `reference_id = sales_order_id`, dentro del mismo commit que el descuento de stock

#### Scenario: venta a crédito postea cargo en la cuenta corriente del cliente
- **WHEN** se confirma una orden con una forma de pago de `kind = 'credit'` y `client_id` indicado, sobre un cliente con `CustomerAccount.balance = 0`
- **THEN** en el mismo commit que el descuento de stock se crea un `customer_account_movement` de tipo `sale` con `amount = total` y `balance_after = total`, la `CustomerAccount.balance` queda en `total`, y NO se crea ningún `cash_movements`

#### Scenario: venta a crédito sin cliente es rechazada
- **WHEN** se confirma una orden con una forma de pago de `kind = 'credit'` pero sin `client_id`
- **THEN** la operación falla con `P0400 credit_requires_client` antes de tocar stock

#### Scenario: venta a crédito crea la CustomerAccount si no existe (lazy)
- **WHEN** se confirma una venta a crédito para un cliente que aún no tiene `CustomerAccount`
- **THEN** la cuenta se materializa (lazy auto-create idempotente) y el cargo se postea sobre ella en el mismo commit

#### Scenario: pago en efectivo sin sesión abierta aborta todo
- **WHEN** se confirma una orden con una forma de pago de `kind = 'cash'` sobre una sesión de caja inexistente o cerrada
- **THEN** el helper de caja lanza `no_open_session` (P0409), la transacción hace rollback total y `branch_stock` no cambia

#### Scenario: cash sin session_id es rechazado
- **WHEN** se confirma una orden con una forma de pago de `kind = 'cash'` pero sin `cash_session_id`
- **THEN** la operación falla con P0400 antes de tocar stock

#### Scenario: forma de pago de otra cuenta es rechazada
- **WHEN** se confirma una orden indicando un `payment_method_id` que pertenece a otra cuenta
- **THEN** la operación falla con `P0404 payment_method_not_found` y no se descuenta stock ni se crea la venta legacy

#### Scenario: texto y forma de pago en desacuerdo son rechazados
- **WHEN** se confirma una orden indicando un `payment_method_id` de `kind = 'credit'` junto con el texto `cash`
- **THEN** la operación falla con `P0400 payment_method_mismatch` sin efectos parciales

#### Scenario: forma de pago sin cableado se persiste como imputación
- **WHEN** se confirma una orden con una forma de pago de `kind = 'transfer'`
- **THEN** la orden queda confirmada con ese `payment_method_id` imputado, sin `cash_movements`, sin `customer_account_movements` y sin `bank_movements`

#### Scenario: la venta legacy hereda la forma de pago de la orden
- **WHEN** se confirma una orden de dos líneas con una forma de pago imputada
- **THEN** las dos filas de `sales` generadas quedan con ese mismo `payment_method_id`

#### Scenario: el camino legacy resuelve la forma de pago desde el kind
- **GIVEN** una cuenta con la forma de pago sembrada de `kind = 'cash'`
- **WHEN** se confirma una orden sin `payment_method_id`, informando solamente el texto `cash`
- **THEN** la orden queda confirmada con el `payment_method_id` de esa forma de pago, y las filas de `sales` nacen con la misma imputación

#### Scenario: el camino legacy sin forma de pago resoluble no aborta
- **GIVEN** una cuenta sin ninguna forma de pago viva y activa de `kind = 'check'`
- **WHEN** se confirma una orden sin `payment_method_id`, informando solamente el texto `check`
- **THEN** la orden queda confirmada con `payment_method_id = NULL` y el evento `SaleConfirmed` transporta `payment_method = 'check'`

#### Scenario: el evento transporta el kind efectivo
- **WHEN** se confirma una orden imputada a una forma de pago de `kind = 'wallet'`
- **THEN** el payload del hecho `SaleConfirmed` insertado en `events` contiene `payment_method = 'wallet'`

#### Scenario: comprobante fiscal reserva número pending_cae sin tocar AFIP
- **WHEN** se confirma una orden indicando un tipo de comprobante y la cuenta tiene perfil fiscal con un PV activo
- **THEN** se crea un `fiscal_documents` en estado `pending_cae` con número reservado y la orden referencia ese `fiscal_document_id`, sin que el hot path llame a AFIP

#### Scenario: rollback total ante fallo a mitad
- **WHEN** la confirmación falla después de descontar stock de la primera línea (por ejemplo, la segunda línea no tiene stock)
- **THEN** ni el descuento de la primera línea, ni el movimiento de caja, ni el cargo de cuenta corriente, ni la numeración, ni el evento de outbox quedan persistidos (cero efectos parciales)

#### Scenario: evento SaleConfirmed insertado en el outbox
- **WHEN** se confirma una orden exitosamente
- **THEN** existe una fila en `events` que representa el hecho `SaleConfirmed` para esa orden, escrita dentro del mismo commit

### Requirement: Promoción de una venta legacy a SalesOrder facturable

El sistema SHALL proveer una RPC `SECURITY DEFINER` `rpc_promote_legacy_sale_to_order(p_operation_id uuid)` que materialice una `SalesOrder` con `status = 'confirmed'` a partir de una venta legacy ya existente (filas `sales` con `operation_id = p_operation_id`), de modo que esa venta cargada a mano pueda facturarse reusando el flujo `emit-invoice` (capability `afip-fiscal-document`). La RPC SHALL ser **side-effect-free respecto de stock, caja y outbox**: por tratarse de la materialización fiscal de una venta que **ya ocurrió** (su stock ya fue descontado al crearse), la promoción NO SHALL descontar `branch_stock`, NO SHALL registrar `cash_movement`, NO SHALL emitir el evento `SaleConfirmed` en el outbox (`events`), y NO SHALL invocar el helper interno `_c29_confirm_order_core`.

La RPC SHALL:
- (a) Validar autenticación (`auth.uid()`) y permiso de escritura sobre la cuenta de la operación (`is_account_writer(account_id)`), y validar la **tenencia** de la operación (existe al menos una fila `sales` con ese `operation_id` perteneciente a una cuenta del usuario); si la operación no existe o no pertenece al usuario SHALL fallar con `P0404`; si no hay permiso de escritura SHALL fallar con `P0401`.
- (b) Resolver la branch efectiva como `COALESCE(MIN(sales.branch_id) de la operación, c26_default_branch(account_id))`; si no hay branch resoluble SHALL fallar con `P0422`.
- (c) Insertar una fila en `sales_orders` con `account_id`, `branch_id` (resuelto en (b)), `client_id` (de la venta legacy), `status = 'confirmed'`, `sale_operation_id = p_operation_id`, `total = Σ subtotales reconstruidos`, `fiscal_document_id = NULL`, `created_by = auth.uid()`. La orden SHALL nacer **sin forma de pago imputada** (`payment_method_id = NULL`): la forma de pago de una venta legacy cargada a mano es genuinamente desconocida y NO SHALL inventarse una etiqueta por defecto.
- (d) Reconstruir `sales_order_items` a partir de `sale_items` de la operación; para ventas pre-backfill sin `sale_items`, reconstruir desde el header plano de `sales` (`product_id`, `quantity`, `amount`, `total`) vía `COALESCE`. Las líneas de servicio (`product_id IS NULL`) SHALL promoverse sin error (la columna `sales_order_items.product_id` es nullable).
- (e) Devolver el `sales_order_id` (y `sale_operation_id`), indicando si fue una promoción nueva o una idempotente (`promoted` / `replayed`).

La RPC SHALL ser idempotente por `sale_operation_id` (ver requisito "Idempotencia de la promoción legacy"). Toda la escritura de `sales_orders` / `sales_order_items` SHALL ocurrir vía la RPC `SECURITY DEFINER` (la RLS de esas tablas no admite INSERT directo del rol `authenticated`).

#### Scenario: promoción exitosa materializa una SalesOrder confirmada

- **GIVEN** una venta legacy con `operation_id = OP` que tiene 2 líneas en `sale_items` (productos P1 y P2) y `branch_id = B`
- **WHEN** se invoca `rpc_promote_legacy_sale_to_order(OP)`
- **THEN** se crea exactamente una fila en `sales_orders` con `status = 'confirmed'`, `sale_operation_id = OP`, `branch_id = B`, `payment_method_id = NULL`, `fiscal_document_id = NULL` y `total` igual a la suma de los subtotales
- **AND** existen 2 filas en `sales_order_items` reconstruidas desde las líneas de `sale_items` de OP
- **AND** la orden queda lista para `emit-invoice` (capability `afip-fiscal-document`)

#### Scenario: la promoción no inventa una forma de pago

- **GIVEN** una venta legacy cargada a mano sin forma de pago conocida
- **WHEN** se la promueve a `SalesOrder`
- **THEN** la orden resultante queda con `payment_method_id = NULL` y se muestra como "Sin especificar", en vez de aparecer imputada a una forma de pago que el usuario nunca eligió

## REMOVED Requirements

### Requirement: payment_method credit es aceptado por el CHECK

**Reason**: Era un escenario del agregado `SalesOrder` que gateaba el dominio del CHECK `sales_orders_payment_method_check`. Ese CHECK desaparece junto con la columna `sales_orders.payment_method`, por lo que el escenario ya no describe ningún comportamiento observable. El invariante equivalente que sigue vivo —que `credit` es un `kind` admitido— lo cubre `payment_methods_kind_check` en la capability `payment-method`.

**Migration**: Una venta a cuenta corriente se expresa imputando una forma de pago de `kind = 'credit'` del catálogo (`payment_method_id`), no escribiendo el literal `'credit'` en la orden. El comportamiento de negocio asociado (cargo en `CustomerAccount`, exigencia de `client_id`) sigue especificado en "SalesOrder.confirm() es transaccional y atómico".
