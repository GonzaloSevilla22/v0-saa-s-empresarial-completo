## MODIFIED Requirements

### Requirement: SalesOrder.confirm() es transaccional y atómico
El sistema SHALL proveer `confirm()` mediante un único RPC `SECURITY DEFINER` (`rpc_confirm_sales_order`, wrapper del helper interno `_c29_confirm_order_core`) que, en UNA sola transacción, ejecuta: (a) valida permiso de escritura (`is_account_writer`) y que la branch efectiva esté operativa; **(a-bis) resuelve la forma de pago: si se indicó `payment_method_id`, SHALL validar que pertenezca a la cuenta y esté viva y activa —si no, `P0404 payment_method_not_found` / `P0400 payment_method_inactive`—, SHALL derivar de ella el `kind` efectivo, y si además se envió el texto y difiere del `kind` derivado SHALL fallar con `P0400 payment_method_mismatch`; si no se indicó `payment_method_id`, el `kind` efectivo es el texto recibido y la orden queda sin forma de pago imputada;** (b) por cada línea con producto, valida stock disponible per-branch y descuenta `branch_stock` vía la mecánica de C-21/C-26, registrando el `stock_movements` con `reference_type = 'sale'`; (c) si el `kind` efectivo es `cash`, invoca el helper intra-transacción `c28_register_cash_movement(session_id, total, 'sale', sales_order_id)`; **(c-bis) si el `kind` efectivo es `credit`, resuelve o crea la `CustomerAccount` del cliente e invoca `c30_register_customer_account_movement(customer_account_id, total, 'sale', sales_order_id)` (cargo positivo) en el mismo commit, sin movimiento de caja, e inserta el hecho `CustomerAccountCharged` en el outbox; una venta a crédito SHALL exigir `client_id` (sino `P0400 credit_requires_client`), validado antes de tocar stock;** (d) si se indicó tipo de comprobante, reserva número fiscal e inserta el `fiscal_documents` en `pending_cae` vía la maquinaria de C-27; (e) inserta el hecho `SaleConfirmed` en el outbox (`events`); (f) transiciona la orden a `confirmed`, **persistiendo `payment_method_id` y `payment_method = kind` efectivo**. **Cada fila legacy de `sales` generada por la confirmación SHALL nacer con el mismo `payment_method_id`.** Si CUALQUIER paso falla, la transacción entera SHALL hacer rollback, sin efectos parciales en stock, caja, cuenta corriente, numeración ni outbox. El `kind` admitido SHALL ser el vocabulario completo del catálogo de formas de pago (`cash`, `transfer`, `card`, `check`, `wallet`, `credit`, `other`); los `kind` sin cableado SHALL persistirse como etiqueta sin efectos sobre caja, cuenta corriente ni movimientos bancarios.

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

#### Scenario: forma de pago sin cableado se persiste como etiqueta
- **WHEN** se confirma una orden con una forma de pago de `kind = 'transfer'`
- **THEN** la orden queda confirmada con `payment_method_id` imputado y `payment_method = 'transfer'`, sin `cash_movements`, sin `customer_account_movements` y sin `bank_movements`

#### Scenario: la venta legacy hereda la forma de pago de la orden
- **WHEN** se confirma una orden de dos líneas con una forma de pago imputada
- **THEN** las dos filas de `sales` generadas quedan con ese mismo `payment_method_id`

#### Scenario: confirmación sin forma de pago imputada sigue el camino legacy
- **WHEN** se confirma una orden sin `payment_method_id`, informando solamente el texto `other`
- **THEN** la orden queda confirmada con `payment_method = 'other'` y `payment_method_id = NULL`, y las filas de `sales` nacen sin forma de pago imputada

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
El sistema SHALL proveer el comando `quickSale()` (RPC `rpc_quick_sale`, `SECURITY DEFINER`) que, en una única llamada y transacción, crea un `SalesOrder` con sus líneas y lo confirma (ejecutando todos los efectos de `confirm()`). Es el camino del punto de venta (POS). El comando SHALL aceptar una forma de pago del catálogo (`payment_method_id`) y SHALL delegar en `confirm()` su resolución, validación y efectos, de modo que el POS y la confirmación de una orden existente compartan exactamente el mismo comportamiento. El resultado SHALL incluir el `sales_order_id` y el `operation_id` de la venta legacy generada.

#### Scenario: quickSale de 2 unidades descuenta stock −2
- **WHEN** se ejecuta `quickSale()` por 2 unidades de un producto con `branch_stock = 10`
- **THEN** tras el commit `branch_stock` es 8 y la orden queda en `status = 'confirmed'`

#### Scenario: quickSale con stock 0 falla
- **WHEN** se ejecuta `quickSale()` de un producto sin stock en la branch
- **THEN** la operación falla con "stock insuficiente" (P0409) y no se crea ninguna orden confirmada

#### Scenario: quickSale a cuenta corriente carga al cliente
- **WHEN** se ejecuta `quickSale()` con una forma de pago de `kind = 'credit'` y `client_id`
- **THEN** la orden queda confirmada, se postea el cargo en la cuenta corriente del cliente en el mismo commit, y no se genera movimiento de caja

#### Scenario: quickSale y confirm producen los mismos efectos para una misma forma de pago
- **WHEN** se cobra la misma venta por `quickSale()` y, en otra cuenta equivalente, creando la orden y confirmándola, ambas con una forma de pago de `kind = 'cash'`
- **THEN** ambos caminos producen el mismo conjunto de efectos: descuento de stock, `cash_movements`, filas legacy de `sales` con el mismo `payment_method_id`, evento de outbox y transición de estado

### Requirement: Idempotencia de confirm() y quickSale()
El sistema SHALL garantizar que `confirm()` y `quickSale()` son idempotentes por `idempotency_key` (DEC-06), reusando `operation_idempotency` con `operation_kind = 'sale'`. Una segunda invocación con la misma clave SHALL devolver el resultado original sin volver a descontar stock, registrar caja, postear cuenta corriente ni reservar número fiscal, **cualquiera sea la forma de pago informada en la reinvocación**.

#### Scenario: doble quickSale con la misma clave no duplica
- **WHEN** se llama `quickSale()` dos veces con la misma `idempotency_key`
- **THEN** se crea una sola orden, el `branch_stock` se descuenta una sola vez, hay un solo `cash_movements` y la segunda llamada devuelve la orden original con `replayed = true`

#### Scenario: replay con otra forma de pago no genera efectos nuevos
- **GIVEN** una venta ya confirmada con una forma de pago de `kind = 'cash'`
- **WHEN** se reinvoca con la misma `idempotency_key` y una forma de pago de `kind = 'credit'`
- **THEN** la llamada devuelve la operación original con `replayed = true`, sin crear ningún `customer_account_movement` ni modificar la imputación persistida
