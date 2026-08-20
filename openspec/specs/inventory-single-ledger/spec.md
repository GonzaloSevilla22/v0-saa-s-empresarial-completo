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

### Requirement: Toda mutación de stock por edición de operación deja rastro espejo en el ledger

La edición de una operación de venta o compra SHALL registrar en `stock_movements` las **dos** patas que ya ejecuta contra `branch_stock` — la reversa de la operación vieja y la aplicación de la nueva — dentro de la misma transacción que las aplica. NO SHALL registrarse un único movimiento neto: el kardex SHALL poder leerse como la secuencia real de hechos (se devolvió lo anterior, se aplicó lo nuevo), que es la semántica que consume el panel de movimientos y la única que permite auditar una edición sin reconstruirla.

La pata de reversa SHALL escribirse con `type = 'sale_return'` (venta) o `'purchase_return'` (compra), `reference_id` = id de la fila vieja y `reference_type = 'sale_update'` / `'purchase_update'` — un `reference_type` propio que distingue "revertido por edición" de "revertido por eliminación" (`sale_reversal` / `purchase_reversal`) sin leer texto libre.

La pata de aplicación SHALL escribirse con `type = 'sale'` / `'purchase'`, `reference_id` = id de la fila **nueva** y `reference_type = 'sale'` / `'purchase'`, es decir **indistinguible del movimiento que emite la creación**. Esto es normativo, no cosmético: es el contrato del que depende la reversa de stock al eliminar.

Cada pata SHALL aplicarse sobre una sucursal explícita, nunca sobre la sucursal default por omisión: la **reversa** SHALL aplicarse sobre la sucursal a la que estaba imputada la operación vieja, y la **aplicación** sobre la sucursal efectiva de la operación editada — la reimputada si la edición informó una sucursal nueva, o la preservada de la operación vieja si no la informó. Editar una operación sin cambiarle la sucursal NO SHALL mover stock entre sucursales. Editar una operación reimputándola a otra sucursal SHALL producir dos patas en sucursales distintas, que describen el traslado.

Cada movimiento emitido por la edición SHALL poblar `quantity_before`, `quantity_after`, `branch_id`, `product_name` y `operation_group_id` con la misma forma que la creación, y SHALL congelar `unit_cost_snapshot` **reusando la decisión de acarreo de snapshot de la línea** (acarrea el costo viejo si el producto no cambió; congela uno fresco si cambió o si no había línea previa). Corregir una cantidad NO SHALL re-valuar el movimiento al costo actual del producto.

Una línea sin `product_id` (línea de servicio) NO SHALL emitir movimiento, ni en la reversa ni en la aplicación.

#### Scenario: editar la cantidad de una venta deja el par espejo en el ledger

- **GIVEN** una venta de 5 unidades de un producto, con su movimiento `type='sale'`, `reference_type='sale'`, `quantity_delta = -5`
- **WHEN** se edita la operación a 3 unidades del mismo producto
- **THEN** el ledger suma dos filas nuevas: `type='sale_return'` / `reference_type='sale_update'` / `quantity_delta = +5` apuntando al id viejo, y `type='sale'` / `reference_type='sale'` / `quantity_delta = -3` apuntando al id nuevo
- **AND** `branch_stock` del producto refleja exactamente `+5 - 3 = +2` respecto del estado previo a la edición

#### Scenario: editar reemplazando el producto mueve el ledger de ambos productos

- **GIVEN** una venta de 2 unidades del producto A
- **WHEN** se edita la operación para que sea de 2 unidades del producto B
- **THEN** el producto A recibe un movimiento `sale_return` de `+2` (`reference_type='sale_update'`) y el producto B un movimiento `sale` de `-2` (`reference_type='sale'`), ambos en la misma transacción

#### Scenario: la edición no re-valúa el costo congelado del movimiento

- **GIVEN** una venta de un producto creada cuando `products.cost = 600`, y `products.cost` movido a 900 después
- **WHEN** se edita la cantidad de esa venta sin cambiar el producto
- **THEN** el movimiento emitido por la pata de aplicación tiene `unit_cost_snapshot = 600`, no 900

#### Scenario: editar una compra emite el par espejo con los signos invertidos

- **GIVEN** una compra de 10 unidades con su movimiento `type='purchase'`, `quantity_delta = +10`
- **WHEN** se edita la operación a 4 unidades
- **THEN** el ledger suma `type='purchase_return'` / `reference_type='purchase_update'` / `quantity_delta = -10` sobre el id viejo, y `type='purchase'` / `reference_type='purchase'` / `quantity_delta = +4` sobre el id nuevo

#### Scenario: una línea de servicio editada no toca el ledger

