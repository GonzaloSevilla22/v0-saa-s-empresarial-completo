## ADDED Requirements

### Requirement: Reversión del cargo de cuenta corriente por borrado de venta
El sistema SHALL registrar un movimiento de tipo `credit_note` por el importe negativo del cargo original cuando se borra una venta que había generado un cargo en la cuenta corriente del cliente, dejando el saldo exactamente en el valor previo a esa venta.

#### Scenario: Venta a crédito impaga
- **WHEN** se borra una venta que cargó la cuenta corriente de un cliente y el cargo sigue impago
- **THEN** se registra un movimiento `credit_note` por el importe negativo del cargo
- **AND** el movimiento referencia la operación borrada
- **AND** el saldo del cliente vuelve exactamente al valor previo a la venta

#### Scenario: Venta sin cargo en cuenta corriente
- **WHEN** se borra una venta que no cargó ninguna cuenta corriente
- **THEN** no se registra ningún movimiento de cuenta corriente

#### Scenario: El ledger permanece append-only
- **WHEN** se compensa el cargo de una venta borrada
- **THEN** el movimiento original permanece en el ledger
- **AND** la compensación se expresa como un movimiento nuevo, no como una baja ni una modificación del original

### Requirement: Rechazo de la reversión que dejaría saldo negativo
El sistema SHALL rechazar el borrado con el código de error `P0425` cuando la reversión del cargo dejaría el saldo de la cuenta corriente por debajo de cero, en lugar de intentar un movimiento que viola el invariante de saldo no negativo del ledger.

#### Scenario: El cliente ya pagó la venta
- **WHEN** se intenta borrar una venta cuyo cargo ya fue cancelado por el cliente
- **THEN** el sistema rechaza el borrado con `P0425`
- **AND** el mensaje indica que debe registrarse primero la devolución del pago
- **AND** no se registra ningún movimiento en la cuenta corriente

#### Scenario: El cliente pagó parcialmente
- **WHEN** se intenta borrar una venta cuyo cargo fue cancelado en parte, de modo que revertirlo dejaría el saldo negativo
- **THEN** el sistema rechaza el borrado con `P0425`
