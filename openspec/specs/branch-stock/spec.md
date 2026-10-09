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

### Requirement: El alta de una venta desde el formulario opera sobre la sucursal elegida
El sistema SHALL entregar a la operación de alta de venta la sucursal que el usuario eligió en el formulario, de punta a punta (cliente, API y RPC), de modo que la venta y su movimiento de stock queden registrados en ESA sucursal y que el stock, la caja y el movimiento bancario se resuelvan contra ella. Cuando el usuario no elige ninguna (cuenta sin módulo de sucursales u opción "Sin sucursal (general)"), el sistema SHALL conservar el comportamiento sin sucursal: la venta queda con `branch_id = NULL` y el stock se descuenta de la sucursal por defecto.

#### Scenario: Venta del formulario en una sucursal que no es la default
- **GIVEN** una cuenta con las sucursales A (default) y B, y un producto con 10 unidades en cada una
- **WHEN** el usuario elige la sucursal B en el formulario y registra una venta de 3 unidades
- **THEN** la fila en `sales` y el `stock_movement` de la venta tienen `branch_id = B`, `branch_stock` de B pasa a 7 y `branch_stock` de A permanece en 10

#### Scenario: La sucursal elegida no tiene stock aunque la default sí
- **GIVEN** un producto con 10 unidades en la sucursal default A y ninguna en la sucursal B
- **WHEN** el usuario elige B en el formulario y registra una venta de 2 unidades
- **THEN** el alta es rechazada con `P0409 insufficient_branch_stock` (HTTP 409), no se persiste ninguna fila y el stock de A no se toca

#### Scenario: Sucursal ajena, inactiva o cerrada
- **GIVEN** una sucursal que pertenece a otra cuenta, que está inactiva o que está cerrada
- **WHEN** una venta se registra indicando esa sucursal
- **THEN** la sucursal ajena o inactiva se rechaza con `P0404` (HTTP 404) y la cerrada con `P0422` (HTTP 422), sin persistir nada

#### Scenario: Venta sin sucursal elegida
- **GIVEN** un formulario de venta sin sucursal elegida
- **WHEN** el usuario registra la venta
- **THEN** la fila en `sales` tiene `branch_id = NULL` y el stock se descuenta de la sucursal por defecto de la cuenta

#### Scenario: Caja y banco siguen a la sucursal elegida
- **GIVEN** el usuario eligió la sucursal B y una forma de pago en efectivo con la casilla "Registrar en caja" tildada
- **WHEN** registra la venta
- **THEN** el movimiento de caja se registra sólo si la sesión abierta es la de B (con la sesión de otra sucursal el alta se rechaza con `P0422`), y el movimiento bancario de una venta por transferencia lleva `branch_id = B`

### Requirement: Ajuste manual de stock por sucursal

El sistema SHALL permitir a los miembros con un rol activo `owner`, `admin` o `stock` ajustar manualmente la cantidad de stock de un producto en una sucursal mediante `rpc_adjust_branch_stock(p_product_id, p_branch_id, p_new_quantity, p_reason)`, fijando la cantidad absoluta de esa sucursal y generando un `stock_movements` de tipo `adjustment` por la diferencia. La RPC SHALL ser un envoltorio público del núcleo único de ajuste manual (ver "Núcleo único de ajuste manual de stock"): hereda de él el rol exigido en la base, el motivo obligatorio, la tenencia por `products.account_id` y el sello de cuenta, sucursal y autor del movimiento. El motivo SHALL persistirse en `stock_movements.reason` (no en `notes`). El producto SHALL pertenecer a la cuenta del usuario y la sucursal SHALL pertenecer a esa misma cuenta y no estar cerrada.

La spec anterior decía "owner y admin" mientras el código dejaba pasar a todo rol con `is_writer` (7 de 8): la exigencia de rol SHALL vivir en la base, no sólo en el formulario del cliente.

#### Scenario: Owner ajusta stock de una sucursal

- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** el owner llama a `rpc_adjust_branch_stock(product_id, branch_id=A, new_quantity=15, reason="conteo físico")`
- **THEN** `branch_stock.quantity` pasa a 15, se inserta un `stock_movements` con `type='adjustment'`, `quantity_delta=5`, `reason='conteo físico'`, `account_id` de la cuenta, `branch_id=A` y `performed_by` = el owner

#### Scenario: El rol de depósito puede ajustar stock de una sucursal

- **GIVEN** un miembro cuyo único rol activo es `stock`
- **WHEN** llama a `rpc_adjust_branch_stock` con un motivo no vacío sobre un producto y una sucursal de su cuenta
- **THEN** el ajuste se aplica y deja su movimiento

#### Scenario: Un rol que escribe pero no ajusta stock es rechazado

- **GIVEN** un miembro cuyos roles activos son `seller`, `cashier`, `purchases` o `accountant`
- **WHEN** llama a `rpc_adjust_branch_stock`
- **THEN** la RPC retorna `P0403 insufficient_role` y no cambia `branch_stock` ni inserta movimiento

#### Scenario: Un viewer no puede ajustar stock de sucursal

- **GIVEN** un miembro cuyo único rol activo es `viewer`
- **WHEN** llama a `rpc_adjust_branch_stock`
- **THEN** la RPC retorna `P0401` y no cambia nada

#### Scenario: Ajuste sin motivo es rechazado

- **WHEN** un owner llama a `rpc_adjust_branch_stock` con `p_reason` nulo, vacío o sólo espacios
- **THEN** la RPC retorna `P0400 stock_adjustment_reason_required` y no cambia nada

#### Scenario: Producto de otra cuenta es rechazado

- **GIVEN** un producto que pertenece a otra cuenta
- **WHEN** un owner llama a `rpc_adjust_branch_stock` con ese producto y una sucursal propia
- **THEN** la RPC retorna `P0404` y no crea ninguna fila de `branch_stock` para ese producto

#### Scenario: Ajuste a cero genera stock_movements con delta negativo

- **GIVEN** un producto con 8 unidades en `branch_stock` de la sucursal B
- **WHEN** el owner ajusta a `new_quantity = 0` con motivo
- **THEN** se inserta `stock_movements` con `quantity_delta = -8` y `branch_stock.quantity = 0`

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

### Requirement: Todos los consumidores de stock crítico reutilizan la RPC canónica

Todo resumen secundario y todo contexto de IA que presente un conteo de stock crítico o bajo comparable con el KPI del Tablero SHALL obtenerlo de `get_dashboard_critical_stock(p_branch_id)`. Ningún consumidor de esa clase SHALL inferir criticidad desde `products.stock`, `v_products_with_stock.stock` ni un umbral por defecto local, porque esos valores agregados ocultan faltantes por sucursal y alteran la semántica de `min_stock = 0`. Queda fuera de este requirement la pantalla `/stock`: su panel de reposición deriva su conteo del catálogo agregado, y alinearlo por sucursal es deuda conocida (OQ-5 de `sucursal-guard-vaciado-auditoria`, ver CHANGES.md), no una obligación de este requirement.

Cuando un consumidor sólo recibe el conteo canónico, SHALL comunicar únicamente ese conteo. No puede atribuir nombres, cantidades o días restantes a productos concretos reconstruyéndolos desde el catálogo agregado.

#### Scenario: El resumen IA del Tablero respeta la sucursal activa
- **WHEN** el resumen secundario del Tablero muestra "Stock bajo" con una sucursal seleccionada
- **THEN** obtiene el conteo mediante la RPC canónica usando esa sucursal, igual que la tarjeta principal

#### Scenario: Copilot e Insights consumen el agregado consciente de sucursal
- **WHEN** Copilot o `ai-insights` construyen su contexto sin un filtro de sucursal
- **THEN** consultan la RPC con `p_branch_id = null` y reciben el conteo de productos críticos en alguna sucursal

