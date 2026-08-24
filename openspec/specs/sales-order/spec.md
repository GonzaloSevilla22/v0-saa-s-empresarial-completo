# sales-order

> Synced from change `v21-quote-salesorder` (C-29) — 2026-06-17; updated from `v21-customer-supplier-accounts` (C-30) — 2026-06-20 (agrega `credit` a `payment_method`); updated from `facturar-venta-afip` — 2026-06-26 (desacopla emisión de comprobante del confirm); updated from `pos-catalogo-pagos` — 2026-08-20 (restaura el bloque `credit` perdido en `20260721000001`, agrega resolución de `payment_method_id` contra el catálogo y amplía el vocabulario a los 7 `kind`)

## Purpose

Agregado `SalesOrder` que representa una orden de venta transaccional. Centraliza el hot path de confirmación: descuento de `branch_stock` (C-21/C-26), registro de caja (C-28), numeración fiscal (C-27) e inserción en el outbox — todo en una sola transacción atómica. Reemplaza el flujo disperso de `rpc_create_sale_operation_v2` como punto de entrada principal. Incluye `quickSale()` para el punto de venta (POS). Retrocompatible: escribe también en `sales`/`sale_items` para que los listados y Edge Functions existentes sigan funcionando sin cambios.
## Requirements
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

### Requirement: La confirmación de una orden sólo puede imputar caja a la sesión de su propia sucursal

El sistema SHALL rechazar la confirmación de una orden de venta que informe una sesión de caja que no esté abierta o que no pertenezca a la sucursal efectiva de esa venta, sin dejar ningún efecto parcial.

El invariante ya rige en el camino del formulario de venta y SHALL regir de forma idéntica en el camino del mostrador, con el mismo código de error y el mismo mensaje, de modo que las dos superficies produzcan un resultado indistinguible ante el mismo input inválido. Hasta ahora el camino del mostrador sólo verificaba que la sesión **estuviera informada**, no de quién era: una orden podía imputar su ingreso de efectivo al arqueo de una caja de otra sucursal — incluso de otra cuenta — dejando el ingreso registrado en los libros de un tercero y ausente en los propios.

La verificación SHALL ocurrir junto al resto de las validaciones de datos de entrada, **antes** de la primera escritura de la confirmación, y SHALL ceder ante las validaciones de datos de entrada que ya existen: un pedido que es inválido por dos motivos a la vez SHALL reportar el motivo que se evalúa primero, para que el orden de las comprobaciones quede congelado y sea verificable.

La verificación SHALL ser autosuficiente: SHALL comprobar por sí misma tanto que la sesión corresponda a la sucursal efectiva de la venta como que esa sucursal pertenezca a la cuenta que confirma, sin delegar ninguna de las dos mitades en comprobaciones posteriores. La sucursal efectiva de una venta del mostrador la determina el pedido, así que una verificación que sólo comparase la caja contra la sucursal declarada quedaría satisfecha cuando el pedido declara la sucursal ajena junto con la caja ajena.

Los comandos públicos que envuelven la confirmación —la confirmación de una orden existente y la venta rápida del mostrador— SHALL heredar la verificación sin modificarse, porque delegan en el mismo núcleo, y SHALL no repetirla en su propio cuerpo: una segunda redacción del mismo invariante es la forma en que los dos caminos divergen.

#### Scenario: Confirmar contra la caja de otra cuenta es rechazado

- **GIVEN** dos cuentas A y B, cada una con su sucursal y su caja, y una sesión de caja abierta en la cuenta B
- **WHEN** un usuario de la cuenta A confirma una venta en efectivo informando la sesión de caja de B
- **THEN** la confirmación es rechazada, no se registra ningún movimiento en la caja de B, y la orden de A queda sin confirmar

#### Scenario: Confirmar contra la caja de otra sucursal de la misma cuenta es rechazado

- **GIVEN** una cuenta con dos sucursales operativas, cada una con su caja y una sesión abierta
- **WHEN** se confirma una venta cuya sucursal efectiva es la primera informando la sesión de caja de la segunda
- **THEN** la confirmación es rechazada con el mismo error que produce el camino del formulario ante el mismo input

#### Scenario: Declarar también la sucursal ajena no evade la verificación

