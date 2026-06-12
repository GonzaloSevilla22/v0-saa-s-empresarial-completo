# branch-stock — Spec (stock-multisucursal)

## Purpose

Inventario de stock por sucursal. Mantiene el ledger por combinación `(product_id, branch_id)` en la tabla `branch_stock` — desde C-21, **único ledger de inventario del sistema** — con ajuste manual, transferencias entre sucursales, alertas de stock bajo y página de inventario por sucursal. La gestión multi-sucursal es exclusiva del plan PRO.
## Requirements
### Requirement: Ledger de stock por sucursal (branch_stock)
El sistema SHALL mantener el inventario por combinación `(product_id, branch_id)` en `branch_stock` como **única fuente de verdad** del stock. Toda operación (venta o compra) SHALL afectar `branch_stock.quantity` de su `branch_id` — incluida la branch por defecto ("Casa Central"/"Principal") cuando la cuenta opera con una sola sucursal. La columna `products.stock` SHALL NOT mutarse por operaciones de stock (el dual-ledger queda retirado por C-21); el stock total de un producto es `SUM(branch_stock.quantity)`.

#### Scenario: Venta descuenta de branch_stock
- **GIVEN** un producto con 10 unidades en `branch_stock` de la sucursal A
- **WHEN** se registra una venta de 3 unidades en la sucursal A
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=A)` pasa a 7 y no se modifica ninguna columna de `products`

#### Scenario: Venta falla si stock insuficiente (gate global)
- **GIVEN** un producto con `SUM(branch_stock.quantity) = 2` en toda la cuenta
- **WHEN** se registra una venta de 5 unidades
- **THEN** la RPC retorna error `Insufficient stock` y no inserta ninguna fila

#### Scenario: Venta en sucursal sin stock local no se bloquea (gate global, decisión PO C-21)
- **GIVEN** un producto con 10 unidades en la branch por defecto y 0 en la sucursal B
- **WHEN** se registra una venta de 2 unidades en la sucursal B
- **THEN** la venta procede (el gate es `SUM(branch_stock)`); `branch_stock` de B queda en −2 transitorio y la suma global se preserva (se regulariza con transferencia)

#### Scenario: Compra incrementa branch_stock
- **GIVEN** un producto con 0 unidades en `branch_stock` de la sucursal B (o sin fila aún)
- **WHEN** se registra una compra de 20 unidades en la sucursal B
- **THEN** `branch_stock.quantity` para `(product_id, branch_id=B)` pasa a 20 (fila creada si no existía)

#### Scenario: Operación sobre la branch por defecto afecta branch_stock, no products.stock
- **GIVEN** una cuenta con una sola sucursal (branch por defecto) y un producto con 10 unidades en `branch_stock`
- **WHEN** se registra una venta de 2 unidades
- **THEN** `branch_stock` de la branch por defecto pasa a 8 y la columna `products.stock` no participa (es la única verdad `branch_stock`)

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