#### Scenario: La IA no inventa detalle de productos desde stock agregado
- **GIVEN** que un producto está crítico en una sucursal pero su stock total agregado supera el mínimo
- **WHEN** se construye un contexto de IA
- **THEN** el contexto informa el conteo canónico y no deriva nombres ni días restantes mediante `v_products_with_stock`

#### Scenario: Fallo aislado del KPI en un contexto de IA
- **WHEN** la RPC de stock crítico falla mientras se construye un resumen o contexto de IA
- **THEN** el consumidor omite el dato, registra el error y no reemplaza la definición con un cálculo local divergente

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

### Requirement: Detalle canónico de productos críticos por sucursal

El sistema SHALL exponer `get_dashboard_critical_stock_items(p_branch_id uuid DEFAULT NULL, p_limit integer DEFAULT 20)` como la definición canónica del **detalle** de stock crítico — hermana de `get_dashboard_critical_stock(p_branch_id)`, con el MISMO predicado (`branch_stock.min_stock > 0 AND quantity <= min_stock`, exclusión de `untracked`/`variant_only`/`deleted_at`, tenencia vía `current_account_ids()`), pero devolviendo una fila por `(product_id, branch_id)` que lo cumple — sin deduplicar por producto, porque el detalle es por definición "por sucursal" (a diferencia del conteo, que cuenta productos distintos).

Todo consumidor de IA que hoy sólo informa el conteo canónico y necesite nombrar productos concretos SHALL obtener ese detalle de esta RPC, nunca reconstruyéndolo desde `v_products_with_stock` ni desde el catálogo agregado. El conteo total que acompaña al detalle SHALL seguir viniendo de `get_dashboard_critical_stock`, nunca derivado de la longitud del detalle (que es sólo un top acotado por `p_limit`).

Las filas SHALL ordenarse por criticidad — menor razón `quantity / min_stock` primero (más lejos bajo su umbral) — desempatado por nombre de producto. `p_limit` SHALL aceptar `NULL` (sin límite) y SHALL rechazar valores menores o iguales a 0 con `P0400`.

#### Scenario: Paridad de predicado con el conteo canónico
- **WHEN** se invoca `get_dashboard_critical_stock_items(NULL, NULL)` y se cuentan los `product_id` distintos de sus filas
- **THEN** el resultado coincide con `get_dashboard_critical_stock(NULL)`, total y por sucursal

#### Scenario: Un producto crítico en varias sucursales aparece una fila por sucursal
- **GIVEN** un producto está por debajo de su umbral en 2 sucursales
- **WHEN** se invoca el detalle sin filtro de sucursal
- **THEN** aparecen 2 filas (una por sucursal), a diferencia del conteo canónico que lo cuenta una sola vez

#### Scenario: El producto más crítico aparece primero
- **GIVEN** dos filas críticas con razones `quantity/min_stock` distintas
- **WHEN** se invoca el detalle
- **THEN** la fila con menor razón (más lejos bajo su umbral) aparece primero

#### Scenario: `p_limit` acota el resultado
- **WHEN** se invoca el detalle con `p_limit = 1` habiendo más de una fila crítica
- **THEN** se devuelve exactamente 1 fila, la más crítica

#### Scenario: `p_limit` inválido se rechaza
- **WHEN** se invoca el detalle con `p_limit <= 0`
- **THEN** la RPC falla con `P0400`

#### Scenario: Tenencia — ninguna fila de otra cuenta es visible
- **WHEN** se invoca el detalle bajo la sesión de una cuenta que no tiene productos críticos propios, existiendo filas críticas de otra cuenta
- **THEN** el resultado no incluye ninguna fila de la cuenta ajena

