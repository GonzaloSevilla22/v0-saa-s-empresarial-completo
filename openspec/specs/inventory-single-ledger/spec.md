# inventory-single-ledger Specification

## Purpose
TBD - created by archiving change v20-inventory-unification. Update Purpose after archive.
## Requirements
### Requirement: Branch por defecto por cuenta
El sistema SHALL garantizar que toda cuenta (`account_id`) tenga al menos una branch. Las cuentas que ya tienen una branch (hoy llamada "Principal") la conservan como branch por defecto. Para cada cuenta sin ninguna branch, el sistema SHALL crear una branch "Casa Central". La creación MUST ser idempotente: re-ejecutarla no crea branches duplicadas.

#### Scenario: cuenta sin branch obtiene una Casa Central
- **WHEN** corre la migración de unificación y una cuenta no tiene ninguna fila en `branches`
- **THEN** se inserta exactamente una branch para esa cuenta con `name = 'Casa Central'` y `is_active = true`

#### Scenario: cuenta con branch existente no recibe una segunda
- **WHEN** corre la migración y una cuenta ya tiene una branch "Principal"
- **THEN** no se crea ninguna branch nueva para esa cuenta y "Principal" actúa como branch por defecto

#### Scenario: la creación de branch por defecto es idempotente
- **WHEN** la migración de creación de branches se ejecuta dos veces seguidas
- **THEN** el número de branches por cuenta es el mismo que tras la primera ejecución, sin duplicados

### Requirement: branch_stock como única fuente de verdad del stock
El sistema SHALL tratar `branch_stock` por `(product_id, branch_id)` como la única fuente de verdad del stock de un producto. El stock total de un producto SHALL ser `SUM(branch_stock.quantity)` sobre todas sus branches. La columna `products.stock` SHALL dejar de ser fuente de verdad y SHALL retirarse como paso final controlado.

#### Scenario: el stock total de un producto es la suma de sus filas branch_stock
- **WHEN** un producto tiene 7 unidades en la branch A y 3 en la branch B
- **THEN** su stock total reportado es 10 (`SUM(branch_stock.quantity)`)

#### Scenario: una venta en una sucursal no afecta el stock de otra
- **GIVEN** un producto con 10 unidades en la branch A y 5 en la branch B
- **WHEN** se registra una venta de 4 unidades en la branch A
- **THEN** `branch_stock` de A pasa a 6, el de B permanece en 5 y el total pasa a 11

### Requirement: Reconciliación de products.stock hacia branch_stock antes del corte de lectura
El sistema SHALL reconciliar, de forma idempotente, el stock visible histórico (`products.stock`) hacia `branch_stock` **antes** de cambiar la fuente de lectura, de modo que `SUM(branch_stock.quantity)` reproduzca el `products.stock` actual de cada producto no borrado. Para un producto sin fila en `branch_stock` cuyo `products.stock > 0`, el sistema SHALL materializar ese stock en `branch_stock` contra la branch por defecto de la cuenta del producto. La reconciliación MUST ser re-ejecutable sin alterar el resultado convergente.

#### Scenario: producto con products.stock y sin branch_stock se materializa en la branch por defecto
- **GIVEN** un producto con `products.stock = 12` y ninguna fila en `branch_stock`
- **WHEN** corre la reconciliación
- **THEN** existe una fila `branch_stock` para `(product, branch por defecto)` con `quantity = 12` y `SUM(branch_stock) = products.stock`

#### Scenario: la reconciliación deja el total igual al stock visible para todo producto
- **WHEN** termina la reconciliación
- **THEN** no existe ningún producto no borrado con `products.stock <> COALESCE(SUM(branch_stock.quantity), 0)` (gate de validación = 0 divergencias)

#### Scenario: re-ejecutar la reconciliación no cambia el resultado
- **WHEN** la migración de reconciliación se ejecuta dos veces seguidas
- **THEN** el `SUM(branch_stock.quantity)` por producto es idéntico tras la segunda corrida

### Requirement: Vista de compatibilidad de stock total con security_invoker
El sistema SHALL exponer una vista `v_products_with_stock` que reconstruye el stock total de cada producto como `COALESCE(SUM(branch_stock.quantity), 0)`, para los consumidores que aún leen el stock como un escalar del producto. La vista MUST declararse `WITH (security_invoker = true)` para no bypassar RLS. La vista SHALL conservarse tras el retiro de `products.stock`.

