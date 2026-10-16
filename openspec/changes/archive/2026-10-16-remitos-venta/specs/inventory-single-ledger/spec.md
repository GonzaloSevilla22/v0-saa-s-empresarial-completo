## MODIFIED Requirements

### Requirement: Reversa de stock al eliminar venta o compra, independiente de la ruta de creación

Al eliminar una venta o una compra, el sistema SHALL revertir el movimiento de stock asociado contra `branch_stock`, de forma independiente de la ruta por la que se creó **o se modificó** la operación (`rpc_create_sale_operation_v2`, ruta legacy con `sale_items_rpc_v2` OFF, ruta C-29 `rpc_quick_sale` / `rpc_confirm_sales_order`, o el resultado de `rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`). Los datos de la reversa (`product_id`, `quantity_delta`, `branch_id`) SHALL leerse desde la fila de `stock_movements` que toda ruta de creación **y toda edición** escribe (`reference_id = <sale|purchase>.id`, `reference_type = 'sale'|'purchase'`), y NO desde `sale_items` / `purchase_items`. La reversa SHALL aplicar `-quantity_delta` (signo opuesto al movimiento original) sobre la `branch_id` registrada en el movimiento, salvo la excepción de la sucursal desactivada descrita abajo, a través del **helper interno de aritmética de saldo** (`_stock_apply_delta`: lock del producto, validación de sucursal, piso en cero trazable cuando el stock ya se vendió), y SHALL NOT pasar por la RPC pública de ajuste `rpc_apply_product_stock_delta`, que desde este cambio exige rol y motivo y rechaza los parámetros internos.

**Sucursal desactivada** (`stock-movimientos-sucursal-origen`): cuando la sucursal registrada en el movimiento original está desactivada (`is_active = false`), la reversa NO SHALL aplicarse en ella: una sucursal dada de baja no se lista ni se vende, y el stock que entrara ahí quedaría invisible. La reversa SHALL aplicarse en la sucursal principal operativa vigente de la cuenta (la misma resolución que se usa para un movimiento sin sucursal). Una sucursal **cerrada** pero activa NO es una sucursal desactivada: la reversa sobre ella SHALL seguir rechazándose con `P0422 branch_closed` hasta que se reabra. Un movimiento original sin sucursal SHALL seguir revirtiéndose en la principal vigente. Si la cuenta no tiene ninguna sucursal operativa, la principal vigente puede ser la misma sucursal desactivada: el stock SHALL entrar donde ya entra un movimiento sin sucursal, sin error nuevo, y el contramovimiento SHALL conservar la sucursal original sin `fallback_*` (no hubo respaldo).

El ledger es append-only: la fila reversada NO SHALL eliminarse ni modificarse. La reversa SHALL expresarse como un **contramovimiento** nuevo (`type = 'sale_return'` / `'purchase_return'`, `reference_type = 'sale_reversal'` / `'purchase_reversal'`, `metadata.reverses_movement_id` apuntando al movimiento original), tal como lo implementa `rpc_reverse_stock_movement`. El contramovimiento SHALL registrar en `branch_id` la sucursal del movimiento original, salvo cuando se aplicó en la principal por estar desactivada la original: entonces SHALL registrar la sucursal en la que efectivamente se aplicó, y su `metadata` SHALL incluir también la sucursal original (`fallback_from_branch_id`) y el motivo (`fallback_reason = 'branch_inactive'`). `rpc_reverse_stock_movement` SHALL ser interna: invocable sólo desde las funciones `SECURITY DEFINER` de borrado (`rpc_delete_sale_operation`, `rpc_delete_purchase_operation`), nunca por `anon` ni `authenticated`. Cuando la operación no tiene movimiento de stock (línea de servicio sin `product_id`), la eliminación SHALL proceder sin reversa y sin error; cuando la operación **tiene** `product_id`, la ausencia de movimiento de referencia es una violación de invariante, no un caso válido de "sin reversa", **salvo** en la venta nacida de un remito.

**Excepción — venta nacida de un remito** (`remitos-venta`): cuando la orden de la venta tiene origen en un remito (`sales_orders.source_delivery_note_id`), el movimiento de stock de esa mercadería pertenece al remito (`reference_type = 'delivery_note'`, `reference_id` = id del remito), no a las filas de `sales`. La eliminación de esa venta SHALL saltear explícitamente la reversa de stock, sin depender de que no encuentre movimientos, y NO SHALL modificar `branch_stock`. La mercadería sigue entregada, el remito vuelve a pendiente, y devolver el stock es la anulación del remito.

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

#### Scenario: eliminar una venta nacida de un remito no repone el stock

- **GIVEN** una venta confirmada desde el remito R-00000005, de 3 unidades de A, con `branch_stock` de A en `7` y el movimiento `sale` / `delivery_note` de `-3` apuntando al remito
- **WHEN** se elimina la venta
- **THEN** `branch_stock` de A sigue en `7`, no se registra ningún contramovimiento `sale_reversal` y el movimiento del remito queda intacto