#### Scenario: El Copiloto y `ai-insights` nombran los productos críticos, no sólo los cuentan
- **WHEN** el Copiloto (`buildBusinessSnapshot.ts`) o `ai-insights` construyen su contexto y el conteo canónico es mayor a 0
- **THEN** además del conteo, listan hasta 5 productos concretos (nombre, sucursal, cantidad y mínimo) obtenidos de esta RPC — nunca reconstruidos desde el catálogo agregado

#### Scenario: Fallo aislado del detalle no afecta al conteo
- **WHEN** `get_dashboard_critical_stock_items` falla mientras `get_dashboard_critical_stock` respondió
- **THEN** el consumidor de IA sigue informando el conteo y omite únicamente el detalle, sin inventar productos

### Requirement: La transferencia entre sucursales se ofrece desde el módulo de Stock principal

El sistema SHALL ofrecer la transferencia de stock entre sucursales desde el **módulo de Stock principal**, en la ruta `/stock`, como una acción por producto del listado.

La transferencia ya existe y funciona, pero sólo se llega a ella recorriendo Sucursales → una sucursal → Stock → la fila del producto. El PO, que conoce el sistema, creyó que la función no existía; la usuaria del incidente del 22-08 desactivó una sucursal llena en vez de vaciarla, muy probablemente por lo mismo. Una función que nadie encuentra equivale a una función que no está.

La acción SHALL aparecer únicamente cuando tenga sentido: sólo si la cuenta tiene el módulo de sucursales habilitado por su plan y tiene **más de una** sucursal activa. Con una sola sucursal no hay a dónde transferir y el control sería ruido.

Al activar la acción, el sistema SHALL mostrar el **desglose por sucursal** de las existencias de ese producto, leído del ledger canónico por sucursal, para que el usuario elija el origen. La transferencia propiamente dicha SHALL **reutilizar el diálogo de transferencia existente** sin reescribirlo ni duplicar su lógica de validación.

#### Scenario: Cuenta con varias sucursales ve la acción de transferir

- **GIVEN** una cuenta con el módulo de sucursales y dos sucursales activas
- **WHEN** un miembro abre el módulo de Stock
- **THEN** cada producto del listado ofrece la acción de transferir stock

#### Scenario: Cuenta con una sola sucursal no ve la acción

- **GIVEN** una cuenta con una única sucursal activa
- **WHEN** un miembro abre el módulo de Stock
- **THEN** la acción de transferir stock no se ofrece

#### Scenario: La acción muestra el desglose por sucursal y transfiere

- **GIVEN** un producto con existencias repartidas en dos sucursales
- **WHEN** un miembro activa la acción de transferir desde el módulo de Stock
- **THEN** ve cuántas unidades hay en cada sucursal, elige el origen, y completa la transferencia con el mismo diálogo que ya se usa desde el inventario de una sucursal

#### Scenario: No se duplica el diálogo de transferencia

- **WHEN** se inspecciona la interfaz tras el cambio
- **THEN** existe un solo diálogo de transferencia de stock, consumido tanto desde el inventario de una sucursal como desde el módulo de Stock principal

### Requirement: El error de venta por falta de stock en la sucursal ofrece el camino a la transferencia

El sistema SHALL ofrecer, junto al aviso de error de una venta rechazada por falta de stock en la sucursal, un **camino directo** a la transferencia de stock del producto involucrado.

El aviso ya explica que puede haber unidades en otra sucursal y que conviene revisar el stock por sucursal, pero deja al usuario buscando dónde se hace eso. Ese es exactamente el momento en que la transferencia le resuelve el problema, y exactamente el momento en que hoy no la encuentra.

El texto del aviso SHALL seguir sin ocultar el error original cuando no lo reconoce, y la traducción existente SHALL extenderse en lugar de duplicarse.

#### Scenario: Venta rechazada por falta de stock en la sucursal

- **GIVEN** un producto con unidades en otra sucursal y ninguna en la sucursal de la venta
- **WHEN** el usuario intenta registrar la venta
- **THEN** el aviso explica que puede haber unidades en otra sucursal y ofrece una acción que lleva a transferir stock de ese producto

