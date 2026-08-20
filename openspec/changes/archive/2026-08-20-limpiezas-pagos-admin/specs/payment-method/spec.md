## MODIFIED Requirements

### Requirement: Seed de formas de pago en el provisioning de la cuenta

El sistema SHALL sembrar siete formas de pago al crear una cuenta —Efectivo (`cash`), Transferencia bancaria (`transfer`), Tarjeta (`card`), Billetera virtual (`wallet`), Cuenta corriente (`credit`), Otro (`other`) y **Cheque (`check`)**— de modo que un tenant nuevo pueda imputar la forma de pago sin configuración manual, incluyendo el `kind` `check` que el CHECK del vocabulario admite pero que el seed original (`metodos-pago-operaciones`) no sembraba (OQ-1: sin este 7º método, la resolución legacy de `sales-order` nunca imputaba una venta con cheque). El seed SHALL ejecutarse dentro de `handle_new_user` envuelto de forma que un fallo suyo **NUNCA** aborte el signup (degrada con warning), SHALL ser idempotente, y SHALL aplicarse por backfill a las cuentas ya existentes.

#### Scenario: Cuenta nueva nace con el catálogo sembrado

- **WHEN** se registra un usuario nuevo y se provisiona su cuenta
- **THEN** la cuenta tiene las siete formas de pago activas, sin intervención manual

#### Scenario: El seed no puede romper el registro

- **GIVEN** una condición que hace fallar el sub-bloque de seed de formas de pago
- **WHEN** se registra un usuario nuevo
- **THEN** el perfil, la cuenta y la membresía se crean igual y el fallo del seed sólo deja un warning

#### Scenario: Re-ejecución idempotente

- **GIVEN** una cuenta que ya tiene el catálogo sembrado
- **WHEN** el backfill vuelve a ejecutarse
- **THEN** no se duplica ninguna forma de pago

#### Scenario: Cuenta existente sin Cheque lo recibe por backfill

- **GIVEN** una cuenta sembrada antes de este change, con las 6 formas de pago originales y sin `kind = 'check'`
- **WHEN** se aplica la migración de `limpiezas-pagos-admin`
- **THEN** la cuenta queda con una 7ª forma de pago "Cheque" (`kind = 'check'`), activa, sin alterar las 6 existentes

### Requirement: Vocabulario cerrado de `kind` compatible con las taxonomías existentes

El sistema SHALL restringir `payment_methods.kind` por CHECK al conjunto `{cash, transfer, card, check, wallet, credit, other}`, y ese CHECK SHALL ser el **único** lugar donde vive el vocabulario de formas de pago del sistema. El `name` SHALL ser la etiqueta que ve y edita el usuario; el `kind` SHALL ser lo único que consuman los subsistemas para razonar sobre la forma de pago. `sales_orders` NO SHALL tener una columna de texto con su propia copia del vocabulario: la forma de pago de una orden SHALL leerse siempre por `payment_method_id → payment_methods.kind`. El CHECK de las RPCs de cobro/pago (`{cash, transfer, card, check}`) sigue siendo un subconjunto propio, sin tocar.

#### Scenario: `kind` fuera del vocabulario es rechazado

- **WHEN** se intenta persistir una forma de pago con `kind = 'crypto'`
- **THEN** la escritura es rechazada por el CHECK

#### Scenario: Renombrar no cambia la semántica

- **GIVEN** la forma de pago sembrada "Transferencia bancaria" con `kind = 'transfer'`
- **WHEN** el usuario la renombra a "Banco Nación"
- **THEN** el `kind` sigue siendo `transfer` y todo consumidor que agrupa por `kind` la sigue tratando como transferencia

#### Scenario: El vocabulario tiene una sola definición

- **WHEN** se inspecciona el schema en busca de CHECKs que enumeren formas de pago
- **THEN** existe únicamente `payment_methods_kind_check` con los 7 valores, y no existe ningún `sales_orders_payment_method_check`

### Requirement: Lectura de la forma de pago en operaciones nacidas en el POS

El sistema SHALL persistir `payment_method_id` en todas las filas legacy de `sales` de una venta nacida en el POS cuando la orden lleva forma de pago imputada, de modo que las ventas nuevas no dependan de ninguna derivación. Para las operaciones históricas cuyas filas de `sales` no tienen `payment_method_id`, el sistema SHALL conservar la derivación **de lectura** desde el `payment_method_id` de la orden de venta asociada (`sales_orders`), resolviendo el catálogo por identidad y NO por `kind`. La imputación explícita SHALL ganar siempre sobre la derivación, y la derivación NO SHALL escribir en `sales`, `sales_orders` ni `payment_methods`.

La derivación por identidad SHALL reemplazar a la derivación por `kind`: `payment_methods.kind` no es único dentro de una cuenta, por lo que un JOIN por `kind` puede devolver más de una fila y duplicar la operación en los listados. El JOIN SHALL ser por `payment_methods.id = sales_orders.payment_method_id`.

#### Scenario: Venta nueva del POS trae su forma de pago persistida

- **WHEN** se cobra desde el POS eligiendo una forma de pago del catálogo
- **THEN** todas las filas de `sales` de esa operación quedan con ese `payment_method_id`, sin necesidad de derivación

#### Scenario: Venta histórica sin imputación se sigue mostrando por derivación

- **GIVEN** una venta previa cuyas filas de `sales` tienen `payment_method_id = NULL` pero cuya orden de venta tiene `payment_method_id` imputado
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación se muestra con la forma de pago de la orden, y ninguna fila de `sales` es modificada por la lectura

#### Scenario: La imputación explícita gana sobre la derivación

- **GIVEN** una operación con `payment_method_id` persistido en `sales`
- **WHEN** se lista
- **THEN** se muestra la forma de pago persistida, sin consultar la orden de venta

#### Scenario: Dos formas de pago del mismo kind no duplican la operación

- **GIVEN** una cuenta con dos formas de pago vivas de `kind = 'transfer'` y una venta del POS imputada a una de ellas
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación aparece exactamente una vez, con la forma de pago efectivamente imputada

#### Scenario: Operación sin forma de pago resoluble se muestra sin imputar

- **GIVEN** una venta cuyas filas de `sales` y cuya orden de venta tienen ambas `payment_method_id = NULL`
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación se muestra sin forma de pago ("Sin especificar"), sin error

## REMOVED Requirements

### Requirement: El vocabulario de `sales_orders.payment_method` es el vocabulario del catálogo

**Reason**: El requirement existía para mantener sincronizadas dos copias del mismo vocabulario (el CHECK de `sales_orders.payment_method` y el de `payment_methods.kind`) mientras la columna de texto se conservaba deliberadamente como columna derivada. Al retirarse esa columna, la sincronización deja de tener objeto: queda un único CHECK, que es exactamente el invariante que el requirement perseguía. Su contenido vivo se absorbe en "Vocabulario cerrado de `kind` compatible con las taxonomías existentes".

**Migration**: La forma de pago de una orden se lee por `sales_orders.payment_method_id → payment_methods.kind`. Todo consumidor que leyera el texto `sales_orders.payment_method` SHALL migrar a ese join. No se requiere backfill de datos: al momento del retiro, el 100% de las órdenes de producción (120/120) tiene `payment_method_id` poblado, y el valor del texto es reconstruible en su totalidad desde `payment_method_id`. La clave `payment_method` del payload de los eventos de dominio (`SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`) NO cambia: sigue transportando el `kind` efectivo, ya derivado por el emisor desde `payment_method_id`.
