## MODIFIED Requirements

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
