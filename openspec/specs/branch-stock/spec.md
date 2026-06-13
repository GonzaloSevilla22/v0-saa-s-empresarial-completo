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

El sistema SHALL generar una alerta cuando `branch_stock.quantity <= branch_stock.min_stock`, independientemente del stock global del producto. La deduplicación garantiza máximo 1 alerta por `(product_id, branch_id)` por 24 horas.

#### Scenario: Stock por debajo del mínimo dispara alerta

- **GIVEN** `branch_stock.min_stock = 5` para el producto X en la sucursal A
- **WHEN** una venta reduce `branch_stock.quantity` a 4
- **THEN** se inserta una fila en `email_logs` con `event_type = 'low_branch_stock_alert'` y los datos de la sucursal

#### Scenario: Segunda alerta en menos de 24h es suprimida

- **GIVEN** ya existe una alerta `low_branch_stock_alert` de hace 2 horas para `(product X, sucursal A)`
- **WHEN** otra venta reduce el stock aún más
- **THEN** NO se inserta una nueva alerta (deduplicación activa)

