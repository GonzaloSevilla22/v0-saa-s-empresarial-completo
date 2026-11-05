## MODIFIED Requirements

### Requirement: Reversión del cargo de cuenta corriente por borrado de venta
El sistema SHALL registrar un movimiento de tipo `credit_note` por el importe negativo de la huella neta de cargo cuando se borra una venta que había generado un cargo en la cuenta corriente del cliente, dejando el saldo exactamente en el valor previo a esa venta. El movimiento SHALL llevar la misma referencia que el cargo que revierte —el `operation_id` en el camino del formulario, el `id` de la orden en el camino del POS—, para que la derivación del aging lo empareje con ese cargo.

#### Scenario: Venta a crédito impaga
- **WHEN** se borra una venta que cargó la cuenta corriente de un cliente y el cargo sigue impago
- **THEN** se registra un movimiento `credit_note` por el importe negativo del cargo
- **AND** el movimiento lleva la misma referencia que el cargo que revierte
- **AND** el saldo del cliente vuelve exactamente al valor previo a la venta

#### Scenario: Venta sin cargo en cuenta corriente
- **WHEN** se borra una venta que no cargó ninguna cuenta corriente
- **THEN** no se registra ningún movimiento de cuenta corriente

#### Scenario: El ledger permanece append-only
- **WHEN** se compensa el cargo de una venta borrada
- **THEN** el movimiento original permanece en el ledger
- **AND** la compensación se expresa como un movimiento nuevo, no como una baja ni una modificación del original

### Requirement: Rechazo de la reversión que dejaría saldo negativo
El sistema SHALL rechazar con el código de error `P0425` el borrado o la edición de una venta cuando el saldo **final** de la cuenta corriente de algún cliente involucrado quedaría por debajo de cero, en lugar de intentar un movimiento que viola el invariante de saldo no negativo del ledger. En la edición, el saldo final es el que resulta de registrar el cargo nuevo y revertir el anterior: un saldo intermedio no es causa de rechazo. El mensaje SHALL indicar que debe registrarse primero la anulación o la devolución del cobro.

#### Scenario: El cliente ya pagó la venta
- **WHEN** se intenta borrar una venta cuyo cargo ya fue cancelado por el cliente
- **THEN** el sistema rechaza el borrado con `P0425`
- **AND** el mensaje indica que debe registrarse primero la devolución del pago
- **AND** no se registra ningún movimiento en la cuenta corriente

#### Scenario: El cliente pagó parcialmente
- **WHEN** se intenta borrar una venta cuyo cargo fue cancelado en parte, de modo que revertirlo dejaría el saldo negativo
- **THEN** el sistema rechaza el borrado con `P0425`

#### Scenario: Editar a la baja por debajo de lo cobrado
- **GIVEN** una venta a crédito de 1000 de la que el cliente ya pagó 800
- **WHEN** se edita su total a 500
- **THEN** el sistema rechaza la edición con `P0425` y no se registra ningún movimiento en la cuenta corriente

#### Scenario: Editar al alza una venta ya cobrada
- **GIVEN** una venta a crédito de 1000 totalmente cobrada
- **WHEN** se edita su total a 1200
- **THEN** la edición se aplica y el saldo del cliente queda en 200

## ADDED Requirements

### Requirement: La edición de una venta a crédito reemplaza su cargo
El sistema SHALL ajustar la cuenta corriente del cliente cuando se edita una venta cuyo cargo cambia —importe, cliente o vencimiento—, registrando primero el cargo nuevo con el helper compartido de cargo y después la reversión de la huella neta con el helper compartido de reversión, en la misma transacción que la edición. SHALL NOT escribir ningún movimiento cuando el cargo no cambia.

El cargo nuevo SHALL referenciar la operación. La reversión SHALL llevar la misma referencia que el cargo que revierte. El vencimiento SHALL seguir el contrato tri-estado de la capability `operation-money-edit`.

Pasar la venta a una forma de pago que no es de cuenta corriente SHALL revertir el cargo sin registrar uno nuevo. Pasarla a cuenta corriente SHALL registrar el cargo con las mismas exigencias del alta: cliente identificado y del tenant.

#### Scenario: Corregir el total de una venta a crédito
- **GIVEN** una venta a crédito de 1000 con su cargo
- **WHEN** se edita a 1200
- **THEN** la cuenta corriente del cliente recibe un cargo de 1200 y una nota de reversión de 1000, en ese orden, y el saldo sube 200

#### Scenario: Corregir sólo el producto a igual total no toca la cuenta corriente
- **GIVEN** una venta a crédito con su cargo
- **WHEN** se reemplaza un producto por otro del mismo precio sin cambiar cliente ni vencimiento
- **THEN** no se registra ningún movimiento en la cuenta corriente

#### Scenario: Pasar a efectivo revierte el cargo
- **GIVEN** una venta a crédito impaga de 1000
- **WHEN** se edita a una forma de pago de efectivo
- **THEN** la cuenta corriente recibe la reversión de 1000 y el saldo del cliente baja en 1000
