## ADDED Requirements

### Requirement: La edición de una compra a crédito reemplaza su cargo
El sistema SHALL ajustar la cuenta corriente del proveedor cuando se edita una compra cuyo cargo cambia —importe, proveedor o vencimiento—, registrando primero el cargo nuevo con el helper compartido de cargo y después la reversión de la huella neta con el helper compartido de reversión, en la misma transacción que la edición. SHALL NOT escribir ningún movimiento cuando el cargo no cambia.

El cargo nuevo SHALL referenciar la operación. La reversión SHALL llevar la misma referencia que el cargo que revierte. El vencimiento SHALL seguir el contrato tri-estado de la capability `operation-money-edit`.

SHALL rechazarse con `P0425` la edición que dejaría negativo el saldo final de la cuenta corriente de algún proveedor involucrado, con el mensaje de que primero hay que anular el pago.

#### Scenario: Corregir el importe de una compra a crédito
- **GIVEN** una compra a crédito de 8000 con su cargo en la cuenta corriente del proveedor
- **WHEN** se edita a 9000
- **THEN** la cuenta corriente del proveedor recibe un cargo de 9000 y la reversión de 8000, y el saldo sube 1000

#### Scenario: Bajar el importe por debajo de lo ya pagado
- **GIVEN** una compra a crédito de 8000 de la que ya se pagaron 8000 al proveedor
- **WHEN** se edita a 6000
- **THEN** la edición se rechaza con `P0425` y nada cambia

#### Scenario: Pasar una compra de efectivo a crédito postea el cargo
- **GIVEN** una compra en efectivo con proveedor y sin movimiento de caja
- **WHEN** se edita a una forma de pago de cuenta corriente
- **THEN** se registra el cargo del total en la cuenta corriente del proveedor, con el vencimiento resuelto por la cascada

## REMOVED Requirements

### Requirement: La compra con cargo posteado es inmutable y se corrige por borrado
**Reason**: El PO pidió (2026-10-14) poder editar toda compra aunque tenga cargo en la cuenta corriente del proveedor. La edición ajusta el cargo en lugar de rechazarse.
**Migration**: Ver el requirement nuevo "La edición de una compra a crédito reemplaza su cargo" y la capability `operation-money-edit`. El `P0423` por cargo de proveedor se retira de `rpc_atomic_update_purchase_operation`. El borrado sigue compensando el cargo, el banco, la caja y el stock como hasta ahora, sobre la huella neta. El listado de compras deja de deshabilitar "Editar" por el cargo.
