## ADDED Requirements

### Requirement: Movimientos del remito de compra en el ledger
El sistema SHALL registrar los movimientos de stock del remito de compra con los `type` existentes de compra y los `reference_type` del remito: la recepción y la pata de aplicación de una edición con `type = 'purchase'` y `reference_type = 'delivery_note'`; la pata de reversa de una edición con `type = 'purchase_return'` y `reference_type = 'delivery_note_update'`; la anulación con `type = 'purchase_return'` y `reference_type = 'delivery_note_reversal'`. Toda pata que resta stock SHALL verificar antes del delta que la sucursal tiene la cantidad y, si no, fallar con `P0409 delivery_note_stock_consumed`, de modo que el stock nunca quede negativo ni la operación aborte por la restricción de la tabla.

#### Scenario: Recepción y anulación cierran en cero
- **GIVEN** un remito de compra emitido de 6 unidades de A y anulado con las 6 en el depósito
- **WHEN** se suman las `quantity_delta` de sus movimientos sobre A
- **THEN** la suma es `0`, con un movimiento `purchase` / `delivery_note` de `+6` y uno `purchase_return` / `delivery_note_reversal` de `-6`

#### Scenario: Pata que resta sin stock
- **WHEN** una edición o anulación de un remito de compra necesita restar más de lo que hay en la sucursal
- **THEN** falla con `P0409 delivery_note_stock_consumed` antes de escribir, y no con un error de la restricción de stock no negativo

### Requirement: La reversa al borrar una compra exceptúa las compras nacidas de un remito
El sistema SHALL saltear de forma explícita la reversa de stock al borrar una compra nacida de un remito de compra, cuyas filas no tienen movimientos propios porque el stock vive en el remito. El invariante de no-orfandad del ledger de operaciones SHALL exceptuar esas filas de compra: su stock se reconstruye desde los movimientos del remito.

#### Scenario: Borrar la compra de un remito no mueve stock
- **GIVEN** una compra nacida de un remito que aportó 10 unidades de A
- **WHEN** se borra la compra
- **THEN** no se escribe ningún movimiento de stock y el stock de A no cambia
