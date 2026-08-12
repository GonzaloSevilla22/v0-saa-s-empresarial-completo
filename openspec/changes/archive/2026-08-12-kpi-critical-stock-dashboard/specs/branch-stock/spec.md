## ADDED Requirements

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
