## MODIFIED Requirements

### Requirement: Sólo el camino del mostrador alimenta el arqueo

El sistema SHALL alimentar `cash_movements` de tipo `sale` desde el camino del mostrador —`quickSale()` y la confirmación de una orden de venta con forma de pago de `kind = 'cash'`— **de forma automática**, y desde el formulario de venta **únicamente mediante un opt-in explícito del usuario** que el servidor SHALL honrar sólo si se cumplen simultáneamente las tres condiciones siguientes: la forma de pago imputada tiene `kind = 'cash'`, existe una sesión de caja `open` en la sucursal efectiva de la venta, y la fecha de la venta es el día de hoy en `America/Argentina/Mendoza`. En ausencia del opt-in, el formulario NO SHALL generar `cash_movements`, aunque la venta esté imputada a una forma de pago de `kind = 'cash'`. Las tres condiciones SHALL verificarse en el servidor y NO SHALL delegarse en la interfaz: una solicitud que informe una sesión de caja sin cumplirlas SHALL fallar en vez de registrar el movimiento. La asimetría entre automático y opt-in es deliberada y SHALL declararse al usuario en la superficie que ofrece el selector: `expected_balance = opening_balance + Σ(cash_movements)` es la base del arqueo y su `difference` es una señal antifraude (RN-95), de modo que inyectar en una sesión abierta un importe que nadie depositó en el cajón convertiría toda diferencia en ruido; el opt-in es la afirmación explícita del usuario de que ese efectivo sí entró a esa caja, y el guard de fecha impide atribuir a una sesión abierta el efectivo de una venta retroactiva.

#### Scenario: Venta en efectivo desde el formulario sin opt-in no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra desde el formulario de venta una venta de 2000 imputada a una forma de pago de `kind = 'cash'` sin marcar el opt-in de caja
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`

#### Scenario: Venta en efectivo desde el formulario con opt-in sí altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos en la sucursal de la venta
- **WHEN** se registra hoy desde el formulario una venta de 2000 imputada a `kind = 'cash'` marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `sale` por 2000 contra esa sesión, con `reference_id` apuntando a la operación
- **AND** al cerrar la sesión declarando `counted_balance = 7000`, `expected_balance = 7000` y `difference = 0`

#### Scenario: Venta en efectivo desde el POS sí altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se cobra desde el POS una venta de 2000 con una forma de pago de `kind = 'cash'`
- **AND** se cierra la sesión declarando `counted_balance = 7000`
- **THEN** `expected_balance = 7000` y `difference = 0`

#### Scenario: El opt-in con fecha anterior a hoy es rechazado

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se registra desde el formulario una venta con fecha de ayer, imputada a `kind = 'cash'`, informando la sesión de caja
- **THEN** la operación falla con `cash_optin_requires_today` y no se crea ninguna venta ni movimiento de caja

#### Scenario: El opt-in sin sesión abierta es rechazado

- **GIVEN** una sucursal sin ninguna sesión de caja `open`
- **WHEN** se registra hoy desde el formulario una venta imputada a `kind = 'cash'` informando un identificador de sesión
- **THEN** la operación falla con `cash_optin_requires_open_session` y no se crea ninguna venta ni movimiento de caja

#### Scenario: El opt-in con una forma de pago que no es efectivo es rechazado

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se registra hoy desde el formulario una venta imputada a una forma de pago de `kind = 'transfer'` informando la sesión de caja
- **THEN** la operación falla con `cash_optin_requires_cash_kind` y no se crea ninguna venta ni movimiento de caja

#### Scenario: El opt-in exige que la sesión sea de la sucursal de la venta

- **GIVEN** dos sucursales, cada una con su caja, y una sesión abierta sólo en la sucursal B
- **WHEN** se registra hoy desde el formulario una venta en la sucursal A imputada a `kind = 'cash'` informando la sesión de la sucursal B
- **THEN** la operación falla con `cash_optin_requires_open_session` y el arqueo de la sesión de B no se ve afectado

#### Scenario: La superficie declara qué camino mueve la caja

- **WHEN** el usuario elige en el formulario de venta una forma de pago de `kind = 'cash'` y no se cumplen las condiciones del opt-in
- **THEN** la pantalla no ofrece el opt-in y explica cuál de las condiciones falta

#### Scenario: Una venta a cuenta corriente no toca la caja

- **GIVEN** una sesión de caja abierta
- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'credit'`
- **THEN** no se crea ningún `cash_movements` y el arqueo de esa sesión no se ve afectado
