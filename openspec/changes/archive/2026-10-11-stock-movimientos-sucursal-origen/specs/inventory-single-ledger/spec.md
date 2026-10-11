## MODIFIED Requirements

### Requirement: Reversa de stock al eliminar venta o compra, independiente de la ruta de creación

Al eliminar una venta o una compra, el sistema SHALL revertir el movimiento de stock asociado contra `branch_stock`, de forma independiente de la ruta por la que se creó **o se modificó** la operación (`rpc_create_sale_operation_v2`, ruta legacy con `sale_items_rpc_v2` OFF, ruta C-29 `rpc_quick_sale` / `rpc_confirm_sales_order`, o el resultado de `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`). Los datos de la reversa (`product_id`, `quantity_delta`, `branch_id`) SHALL leerse desde la fila de `stock_movements` que toda ruta de creación **y toda edición** escribe (`reference_id = <sale|purchase>.id`, `reference_type = 'sale'|'purchase'`), y NO desde `sale_items` / `purchase_items`. La reversa SHALL aplicar `-quantity_delta` (signo opuesto al movimiento original) sobre la `branch_id` registrada en el movimiento, salvo la excepción de la sucursal desactivada descrita abajo, a través del **helper interno de aritmética de saldo** (`_stock_apply_delta`: lock del producto, validación de sucursal, piso en cero trazable cuando el stock ya se vendió), y SHALL NOT pasar por la RPC pública de ajuste `rpc_apply_product_stock_delta`, que desde este cambio exige rol y motivo y rechaza los parámetros internos.

**Sucursal desactivada** (`stock-movimientos-sucursal-origen`): cuando la sucursal registrada en el movimiento original está desactivada (`is_active = false`), la reversa NO SHALL aplicarse en ella: una sucursal dada de baja no se lista ni se vende, y el stock que entrara ahí quedaría invisible. La reversa SHALL aplicarse en la sucursal principal operativa vigente de la cuenta (la misma resolución que se usa para un movimiento sin sucursal). Una sucursal **cerrada** pero activa NO es una sucursal desactivada: la reversa sobre ella SHALL seguir rechazándose con `P0422 branch_closed` hasta que se reabra. Un movimiento original sin sucursal SHALL seguir revirtiéndose en la principal vigente. Si la cuenta no tiene ninguna sucursal operativa, la principal vigente puede ser la misma sucursal desactivada: el stock SHALL entrar donde ya entra un movimiento sin sucursal, sin error nuevo, y el contramovimiento SHALL conservar la sucursal original sin `fallback_*` (no hubo respaldo).

El ledger es append-only: la fila reversada NO SHALL eliminarse ni modificarse. La reversa SHALL expresarse como un **contramovimiento** nuevo (`type = 'sale_return'` / `'purchase_return'`, `reference_type = 'sale_reversal'` / `'purchase_reversal'`, `metadata.reverses_movement_id` apuntando al movimiento original), tal como lo implementa `rpc_reverse_stock_movement`. El contramovimiento SHALL registrar en `branch_id` la sucursal del movimiento original, salvo cuando se aplicó en la principal por estar desactivada la original: entonces SHALL registrar la sucursal en la que efectivamente se aplicó, y su `metadata` SHALL incluir también la sucursal original (`fallback_from_branch_id`) y el motivo (`fallback_reason = 'branch_inactive'`). `rpc_reverse_stock_movement` SHALL ser interna: invocable sólo desde las funciones `SECURITY DEFINER` de borrado (`rpc_delete_sale_operation`, `rpc_delete_purchase_operation`), nunca por `anon` ni `authenticated`. Cuando la operación no tiene movimiento de stock (línea de servicio sin `product_id`), la eliminación SHALL proceder sin reversa y sin error; cuando la operación **tiene** `product_id`, la ausencia de movimiento de referencia es una violación de invariante, no un caso válido de "sin reversa".

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

#### Scenario: eliminar una compra ya vendida aplica el piso en cero trazable

- **GIVEN** una compra de 5 unidades de las que ya se vendieron 3 (quedan 2 en la sucursal)
- **WHEN** un usuario con permiso elimina la compra
- **THEN** el saldo queda en 0, se registra el ajuste trazable con motivo `floor_on_purchase_delete` y el contramovimiento `purchase_return` por lo efectivamente aplicado, sin error

#### Scenario: la reversa no es invocable por PostgREST

- **WHEN** un usuario autenticado llama directamente a `rpc_reverse_stock_movement` con el id de una venta propia
- **THEN** la llamada es rechazada por falta de `EXECUTE` y ni el saldo ni el ledger cambian; borrar esa venta por su camino normal sí la revierte

#### Scenario: eliminar una venta cuyo movimiento está en una sucursal desactivada repone en la principal operativa

