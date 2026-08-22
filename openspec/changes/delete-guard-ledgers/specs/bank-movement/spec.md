## ADDED Requirements

### Requirement: Movimiento bancario espejo por borrado de operación
El sistema SHALL registrar un movimiento bancario espejo, con la dirección invertida respecto del original y por el mismo importe, cuando se borra una operación que había registrado un movimiento bancario.

#### Scenario: Venta cobrada por transferencia
- **WHEN** se borra una venta que registró un ingreso bancario
- **THEN** se registra un movimiento de egreso por el mismo importe en la misma cuenta bancaria
- **AND** el saldo de la cuenta bancaria vuelve exactamente al valor previo a la venta

#### Scenario: Operación sin movimiento bancario
- **WHEN** se borra una operación que nunca registró un movimiento bancario
- **THEN** no se registra ningún movimiento bancario

### Requirement: Estado de conciliación del movimiento espejo
El movimiento bancario espejo SHALL nacer con estado de conciliación `unreconciled`, y el sistema SHALL registrarlo también cuando el movimiento original ya esté conciliado, sin alterar el estado ni la conciliación del original.

#### Scenario: El movimiento original ya está conciliado
- **WHEN** se borra una operación cuyo movimiento bancario ya fue conciliado contra un extracto
- **THEN** el movimiento espejo se registra igualmente
- **AND** nace `unreconciled`
- **AND** el movimiento original conserva su estado conciliado y su vínculo con el extracto

#### Scenario: El movimiento espejo queda pendiente de conciliar
- **WHEN** se lista la conciliación bancaria después de borrar una operación con movimiento bancario
- **THEN** el movimiento espejo aparece entre los pendientes de conciliar
- **AND** no se concilia automáticamente contra ninguna línea de extracto