- **GIVEN** dos cuentas A y B, y una sesión de caja abierta en la sucursal de la cuenta B
- **WHEN** un usuario de la cuenta A confirma una venta en efectivo declarando **a la vez** la sucursal de B y la sesión de caja de B
- **THEN** la confirmación es rechazada por la verificación de la caja —no por una comprobación posterior— y no se registra ningún movimiento en la caja de B
- **AND** el resultado es el mismo cuando la sucursal ajena ya venía guardada en la orden y no viaja en el pedido

#### Scenario: Confirmar contra una sesión cerrada de la propia sucursal es rechazado

- **GIVEN** una venta en efectivo cuya sucursal efectiva tiene su sesión de caja cerrada
- **WHEN** se intenta confirmar informando esa sesión
- **THEN** la confirmación es rechazada y no se registra ningún movimiento de caja

#### Scenario: La venta en efectivo con la caja correcta sigue funcionando

- **GIVEN** una venta en efectivo cuya sucursal efectiva tiene una sesión de caja abierta
- **WHEN** se confirma informando esa sesión
- **THEN** la confirmación tiene éxito y se registra exactamente un movimiento de caja de tipo venta, por el total de la orden, referenciando la orden confirmada

#### Scenario: La venta rápida hereda la verificación sin cambios propios

- **WHEN** la venta rápida del mostrador informa una sesión de caja ajena a la sucursal efectiva
- **THEN** es rechazada igual que la confirmación de una orden existente, porque ambas delegan en el mismo núcleo

#### Scenario: Las validaciones de datos de entrada preceden a la verificación de la caja

- **GIVEN** una confirmación con una sesión de caja ajena **y** una forma de pago en efectivo sin sesión informada
- **WHEN** se intenta confirmar
- **THEN** el error reportado es el de la validación de datos de entrada que ya existía, no el de la verificación nueva

### Requirement: Idempotencia de confirm() y quickSale()
El sistema SHALL garantizar que `confirm()` y `quickSale()` son idempotentes por `idempotency_key` (DEC-06), reusando `operation_idempotency` con `operation_kind = 'sale'`. Una segunda invocación con la misma clave SHALL devolver el resultado original sin volver a descontar stock, registrar caja, postear cuenta corriente ni reservar número fiscal, **cualquiera sea la forma de pago informada en la reinvocación**.

#### Scenario: doble quickSale con la misma clave no duplica
- **WHEN** se llama `quickSale()` dos veces con la misma `idempotency_key`
- **THEN** se crea una sola orden, el `branch_stock` se descuenta una sola vez, hay un solo `cash_movements` y la segunda llamada devuelve la orden original con `replayed = true`

#### Scenario: replay con otra forma de pago no genera efectos nuevos
- **GIVEN** una venta ya confirmada con una forma de pago de `kind = 'cash'`
- **WHEN** se reinvoca con la misma `idempotency_key` y una forma de pago de `kind = 'credit'`
- **THEN** la llamada devuelve la operación original con `replayed = true`, sin crear ningún `customer_account_movement` ni modificar la imputación persistida

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

<!--
NOTA (corrección al archivar): este delta originalmente traía una sección
"## REMOVED Requirements" para "payment_method credit es aceptado por el
CHECK", pero esa entrada no correspondía a un Requirement propio del spec
principal — era un `#### Scenario` dentro de "Agregado SalesOrder con
líneas" (ver openspec/specs/sales-order/spec.md). El openspec CLI abortó el
archive ("REMOVED failed... not found") porque REMOVED exige matchear un
header de Requirement real. El propio "Reason" original ya lo decía: "Era
un escenario del agregado SalesOrder". Se retira esta sección — el
escenario desaparece igual, de forma implícita, porque el MODIFIED de
arriba reemplaza el texto COMPLETO de "Agregado SalesOrder con líneas" y
ya no lo incluye. Contenido del Reason/Migration originales preservado acá
para que no se pierda el razonamiento:
  Reason: Era un escenario del agregado SalesOrder que gateaba el dominio
  del CHECK sales_orders_payment_method_check. Ese CHECK desaparece junto
  con la columna sales_orders.payment_method, por lo que el escenario ya
  no describe ningún comportamiento observable. El invariante equivalente
  que sigue vivo —que credit es un kind admitido— lo cubre
  payment_methods_kind_check en la capability payment-method.
  Migration: Una venta a cuenta corriente se expresa imputando una forma
  de pago de kind='credit' del catálogo (payment_method_id), no
  escribiendo el literal 'credit' en la orden. El comportamiento de
  negocio asociado (cargo en CustomerAccount, exigencia de client_id)
  sigue especificado en "SalesOrder.confirm() es transaccional y atómico".