- **GIVEN** una venta de 2 unidades cuyo movimiento registra la sucursal A, y A fue vaciada y desactivada después; la principal operativa de la cuenta es B
- **WHEN** se elimina la venta
- **THEN** `branch_stock` de B aumenta en 2, A sigue en 0, y el contramovimiento registra `branch_id = B` con `metadata.reverses_movement_id`, `metadata.fallback_from_branch_id = A` y `metadata.fallback_reason = 'branch_inactive'`

#### Scenario: eliminar una compra cuyo movimiento está en una sucursal desactivada descuenta de la principal operativa

- **GIVEN** una compra de 5 unidades cuyo movimiento registra la sucursal A, A fue vaciada y desactivada, y la principal operativa B tiene 3 unidades del producto
- **WHEN** se elimina la compra
- **THEN** B queda en 0 con el ajuste trazable `floor_on_purchase_delete`, A no cambia, y el contramovimiento `purchase_return` registra `branch_id = B` con la sucursal original en `metadata`

#### Scenario: una sucursal cerrada sigue pidiendo reabrirse

- **GIVEN** una venta cuyo movimiento registra la sucursal A, activa pero cerrada
- **WHEN** se intenta eliminar la venta
- **THEN** la eliminación se rechaza con `P0422 branch_closed`, sin cambios en `branch_stock` ni en el ledger

#### Scenario: sin ninguna sucursal operativa no hay respaldo ni error nuevo

- **GIVEN** una venta cuyo movimiento registra la sucursal A, y todas las sucursales de la cuenta están desactivadas
- **WHEN** se elimina la venta
- **THEN** el stock entra en la sucursal más antigua de la cuenta (donde ya entra un movimiento sin sucursal), el contramovimiento conserva `branch_id = A` y su `metadata` NO trae `fallback_from_branch_id` ni `fallback_reason`

#### Scenario: un movimiento sin sucursal se sigue revirtiendo en la principal vigente

- **GIVEN** una venta cuyo movimiento tiene `branch_id` nulo
- **WHEN** se elimina la venta
- **THEN** el stock se repone en la principal operativa vigente y el contramovimiento conserva `branch_id` nulo, como antes de este cambio

### Requirement: Única excepción auditada al carácter append-only: la sucursal nula de los movimientos de venta de origen demostrable

El ledger de stock SHALL seguir siendo append-only (RN-21) para toda escritura de la aplicación y de los usuarios: las políticas de `UPDATE` y `DELETE` siguen cerradas y las correcciones se expresan con movimientos nuevos.

Como única excepción, firmada por el PO, SHALL poder completarse `branch_id` en movimientos existentes **sólo** desde dos migraciones de datos: la de `ventas-sucursal-por-defecto` (`20261075000002`, OQ-5) y la de `stock-movimientos-sucursal-origen` (`20261077000002`, OQ-A y OQ-B). Ningún otro camino, presente o futuro, SHALL modificar un movimiento existente. Cada movimiento completado SHALL cumplir **todas** estas condiciones:

- `type = 'sale'`, `reference_type = 'sale'` y `branch_id IS NULL`;
- `reference_id` igual a una venta **viva** con cuenta, y la sucursal escrita es de esa cuenta;
- su **origen es demostrable**, en el sentido de abajo;
- ni la caja ni el banco de la misma operación registraron otra sucursal.

**Origen demostrable** es la sucursal de la que el sistema tomó el stock cuando se registró el movimiento (`stock_movements.created_at`, el instante T), reconstruida sólo con lo que quedó registrado:

- si la cuenta **no tenía sucursales** en T, la sucursal **más antigua** de la cuenta, sin importar si hoy opera: ese stock vivía en el stock general del producto, y la unificación de inventario (C-21) lo materializó en esa sucursal; es la misma convención que el sistema aplicó a todo el stock anterior a las sucursales;
- si tenía **una sola** sucursal en T, esa, opere o no hoy: la resolución de la sucursal principal no podía devolver otra;
- si tenía **dos o más**, la que la resolución de la sucursal principal habría devuelto en T: la primera por antigüedad que estaba activa y abierta en T, o la más antigua si ninguna lo estaba. El estado de cada sucursal en T SHALL obtenerse partiendo de su estado actual y deshaciendo los cambios de su ciclo de vida registrados después de T; para un instante anterior al comienzo de ese registro, sobre ese resultado sólo SHALL inferirse lo que no pudo cambiar sin dejar rastro (una sucursal que figura activa ya lo estaba, porque antes del registro no había forma de reactivarla; una sucursal sin fecha de cierre nunca se cerró). Si el estado en T de alguna sucursal que la regla recorre no se puede establecer así —por ejemplo, una sucursal ya inactiva al empezar el registro, cuya baja no tiene fecha—, el origen no es demostrable. Tampoco lo es si la sucursal que la regla elegiría comparte `created_at` con otra sucursal de la cuenta (la resolución de la sucursal principal no desempata), si un cambio registrado de una sucursal que la regla recorre ocurre en el mismo instante que el movimiento, o si los cambios de una sucursal en un mismo instante dejan estados previos distintos.