- **GIVEN** una operación con una línea sin `product_id`
- **WHEN** se edita esa operación
- **THEN** no se inserta ninguna fila en `stock_movements` por esa línea, y la edición procede sin error

#### Scenario: editar una venta de una sucursal no default no muda el stock

- **GIVEN** una venta imputada a una sucursal distinta de la default, y una cuenta con varias sucursales con stock
- **WHEN** se edita la cantidad de esa venta sin informar sucursal
- **THEN** ambas patas del par espejo se registran sobre la sucursal original
- **AND** el stock de la sucursal default no se modifica

#### Scenario: reimputar la sucursal produce un par espejo entre sucursales

- **GIVEN** una venta imputada a la sucursal A
- **WHEN** se edita la operación reimputándola a la sucursal B
- **THEN** la pata de reversa se registra sobre la sucursal A y la de aplicación sobre la sucursal B, y `branch_stock` de ambas refleja el traslado

### Requirement: Invariante de reconstrucción y de no-orfandad del ledger de operaciones

Para toda operación de venta o compra creada, editada o eliminada, la suma de `quantity_delta` de los movimientos de `stock_movements` asociados a esa operación, agrupada por `(product_id, branch_id)`, SHALL ser igual al delta neto aplicado a `branch_stock.quantity` para ese par en la misma transacción. Ninguna ruta de escritura de operaciones SHALL mover `branch_stock` sin dejar el movimiento correspondiente.

Toda fila viva de `sales` / `purchases` con `product_id` NO NULO SHALL tener al menos un movimiento con `reference_id` = su id y `reference_type = 'sale'` / `'purchase'`. Recíprocamente, hacia adelante, ningún movimiento con `reference_type = 'sale'` / `'purchase'` SHALL quedar apuntando a una fila inexistente **sin** que exista para ese mismo `reference_id` un contramovimiento (`sale_reversal` / `purchase_reversal` para la eliminación, `sale_update` / `purchase_update` para la edición) que cierre el par.

Los `reference_type` de cierre (`*_reversal`, `*_update`) SHALL quedar excluidos de la verificación de no-orfandad: apuntan por diseño a filas que la misma transacción elimina. El ledger es append-only (RN-21), de modo que estas invariantes SHALL verificarse como gate de comportamiento sobre datos sintéticos y NO como aserción retroactiva sobre el historial de producción, cuyo desvío previo a este change queda documentado y acotado.

#### Scenario: crear, editar y eliminar reconstruye el stock desde el ledger

- **GIVEN** un producto con stock inicial conocido en una sucursal
- **WHEN** se crea una venta, se la edita y luego se la elimina
- **THEN** la suma de `quantity_delta` de todos los movimientos de esa secuencia para `(product_id, branch_id)` es igual al cambio total de `branch_stock.quantity`, y el stock final iguala al inicial

#### Scenario: eliminar una operación editada no deja huérfanos abiertos

- **GIVEN** una operación de venta ya editada al menos una vez
- **WHEN** se la elimina
- **THEN** todo movimiento `reference_type='sale'` que quede apuntando a una fila inexistente tiene su contramovimiento de cierre para el mismo `reference_id`, y el conteo de huérfanos sin cierre generados por la secuencia es cero

#### Scenario: ninguna ruta mueve branch_stock en silencio

- **WHEN** se ejercita cada ruta de escritura de operaciones (creación v2, creación legacy, POS/C-29, edición, eliminación) sobre anchors sintéticos
- **THEN** cada una que modifica `branch_stock` deja al menos un movimiento en `stock_movements`, y ninguna modifica `branch_stock` sin dejarlo

### Requirement: Reversa de stock al eliminar venta o compra, independiente de la ruta de creación

Al eliminar una venta o una compra, el sistema SHALL revertir el movimiento de stock asociado contra `branch_stock`, de forma independiente de la ruta por la que se creó **o se modificó** la operación (`rpc_create_sale_operation_v2`, ruta legacy con `sale_items_rpc_v2` OFF, ruta C-29 `rpc_quick_sale` / `rpc_confirm_sales_order`, o el resultado de `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`). Los datos de la reversa (`product_id`, `quantity_delta`, `branch_id`) SHALL leerse desde la fila de `stock_movements` que toda ruta de creación **y toda edición** escribe (`reference_id = <sale|purchase>.id`, `reference_type = 'sale'|'purchase'`), y NO desde `sale_items` / `purchase_items`. La reversa SHALL aplicar `-quantity_delta` (signo opuesto al movimiento original) vía `rpc_apply_product_stock_delta` sobre la `branch_id` registrada en el movimiento.

