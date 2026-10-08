## ADDED Requirements

### Requirement: El ledger de stock y el saldo por sucursal se escriben sólo desde funciones SECURITY DEFINER

El sistema SHALL garantizar **por estructura, no por convención** (mismo criterio que RN-A3 para `document_status_history`) que ningún rol de aplicación escriba directamente `public.stock_movements` ni `public.branch_stock`:

- `anon` y `authenticated` SHALL NOT tener `INSERT`, `UPDATE`, `DELETE` ni `TRUNCATE` a nivel tabla sobre ninguna de las dos;
- SHALL NOT existir policy permisiva de `INSERT`, `UPDATE` ni `DELETE` sobre ellas: sólo las de lectura por cuenta (`stock_movements_account_select`, `branch_stock_member_select`) y, en `stock_movements`, las dos policies `qual = false` de `UPDATE`/`DELETE`, que se conservan como segunda red ante un re-`GRANT` accidental;
- toda escritura SHALL ocurrir dentro de una función `SECURITY DEFINER` que ya validó al usuario, o de un helper `SECURITY INVOKER` sin `EXECUTE` para `anon`/`authenticated` invocado sólo desde ellas;
- las funciones internas que mueven stock —`rpc_reverse_stock_movement` (que no valida rol: confía en su caller), el helper de aritmética de saldo (que recibe la cuenta por parámetro) y el núcleo de ajuste manual (alcanzable sólo a través de sus envoltorios públicos)— SHALL NOT ser ejecutables por `anon` ni `authenticated`.

Las acciones referenciales de las FKs (`ON DELETE CASCADE`/`SET NULL` desde `products`, `branches` y `auth.users`) SHALL seguir funcionando: corren como dueño de la tabla, no como el rol que borra.

#### Scenario: Una fila forjada por PostgREST es rechazada

- **GIVEN** un miembro de la cuenta, de cualquier rol
- **WHEN** intenta `INSERT` en `stock_movements` con `reference_type = 'sale'` por PostgREST o bajo `SET LOCAL ROLE authenticated`
- **THEN** la operación falla con `42501` *permission denied* (capa de privilegio, no de RLS) y no queda ninguna fila

#### Scenario: Pisar un saldo por PostgREST es rechazado

- **GIVEN** un miembro con rol `seller` (escritor de la cuenta)
- **WHEN** intenta `UPDATE`, `UPDATE … RETURNING`, `INSERT … ON CONFLICT DO UPDATE`, `DELETE` o `TRUNCATE` sobre `branch_stock`
- **THEN** cada variante falla con `42501` *permission denied* y el saldo no cambia

#### Scenario: Ocupar el saldo de otra cuenta es imposible

- **GIVEN** un escritor de la cuenta A que conoce un producto y una sucursal de la cuenta B sin fila de saldo
- **WHEN** intenta insertar en `branch_stock` la fila `(account_id = A, product_id de B, branch_id de B)`
- **THEN** la inserción falla con `42501` y la primera venta o compra de B crea su propia fila con `account_id = B`

#### Scenario: La reversa pública ya no es invocable

- **WHEN** un usuario autenticado llama a `rpc_reverse_stock_movement` por PostgREST
- **THEN** la llamada es rechazada por falta de `EXECUTE` y el saldo no cambia

#### Scenario: Los caminos legítimos siguen escribiendo

- **GIVEN** la escritura directa cerrada
- **WHEN** un usuario registra una venta, una compra, un ajuste con permiso, una transferencia, o borra una venta o una compra
- **THEN** cada operación escribe `branch_stock` y `stock_movements` como antes, a través de sus funciones `SECURITY DEFINER`

#### Scenario: Borrar un producto con historial sigue funcionando

- **GIVEN** un producto sin stock y con movimientos en el ledger
- **WHEN** su dueño lo borra
- **THEN** el borrado procede y las acciones referenciales de las FKs se aplican pese a que `authenticated` no tiene escritura sobre las tablas del ledger

## MODIFIED Requirements

### Requirement: Reversa de stock al eliminar venta o compra, independiente de la ruta de creación

Al eliminar una venta o una compra, el sistema SHALL revertir el movimiento de stock asociado contra `branch_stock`, de forma independiente de la ruta por la que se creó **o se modificó** la operación (`rpc_create_sale_operation_v2`, ruta legacy con `sale_items_rpc_v2` OFF, ruta C-29 `rpc_quick_sale` / `rpc_confirm_sales_order`, o el resultado de `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`). Los datos de la reversa (`product_id`, `quantity_delta`, `branch_id`) SHALL leerse desde la fila de `stock_movements` que toda ruta de creación **y toda edición** escribe (`reference_id = <sale|purchase>.id`, `reference_type = 'sale'|'purchase'`), y NO desde `sale_items` / `purchase_items`. La reversa SHALL aplicar `-quantity_delta` (signo opuesto al movimiento original) sobre la `branch_id` registrada en el movimiento, a través del **helper interno de aritmética de saldo** (`_stock_apply_delta`: lock del producto, validación de sucursal, piso en cero trazable cuando el stock ya se vendió), y SHALL NOT pasar por la RPC pública de ajuste `rpc_apply_product_stock_delta`, que desde este cambio exige rol y motivo y rechaza los parámetros internos.

El ledger es append-only: la fila reversada NO SHALL eliminarse ni modificarse. La reversa SHALL expresarse como un **contramovimiento** nuevo (`type = 'sale_return'` / `'purchase_return'`, `reference_type = 'sale_reversal'` / `'purchase_reversal'`, `metadata.reverses_movement_id` apuntando al movimiento original), tal como lo implementa `rpc_reverse_stock_movement`. `rpc_reverse_stock_movement` SHALL ser interna: invocable sólo desde las funciones `SECURITY DEFINER` de borrado (`rpc_delete_sale_operation`, `rpc_delete_purchase_operation`), nunca por `anon` ni `authenticated`. Cuando la operación no tiene movimiento de stock (línea de servicio sin `product_id`), la eliminación SHALL proceder sin reversa y sin error; cuando la operación **tiene** `product_id`, la ausencia de movimiento de referencia es una violación de invariante, no un caso válido de "sin reversa".

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
