## MODIFIED Requirements

### Requirement: RPC versionado que escribe el ítem
El sistema SHALL escribir la fila de `sale_items`/`purchase_items` en la misma transacción que el header para **toda cuenta**, presente o futura, y **en toda ruta que crea o modifica una operación**, sin ningún interruptor por cuenta. `rpc_create_sale_operation`, `rpc_create_purchase_operation`, `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` SHALL tener un único camino de escritura que escribe la línea. El feature flag `sale_items_rpc_v2` y la rama legacy que escribía sólo el header SHALL NOT existir: ninguna función de la base SHALL leer ese flag, y una fila en `account_feature_flags` con esa clave, si existiera, SHALL NOT alterar el comportamiento. `rpc_create_sale_operation` SHALL conservar su nombre y su firma pública como punto de entrada que despacha incondicionalmente a `rpc_create_sale_operation_v2`. El camino único MUST preservar la idempotencia existente (clave `(user_id, operation_kind, idempotency_key)`) y el comportamiento de stock y ledger.

#### Scenario: cuenta sin configuración de flag escribe la línea
- **WHEN** una cuenta sin ninguna fila en `account_feature_flags` crea una venta de un producto vía `rpc_create_sale_operation`
- **THEN** existe una fila en `sale_items` con `sale_id` igual al id de la venta, `product_id` del producto y `variant_id = NULL`

#### Scenario: una desactivación registrada ya no tiene efecto
- **WHEN** existe una fila `account_feature_flags(flag_key = 'sale_items_rpc_v2', enabled = false)` para una cuenta y esa cuenta crea o edita una venta o una compra de un producto
- **THEN** la operación resultante tiene su línea, exactamente igual que en una cuenta sin la fila

#### Scenario: la compra y la edición escriben su línea
- **WHEN** una cuenta registra una compra de un producto vía `rpc_create_purchase_operation`, o edita una operación vía `rpc_atomic_update_sale_operation` o `rpc_atomic_update_purchase_operation`
- **THEN** la operación resultante tiene su fila en `purchase_items` o `sale_items`

#### Scenario: ninguna función lee el flag
- **WHEN** se inspecciona el cuerpo (`prosrc`) de todas las funciones del esquema `public`
- **THEN** ninguno contiene `sale_items_rpc_v2`

#### Scenario: idempotencia preservada en el camino único
- **WHEN** se llama dos veces a `rpc_create_sale_operation` con la misma `idempotency_key`
- **THEN** se crea una sola venta con una sola línea en `sale_items`, y la segunda llamada devuelve el resultado original sin tocar el stock

### Requirement: La edición de una operación reconcilia sus líneas con el header
El sistema SHALL garantizar que, al terminar una edición de operación, cada fila de `sales`/`purchases` resultante tenga exactamente una línea canónica (`variant_id IS NULL`) en `sale_items`/`purchase_items` que espeje el header editado: mismo `product_id` (NULL en una línea de servicio), misma `quantity`, `price` igual al precio unitario editado, `subtotal` igual a `COALESCE(total, amount * quantity)` del header y `name_snapshot` no nulo. Una edición NO SHALL dejar una operación sin línea, ni SHALL dejar líneas apuntando a un header inexistente. La reconciliación SHALL ocurrir en la misma transacción que reescribe el header. Las líneas de servicio (`product_id IS NULL`) SHALL generar su línea igual que en la creación.

#### Scenario: editar la cantidad deja la línea en sincronía
- **GIVEN** una venta de un producto con `quantity = 2` y su fila en `sale_items`
- **WHEN** se edita la operación llevándola a `quantity = 5`
- **THEN** la operación resultante tiene exactamente una línea canónica en `sale_items`, con `quantity = 5` y `subtotal` igual al total del header

#### Scenario: editar una operación que nació sin línea la hace nacer
- **GIVEN** una venta histórica sin ninguna fila en `sale_items`
- **WHEN** se edita esa operación
- **THEN** la operación resultante tiene su línea en `sale_items`, con los datos del header editado

#### Scenario: la edición no deja líneas huérfanas ni duplicadas
- **WHEN** se edita una operación de un producto reemplazando su ítem
- **THEN** no queda ninguna fila de `sale_items` cuyo `sale_id` no exista en `sales`, y la operación tiene una sola línea canónica por fila de header

#### Scenario: la línea de servicio genera su línea al editar
- **WHEN** se edita una operación cuyo ítem tiene `product_id IS NULL`
- **THEN** la edición termina sin error y la fila de header resultante tiene exactamente una línea en `sale_items`, con `product_id` NULL, `name_snapshot` no nulo y `subtotal` igual al total del header

#### Scenario: la compra edita su línea igual que la venta
- **GIVEN** una compra de un producto con su fila en `purchase_items`
- **WHEN** se edita la operación de compra cambiando la cantidad
- **THEN** la compra resultante tiene exactamente una línea canónica en `purchase_items`, con la cantidad nueva y su `subtotal` recalculado

#### Scenario: la edición preserva el comportamiento de stock y los guards
- **WHEN** se edita una operación devolviendo el stock viejo y aplicando el nuevo
- **THEN** `branch_stock` refleja el neto de la edición, y los guards vigentes siguen rechazando, con el mismo código de error que antes del cambio, cantidad ≤ 0, producto de otro usuario, producto con variantes y stock insuficiente

### Requirement: Invariante — toda venta con producto tiene su fila en sale_items, sin importar la ruta

