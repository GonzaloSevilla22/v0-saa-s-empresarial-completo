# branch-stock — Spec (stock-multisucursal)

## Purpose

Inventario de stock por sucursal. Mantiene el ledger por combinación `(product_id, branch_id)` en la tabla `branch_stock` — desde C-21, **único ledger de inventario del sistema** — con ajuste manual, transferencias entre sucursales, alertas de stock bajo y página de inventario por sucursal. La gestión multi-sucursal es exclusiva del plan PRO.
## Requirements
### Requirement: Ledger de stock por sucursal (branch_stock)
El sistema SHALL mantener el inventario por combinación `(product_id, branch_id)` en `branch_stock` como única fuente de verdad, con el invariante **`quantity >= 0`** garantizado por CHECK en la base. Las operaciones **con `branch_id` explícito** SHALL validar stock suficiente en ESA sucursal; las operaciones **sin `branch_id`** afectan la sucursal default de la cuenta con gate global (`SUM(branch_stock.quantity)`). El stock total de un producto es `SUM(branch_stock.quantity)`.

#### Scenario: Venta descuenta de branch_stock
- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** se registra una venta de 3 unidades en la sucursal A
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=A)` pasa a 7

#### Scenario: Venta con sucursal explícita falla si esa sucursal no tiene stock suficiente
- **GIVEN** un producto con 10 unidades en la sucursal default y 0 en la sucursal B
- **WHEN** se registra una venta de 2 unidades con `p_branch_id = B`
- **THEN** la RPC retorna `P0409 insufficient_branch_stock` y no inserta ninguna fila (transferir stock a B primero)

#### Scenario: Venta sin sucursal usa la default con gate global
- **GIVEN** una cuenta mono-sucursal con `SUM(branch_stock) = 2` para un producto
- **WHEN** se registra una venta de 5 unidades sin `branch_id`
- **THEN** la RPC retorna `P0409` Insufficient stock y no inserta ninguna fila

#### Scenario: Compra incrementa branch_stock
- **GIVEN** un producto con 0 unidades en `branch_stock` de la sucursal B (o sin fila aún)
- **WHEN** se registra una compra de 20 unidades en la sucursal B
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=B)` pasa a 20 (fila creada si no existía)

#### Scenario: Ninguna escritura puede dejar una sucursal en negativo
- **GIVEN** cualquier vía de escritura sobre `branch_stock` (RPCs, helper, importador)
- **WHEN** el resultado dejaría `quantity < 0`
- **THEN** la base rechaza la operación por CHECK constraint (red de seguridad física del invariante)

#### Scenario: Reversa de compra borrada con stock ya vendido hace floor a 0
- **GIVEN** una compra de 5 unidades cuyo stock ya fue vendido (la sucursal quedó en 0)
- **WHEN** se borra la compra y la reversa de −5 dejaría la sucursal en negativo
- **THEN** la cantidad queda en 0 y se registra un `stock_movement` de ajuste con reason `floor_on_purchase_delete` por la diferencia (trazabilidad en lugar de negativo)

### Requirement: Ajuste manual de stock por sucursal

El sistema SHALL permitir a `owner` y `admin` ajustar manualmente la cantidad de stock en una sucursal mediante `rpc_adjust_branch_stock`, generando un `stock_movements` de tipo `adjustment`.

#### Scenario: Owner ajusta stock de una sucursal

- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** el owner llama a `rpc_adjust_branch_stock(product_id, branch_id=A, new_quantity=15, reason="conteo físico")`
- **THEN** `branch_stock.quantity` pasa a 15, se inserta un `stock_movements` con `type='adjustment'` y `quantity_delta=5`

#### Scenario: Member no puede ajustar stock de sucursal

- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_adjust_branch_stock`
- **THEN** la RPC retorna error `insufficient_privilege`

#### Scenario: Ajuste a cero genera stock_movements con delta negativo

- **GIVEN** un producto con 8 unidades en `branch_stock` de la sucursal B
- **WHEN** el owner ajusta a `new_quantity = 0`
- **THEN** se inserta `stock_movements` con `quantity_delta = -8` y `branch_stock.quantity = 0`

---

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

---

### Requirement: Inventario de sucursal en /sucursales/:id/stock

El sistema SHALL proveer una página `/sucursales/:id/stock` que muestra todos los productos con stock registrado en esa sucursal, con opción de ajuste manual. La página es exclusiva de plan PRO.

#### Scenario: Owner ve el inventario de una sucursal

- **GIVEN** una sucursal con 5 productos en `branch_stock`
- **WHEN** el owner navega a `/sucursales/:id/stock`
- **THEN** ve una tabla con los 5 productos, su `quantity` actual y su `min_stock` por sucursal

#### Scenario: Cuenta no-PRO no puede acceder al inventario por sucursal

- **GIVEN** un usuario con plan `avanzado`
- **WHEN** intenta navegar a `/sucursales/:id/stock`
- **THEN** ve el componente `PlanGate` con CTA de upgrade a PRO

#### Scenario: Productos sin stock en la sucursal no aparecen en la tabla

- **GIVEN** una sucursal con `branch_stock` para 3 de 10 productos totales del usuario
- **WHEN** el usuario navega a `/sucursales/:id/stock`
- **THEN** la tabla muestra solo 3 productos (lazy init — los 7 restantes no tienen fila aún)

---

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

---

### Requirement: KPI de stock crítico consciente de sucursal

El KPI de stock crítico SHALL calcularse sobre `branch_stock` (la fila por sucursal) con el predicado canónico `min_stock > 0 AND quantity <= min_stock`, aceptando un filtro opcional de sucursal.

La RPC `get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL)` es la definición canónica del KPI. `min_stock = 0` significa "sin umbral configurado" y nunca es crítico (RN-23). El scope de datos deriva siempre de `auth.uid()` — `p_branch_id` es un parámetro de filtro, nunca de identidad.

#### Scenario: Filtro por sucursal cuenta solo esa sucursal
- **WHEN** un producto tiene `min_stock = 5` con 0 unidades en la Sucursal A y 50 en la Sucursal B, y se invoca la RPC con `p_branch_id` = Sucursal A
- **THEN** el KPI devuelve 1

#### Scenario: Un faltante local es visible en el agregado
- **WHEN** un producto tiene `min_stock = 5` con 0 unidades en la Sucursal A y 50 en la Sucursal B, y se invoca la RPC sin `p_branch_id`
- **THEN** el KPI devuelve 1, porque el producto es crítico en alguna sucursal con umbral

#### Scenario: Un producto crítico en varias sucursales cuenta una sola vez
- **WHEN** un producto está por debajo de su umbral en 3 sucursales y se invoca la RPC sin `p_branch_id`
- **THEN** el KPI devuelve 1 (cuenta productos distintos, no pares producto-sucursal)

#### Scenario: Sin umbral configurado nunca cuenta como crítico
- **WHEN** una fila de `branch_stock` tiene `min_stock = 0` y `quantity = 0`
- **THEN** esa fila no suma al KPI, con o sin filtro de sucursal

#### Scenario: Productos que no sostienen stock propio quedan fuera
- **WHEN** existen productos con `stock_control_type` `untracked` o `variant_only` por debajo de su umbral
- **THEN** no suman al KPI, y un `stock_control_type` nulo o desconocido sí suma (fail-open, espejo de `holdsOwnStock`)

#### Scenario: Productos borrados lógicamente quedan fuera
- **WHEN** un producto con `deleted_at` no nulo está por debajo de su umbral
- **THEN** no suma al KPI

#### Scenario: Scope por cuenta, no por usuario dueño
- **WHEN** un miembro de la cuenta (distinto del `user_id` que creó los productos) invoca la RPC
- **THEN** obtiene el mismo KPI que el owner de esa cuenta

#### Scenario: Una sucursal de otra cuenta no filtra datos ajenos
- **WHEN** se invoca la RPC con un `p_branch_id` que pertenece a otra cuenta
- **THEN** el KPI devuelve 0 y no se expone ningún dato de la cuenta ajena

#### Scenario: Llamada sin sesión es rechazada
- **WHEN** se invoca la RPC sin usuario autenticado (`auth.uid()` nulo)
- **THEN** la llamada falla con `insufficient_privilege`

### Requirement: El Tablero consume la definición canónica de stock crítico

La tarjeta "Productos en alerta" del Tablero SHALL obtener su valor de la RPC canónica pasándole el selector de sucursal activo, sin recalcular el predicado de criticidad en el cliente.

El Tablero deja de derivar el conteo del catálogo agregado (`v_products_with_stock`) y deja de aplicar un predicado inline propio. Donde el cálculo de criticidad sí ocurre en el cliente, se usan los helpers canónicos de `lib/product-stock.ts`.

#### Scenario: Cambiar el selector de sucursal actualiza la tarjeta
- **WHEN** el usuario cambia el filtro de sucursal en el Tablero (parámetro `?branch=`)
- **THEN** la tarjeta "Productos en alerta" vuelve a consultar el KPI para esa sucursal y muestra el conteo de esa sucursal

#### Scenario: Sin selector de sucursal se muestra el agregado consciente de sucursal
- **WHEN** el Tablero se carga sin `?branch=`
- **THEN** la tarjeta muestra la cantidad de productos críticos en alguna sucursal con umbral

#### Scenario: El Tablero no reimplementa el predicado de criticidad
- **WHEN** se inspecciona el código del Tablero
- **THEN** no existe ningún filtro inline de la forma `stock <= minStock` y el valor proviene del hook que consulta la RPC

#### Scenario: El predicado en cliente vive en un solo lugar
- **WHEN** un componente necesita decidir si una fila de stock por sucursal está por debajo del mínimo
- **THEN** usa `isBelowThreshold` de `lib/product-stock.ts` en lugar de comparar `quantity` con `min_stock` inline

#### Scenario: Estado de carga coherente con las demás tarjetas
- **WHEN** el KPI todavía no resolvió
- **THEN** la tarjeta muestra el mismo marcador de carga que las otras tarjetas del Tablero, sin cambiar su layout ni sus estilos

#### Scenario: Un fallo del KPI no rompe el Tablero
- **WHEN** la consulta del KPI falla
- **THEN** la tarjeta muestra 0, el error queda registrado en consola y el resto del Tablero sigue funcionando

### Requirement: Firma única y ACLs explícitas de la RPC de stock crítico

La RPC `get_dashboard_critical_stock` SHALL existir con exactamente una firma en la base de datos, y ninguna variante puede recibir la identidad del usuario como parámetro.

El overload histórico `(p_user_id uuid)` es un vector IDOR (filtra por el `user_id` que pasa el caller sin verificar `auth.uid()`) y está prohibido de forma permanente. La migración que cambie la firma debe dropear la firma anterior antes de crear la nueva y re-aplicar las ACLs, porque `DROP` + `CREATE` las resetea.

#### Scenario: No hay overloads
- **WHEN** el gate de validación de KPIs inspecciona `pg_proc`
- **THEN** encuentra exactamente una función `get_dashboard_critical_stock`, con la firma `p_branch_id uuid`

#### Scenario: La firma con identidad de usuario sigue prohibida
- **WHEN** alguna migración reintroduce `get_dashboard_critical_stock(p_user_id uuid)`
- **THEN** el gate de validación de KPIs falla e identifica la firma ofensora

#### Scenario: ACLs restauradas tras recrear la función
- **WHEN** se aplica la migración que cambia la firma
- **THEN** `anon` y `PUBLIC` no tienen EXECUTE sobre la función y `authenticated` sí

#### Scenario: Los invariantes de seguridad se conservan
- **WHEN** el gate inspecciona la definición de la función
- **THEN** la función es `SECURITY DEFINER`, verifica `auth.uid()`, conserva el guard `min_stock > 0` y lee de `branch_stock`

#### Scenario: La migración es idempotente
- **WHEN** la migración se aplica dos veces (integración GitHub de Supabase y luego `db push`)
- **THEN** la segunda aplicación no falla y el estado final es idéntico

