## MODIFIED Requirements

### Requirement: RPC versionado que escribe el ítem
El sistema SHALL escribir la fila de `sale_items`/`purchase_items` en la misma transacción que el header para **toda cuenta por defecto**, presente o futura, sin requerir habilitación previa por cuenta, y **en toda ruta que crea o modifica una operación**. `rpc_create_sale_operation`, `rpc_create_purchase_operation`, `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` SHALL despachar a su versión que escribe la línea siempre que no exista una desactivación explícita para esa cuenta. La versión legacy SHALL permanecer disponible como fallback y el feature flag SHALL conservarse como interruptor de apagado, conmutable sin redeploy de backend ni frontend. Un mismo flag SHALL gobernar ventas y compras, y creación y edición: no SHALL existir una configuración que deje la creación escribiendo línea y la edición sin escribirla. La versión nueva MUST preservar la idempotencia existente (clave `(user_id, operation_kind, idempotency_key)`) y el comportamiento de stock/ledger.

#### Scenario: cuenta sin configuración de flag escribe la línea
- **WHEN** una cuenta sin ninguna fila de configuración para el flag crea una venta de un producto vía `rpc_create_sale_operation`
- **THEN** existe una fila en `sale_items` con `sale_id` igual al id de la venta, `product_id` del producto y `variant_id = NULL`

#### Scenario: cuenta creada después del cutover escribe la línea
- **WHEN** se crea una cuenta nueva y su primera venta de un producto
- **THEN** la venta tiene su fila en `sale_items` sin que nadie haya habilitado el flag para esa cuenta

#### Scenario: la compra usa el mismo interruptor que la venta
- **WHEN** una cuenta sin desactivación explícita registra una compra de un producto vía `rpc_create_purchase_operation`
- **THEN** existe una fila en `purchase_items` ligada a la compra, sin requerir un flag separado de compras

#### Scenario: la edición usa el mismo interruptor que la creación
- **WHEN** una cuenta sin desactivación explícita edita una operación vía `rpc_atomic_update_sale_operation` o `rpc_atomic_update_purchase_operation`
- **THEN** la operación resultante tiene su línea, sin requerir un flag separado de edición

#### Scenario: el apagado explícito devuelve el camino legacy sin redeploy
- **WHEN** un administrador registra la desactivación del flag para una cuenta
- **THEN** las siguientes llamadas a `rpc_create_sale_operation`, `rpc_create_purchase_operation` y a las RPCs de edición de esa cuenta ejecutan el camino legacy sin reiniciar ni redeployar backend ni frontend

#### Scenario: idempotencia preservada en el RPC nuevo
- **WHEN** se llama dos veces el RPC nuevo con la misma `idempotency_key`
- **THEN** se crea una sola venta con un solo `sale_items`, y la segunda llamada devuelve el resultado original sin tocar stock

## ADDED Requirements

### Requirement: La edición de una operación reconcilia sus líneas con el header
El sistema SHALL garantizar que, al terminar una edición de operación, cada fila de `sales`/`purchases` con `product_id NOT NULL` resultante tenga exactamente una fila en `sale_items`/`purchase_items` que espeje el header editado: mismo `product_id`, misma `quantity`, `price` igual al precio unitario editado y `subtotal` igual a `COALESCE(total, amount * quantity)` del header. Una edición NO SHALL dejar una operación sin línea, ni SHALL dejar líneas apuntando a un header inexistente. La reconciliación SHALL ocurrir en la misma transacción que reescribe el header. Las líneas de servicio (`product_id IS NULL`) NO SHALL generar fila, igual que en la creación.

#### Scenario: editar la cantidad deja la línea en sincronía
- **GIVEN** una venta de un producto con `quantity = 2` y su fila en `sale_items`
- **WHEN** se edita la operación llevándola a `quantity = 5`
- **THEN** la operación resultante tiene exactamente una fila en `sale_items` con `quantity = 5` y `subtotal` igual al total del header

#### Scenario: editar una operación que nació sin línea la hace nacer
- **GIVEN** una venta histórica sin ninguna fila en `sale_items`
- **WHEN** se edita esa operación
- **THEN** la operación resultante tiene su fila en `sale_items`, con los datos del header editado

#### Scenario: la edición no deja líneas huérfanas ni duplicadas
- **WHEN** se edita una operación de un producto reemplazando su ítem
- **THEN** no queda ninguna fila de `sale_items` cuyo `sale_id` no exista en `sales`, y la operación tiene una sola línea por fila de header

#### Scenario: la línea de servicio sigue sin generar fila al editar
- **WHEN** se edita una operación cuyo ítem tiene `product_id IS NULL`
- **THEN** la edición termina sin error y no se crea ninguna fila en `sale_items`

#### Scenario: la compra edita su línea igual que la venta
- **GIVEN** una compra de un producto con su fila en `purchase_items`
- **WHEN** se edita la operación de compra cambiando la cantidad
- **THEN** la compra resultante tiene exactamente una fila en `purchase_items` con la cantidad nueva y su `subtotal` recalculado

#### Scenario: la edición preserva el comportamiento de stock y los guards
- **WHEN** se edita una operación devolviendo el stock viejo y aplicando el nuevo
- **THEN** `branch_stock` refleja el neto de la edición y los guards vigentes siguen disparando: cantidad ≤ 0, producto de otro usuario, producto con variantes y stock insuficiente son rechazados con el mismo código de error que antes del cambio
