## ADDED Requirements

### Requirement: Destino bancario por defecto de la forma de pago

El sistema SHALL permitir asociar a cada forma de pago del catálogo una cuenta bancaria destino por defecto (`payment_methods.bank_account_id`, nullable, FK a `bank_accounts` con `ON DELETE SET NULL`), de modo que una organización configure **una sola vez** a qué cuenta entra el dinero de cada método y no vuelva a decidirlo en cada operación. El destino SHALL ser opcional: una forma de pago sin destino configurado NO SHALL registrar movimiento bancario, y ese es el estado inicial de todas las formas de pago sembradas por el provisioning. La asignación SHALL validarse contra la organización (la cuenta bancaria pertenece a la misma cuenta, está activa y no está borrada) y SHALL estar gateada por el mismo rol que el resto de la gestión del catálogo (`owner`/`admin`). La actualización del destino SHALL usar contrato tri-estado —no informado (conserva), informado con valor (asigna), informado en nulo (desasigna)— para que desasignar el destino sea expresable y no se confunda con no tocarlo. Configurar un destino sobre una forma de pago cuyo `kind` no es bancario SHALL rechazarse, porque ese destino nunca se usaría.

#### Scenario: Asignar el destino bancario a una forma de pago

- **GIVEN** un `owner` con una cuenta bancaria activa "Galicia CC"
- **WHEN** asigna esa cuenta como destino de la forma de pago "Transferencia bancaria"
- **THEN** la forma de pago queda con ese destino y las ventas siguientes por ese método registran su movimiento contra "Galicia CC"

#### Scenario: Desasignar el destino bancario

- **WHEN** el `owner` actualiza la forma de pago informando el destino en nulo
- **THEN** la forma de pago queda sin destino y las ventas siguientes por ese método no registran movimiento bancario

#### Scenario: Actualizar el nombre no toca el destino

- **WHEN** el `owner` renombra la forma de pago sin informar el campo de destino
- **THEN** el destino bancario configurado se conserva sin cambios

#### Scenario: Las formas de pago sembradas nacen sin destino

- **WHEN** se provisiona una cuenta nueva y se siembra su catálogo de formas de pago
- **THEN** todas las formas nacen sin destino bancario y ninguna operación registra movimiento bancario hasta que alguien lo configure

#### Scenario: Un member no puede configurar el destino

- **WHEN** un usuario con rol `member` intenta asignar el destino bancario de una forma de pago
- **THEN** la operación es rechazada por rol y el catálogo no cambia

#### Scenario: Destino bancario sobre un kind no bancario es rechazado

- **WHEN** se intenta asignar una cuenta bancaria como destino de una forma de pago de `kind = 'cash'`
- **THEN** la operación es rechazada y la forma de pago queda sin destino

#### Scenario: Borrar la cuenta bancaria degrada el default sin romper el catálogo

- **GIVEN** una forma de pago con destino "Galicia CC"
- **WHEN** esa cuenta bancaria se elimina
- **THEN** la forma de pago queda sin destino y sigue siendo usable, sin registrar movimiento bancario

## MODIFIED Requirements

### Requirement: La forma de pago dispara efectos según el camino, no según la etiqueta

El sistema SHALL determinar los efectos sobre caja y cuenta corriente por el **camino** que registra la operación combinado con el `kind` de la forma de pago, y SHALL derivar ese `kind` en el servidor a partir de `payment_method_id`, nunca aceptándolo como dato del cliente. En el camino del mostrador (POS / `quickSale` / confirmación de orden de venta) los efectos SHALL ser automáticos: `kind = 'cash'` exige sesión de caja abierta y genera `cash_movements`; `kind = 'credit'` exige cliente y postea el cargo en `customer_account_movements`. En el camino de los formularios de venta y de compra, `kind = 'credit'` SHALL exigir la parte identificada (cliente en venta, proveedor en compra) y postear el cargo en la cuenta corriente correspondiente, mientras que `kind = 'cash'` SHALL generar `cash_movements` **sólo** ante un opt-in explícito del usuario que cumpla las tres condiciones de servidor definidas en la capability `cash-session`. Los `kind` bancarios (`transfer`, `card`, `check`, `wallet`) SHALL generar un `bank_movement` en el ledger operativo —en todos los caminos de alta de venta y de compra— **únicamente** cuando se resuelva una cuenta bancaria destino según las reglas de la capability `bank-movement`; sin destino resuelto SHALL comportarse como etiqueta, que es el estado inicial de toda forma de pago sembrada. El `kind = 'other'` SHALL comportarse siempre como etiqueta a efectos de caja, cuenta corriente y banco. Nada de esto SHALL alterar la contrapartida contable que la capability `journal-entry` asigna a cada `kind`, que se sigue posteando de forma asíncrona por el outbox y es independiente del ledger operativo. Las superficies que ofrecen el selector SHALL declarar explícitamente qué efecto tiene cada elección, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple ni oculte un efecto que sí produce.

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