El valor escrito SHALL ser el origen, aunque difiera de la sucursal de la venta o esa sucursal esté hoy desactivada: el movimiento registra de dónde salió el stock, y la venta conserva la sucursal que se le asignó. (La reversa de un movimiento en una sucursal desactivada se aplica en la principal operativa: ver «Reversa de stock al eliminar venta o compra, independiente de la ruta de creación».) Un movimiento cuyo origen no es demostrable, o que la caja o el banco contradicen, SHALL conservar `branch_id` nulo, y la migración SHALL contarlo por motivo.

La condición de origen demostrable existe porque el stock de una venta sin sucursal salió de la sucursal principal **del momento de la venta**, que puede no ser la sucursal que tiene hoy la venta ni la principal de hoy. Escribir una sucursal de la que el stock no salió falsearía el ledger por `(product_id, branch_id)` y haría que el borrado de la venta repusiera el stock en el lugar equivocado.

La excepción NO SHALL modificar ninguna otra columna del movimiento (cantidad, cantidades antes y después, costo congelado, tipo, referencias, grupo de operación, cuenta, metadatos). Tampoco SHALL eliminar movimientos, ni tocar movimientos que ya registran una sucursal, los de otros tipos o los de ventas que ya no existen. Cada movimiento modificado SHALL quedar listado por id —y, en la segunda migración, agrupado por la regla que dio su origen— en el registro de auditoría de su migración, de modo que el cambio sea reversible fila por fila.

Con `stock-movimientos-sucursal-origen` la excepción SHALL quedar **agotada**: los movimientos que conserven `branch_id` nulo SHALL quedar así, y toda corrección posterior SHALL expresarse con un movimiento nuevo. La excepción completa un dato que faltaba sólo cuando se puede demostrar su valor; no corrige ni reinterpreta un hecho registrado.

#### Scenario: Un movimiento de cuando la cuenta no tenía sucursales toma la sucursal más antigua

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva, registrado antes de que existiera ninguna sucursal de la cuenta, y una cuenta cuya sucursal más antigua es A, hoy desactivada
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento queda con `branch_id = A`, y su cantidad, sus cantidades antes y después, su costo congelado, su tipo, sus referencias y su cuenta no cambian

#### Scenario: Un movimiento de cuando la cuenta tenía una sola sucursal toma esa sucursal

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva asignada a la sucursal B, registrado cuando la única sucursal de la cuenta era A, hoy desactivada
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento queda con `branch_id = A`, la venta sigue en B, y la migración lo cuenta como discrepancia entre venta y movimiento

#### Scenario: Con varias sucursales y su estado registrado, se toma la principal de ese momento

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva, registrado en T posterior al inicio del registro del ciclo de vida, en una cuenta con las sucursales A (la más antigua) y B, donde el registro muestra que A se desactivó antes de T y B operaba en T
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento queda con `branch_id = B`

#### Scenario: Con varias sucursales y una baja sin fecha, el movimiento queda nulo

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva, registrado en T anterior al inicio del registro del ciclo de vida, en una cuenta con las sucursales A (la más antigua, ya inactiva al empezar el registro, sin fecha de baja) y B
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento conserva `branch_id` nulo y la migración lo cuenta como no fechable

#### Scenario: Una sucursal elegida con el mismo created_at que otra deja el movimiento nulo

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo de una venta viva, registrado en T en una cuenta con dos sucursales activas que comparten `created_at` anterior a T
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento conserva `branch_id` nulo y la migración lo cuenta como no fechable

#### Scenario: La caja o el banco de la operación contradicen el origen

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo cuyo origen reconstruido es A, y un movimiento de caja o de banco de la misma operación registrado en la sucursal B
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento conserva `branch_id` nulo y la migración lo cuenta como contradicción

#### Scenario: Un movimiento que ya registra una sucursal no se modifica

- **GIVEN** un movimiento `'sale'` con `branch_id = X` de una venta con `branch_id` nulo
- **WHEN** se aplica la migración de datos
- **THEN** el movimiento conserva `branch_id = X`

#### Scenario: Los movimientos de una venta borrada no se tocan

- **GIVEN** un movimiento `'sale'` con `branch_id` nulo cuya venta ya fue borrada, y su contramovimiento también nulo
- **WHEN** se aplica la migración de datos
- **THEN** los dos movimientos conservan `branch_id` nulo

#### Scenario: Cada movimiento modificado queda en la auditoría

- **WHEN** la migración de datos completa la sucursal de movimientos de una cuenta
- **THEN** la fila de auditoría de esa cuenta lista los ids de esos movimientos y, en la migración de `stock-movimientos-sucursal-origen`, los agrupa por la regla que dio su origen

#### Scenario: La excepción queda agotada

- **GIVEN** las dos migraciones de datos ya aplicadas
- **WHEN** se vuelve a ejecutar la de `stock-movimientos-sucursal-origen`
- **THEN** no se modifica ningún movimiento ni se escribe auditoría, y los movimientos que quedaron nulos siguen nulos
