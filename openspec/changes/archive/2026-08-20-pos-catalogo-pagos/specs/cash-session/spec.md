## ADDED Requirements

### Requirement: Sólo el camino del mostrador alimenta el arqueo

El sistema SHALL alimentar `cash_movements` de tipo `sale` **exclusivamente** desde el camino del mostrador —`quickSale()` y la confirmación de una orden de venta con forma de pago de `kind = 'cash'`—, y NO SHALL generarlos desde el alta ni la edición de una venta hecha por el formulario de venta, aunque esa venta esté imputada a una forma de pago de `kind = 'cash'`. La asimetría es deliberada y SHALL declararse al usuario en la superficie que ofrece el selector: `expected_balance = opening_balance + Σ(cash_movements)` es la base del arqueo y su `difference` es una señal antifraude (RN-95), de modo que inyectar en una sesión abierta el importe de una venta que nadie depositó en el cajón convertiría toda diferencia en ruido. A esto se suma que el formulario admite fechas anteriores, para las cuales no existe una sesión de caja a la que atribuir el movimiento.

#### Scenario: Venta en efectivo desde el formulario no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra desde el formulario de venta una venta de 2000 imputada a una forma de pago de `kind = 'cash'`
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`

#### Scenario: Venta en efectivo desde el POS sí altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se cobra desde el POS una venta de 2000 con una forma de pago de `kind = 'cash'`
- **AND** se cierra la sesión declarando `counted_balance = 7000`
- **THEN** `expected_balance = 7000` y `difference = 0`

#### Scenario: La superficie declara qué camino mueve la caja

- **WHEN** el usuario elige en el formulario de venta una forma de pago de `kind = 'cash'`
- **THEN** la pantalla explica que el movimiento de caja lo genera la venta desde el POS, que exige una sesión abierta

#### Scenario: Una venta a cuenta corriente no toca la caja

- **GIVEN** una sesión de caja abierta
- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'credit'`
- **THEN** no se crea ningún `cash_movements` y el arqueo de esa sesión no se ve afectado