#### Scenario: Un error no reconocido se sigue mostrando tal cual

- **GIVEN** una venta que falla por un motivo que la traducción no reconoce
- **WHEN** el usuario intenta registrarla
- **THEN** el aviso muestra el mensaje original sin ocultarlo y sin ofrecer la acción de transferir

### Requirement: Desglose por sucursal en el listado de stock

El sistema SHALL mostrar, en el listado principal de `/stock`, el total agregado de cada producto y permitir desplegar por fila las existencias de cada sucursal con su cantidad, su mínimo y su estado, leídas del ledger canónico (`branch_stock`), sin recalcular el predicado de criticidad.

Cierra OQ-5 de `sucursal-guard-vaciado-auditoria`: el listado sólo mostraba el agregado del catálogo (`SUM(branch_stock.quantity)`), lo mismo que hizo invisible el incidente del 22-08 (una sucursal se vació sin que nadie viera qué se estaba perdiendo en esa sucursal en particular). El despliegue es opcional por fila (colapsado por defecto) y se monta perezosamente — la consulta del desglose de una fila no corre hasta que el usuario la despliega.

#### Scenario: El listado muestra el total y ofrece desplegar el desglose

- **GIVEN** un producto con existencias en dos sucursales
- **WHEN** un usuario abre el listado de `/stock`
- **THEN** la fila del producto muestra el total agregado y ofrece una acción para desplegar el desglose por sucursal

#### Scenario: Desplegar una fila muestra cantidad, mínimo y estado por sucursal

- **GIVEN** un producto con 2 unidades y `min_stock = 5` en la sucursal A, y 40 unidades y `min_stock = 5` en la sucursal B
- **WHEN** el usuario despliega el desglose de ese producto
- **THEN** ve ambas sucursales con su cantidad y su mínimo, la sucursal A con estado "Crítico" y la sucursal B con estado "OK", usando el mismo semáforo que la columna "Estado" del listado

#### Scenario: Una sucursal sin umbral configurado nunca se muestra "Crítico"

- **GIVEN** una fila `branch_stock` con `min_stock = 0`
- **WHEN** el usuario despliega el desglose del producto
- **THEN** esa sucursal se muestra "Sin mínimo", nunca "Crítico" (mismo predicado canónico de `lib/product-stock.ts`, `min_stock <= 0` = sin umbral)

#### Scenario: El desglose no se consulta hasta que la fila se despliega

- **GIVEN** un listado con productos sin ninguna fila desplegada
- **WHEN** la página termina de renderizar
- **THEN** no se dispara ninguna consulta de desglose por sucursal para esos productos; sólo se dispara al desplegar una fila puntual

### Requirement: El umbral de stock mínimo admite fracciones en la unidad base del producto

`branch_stock.min_stock` SHALL tener la misma precisión que `branch_stock.quantity` (`numeric(15,4)`) y expresarse en la unidad base del producto. La propagación del mínimo desde el producto a todas sus sucursales, el trigger de alerta de stock bajo y el cálculo canónico de stock crítico SHALL evaluar el umbral sin truncarlo a entero. El backend SHALL aceptar un mínimo fraccionario no negativo en el alta y la edición del producto y SHALL rechazar un mínimo negativo con error de validación. Para productos llevados por unidad el comportamiento SHALL ser indistinguible del vigente: un mínimo entero sigue siendo entero.

#### Scenario: un mínimo de medio kilo dispara la alerta

- **GIVEN** un producto con unidad base Kilogramo, `branch_stock.quantity = 0.6` y el owner edita "Stock Mínimo" a `0.5`
- **WHEN** una venta reduce la cantidad a `0.45`
- **THEN** `branch_stock.min_stock` es `0.5` en todas las sucursales del producto y se inserta la alerta `low_branch_stock_alert` para esa sucursal

#### Scenario: el mínimo fraccionario no se redondea en ninguna capa

