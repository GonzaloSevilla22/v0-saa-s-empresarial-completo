## ADDED Requirements

### Requirement: Toda mutación de stock por edición de operación deja rastro espejo en el ledger

La edición de una operación de venta o compra SHALL registrar en `stock_movements` las **dos** patas que ya ejecuta contra `branch_stock` — la reversa de la operación vieja y la aplicación de la nueva — dentro de la misma transacción que las aplica. NO SHALL registrarse un único movimiento neto: el kardex SHALL poder leerse como la secuencia real de hechos (se devolvió lo anterior, se aplicó lo nuevo), que es la semántica que consume el panel de movimientos y la única que permite auditar una edición sin reconstruirla.

La pata de reversa SHALL escribirse con `type = 'sale_return'` (venta) o `'purchase_return'` (compra), `reference_id` = id de la fila vieja y `reference_type = 'sale_update'` / `'purchase_update'` — un `reference_type` propio que distingue "revertido por edición" de "revertido por eliminación" (`sale_reversal` / `purchase_reversal`) sin leer texto libre.

La pata de aplicación SHALL escribirse con `type = 'sale'` / `'purchase'`, `reference_id` = id de la fila **nueva** y `reference_type = 'sale'` / `'purchase'`, es decir **indistinguible del movimiento que emite la creación**. Esto es normativo, no cosmético: es el contrato del que depende la reversa de stock al eliminar.

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

## MODIFIED Requirements

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