#### Scenario: Forma de pago de transferencia con destino configurado genera movimiento bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se cobra desde el POS con esa forma de pago
- **THEN** la venta se confirma y se crea un `bank_movements` de ingreso contra esa cuenta, en el mismo commit

#### Scenario: Forma de pago de transferencia sin destino no genera movimiento bancario

- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'transfer'` sin destino bancario configurado y sin informar cuenta en la operación
- **THEN** la venta se confirma, no se crea ningún `bank_movements`, y la operación queda imputada a esa forma de pago

#### Scenario: El texto de apoyo nombra el efecto de cada elección

- **WHEN** el usuario elige en el form de venta una forma de pago de `kind = 'cash'`, de `kind = 'credit'` o de un `kind` bancario con destino configurado
- **THEN** la pantalla explica qué va a ocurrir con la caja, con la cuenta corriente del cliente o con la cuenta bancaria antes de confirmar

### Requirement: Superficies de la forma de pago

El sistema SHALL exponer la forma de pago en: (a) el gestor del catálogo dentro de `/configuracion`, junto al de centros de costo, visible sólo para `owner`/`admin`, **incluyendo la asignación del destino bancario por defecto de cada forma de pago, con el estado sin destino rotulado como "no registra movimiento bancario"**; (b) un selector "Forma de pago" en el alta y edición de ventas y de compras, que ofrece sólo las formas activas, **acompañado de un selector de cuenta bancaria que aparece únicamente cuando el `kind` elegido es bancario y la organización tiene cuentas bancarias cargadas**; (c) un badge con la forma de pago y un filtro por forma de pago en los listados de ventas y de compras; (d) la pantalla `/reportes/formas-pago`, alcanzable desde una entrada propia del sidebar y sin gate de plan —mismo criterio que el reporte de centros de costo, porque gatearlo dejaría al plan free imputando datos que no puede leer; y (e) la grilla de formas de pago del POS (`/ventas/pos`), con sus estados propios: indicador de sesión de caja cuando el `kind` es `cash`, bloque de cliente y saldo cuando es `credit`, **y un indicador de cuenta bancaria destino cuando el `kind` es bancario, que muestra el destino resuelto y permite cambiarlo en una sola pulsación sin bloquear el cobro**. La superficie del POS NO SHALL exigir elegir cuenta bancaria para cobrar, y NO SHALL mostrar el indicador cuando la organización no tiene cuentas bancarias cargadas, de modo que el mostrador conserve su fricción actual para quien no lleva el banco en el sistema. Toda superficie nueva SHALL usar los tokens semánticos y los componentes base del design system, y SHALL verificarse en desktop y mobile y en tema claro y oscuro.

#### Scenario: Alta de venta con el selector

- **WHEN** un usuario abre el form de venta
- **THEN** ve el selector "Forma de pago" con las formas activas de su cuenta y la opción de dejarlo sin especificar

#### Scenario: Filtrar el listado por forma de pago

- **GIVEN** operaciones imputadas a distintas formas de pago
- **WHEN** el usuario filtra el listado por "Efectivo"
- **THEN** sólo ve las operaciones imputadas a "Efectivo"

#### Scenario: El member no ve el gestor del catálogo

- **GIVEN** un usuario con rol `member`
- **WHEN** abre `/configuracion`
- **THEN** no se le ofrece la gestión del catálogo de formas de pago, aunque sí puede elegir formas de pago al operar

#### Scenario: El POS muestra el estado de caja sólo para efectivo

- **GIVEN** un usuario en el POS
- **WHEN** elige una forma de pago de `kind` distinto de `cash`
- **THEN** el indicador de sesión de caja no se muestra y el cobro no queda condicionado a una sesión abierta

#### Scenario: El POS muestra el destino bancario resuelto sin pedir una pulsación

- **GIVEN** una organización con cuentas bancarias y la forma de pago "Transferencia bancaria" con destino "Galicia CC"
- **WHEN** el usuario elige esa forma de pago en el POS
- **THEN** ve el destino "Galicia CC" indicado junto a la grilla, con la opción de cambiarlo, y puede cobrar sin ninguna pulsación adicional

#### Scenario: El POS no muestra nada bancario si la organización no tiene cuentas

- **GIVEN** una organización sin ninguna cuenta bancaria cargada
- **WHEN** el usuario elige una forma de pago de `kind = 'transfer'` en el POS
- **THEN** no se muestra indicador ni selector de cuenta bancaria y el cobro procede igual que antes de este change

#### Scenario: El gestor del catálogo permite configurar el destino

- **GIVEN** un `owner` en `/configuracion`
- **WHEN** abre el gestor de formas de pago
- **THEN** ve para cada forma su destino bancario (o el rótulo de que no registra movimiento bancario) y puede asignarlo o quitarlo desde ahí