- **WHEN** se guarda un producto con mínimo `0.5` desde el formulario
- **THEN** la respuesta de la API y el listado de stock devuelven `0.5`, no `0` ni `1`

#### Scenario: el mínimo negativo se rechaza

- **WHEN** se intenta guardar un producto con mínimo `-1`
- **THEN** la API responde con error de validación y ninguna fila de `branch_stock` cambia

#### Scenario: el mínimo entero de un producto por unidad no cambia

- **GIVEN** un producto sin unidad base con mínimo `5`
- **WHEN** corre la migración y luego se vuelve a propagar el mínimo
- **THEN** `branch_stock.min_stock` sigue siendo `5` y la alerta se comporta igual que antes

### Requirement: Núcleo único de ajuste manual de stock

El sistema SHALL tener **un solo núcleo** de ajuste manual de stock, interno (sin `EXECUTE` para `anon` ni `authenticated`), y SHALL ser el único camino por el que un usuario cambia el saldo de un producto a mano. Las RPCs públicas `rpc_stock_adjustment` (modal y CSV de `/stock`), `rpc_adjust_branch_stock` (inventario por sucursal) y `rpc_apply_product_stock_delta` (stock inicial del alta de producto) SHALL ser envoltorios de ese núcleo que conservan su firma y la forma de su respuesta.

El núcleo SHALL, en este orden y antes de escribir nada:

1. resolver la **tenencia por `products.account_id`**: el producto SHALL pertenecer a una cuenta del usuario (`current_account_ids()`); si no, `P0404` sin revelar si existe. La tenencia por `products.user_id` SHALL dejar de usarse;
2. exigir el **rol en la base**: `is_account_writer` de esa cuenta (`P0401`) y al menos un rol activo en `{owner, admin, stock}` (`P0403 insufficient_role`);
3. exigir un **motivo no vacío** tras recortar espacios (`P0400 stock_adjustment_reason_required`);
4. aceptar sólo los tipos de ajuste manual `adjustment`, `physical_count`, `loss`, `damage` y `expiry` (`P0400 stock_adjustment_type_invalid`); `loss`, `damage` y `expiry` SHALL sólo restar;
5. rechazar el ajuste de un producto padre `variant_only` o `untracked` (RN-20);
6. rechazar un resultado negativo en la sucursal afectada (`P0409`).

Todo ajuste aceptado SHALL dejar **exactamente un** movimiento con `account_id`, `branch_id`, `user_id`, `performed_by`, `reason` y `quantity_after = quantity_before + quantity_delta` expresados sobre la **sucursal** afectada. Un `CHECK` sobre `stock_movements` SHALL rechazar, por cualquier camino, una fila de tipo de ajuste manual sin motivo; las filas históricas sin motivo SHALL conservarse sin reescribir.

Los parámetros internos de `rpc_apply_product_stock_delta` —`p_log_movement = false` (cambiar el saldo sin movimiento) y `p_allow_negative = true` (piso en cero)— SHALL NOT ser alcanzables desde `authenticated`: el envoltorio SHALL rechazarlos con `P0400`.

#### Scenario: Los tres envoltorios exigen el mismo rol

- **GIVEN** un miembro cuyo único rol activo es `seller`
- **WHEN** llama a `rpc_stock_adjustment`, a `rpc_adjust_branch_stock` o a `rpc_apply_product_stock_delta` sobre un producto de su cuenta, con motivo
- **THEN** las tres retornan `P0403 insufficient_role` y ninguna cambia `branch_stock` ni inserta movimiento

#### Scenario: Los tres envoltorios exigen motivo

- **GIVEN** un owner
- **WHEN** llama a cualquiera de los tres envoltorios con motivo nulo o en blanco
- **THEN** los tres retornan `P0400 stock_adjustment_reason_required` y ninguno escribe

#### Scenario: El modal de /stock sella cuenta, sucursal y autor