### Requirement: Invariante de reconstrucción y de no-orfandad del ledger de operaciones

Para toda operación de venta o compra creada, editada o eliminada, la suma de `quantity_delta` de los movimientos de `stock_movements` asociados a esa operación, agrupada por `(product_id, branch_id)`, SHALL ser igual al delta neto aplicado a `branch_stock.quantity` para ese par en la misma transacción. Ninguna ruta de escritura de operaciones SHALL mover `branch_stock` sin dejar el movimiento correspondiente.

Toda fila viva de `sales` / `purchases` con `product_id` NO NULO SHALL tener al menos un movimiento con `reference_id` = su id y `reference_type = 'sale'` / `'purchase'`. **Se exceptúan** las filas de `sales` de una operación cuya orden nació de un remito: su mercadería está cubierta por los movimientos del remito (`reference_type = 'delivery_note'`), y el invariante de reconstrucción se verifica sobre el remito (ver "Movimientos del remito en el ledger"). Recíprocamente, hacia adelante, ningún movimiento con `reference_type = 'sale'` / `'purchase'` SHALL quedar apuntando a una fila inexistente **sin** que exista para ese mismo `reference_id` un contramovimiento (`sale_reversal` / `purchase_reversal` para la eliminación, `sale_update` / `purchase_update` para la edición) que cierre el par.

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

#### Scenario: la venta nacida de un remito no es huérfana

- **GIVEN** un remito emitido y convertido en venta
- **WHEN** se audita la no-orfandad de las filas vivas de `sales`
- **THEN** las filas de esa venta no cuentan como huérfanas, porque su orden tiene origen de remito, y el remito tiene sus movimientos `delivery_note`

## ADDED Requirements

### Requirement: Movimientos del remito en el ledger
El sistema SHALL registrar en `stock_movements` todo cambio de stock que produzca un remito, en la misma transacción que lo aplica a `branch_stock`, con `reference_id` = id del remito y un movimiento por par producto-sucursal.

Los `reference_type` SHALL ser estos, sumados de forma aditiva al conjunto cerrado:

| Momento | `type` | `reference_type` |
|---|---|---|
| Emisión, y pata de aplicación de una edición | `sale` | `delivery_note` |
| Pata de reversa de una edición | `sale_return` | `delivery_note_update` |
| Anulación | `sale_return` | `delivery_note_reversal` |

Cada movimiento SHALL poblar `quantity_before`, `quantity_after`, `branch_id`, `product_name`, `performed_by`, `operation_group_id` y el costo unitario congelado de la línea.

El stock que retiene un remito en cada par SHALL ser la suma de las cantidades base guardadas en sus líneas vigentes, en su sucursal vigente: la cantidad que efectivamente se descontó, normalizada al emitir o editar. La edición y la anulación SHALL revertir por ese valor, nunca reconvirtiendo las líneas y nunca sumando movimientos del ledger: aunque ningún rol de aplicación puede escribir en `stock_movements` (ver «El ledger de stock y el saldo por sucursal se escriben sólo desde funciones SECURITY DEFINER»), el stock devuelto a `branch_stock` NO SHALL depender de lo que diga el ledger, de modo que una fila ajena al remito, de cualquier origen, nunca pueda convertirse en stock devuelto.

Para todo remito, la suma de `quantity_delta` de sus movimientos por par SHALL igualar el cambio neto de `branch_stock` de ese par producido por el remito y, mientras esté pendiente, el negativo de lo retenido. Un remito anulado SHALL quedar con suma cero en cada par. Estas igualdades SHALL verificarse como gate de comportamiento.

Ningún consumidor del ledger SHALL asumir que `type = 'sale'` implica una fila en `sales`; la venta y el remito se distinguen por `reference_type`.

#### Scenario: emisión, edición y anulación se reconstruyen desde el ledger
- **GIVEN** un producto con stock inicial conocido en una sucursal
- **WHEN** se emite un remito, se edita su cantidad dos veces y se lo anula
- **THEN** la suma de los `quantity_delta` del remito para ese par es cero, el stock final iguala al inicial y cada movimiento lleva el `reference_type` de su momento

#### Scenario: una fila forjada es rechazada y no cambia lo que devuelve la anulación
- **GIVEN** un remito pendiente que retiene 3 unidades de A
- **WHEN** un miembro de la cuenta intenta insertar por PostgREST un movimiento de `-1000` con la referencia de ese remito
- **THEN** la inserción falla con `42501` *permission denied* (capa de privilegio) y no queda ninguna fila
- **AND** al anular el remito, `branch_stock` de A aumenta exactamente en 3

#### Scenario: el reference_type del remito es admitido y distinto del de la venta
- **WHEN** se registra un movimiento con `reference_type = 'delivery_note'`
- **THEN** el `CHECK` lo admite, y la edición de una venta nunca lo lee como movimiento propio, porque filtra por los ids de sus filas de `sales`
