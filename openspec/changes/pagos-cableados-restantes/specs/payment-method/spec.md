## MODIFIED Requirements

### Requirement: La forma de pago dispara efectos según el camino, no según la etiqueta

El sistema SHALL determinar los efectos sobre caja y cuenta corriente por el **camino** que registra la operación combinado con el `kind` de la forma de pago, y SHALL derivar ese `kind` en el servidor a partir de `payment_method_id`, nunca aceptándolo como dato del cliente. En el camino del mostrador (POS / `quickSale` / confirmación de orden de venta) los efectos SHALL ser automáticos: `kind = 'cash'` exige sesión de caja abierta y genera `cash_movements`; `kind = 'credit'` exige cliente y postea el cargo en `customer_account_movements`. En el camino de los formularios de venta y de compra, `kind = 'credit'` SHALL exigir la parte identificada (cliente en venta, proveedor en compra) y postear el cargo en la cuenta corriente correspondiente, mientras que `kind = 'cash'` SHALL generar `cash_movements` **sólo** ante un opt-in explícito del usuario que cumpla las tres condiciones de servidor definidas en la capability `cash-session`. Los `kind` restantes (`transfer`, `card`, `check`, `wallet`, `other`) SHALL comportarse como etiqueta a efectos de caja y cuenta corriente en todos los caminos, sin perjuicio de la contrapartida contable que la capability `journal-entry` les asigna. NO SHALL generarse `bank_movements` desde ningún camino de alta de venta o compra. Las superficies que ofrecen el selector SHALL declarar explícitamente qué efecto tiene cada elección, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple ni oculte un efecto que sí produce.

#### Scenario: Venta en efectivo desde el form sin opt-in no mueve caja

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** se registra una venta con la forma de pago de `kind = 'cash'` desde el form de venta
- **THEN** la venta se registra normalmente, no se crea ningún `cash_movement` y no se ofrece el opt-in

#### Scenario: Venta en efectivo desde el form con opt-in mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal de la venta
- **WHEN** se registra hoy una venta con la forma de pago de `kind = 'cash'` desde el form marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

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

#### Scenario: Forma de pago de transferencia no genera movimiento bancario

- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'transfer'`
- **THEN** la venta se confirma, no se crea ningún `bank_movements`, y la operación queda imputada a esa forma de pago

#### Scenario: El texto de apoyo nombra el efecto de cada elección

- **WHEN** el usuario elige en el form de venta una forma de pago de `kind = 'cash'` o de `kind = 'credit'`
- **THEN** la pantalla explica qué va a ocurrir con la caja o con la cuenta corriente del cliente antes de confirmar

## ADDED Requirements

### Requirement: La forma de pago imputada determina la contrapartida contable de la compra

El sistema SHALL propagar el `kind` de la forma de pago imputada a una compra hasta el evento de dominio que alimenta la partida doble, de modo que la contrapartida del asiento refleje cómo se pagó realmente la compra. Una compra sin forma de pago imputada SHALL propagarse como `credit`, preservando el comportamiento histórico.

#### Scenario: Compra en efectivo no queda como deuda con el proveedor

- **WHEN** se registra una compra imputada a una forma de pago de `kind = 'cash'`
- **THEN** el evento emitido transporta `payment_method = 'cash'` y el asiento acredita la cuenta de caja, no la de proveedores

#### Scenario: Compra sin forma de pago conserva el comportamiento anterior

- **WHEN** se registra una compra sin forma de pago imputada
- **THEN** el evento emitido transporta `payment_method = 'credit'` y el asiento acredita la cuenta de proveedores
