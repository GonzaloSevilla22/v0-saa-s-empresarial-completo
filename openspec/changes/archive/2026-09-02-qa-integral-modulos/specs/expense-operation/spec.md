# expense-operation — Delta

## ADDED Requirements

### Requirement: Los movimientos de libros de un gasto llevan su descripción como motivo

El sistema SHALL registrar la descripción del gasto como motivo (`description`) tanto en el movimiento de caja (`c28_register_cash_movement`) como en el movimiento bancario (`_pay_register_operation_bank_movement`) que el gasto genera, de modo que desde el historial de caja o de banco siempre se sepa a qué gasto corresponde el egreso — la descripción del gasto es un dato obligatorio, así que el motivo nunca puede quedar vacío para un movimiento nuevo. Los movimientos de reversa del borrado SHALL llevar el mismo motivo.

#### Scenario: Gasto en efectivo con motivo en caja

- **GIVEN** un gasto en efectivo con opt-in de caja y descripción "Alquiler del local"
- **WHEN** se crea el gasto
- **THEN** el movimiento `expense` de la sesión de caja lleva "Alquiler del local" como motivo visible en el historial

#### Scenario: Gasto bancario con motivo en el ledger

- **GIVEN** un gasto por transferencia con cuenta bancaria seleccionada
- **WHEN** se crea el gasto
- **THEN** el movimiento bancario lleva la descripción del gasto como motivo, no un motivo vacío

#### Scenario: Backfill de los movimientos históricos de gastos

- **GIVEN** movimientos de caja o banco generados por gastos antes de este change, con motivo vacío
- **WHEN** se aplica la migración
- **THEN** esos movimientos quedan con la descripción de su gasto como motivo, mediante un bloque idempotente que no toca movimientos con motivo ya presente
