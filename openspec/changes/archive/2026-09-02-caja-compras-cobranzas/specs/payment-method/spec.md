## MODIFIED Requirements

### Requirement: La forma de pago dispara efectos según el camino, no según la etiqueta

El sistema SHALL determinar los efectos sobre caja y cuenta corriente por el **camino** que registra la operación combinado con el `kind` de la forma de pago, y SHALL derivar ese `kind` en el servidor a partir de `payment_method_id`, nunca aceptándolo como dato del cliente. En el camino del mostrador (POS / `quickSale` / confirmación de orden de venta) los efectos SHALL ser automáticos: `kind = 'cash'` exige sesión de caja abierta y genera `cash_movements`; `kind = 'credit'` exige cliente y postea el cargo en `customer_account_movements`. En el camino de los formularios de venta y de compra, `kind = 'credit'` SHALL exigir la parte identificada (cliente en venta, proveedor en compra) y postear el cargo en la cuenta corriente correspondiente, mientras que `kind = 'cash'` SHALL generar `cash_movements` **sólo** ante un opt-in explícito del usuario que cumpla las tres condiciones de servidor definidas en la capability `cash-session` — **en los dos formularios por igual**: la venta genera un movimiento de tipo `sale` y la compra uno de tipo `purchase_payment` con signo de egreso. Los `kind` bancarios (`transfer`, `card`, `check`, `wallet`) SHALL generar un `bank_movement` en el ledger operativo —en todos los caminos de alta de venta y de compra— **únicamente** cuando se resuelva una cuenta bancaria destino según las reglas de la capability `bank-movement`; sin destino resuelto SHALL comportarse como etiqueta, que es el estado inicial de toda forma de pago sembrada. El `kind = 'other'` SHALL comportarse siempre como etiqueta a efectos de caja, cuenta corriente y banco. Nada de esto SHALL alterar la contrapartida contable que la capability `journal-entry` asigna a cada `kind`, que se sigue posteando de forma asíncrona por el outbox y es independiente del ledger operativo. Las superficies que ofrecen el selector SHALL declarar explícitamente qué efecto tiene cada elección, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple ni oculte un efecto que sí produce.

La simetría entre venta y compra SHALL ser total en la rama de efectivo: hasta este cambio la compra imputada a `kind = 'cash'` era la única imputación del catálogo que no producía **ningún** efecto en ningún libro —ni caja, ni banco, ni cuenta corriente—, de modo que la etiqueta describía un hecho que el sistema no registraba en ninguna parte.

#### Scenario: Venta en efectivo desde el form sin opt-in no mueve caja

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** se registra una venta con la forma de pago de `kind = 'cash'` desde el form de venta
- **THEN** la venta se registra normalmente, no se crea ningún `cash_movement` y no se ofrece el opt-in

#### Scenario: Venta en efectivo desde el form con opt-in mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal de la venta
- **WHEN** se registra hoy una venta con la forma de pago de `kind = 'cash'` desde el form marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

#### Scenario: Compra en efectivo desde el form con opt-in mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal de la compra
- **WHEN** se registra hoy una compra con la forma de pago de `kind = 'cash'` desde el form marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `purchase_payment` con signo de egreso por el total, en el mismo commit que el ingreso de stock

#### Scenario: Compra en efectivo desde el form sin opt-in no mueve caja

- **WHEN** se registra una compra con la forma de pago de `kind = 'cash'` sin marcar el opt-in
- **THEN** la compra se registra normalmente y no se crea ningún `cash_movement` ni `bank_movement`

#### Scenario: Venta en efectivo desde el POS sí mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se cobra desde el POS con la forma de pago de `kind = 'cash'`
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

#### Scenario: Cuenta corriente en el form sí genera cargo

- **WHEN** se registra una venta desde el form con la forma de pago de `kind = 'credit'` y un cliente seleccionado
- **THEN** la venta queda imputada a esa forma de pago y se crea el cargo correspondiente en `customer_account_movements` en el mismo commit

#### Scenario: Cuenta corriente en el form sin cliente es rechazada

- **WHEN** se registra una venta desde el form con la forma de pago de `kind = 'credit'` sin cliente
- **THEN** la operación falla con `credit_requires_client` y no se registra ni la venta ni ningún cargo

#### Scenario: El kind se deriva en el servidor

- **WHEN** una solicitud informa un `payment_method_id` de `kind = 'transfer'` junto con un texto de forma de pago que dice `cash`
- **THEN** el servidor rechaza la incoherencia y no aplica los efectos de efectivo

#### Scenario: Forma de pago de transferencia con destino configurado genera movimiento bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se cobra desde el POS con esa forma de pago
- **THEN** la venta se confirma y se crea un `bank_movements` de ingreso contra esa cuenta, en el mismo commit

#### Scenario: Forma de pago de transferencia sin destino no genera movimiento bancario

- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'transfer'` sin destino bancario configurado y sin informar cuenta en la operación
- **THEN** la venta se confirma, no se crea ningún `bank_movements`, y la operación queda imputada a esa forma de pago

#### Scenario: El texto de apoyo nombra el efecto de cada elección

- **WHEN** el usuario elige en el form de venta o en el de compra una forma de pago de `kind = 'cash'`, de `kind = 'credit'` o de un `kind` bancario con destino configurado
- **THEN** la pantalla explica qué va a ocurrir con la caja, con la cuenta corriente de la parte o con la cuenta bancaria antes de confirmar