El ledger es append-only: la fila reversada NO SHALL eliminarse ni modificarse. La reversa SHALL expresarse como un **contramovimiento** nuevo (`type = 'sale_return'` / `'purchase_return'`, `reference_type = 'sale_reversal'` / `'purchase_reversal'`, `metadata.reverses_movement_id` apuntando al movimiento original), tal como lo implementa `rpc_reverse_stock_movement`. Cuando la operación no tiene movimiento de stock (línea de servicio sin `product_id`), la eliminación SHALL proceder sin reversa y sin error; cuando la operación **tiene** `product_id`, la ausencia de movimiento de referencia es una violación de invariante, no un caso válido de "sin reversa".

#### Scenario: eliminar una venta creada por la ruta C-29 (POS) repone el stock

- **GIVEN** una venta con `product_id` y `branch_id` creada por `rpc_quick_sale` / `rpc_confirm_sales_order`, con fila en `stock_movements` (`reference_type = 'sale'`, `quantity_delta = -2`) y sin fila en `sale_items`
- **WHEN** se elimina la venta vía `DELETE /sales/{id}`
- **THEN** `branch_stock` de `(product_id, branch_id)` aumenta en 2, se registra el contramovimiento `sale_return` / `sale_reversal`, y la respuesta es exitosa

#### Scenario: eliminar una venta creada por la ruta v2 sigue reponiendo el stock

- **GIVEN** una venta con fila en `sale_items` y fila en `stock_movements` (`quantity_delta = -1`)
- **WHEN** se elimina la venta
- **THEN** `branch_stock` aumenta en 1 y se registra el contramovimiento correspondiente (paridad con el comportamiento previo)

#### Scenario: eliminar una venta previamente EDITADA repone el stock

- **GIVEN** una venta de 3 unidades que fue editada a 2 unidades (la edición regeneró el id de la fila y emitió su movimiento `reference_type='sale'` sobre el id nuevo)
- **WHEN** se elimina la venta resultante
- **THEN** `branch_stock` de `(product_id, branch_id)` aumenta en 2 y se registra el contramovimiento — la eliminación NO queda sin efecto sobre el stock por el hecho de que la operación haya sido editada

#### Scenario: eliminar una operación completa repone el stock de todas sus líneas con producto

- **GIVEN** una operación de venta con varias filas `sales`, cada una con su `stock_movements`, creada por cualquier ruta
- **WHEN** se elimina vía `DELETE /sales?operation_id=<id>`
- **THEN** cada línea con `product_id` repone su `quantity_delta` en la `branch_id` de su movimiento y cada una registra su contramovimiento

#### Scenario: eliminar una línea de servicio sin producto no intenta reversa

- **GIVEN** una venta sin `product_id` (línea de servicio) y sin fila en `stock_movements`
- **WHEN** se elimina la venta
- **THEN** la eliminación procede sin reversa de stock y sin error

#### Scenario: eliminar una compra repone el stock por la ruta espejo

- **GIVEN** una compra con `product_id` y fila en `stock_movements` (`reference_type = 'purchase'`, `quantity_delta > 0`, una entrada de stock)
- **WHEN** se elimina la compra
- **THEN** `branch_stock` de `(product_id, branch_id)` se decrementa en `quantity_delta` (revierte la entrada) y se registra el contramovimiento `purchase_return` / `purchase_reversal`

### Requirement: Costo unitario congelado en stock_movements para valuación

El sistema SHALL agregar `unit_cost_snapshot NUMERIC(15,2)` NULLABLE a `stock_movements` y SHALL congelar el costo unitario del producto al registrar cada movimiento generado por una venta o compra, dentro de la misma transacción que ya escribe `quantity_before`/`quantity_after`. Este costo congelado SHALL habilitar la valuación de inventario histórica sin depender de `products.cost` actual, y SHALL respetar la inmutabilidad del ledger (append-only) ya especificada: el valor se escribe una única vez en el INSERT del movimiento.

#### Scenario: El movimiento generado por una venta congela el costo

- **GIVEN** un producto con `products.cost = 600`
- **WHEN** una venta genera un movimiento `type = 'sale'` en `stock_movements`
- **THEN** el movimiento tiene `unit_cost_snapshot = 600`, escrito en la misma transacción que `quantity_after`, y no se modifica luego

#### Scenario: Movimientos históricos conservan NULL sin romper el ledger

- **WHEN** la migración agrega `unit_cost_snapshot` a `stock_movements`
- **THEN** los movimientos previos quedan con `unit_cost_snapshot = NULL` y el carácter append-only del ledger se mantiene (ni UPDATE ni DELETE)

#### Scenario: La reversa de stock preserva el costo del movimiento original

- **GIVEN** un movimiento de venta con `unit_cost_snapshot = 600`
- **WHEN** se elimina la venta y se genera el contra-movimiento de reversa
- **THEN** el contra-movimiento congela su propio `unit_cost_snapshot` sin alterar el `unit_cost_snapshot` del movimiento original