#### Scenario: la vista respeta RLS por cuenta
- **WHEN** un usuario consulta `v_products_with_stock`
- **THEN** solo ve los productos y el stock de su propia cuenta (`account_id`), idéntico a consultar `products` directamente

#### Scenario: la vista expone el total desde branch_stock
- **WHEN** se consulta `v_products_with_stock` para un producto con 6 y 4 unidades en dos branches
- **THEN** el stock total expuesto es 10, calculado desde `branch_stock`, no desde la columna `products.stock`

#### Scenario: la vista sobrevive al DROP de products.stock
- **WHEN** se elimina la columna `products.stock`
- **THEN** `v_products_with_stock` sigue devolviendo el stock total correcto, computado desde `branch_stock`

### Requirement: Lecturas de stock migradas a branch_stock
El sistema SHALL leer el stock desde `branch_stock` (suma por `account_id`/`product_id`) en el backend y desde `v_products_with_stock` (o el hook que la consume) en el frontend, no desde la columna `products.stock`. El backend `StockRepository` MUST filtrar por `account_id` (no por `user_id`). El importador de CSV MUST escribir el stock en `branch_stock` contra la branch por defecto, no en `products.stock`.

#### Scenario: el repositorio de stock suma branch_stock por account_id
- **WHEN** el backend consulta el stock de un producto
- **THEN** el valor proviene de `SUM(branch_stock.quantity) WHERE product_id = $1 AND account_id = $2`, no de `SELECT stock FROM products`

#### Scenario: el hook de productos expone el stock desde la vista
- **WHEN** `use-products` carga el catálogo
- **THEN** el campo `stock` de cada producto proviene de `v_products_with_stock` (`SUM(branch_stock)`), no de la columna `products.stock`

#### Scenario: el importador de CSV escribe en branch_stock
- **WHEN** se importa un producto con stock inicial 25 vía CSV
- **THEN** se crea/actualiza una fila en `branch_stock` para `(producto, branch por defecto)` con `quantity = 25`

### Requirement: Verificación y descarte del sistema de inventario legacy
El sistema SHALL eliminar las tablas `inventory_stock`, `inventory_movements` y `warehouses` (Sistema B legacy) únicamente tras verificar, con una consulta reproducible, que (a) sus filas de stock ya están representadas en `branch_stock` o cubiertas por la reconciliación, y (b) ninguna función o vista del schema las referencia. Estas tablas MUST NOT migrarse mediante INSERT a `branch_stock` (sus filas ya existen y pueden estar desactualizadas). El DROP es **BREAKING** y MUST ejecutarse en una migración separada sujeta a aprobación explícita.

#### Scenario: el descarte se bloquea si algo todavía referencia las tablas legacy
- **WHEN** la verificación previa al DROP detecta que una función o vista referencia `inventory_stock`, `inventory_movements` o `warehouses`
- **THEN** la verificación falla y el DROP no se aplica

#### Scenario: los warehouses no se convierten en branches
- **WHEN** se procesa el Sistema B legacy
- **THEN** las 6 filas de `warehouses` ("Main Warehouse" auto-generadas) se descartan con el DROP y no se crea ninguna branch a partir de ellas (PA-19)

### Requirement: Retiro de products.stock como paso final controlado
El sistema SHALL eliminar la columna `products.stock` únicamente como último paso, tras validar que la reconciliación dejó `SUM(branch_stock) = products.stock` para todo producto y que ningún consumidor (función, vista o código) lee la columna. Esta remoción es **BREAKING** y MUST ejecutarse en una migración separada con SQL de rollback documentado (recrear la columna y recomputar desde `branch_stock`), sujeta a aprobación explícita.

#### Scenario: el DROP de products.stock se bloquea si algo todavía la lee
- **WHEN** la verificación previa al DROP detecta una función o vista (fuera de la lista esperada) que referencia `products.stock`
- **THEN** la verificación falla y el DROP no se aplica

#### Scenario: el ledger stock_movements no se ve afectado por el DROP
- **WHEN** se elimina `products.stock`
- **THEN** `stock_movements` permanece intacto (DEC-07) y el stock total se sigue calculando desde `branch_stock`

#### Scenario: rollback del DROP recompone el stock desde branch_stock
- **WHEN** se ejecuta el SQL de rollback de la migración destructiva
- **THEN** la columna `products.stock` se recrea y se repuebla con `COALESCE(SUM(branch_stock.quantity), 0)` por producto

