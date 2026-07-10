## ADDED Requirements

### Requirement: Propagación de min_stock del producto a branch_stock

El sistema SHALL propagar el `min_stock` definido en el formulario/registro del producto (`products.min_stock`) a `branch_stock.min_stock` de **todas** las filas existentes de ese producto, en la **misma transacción** que persiste el producto (creación o edición). La semántica es "aplica a todas las sucursales": el `min_stock` del producto es uniforme para todas sus filas `branch_stock`. La propagación SHALL ejecutarse vía una RPC `rpc_set_product_min_stock` con `SECURITY DEFINER` y guard `is_account_writer(account_id)` (patrón de las RPCs de escritura de stock del repositorio). La RPC SHALL actualizar las filas `branch_stock` existentes del producto; las filas creadas más tarde por las vías lazy heredan `min_stock` mediante la propagación disparada por la creación del producto o la próxima edición. La edición fina por sucursal está fuera de alcance.

#### Scenario: editar el mínimo de un producto propaga a todas sus sucursales
- **GIVEN** un producto con filas `branch_stock` en las sucursales A y B (`min_stock = 0` en ambas)
- **WHEN** el owner edita "Stock Mínimo" del producto a 5
- **THEN** `branch_stock.min_stock` pasa a 5 para `(producto, A)` y `(producto, B)`, en la misma transacción del UPDATE del producto

#### Scenario: crear un producto con mínimo siembra la fila branch_stock inicial
- **GIVEN** que se crea un producto con `min_stock = 3` y stock inicial 10
- **WHEN** el backend inserta el producto y aplica el delta de stock inicial en la sucursal default
- **THEN** la fila `branch_stock` recién creada para `(producto, sucursal default)` tiene `quantity = 10` y `min_stock = 3` (la propagación corre después del delta inicial)

#### Scenario: un member no puede propagar min_stock
- **GIVEN** un usuario con rol `member` (no writer) en la cuenta
- **WHEN** su llamada alcanza `rpc_set_product_min_stock`
- **THEN** la RPC retorna error de privilegio (`P0401` / `P403`) y no modifica ninguna fila `branch_stock`

#### Scenario: propagar el mismo mínimo dos veces es idempotente
- **GIVEN** un producto cuyas filas `branch_stock` ya tienen `min_stock = 5`
- **WHEN** se vuelve a propagar `min_stock = 5`
- **THEN** las filas `branch_stock` quedan con `min_stock = 5` (sin cambio observable, operación convergente)

### Requirement: Backfill de min_stock hacia branch_stock (products→branch_stock)

El sistema SHALL reconciliar, de forma idempotente y guarded, el `min_stock` histórico editado en `products.min_stock` hacia `branch_stock.min_stock` para toda fila `branch_stock` existente de un producto no borrado, **antes** de que la vista pase a exponer el `min_stock` derivado de `branch_stock`. La dirección es `products.min_stock` → `branch_stock.min_stock` (es el valor que el usuario editó creyendo que funcionaba). El backfill MUST ser re-ejecutable sin alterar el resultado convergente y MUST validar 0 divergencias tras correr.

#### Scenario: el backfill sincroniza el mínimo editado a todas las filas branch_stock del producto
- **GIVEN** un producto con `products.min_stock = 5` y filas `branch_stock` con `min_stock = 0`
- **WHEN** corre el backfill
- **THEN** todas las filas `branch_stock` del producto quedan con `min_stock = 5`

#### Scenario: el backfill deja 0 divergencias (gate de validación)
- **WHEN** termina el backfill
- **THEN** no existe ningún producto no borrado con una fila `branch_stock` donde `min_stock <> products.min_stock` (gate = 0 divergencias)

#### Scenario: re-ejecutar el backfill no cambia el resultado
- **WHEN** la migración de backfill se ejecuta dos veces seguidas
- **THEN** el `branch_stock.min_stock` por fila es idéntico tras la segunda corrida

## MODIFIED Requirements

### Requirement: Alerta de stock bajo por sucursal

El sistema SHALL generar una alerta cuando `branch_stock.quantity <= branch_stock.min_stock`, independientemente del stock global del producto. `branch_stock.min_stock` es la **única fuente de verdad** del umbral de alerta, alimentada por la propagación desde `products.min_stock` (write path) y el backfill de reconciliación. La alerta re-dispara solo cuando la cantidad **baja** (`NEW.quantity < OLD.quantity`), de modo que una edición pura de `min_stock` no genera alertas espurias. La deduplicación garantiza máximo 1 alerta por `(product_id, branch_id)` por 24 horas. El productor `StockBelowMinimum` hacia la outbox (notificación in-app post-commit) SHALL preservarse en el mismo trigger.

#### Scenario: Stock por debajo del mínimo dispara alerta
- **GIVEN** `branch_stock.min_stock = 5` para el producto X en la sucursal A
- **WHEN** una venta reduce `branch_stock.quantity` a 4
- **THEN** se inserta una fila en `email_logs` con `event_type = 'low_branch_stock_alert'` y los datos de la sucursal, y se emite `StockBelowMinimum` a la outbox

#### Scenario: Segunda alerta en menos de 24h es suprimida
- **GIVEN** ya existe una alerta `low_branch_stock_alert` de hace 2 horas para `(producto X, sucursal A)`
- **WHEN** otra venta reduce el stock aún más
- **THEN** NO se inserta una nueva alerta (deduplicación activa)

#### Scenario: editar el mínimo del producto realinea el umbral de la alerta real
- **GIVEN** un producto con `branch_stock.quantity = 6` y `min_stock` viejo (frozen) = 0
- **WHEN** el owner edita "Stock Mínimo" a 8 (propagado a `branch_stock.min_stock`)
- **THEN** el umbral de alerta pasa a 8 y la próxima venta que baje la cantidad (a ≤ 8) dispara la alerta, en lugar de disparar contra un valor frozen

#### Scenario: una edición pura de min_stock no dispara alerta espuria
- **GIVEN** un producto con `branch_stock.quantity = 4` y se edita `min_stock` a 5 (quantity no cambia)
- **WHEN** la propagación actualiza `branch_stock.min_stock`
- **THEN** NO se inserta una alerta (el trigger re-dispara solo cuando `NEW.quantity < OLD.quantity`)