- **GIVEN** un miembro con rol `stock` y un producto de su cuenta
- **WHEN** registra una pérdida de 2 unidades con motivo `"rotura en depósito"` vía `rpc_stock_adjustment`
- **THEN** se inserta un movimiento `type='loss'`, `quantity_delta=-2`, con `account_id` de la cuenta, `branch_id` de la sucursal afectada, `performed_by` = el miembro y el motivo persistido, visible en el historial bajo RLS

#### Scenario: Un miembro que no creó el producto puede ajustarlo

- **GIVEN** una cuenta con dos miembros, y un producto creado por el primero
- **WHEN** el segundo, con rol `admin`, lo ajusta con motivo
- **THEN** el ajuste se aplica (la tenencia es por cuenta, no por `products.user_id`)

#### Scenario: Cambiar el saldo sin movimiento ya no es alcanzable

- **WHEN** un owner llama a `rpc_apply_product_stock_delta(..., p_log_movement => false)` o con `p_allow_negative => true`
- **THEN** la RPC retorna `P0400` y no cambia el saldo

#### Scenario: El stock inicial del alta de producto sigue funcionando

- **GIVEN** un owner que crea un producto con 12 unidades de stock inicial
- **WHEN** el backend llama a `rpc_apply_product_stock_delta(producto, 12, NULL, 'Stock inicial', true, false)`
- **THEN** el saldo de la sucursal operativa por defecto queda en 12 y se inserta un movimiento `adjustment` con motivo `"Stock inicial"`, cuenta, sucursal y autor

#### Scenario: Un padre variant_only no se ajusta por ningún camino

- **WHEN** un owner intenta ajustar un producto padre `variant_only` por cualquiera de los tres envoltorios
- **THEN** la operación es rechazada y no se crea saldo para el padre

#### Scenario: El CHECK de motivo rechaza filas sin motivo aunque vengan de una función interna

- **WHEN** cualquier escritor, incluso uno `SECURITY DEFINER`, inserta un movimiento `adjustment`, `physical_count`, `loss`, `damage` o `expiry` con `reason` nulo o en blanco
- **THEN** la inserción falla por el `CHECK` y no queda ninguna fila

#### Scenario: Los movimientos históricos sin motivo no se reescriben

- **WHEN** se aplica la migración del `CHECK`
- **THEN** las filas de ajuste manual anteriores sin motivo conservan su contenido y la migración no falla por ellas

### Requirement: La superficie de ajuste manual se ofrece sólo a quien puede ajustar y exige el motivo

El sistema SHALL mostrar las acciones de ajuste manual de stock únicamente a los miembros con un rol activo en `CAN_STOCK` (`owner`, `admin`, `stock`), decidido sobre el **conjunto** de roles activos (`useOrgRole().roles`) con el espejo `CAN_STOCK` de `frontend/lib/rbac-capabilities.ts`, atado por test a `backend/core/rbac.py` y al conjunto que exige la base. Mientras el conjunto de roles no resolvió, la decisión SHALL ser optimista (la barrera real es la base). Aplica a: el botón "Ajustar stock" y la acción por fila de `/stock`, el botón "Importar ajuste" de `/stock`, la acción de ajuste de `/sucursales/[id]/stock` y el acceso al ajuste desde el formulario de producto. La transferencia entre sucursales conserva su propia condición de visibilidad.

Todo formulario de ajuste SHALL exigir un motivo no vacío antes de enviar: el modal de `/stock`, el diálogo de ajuste por sucursal y el importador CSV de ajustes, en el que la columna "Motivo" SHALL ser obligatoria (encabezado ausente o celda vacía = error bloqueante de esa fila). Los rechazos del servidor por rol, motivo, tipo o stock insuficiente SHALL mostrarse en castellano accionable a través del mapa canónico `lib/operation-errors.ts`, sin exponer códigos ni identificadores.

La superficie SHALL verificarse en desktop y mobile y en tema claro y oscuro.

#### Scenario: Un vendedor no ve las acciones de ajuste

