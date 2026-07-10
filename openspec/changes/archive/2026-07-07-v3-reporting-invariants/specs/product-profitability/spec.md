## MODIFIED Requirements

### Requirement: RPC de cálculo de rentabilidad por SKU

El sistema SHALL proveer el RPC `rpc_product_profitability(p_period_days INT DEFAULT 30)` que calcula para cada producto de la cuenta activa: `total_revenue`, `total_cost`, `gross_margin`, `gross_margin_pct`, `units_sold`, `last_sale_date`. El RPC deriva el `account_id` internamente desde `current_account_ids()` — no acepta parámetros de identidad. `total_revenue` SHALL ser la suma del **total de línea** (`COALESCE(total, amount)`) — nunca `amount` solo, que es precio unitario (corrige el margen para líneas con `quantity > 1`). El costo SHALL derivarse del snapshot de costo congelado en la línea (`unit_cost_snapshot`), no del maestro actual (RN-D2), con una cascada de fallback: (1) `unit_cost_snapshot` de la línea cuando está presente; (2) `products.cost` actual sólo cuando el snapshot es NULL (líneas muy antiguas no backfilleadas). Las líneas con `snapshot_backfilled = true` SHALL usar su snapshot aunque sea aproximado, en lugar del maestro actual. La ventana de `p_period_days` SHALL anclarse a la fecha local del tenant (`reporting_local_today()`, RN-D5), no a `CURRENT_DATE` del servidor en UTC. La firma de entrada y las columnas de salida NO cambian.

#### Scenario: RPC calcula margen desde el snapshot de costo de la línea

- **GIVEN** un producto vendido en una línea de 2 unidades a precio unitario $1.000 (`total = 2000`) cuya línea congeló `unit_cost_snapshot = 600` en los últimos 30 días
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el producto aparece con `total_revenue = 2000`, `total_cost = 1200` (snapshot × cantidad, no `products.cost` actual), `gross_margin = 800` y `gross_margin_pct = 40.0`

#### Scenario: El revenue suma totales de línea, no precios unitarios

- **GIVEN** un producto con una única venta de 3 unidades a precio unitario $500 (`amount = 500`, `quantity = 3`, `total = 1500`)
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** `total_revenue = 1500` (no 500) y el margen compara revenue y costo en la misma base (× cantidad)

#### Scenario: Remarcar el maestro no altera el margen histórico

- **GIVEN** una venta cuya línea congeló `unit_cost_snapshot = 600`
- **WHEN** `products.cost` sube a `900` y luego se llama a `rpc_product_profitability(30)`
- **THEN** el `total_cost` del período que contiene esa venta sigue basado en `600`, no en `900`

#### Scenario: Fallback a costo de catálogo cuando la línea no tiene snapshot

- **GIVEN** una venta antigua cuya línea tiene `unit_cost_snapshot = NULL` (no backfilleada), con `products.cost = 50` y `units_sold = 10`
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el `total_cost` de esa línea usa `products.cost` como último recurso (50 × 10 = 500)

#### Scenario: Solo se incluyen productos con al menos una venta en el período

- **GIVEN** la cuenta tiene 20 productos pero solo 12 tuvieron ventas en los últimos 30 días
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** el resultado contiene exactamente 12 productos

#### Scenario: La ventana se ancla a la fecha local del tenant

- **GIVEN** son las 22:00 hora Argentina del 2026-07-15 (01:00 UTC del 16)
- **WHEN** se llama a `rpc_product_profitability(30)`
- **THEN** la ventana de 30 días se calcula desde el 2026-07-15 local, no desde el 2026-07-16 UTC

#### Scenario: Usuario sin cuenta activa no puede llamar al RPC

- **GIVEN** un usuario autenticado sin membership activa
- **WHEN** llama a `rpc_product_profitability(30)`
- **THEN** el RPC lanza excepción con ERRCODE = 'P403'