-->

### Requirement: Snapshot congelado en las líneas de la orden de venta

El sistema SHALL agregar a `sales_order_items`, de forma aditiva y NULLABLE, las columnas `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)` e `iva_rate_snapshot NUMERIC(5,2)`, más `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false`. `_c29_confirm_order_core` (y las rutas de `confirm()` / `quickSale()` que lo invocan) SHALL congelar el nombre, SKU, costo y alícuota de IVA del maestro en la misma transacción atómica de la confirmación, sin alterar la atomicidad, la idempotencia ni el descuento de `branch_stock` ya especificados.

#### Scenario: confirm() congela el snapshot en la transacción atómica

- **GIVEN** un producto con `products.cost = 600` y una `SalesOrder` en DRAFT
- **WHEN** se confirma la orden vía `_c29_confirm_order_core`
- **THEN** cada `sales_order_items` de la orden queda con `unit_cost_snapshot = 600` y los demás snapshots congelados, en la misma transacción que descuenta `branch_stock` y escribe `sale_items`

#### Scenario: quickSale() congela el snapshot en un solo paso

- **WHEN** se ejecuta `quickSale()` (crear + confirmar)
- **THEN** las líneas resultantes quedan con los snapshots congelados desde el maestro, sin una escritura posterior

#### Scenario: La idempotencia de la confirmación se preserva

- **WHEN** se invoca `_c29_confirm_order_core` dos veces con la misma clave de idempotencia
- **THEN** la orden se confirma una sola vez con un único set de snapshots, y la segunda llamada devuelve el resultado original sin re-descontar stock

#### Scenario: Una venta promovida desde legacy admite snapshot backfilled

- **GIVEN** una venta legacy promovida a `SalesOrder`
- **WHEN** se le aplica el backfill de snapshots
- **THEN** sus `sales_order_items` quedan con snapshots completados desde el maestro actual y `snapshot_backfilled = true`

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

### Requirement: La orden de venta registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'sales_order'`) tanto la creación de la orden (`from_status = NULL`, `to_status = 'draft'`) como su transición a `confirmed` durante `_c29_confirm_order_core`, en la misma transacción atómica de la confirmación (junto con stock, caja, fiscal y outbox).

#### Scenario: Crear una orden de venta registra su estado inicial
- **WHEN** se crea una orden de venta en estado `draft` (incluyendo la creación implícita de `quickSale`)
- **THEN** el sistema inserta una fila de historial con `document_type = 'sales_order'`, `from_status = NULL`, `to_status = 'draft'`

#### Scenario: Confirmar una orden registra la transición atómicamente
- **WHEN** `_c29_confirm_order_core` transiciona la orden de `draft` a `confirmed`
- **THEN** el sistema inserta una fila de historial con `from_status = 'draft'`, `to_status = 'confirmed'` en la misma transacción, y si el registro falla toda la confirmación (stock, caja, fiscal, outbox) se revierte

#### Scenario: La idempotencia de la confirmación no duplica el historial
- **WHEN** una confirmación se reejecuta con la misma `idempotency_key` y devuelve la operación original sin re-ejecutar
- **THEN** no se inserta una nueva fila de historial para la transición ya registrada

### Requirement: Cancelación de la orden al borrar su venta
El sistema SHALL cancelar la orden de venta en la misma transacción en que se borra la venta que originó, dejándola en estado `canceled` y sin referencia a una operación de venta inexistente.

#### Scenario: Borrado de la venta del POS
- **WHEN** se borra la venta originada por una orden confirmada del POS
- **THEN** la orden queda en estado `canceled`
- **AND** deja de referenciar la operación de venta borrada

#### Scenario: La transición queda registrada
- **WHEN** una orden se cancela por el borrado de su venta
- **THEN** la transición de estado queda registrada en el historial de la orden
- **AND** el motivo registrado identifica el borrado de la venta

#### Scenario: Orden con comprobante fiscal
- **WHEN** se intenta borrar la venta de una orden con comprobante fiscal emitido
- **THEN** el borrado se rechaza
- **AND** la orden conserva su estado confirmado

### Requirement: Ausencia de órdenes confirmadas sin venta viva
El sistema SHALL NOT dejar órdenes en estado `confirmed` cuya operación de venta asociada no exista.

#### Scenario: Verificación de consistencia
- **WHEN** se audita el conjunto de órdenes confirmadas con operación de venta asignada
- **THEN** cada una referencia una operación de venta existente

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
