## MODIFIED Requirements

### Requirement: Sólo el camino del mostrador alimenta el arqueo

El sistema SHALL alimentar `cash_movements` de tipo `sale` desde el camino del mostrador —`quickSale()` y la confirmación de una orden de venta con forma de pago de `kind = 'cash'`— **de forma automática**, y SHALL alimentar el arqueo desde **todos los demás caminos únicamente mediante un opt-in explícito del usuario**. Los caminos con opt-in son cuatro: el formulario de venta (`sale`), el gasto (`expense`), la compra (`purchase_payment`) y el cobro o pago de una cuenta corriente (`payment_received` / `payment_made`).

Para los caminos que registran un **documento con fecha y sucursal propias** —formulario de venta, gasto y compra— el servidor SHALL honrar el opt-in sólo si se cumplen simultáneamente las tres condiciones siguientes: la forma de pago imputada tiene `kind = 'cash'`, existe una sesión de caja `open` en la sucursal efectiva del documento, y la fecha del documento es el día de hoy en `America/Argentina/Mendoza`.

Para el **cobro y el pago de cuenta corriente** el servidor SHALL honrar el opt-in si se cumplen las dos condiciones aplicables: **la forma de pago imputada tiene `kind = 'cash'`**, y la sesión de caja informada está `open` y pertenece a la cuenta. La condición de fecha NO SHALL exigirse, y la de sucursal NO SHALL exigirse como coincidencia: un cobro no tiene fecha ni sucursal propias —se registra en el instante en que ocurre y su sucursal es, por construcción, la de la caja elegida—, de modo que ambas condiciones son verdaderas por diseño y especificarlas como guards sugeriría un caso retroactivo que el modelo no admite. La pertenencia de la sesión a la cuenta SHALL verificarse igual, y la aporta el punto de paso obligado del registro de movimientos de caja.

La condición de efectivo SHALL evaluarse, **en los cuatro caminos por igual**, sobre el `kind` derivado del catálogo de formas de pago a partir del identificador imputado al documento, y NO SHALL evaluarse sobre ninguna etiqueta de texto recibida del cliente ni sobre el valor de un control de selección de la interfaz. Esta uniformidad es normativa: el cobro y el pago de cuenta corriente eran los últimos caminos que resolvían la condición contra una taxonomía de texto propia, y mientras lo hicieran la misma pregunta —«¿esto es efectivo?»— tenía dos implementaciones distintas que podían divergir sin que nada lo detectara.

En ausencia del opt-in, ningún camino distinto del mostrador SHALL generar `cash_movements`, aunque la operación esté imputada a efectivo. Todas las condiciones SHALL verificarse en el servidor y NO SHALL delegarse en la interfaz: una solicitud que informe una sesión de caja sin cumplirlas SHALL fallar en vez de registrar el movimiento.

La asimetría entre automático y opt-in es deliberada y SHALL declararse al usuario en la superficie que ofrece el selector: `expected_balance = opening_balance + Σ(cash_movements)` es la base del arqueo y su `difference` es una señal antifraude (RN-95), de modo que inyectar en una sesión abierta un importe que nadie depositó en el cajón convertiría toda diferencia en ruido; el opt-in es la afirmación explícita del usuario de que ese efectivo sí entró o salió de esa caja, y el guard de fecha impide atribuir a una sesión abierta el efectivo de un documento retroactivo.

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

#### Scenario: Compra en efectivo con opt-in resta del arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos en la sucursal de la compra
- **WHEN** se registra hoy una compra de 2000 imputada a `kind = 'cash'` marcando el opt-in de caja
- **AND** se cierra la sesión declarando `counted_balance = 3000`
- **THEN** `expected_balance = 3000` y `difference = 0`

#### Scenario: Compra en efectivo sin opt-in no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra una compra de 2000 imputada a `kind = 'cash'` sin marcar el opt-in
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`

#### Scenario: Cobro de cuenta corriente en efectivo con opt-in suma al arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un cobro de 1200 imputado a una forma de pago de `kind = 'cash'` sobre la cuenta corriente de un cliente, confirmando el impacto en caja
- **AND** se cierra la sesión declarando `counted_balance = 6200`
- **THEN** `expected_balance = 6200` y `difference = 0`

#### Scenario: Pago a proveedor en efectivo con opt-in resta del arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un pago de 1200 imputado a una forma de pago de `kind = 'cash'` a un proveedor, confirmando el impacto en caja
- **AND** se cierra la sesión declarando `counted_balance = 3800`
- **THEN** `expected_balance = 3800` y `difference = 0`

#### Scenario: El cobro en efectivo sin opt-in no altera el arqueo

- **GIVEN** una sesión de caja abierta con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un cobro de 1200 en efectivo sin confirmar el impacto en caja
- **AND** se cierra la sesión declarando `counted_balance = 5000`
- **THEN** `expected_balance = 5000` y `difference = 0`
- **AND** el saldo del cliente igual se redujo en 1200

#### Scenario: El cobro con forma de pago de efectivo renombrada suma igual al arqueo

- **GIVEN** una sesión de caja abierta y una forma de pago de `kind = 'cash'` que el usuario renombró a "Caja chica"
- **WHEN** se registra un cobro imputado a ella, confirmando el impacto en caja
- **THEN** el movimiento de caja se registra igual, porque la condición se evalúa sobre el `kind` derivado del catálogo y no sobre el nombre

#### Scenario: El cobro imputado a una forma de pago no efectiva no puede optar por caja

- **GIVEN** una sesión de caja abierta
- **WHEN** se registra un cobro imputado a una forma de pago de `kind` bancario informando esa sesión
- **THEN** la operación falla con `cash_optin_requires_cash_kind` y no se registra ni el cobro ni ningún movimiento

#### Scenario: El cobro no exige que la fecha sea hoy

- **GIVEN** una sesión de caja abierta
- **WHEN** se registra un cobro en efectivo confirmando el impacto en caja
- **THEN** el movimiento se registra sin ninguna verificación de fecha, porque el cobro se registra en el instante en que ocurre

#### Scenario: El cobro contra una sesión de otra cuenta es rechazado

- **GIVEN** una sesión de caja abierta perteneciente a otra cuenta
- **WHEN** se registra un cobro en efectivo informando esa sesión
- **THEN** la operación es rechazada, no se registra el cobro y la cantidad de movimientos de la sesión ajena queda sin cambios

#### Scenario: El opt-in con fecha anterior a hoy es rechazado

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se registra desde el formulario una venta con fecha de ayer, imputada a `kind = 'cash'`, informando la sesión de caja
- **THEN** la operación falla con `cash_optin_requires_today` y no se crea ninguna venta ni movimiento de caja

#### Scenario: El opt-in sin sesión abierta es rechazado

- **GIVEN** una sucursal sin ninguna sesión de caja `open`
- **WHEN** se registra hoy desde el formulario una venta imputada a `kind = 'cash'` informando un identificador de sesión
- **THEN** la operación falla con `cash_optin_requires_open_session` y no se crea ninguna venta ni movimiento de caja