El sistema SHALL garantizar que **toda** fila de `sales` y de `purchases`, tenga producto o no, tenga exactamente una línea canónica (`variant_id IS NULL`) en `sale_items`/`purchase_items`, **independiente de la ruta de creación**: `rpc_create_sale_operation`/`_v2`, la ruta C-29 (`rpc_quick_sale`, `rpc_confirm_sales_order`, `rpc_convert_quote_to_sale`, `rpc_convert_delivery_note_to_sale`), `rpc_create_purchase_operation`, `rpc_create_purchase_operation_v2`, `rpc_convert_delivery_note_to_purchase` y las RPCs de edición. La línea canónica MUST tener el mismo `product_id` que el header y `subtotal` igual a `COALESCE(total, amount * quantity)` del header. La línea de servicio (`product_id IS NULL`) MUST escribirse en la misma transacción, con `name_snapshot` tomado, en este orden, del nombre de la línea de la orden (`sales_order_items.name_snapshot`), del nombre o la descripción del ítem del payload, de la descripción de la compra o, si no hay ninguno, de la etiqueta `Ítem sin producto`. Las filas legacy de variante (`variant_id NOT NULL`) preexistentes SHALL conservarse y SHALL NOT contar como línea canónica; ningún escritor SHALL crear filas nuevas con `variant_id NOT NULL`. Un gate SQL de dinero, corrido en modo estricto en CI, MUST verificar este invariante sobre cada escritor ejecutado y sobre el barrido global de las tablas.

#### Scenario: quickSale (POS) escribe la línea en sale_items
- **WHEN** se ejecuta `rpc_quick_sale` con un ítem de producto
- **THEN** existe una línea canónica en `sale_items` ligada a la fila `sales` generada, con el `product_id` del producto y la `quantity`, el `price` y el `subtotal` de la línea

#### Scenario: la línea de servicio de una orden escribe su línea con nombre
- **WHEN** se confirma una orden de venta (o se convierte un presupuesto) que tiene una línea de `sales_order_items` sin producto y con nombre
- **THEN** la fila `sales` de esa línea tiene exactamente una línea en `sale_items`, con `product_id` NULL y `name_snapshot` igual al nombre de la línea de la orden

#### Scenario: la compra de servicio sin descripción usa la etiqueta
- **WHEN** se registra una compra con un ítem sin producto, sin descripción de ítem y sin descripción de operación
- **THEN** su línea en `purchase_items` tiene `name_snapshot = 'Ítem sin producto'`

#### Scenario: no quedan documentos sin línea canónica
- **WHEN** se consultan todas las filas de `sales` y de `purchases`
- **THEN** ninguna carece de línea canónica y ninguna tiene más de una

#### Scenario: los reportes no cambian con la línea de servicio
- **WHEN** se crea una venta de servicio en una cuenta
- **THEN** `rpc_dashboard_kpi_summary` y `reporting_sales_lines_in_window` devuelven los mismos importes que si la línea de servicio no existiera (sólo cuenta el header, como antes del cambio)

## ADDED Requirements

### Requirement: Toda línea de documento tiene nombre
El sistema SHALL exigir `name_snapshot NOT NULL` en `sale_items` y en `purchase_items`, a nivel de columna. Toda línea creada por cualquier escritor MUST llevar nombre: el del producto en el momento de la escritura, o la cascada de la línea de servicio. Las líneas históricas sin nombre SHALL completarse antes de imponer la restricción, con `snapshot_backfilled = true`, tomando el nombre en este orden: el producto vivo, `stock_movements.product_name` del mismo documento, `purchases.description` y la etiqueta `Ítem sin producto`. Ese backfill SHALL ser idempotente.

#### Scenario: la columna rechaza una línea sin nombre
- **WHEN** se intenta insertar una fila en `sale_items` o en `purchase_items` con `name_snapshot` NULL
- **THEN** la base la rechaza por violación de `NOT NULL`

#### Scenario: la línea de un producto borrado recupera su nombre del ledger de stock
- **GIVEN** una línea histórica con `product_id` NULL (producto borrado), `name_snapshot` NULL y un movimiento de stock del mismo documento con `product_name`
- **WHEN** corre el backfill
- **THEN** la línea toma ese `product_name` y queda con `snapshot_backfilled = true`

#### Scenario: el backfill es idempotente
- **WHEN** el backfill de líneas y nombres se ejecuta dos veces seguidas
- **THEN** la segunda corrida no inserta ni modifica ninguna fila

### Requirement: Los documentos históricos sin línea se completan desde su header
El sistema SHALL crear, para cada fila de `sales`/`purchases` sin línea canónica, una línea derivada de su header: mismo `product_id`, `quantity` y `unit_id`; `price = amount`; `subtotal = COALESCE(total, amount * quantity)`; el `account_id` del header; `snapshot_backfilled = true`; y el nombre según la cascada del backfill. El importe de la línea creada MUST coincidir con el total del header.

#### Scenario: la venta histórica sin línea gana su línea con el mismo importe
- **GIVEN** una venta histórica con `product_id` NULL, `total = 31920` y ninguna fila en `sale_items`
- **WHEN** corre el backfill
- **THEN** existe exactamente una línea canónica para esa venta, con `subtotal = 31920` y `snapshot_backfilled = true`

### Requirement: Los lectores agregan sobre la línea canónica
Todo lector que una `sale_items`/`purchase_items` a su header para sumar importes o cantidades SHALL filtrar por la línea canónica (`variant_id IS NULL`), o bien por el producto del header, de modo que una fila legacy de variante nunca duplique el importe de su documento. En particular, la actividad de clientes (`backend/repositories/client_repository.py`) SHALL sumar cada fila de venta una sola vez.

#### Scenario: una venta con fila legacy de variante cuenta una sola vez en la actividad del cliente
- **GIVEN** una venta de un cliente con `total = 15000`, una línea canónica y una fila legacy de variante, ambas con `subtotal = 15000`
- **WHEN** se consulta la actividad de ese cliente
- **THEN** el importe atribuido a esa venta es 15000, no 30000