- **GIVEN** un miembro cuyo único rol activo es `seller`
- **WHEN** abre `/stock`
- **THEN** no ve "Ajustar stock", la acción de ajuste por fila ni "Importar ajuste", y sigue viendo el listado

#### Scenario: El rol de depósito ve y usa el ajuste

- **GIVEN** un miembro con rol `stock`
- **WHEN** abre `/stock`
- **THEN** ve las acciones de ajuste y puede registrar un ajuste con motivo

#### Scenario: El modal no envía sin motivo

- **WHEN** un usuario con permiso completa producto y cantidad en el modal de `/stock` y deja el motivo vacío o en blanco
- **THEN** el modal muestra que el motivo es obligatorio y no llama al servidor

#### Scenario: El CSV sin motivo bloquea la fila

- **WHEN** un usuario importa un CSV de ajustes con una fila sin motivo
- **THEN** esa fila queda marcada como error bloqueante con el texto "Falta el motivo" y no se aplica

#### Scenario: Un rechazo de rol del servidor se explica en castellano

- **GIVEN** un miembro con un rol que no ajusta stock y una pestaña abierta antes de perder el rol
- **WHEN** intenta un ajuste y la base responde `insufficient_role`
- **THEN** ve un mensaje que explica que su rol no permite ajustar stock a mano y quién puede asignarle el rol, sin el código crudo

### Requirement: El formulario de producto no edita el stock

El sistema SHALL tratar el formulario de producto así: en el **alta**, el campo "Stock inicial" SHALL ofrecerse sólo a quien puede ajustar stock (`CAN_STOCK`) y sólo para productos con control de stock propio (nunca para un padre `variant_only`); su valor viaja como stock inicial y el backend lo registra con el motivo fijo "Stock inicial" sin pedir otro. En la **edición**, el formulario SHALL mostrar el stock actual en sólo lectura y, a quien puede ajustar, una acción "Ajustar stock" que abre el modal de ajuste existente con el producto preseleccionado; la edición SHALL NOT enviar `stock`.

`POST /products` con stock inicial distinto de cero SHALL exigir `CAN_STOCK` **antes** de escribir nada (403 RFC 7807, el producto no se crea). `PUT /products/{id}` SHALL NOT ajustar stock: si el cuerpo trae un `stock` distinto del saldo actual, SHALL responder `422` con código `stock_adjust_required` sin escribir; si trae el mismo valor, SHALL ignorarlo.

#### Scenario: El alta con stock inicial queda registrada con su motivo fijo

- **GIVEN** un owner
- **WHEN** crea un producto con stock inicial 5
- **THEN** el producto se crea, el saldo queda en 5 y el movimiento lleva motivo `"Stock inicial"`

#### Scenario: Un vendedor no carga stock inicial

- **GIVEN** un miembro con rol `seller`
- **WHEN** abre el alta de producto
- **THEN** no ve el campo "Stock inicial"; y si un cliente envía igual `stock = 5` a `POST /products`, la respuesta es 403 y el producto no se crea

#### Scenario: La edición deriva al modal de ajuste

- **GIVEN** un owner que edita un producto con 10 unidades
- **WHEN** abre el formulario de edición
- **THEN** ve "Stock actual: 10" en sólo lectura y una acción "Ajustar stock" que abre el modal con ese producto preseleccionado, que exige motivo

#### Scenario: Guardar la edición no toca el stock

- **GIVEN** un producto con 10 unidades y un formulario de edición abierto, y una venta posterior que deja el saldo en 8
- **WHEN** el usuario cambia el precio y guarda
- **THEN** el saldo sigue en 8 y no se inserta ningún movimiento de ajuste

#### Scenario: Un cliente viejo que envía otro stock por PUT es rechazado

- **WHEN** un cliente envía `PUT /products/{id}` con `stock` distinto del saldo actual
- **THEN** la respuesta es `422` con código `stock_adjust_required`, ningún campo del producto se escribe y el saldo no cambia

