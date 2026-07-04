## MODIFIED Requirements

### Requirement: Vista de compatibilidad de stock total con security_invoker

El sistema SHALL exponer una vista `v_products_with_stock` que reconstruye el stock total de cada producto como `COALESCE(SUM(branch_stock.quantity), 0)`, para los consumidores que aún leen el stock como un escalar del producto. La vista MUST declararse `WITH (security_invoker = true)` para no bypassar RLS. La vista SHALL conservarse tras el retiro de `products.stock`. Además, la vista SHALL exponer una columna `min_stock` **derivada de `branch_stock`** (no de `products.min_stock`): dado que la semántica de propagación deja el `min_stock` uniforme entre las filas `branch_stock` de un producto, la vista computa `min_stock` como una subconsulta correlacionada sobre `branch_stock` (p. ej. `MAX(branch_stock.min_stock)`), espejando el patrón de la subconsulta de `stock`. El **nombre** de la columna SHALL seguir siendo `min_stock` para que ningún consumidor de frontend (hook `use-products`, `low-stock-alert.tsx`, tipos) requiera cambios. Con esto, las alertas y KPIs que leen la vista quedan consistentes con el trigger `check_branch_low_stock`, que lee `branch_stock.min_stock`.

#### Scenario: la vista respeta RLS por cuenta
- **WHEN** un usuario consulta `v_products_with_stock`
- **THEN** solo ve los productos y el stock de su propia cuenta (`account_id`), idéntico a consultar `products` directamente

#### Scenario: la vista expone el total desde branch_stock
- **WHEN** se consulta `v_products_with_stock` para un producto con 6 y 4 unidades en dos branches
- **THEN** el stock total expuesto es 10, calculado desde `branch_stock`, no desde la columna `products.stock`

#### Scenario: la vista expone min_stock derivado de branch_stock
- **GIVEN** un producto con `branch_stock.min_stock = 5` en sus filas (uniforme por propagación) y `products.min_stock` con cualquier valor legacy
- **WHEN** se consulta `v_products_with_stock` para ese producto
- **THEN** la columna `min_stock` expuesta es 5 (derivada de `branch_stock`), consistente con el umbral del trigger de alerta

#### Scenario: un producto sin filas branch_stock expone min_stock 0
- **GIVEN** un producto sin ninguna fila en `branch_stock`
- **WHEN** se consulta `v_products_with_stock`
- **THEN** `min_stock` expuesto es 0 (`COALESCE`), sin error

#### Scenario: la vista sobrevive al DROP de products.stock
- **WHEN** se elimina la columna `products.stock`
- **THEN** `v_products_with_stock` sigue devolviendo el stock total correcto, computado desde `branch_stock`
