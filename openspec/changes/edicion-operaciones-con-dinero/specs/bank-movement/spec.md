## ADDED Requirements

### Requirement: Movimiento espejo y movimiento nuevo bancario por edición de una operación
El sistema SHALL ajustar el ledger bancario al editar una venta, una compra o un gasto cuyo efecto bancario cambia —otra cuenta bancaria, otro importe, otra fecha de operación o salida del banco—, en la misma transacción que la edición:

1. registrar, por cada fila de huella bancaria neta distinta de cero, un movimiento espejo con la dirección invertida, por el importe opuesto, en la misma cuenta bancaria, con fecha valor de hoy, en estado `unreconciled` y con la misma referencia, aunque el movimiento original esté conciliado, sin alterar el original ni su conciliación (mismo criterio que el borrado);
2. registrar el movimiento nuevo con el helper de la operación del alta, con la fecha de la operación como fecha valor y sus mismas validaciones: `P0412` para una cuenta ajena, inactiva o borrada; `P0400` para una cuenta explícita con forma de pago no bancaria; `P0424` para una fecha valor dentro de un período conciliado y cerrado.

SHALL NOT registrar ningún movimiento cuando el efecto no cambia, para no generar pares sin línea de extracto que conciliar. El efecto no cambia cuando la cuenta bancaria es la misma, el importe neto es el mismo y la fecha de la operación no cambió.

#### Scenario: Corregir el importe de una venta por transferencia
- **GIVEN** una venta por transferencia de 10000 con su `transfer_in` en la cuenta Galicia
- **WHEN** se edita a 12000
- **THEN** la cuenta Galicia recibe un `transfer_out` de −10000 `unreconciled` con fecha valor de hoy y un `transfer_in` de +12000 con la fecha de la venta

#### Scenario: Pasar de transferencia a efectivo
- **GIVEN** una compra por transferencia con su `transfer_out` de −4000
- **WHEN** se edita a efectivo
- **THEN** la cuenta bancaria recibe un `transfer_in` de +4000 y no se registra ningún movimiento bancario nuevo

#### Scenario: Una edición que no cambia el banco no lo toca
- **GIVEN** una venta por transferencia cuyo movimiento ya fue conciliado
- **WHEN** se edita sólo su cliente
- **THEN** no se registra ningún movimiento bancario y el movimiento conciliado sigue igual

#### Scenario: Movimiento nuevo dentro de un período conciliado
- **GIVEN** una sesión de conciliación cerrada que cubre la fecha de la operación
- **WHEN** se edita el importe bancario de esa operación
- **THEN** la edición falla con `P0424`, con el mensaje de registrar el ajuste como movimiento manual, y ningún libro cambia
