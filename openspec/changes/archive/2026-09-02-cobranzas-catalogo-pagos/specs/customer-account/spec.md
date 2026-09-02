## MODIFIED Requirements

### Requirement: PaymentReceived reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL, p_payment_method_id uuid DEFAULT NULL, p_bank_account_id uuid DEFAULT NULL, p_cash_session_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) **resuelve el `kind` de la forma de pago** consultando el catálogo por `p_payment_method_id` **bajo el `account_id` del tenant**, rechazando con `P0404` la forma de pago inexistente o de otra cuenta, con un mensaje que no revela cuál de los dos casos ocurrió; (c) resuelve o crea la `CustomerAccount` del cliente; (d) aplica idempotencia DEC-06 con `operation_kind = 'payment_received'`; (e) invoca el helper con `amount` negativo (`payment_received` reduce la deuda); (f) inserta una fila en `payments_received` con `payment_method_id`; (g) **rutea el ingreso de fondos por el `kind` derivado**: cuando el `kind` es bancario (`transfer` / `card` / `check` / `wallet`) SHALL delegar en el **helper compartido de movimiento bancario de operaciones** —el mismo que usan la venta, la compra y el gasto— con dirección de ingreso, `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro, obteniendo de él el mapa `kind → movement_type` (`card_settlement` para `card`, `transfer_in` para el resto) y el guard de período conciliado (`P0424`); cuando es `cash` **y se informa `p_cash_session_id`** SHALL invocar el helper intra-transaccional de caja con `amount` positivo, `movement_type = 'payment_received'` y referencia al cobro, sin tocar el ledger bancario; cuando es `cash` **sin** `p_cash_session_id`, o cuando el `kind` es `other`, o cuando no se informa forma de pago, SHALL registrar el cobro sin efecto sobre ningún libro de dinero; (h) emite el evento `PaymentReceived` al outbox con el `kind` derivado y `payment_method_id` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`.

El `kind` NO SHALL aceptarse como dato del cliente: la función NO SHALL contener ninguna enumeración literal de formas de pago. Una forma de pago de `kind = 'credit'` SHALL rechazarse con `P0400`, porque cancelar una cuenta corriente con cuenta corriente es circular.

Un `kind` bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`); esa exigencia SHALL conservarse aunque el helper compartido admita resolver la cuenta desde el destino configurado en la forma de pago, porque un destino sin configurar haría que el helper no escribiera el movimiento **sin levantar error**. Informar `p_cash_session_id` con un `kind` distinto de `cash` SHALL rechazarse con `P0422 cash_optin_requires_cash_kind`, y con una sesión que no esté `open` SHALL rechazarse con `P0422 cash_optin_requires_open_session`; la pertenencia de la sesión a la cuenta la aporta el punto de paso obligado del registro de movimientos de caja. El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia: un replay SHALL devolver el resultado original sin registrar un segundo movimiento.

`payments_received` SHALL persistir la forma de pago como `payment_method_id` con FK al catálogo, y NO SHALL conservar además una columna de texto con el mismo dato: la baja de una forma de pago es desactivación y preserva la imputación histórica, de modo que la referencia nunca queda colgada y un snapshot de texto sería una segunda fuente de verdad sin consumidor. El parámetro `p_payment_method_id` es **opcional** (`NULL` = sin imputar), y los cobros anteriores a este cambio SHALL permanecer sin imputar, sin backfill. La firma SHALL quedar como **única firma viva** de la función: la firma anterior —con la forma de pago como texto— SHALL eliminarse con `DROP FUNCTION` en la misma migración en lugar de convivir como sobrecarga, y los permisos SHALL re-otorgarse explícitamente porque el `DROP` los resetea. Un cobro que excede el saldo deudor sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar cobro disminuye el saldo
- **WHEN** se registra un `PaymentReceived` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `customer_account_movement` de tipo `payment_received` con `amount = −400` y `balance_after = 600`, y una fila en `payments_received`

#### Scenario: cobro idempotente no duplica
- **WHEN** se llama `rpc_register_payment_received` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo cobro, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si el `kind` es bancario), se inserta un solo `cash_movement` (si se informó sesión de caja) y la segunda llamada devuelve el resultado original (`replayed = true`)

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentReceived` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: sin permiso de escritura es rechazado
- **WHEN** un usuario sin rol owner/admin intenta registrar un cobro
- **THEN** la operación falla con `P0401`

#### Scenario: cobro por transferencia registra movimiento bancario en la misma transacción
- **WHEN** se registra un `PaymentReceived` de 400 imputado a una forma de pago de `kind = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `CustomerAccount` queda en `balance = 600` (con su `customer_account_movement` `payment_received` de `amount = −400`), existe una fila en `payments_received`, y existe un `bank_movement` de `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: cobro por billetera virtual registra movimiento bancario
- **WHEN** se registra un `PaymentReceived` imputado a una forma de pago de `kind = 'wallet'` con una cuenta bancaria activa
- **THEN** se crea un `bank_movement` de ingreso con `movement_type = 'transfer_in'` sobre esa cuenta, en el mismo commit
- **AND** el `kind` `wallet` es tratado como bancario igual que en el resto del sistema

#### Scenario: cobro imputado a `other` no toca ningún libro de dinero
- **WHEN** se registra un `PaymentReceived` de 400 imputado a una forma de pago de `kind = 'other'`
- **THEN** el saldo del cliente se reduce a 600 y el cobro queda imputado a esa forma de pago
- **AND** no se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: cobro imputado a cuenta corriente es rechazado
- **WHEN** se registra un `PaymentReceived` imputado a una forma de pago de `kind = 'credit'`
- **THEN** la operación falla con `P0400` y no se inserta ni el cobro, ni el movimiento de cuenta corriente, ni ningún movimiento de dinero

#### Scenario: forma de pago de otro tenant es rechazada
- **WHEN** se registra un `PaymentReceived` informando el identificador de una forma de pago de otra cuenta
- **THEN** la operación falla con `P0404` y no se inserta ninguna fila
- **AND** el mensaje no revela si el identificador existe en otra cuenta

#### Scenario: cobro en efectivo con sesión de caja ingresa al cajón
- **WHEN** se registra un `PaymentReceived` de 400 imputado a `kind = 'cash'` informando una sesión de caja abierta, sobre una cuenta con `balance = 1000`
- **THEN** el saldo del cliente se reduce a 600, existe una fila en `payments_received`, y existe un `cash_movement` de tipo `payment_received` con `amount = +400` y referencia al cobro, todo atómico en un solo commit
- **AND** no se inserta ninguna fila en `bank_movements`

#### Scenario: cobro en efectivo sin sesión de caja no toca ningún libro de dinero
- **WHEN** se registra un `PaymentReceived` de 400 imputado a `kind = 'cash'` sin informar sesión de caja
- **THEN** el saldo del cliente se reduce a 600 y NO se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: sesión de caja con kind no efectivo es rechazada
- **WHEN** se registra un `PaymentReceived` imputado a `kind = 'transfer'` informando una sesión de caja
- **THEN** la operación falla con `P0422 cash_optin_requires_cash_kind` y no se inserta ni el cobro, ni el movimiento de cuenta corriente, ni el movimiento bancario, ni el de caja

#### Scenario: sesión de caja cerrada es rechazada
- **WHEN** se registra un `PaymentReceived` en efectivo informando una sesión de caja que no está `open`
- **THEN** la operación falla con `P0422 cash_optin_requires_open_session` y no se inserta ninguna fila

#### Scenario: kind bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentReceived` imputado a un `kind` bancario y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400` cuando falta la cuenta, `P0412` cuando la cuenta no existe o está inactiva) y no se inserta ni el cobro ni el movimiento bancario
- **AND** la operación NO recae en el destino configurado en la forma de pago

#### Scenario: cobro sin forma de pago imputada
- **WHEN** se invoca `rpc_register_payment_received` sin `p_payment_method_id` ni `p_cash_session_id`
- **THEN** el cobro se registra con la imputación vacía y sin impacto en ningún libro de dinero

#### Scenario: cobro en un período bancario ya conciliado es rechazado
- **GIVEN** una sesión de conciliación cerrada cuyo período incluye la fecha de hoy para una cuenta bancaria
- **WHEN** se registra un `PaymentReceived` por un `kind` bancario contra esa cuenta
- **THEN** la operación falla con `P0424` y no se inserta ni el cobro ni ningún movimiento

#### Scenario: no queda una sobrecarga con la firma anterior
- **WHEN** se inspeccionan las funciones de registro de cobro tras la migración
- **THEN** existe exactamente una definición viva, con la forma de pago como identificador del catálogo, y sus permisos re-otorgados explícitamente
- **AND** no existe ninguna definición que reciba la forma de pago como texto

### Requirement: La superficie de cobro ofrece el impacto en caja pre-marcado y explica cuándo no aplica

La interfaz de registro de un cobro de cuenta corriente SHALL ofrecer las formas de pago del **catálogo de la cuenta** a través del componente selector compartido, en el contexto de cobranza, y NO SHALL declarar una lista propia de opciones.

Cuando la forma de pago elegida tiene `kind = 'cash'`, SHALL ofrecer la afirmación del impacto en caja **pre-marcada** si existe una sesión abierta, y SHALL mostrar el motivo concreto cuando no la hay, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado: cobrar en efectivo es, literalmente, poner plata en el cajón, y el estado previo a este cambio —el cobro que nunca llega al arqueo— se reproduciría si el usuario tuviera que acordarse de marcarlo.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean los formularios de venta, gasto y compra, adaptando únicamente el texto del motivo; la autoridad sobre la decisión SHALL seguir siendo el servidor. El `kind` que alimenta esa resolución SHALL derivarse de la forma de pago elegida en el catálogo, y NO SHALL inferirse del valor del control de selección: cuando el selector emite un identificador, comparar ese identificador contra la constante de efectivo daría siempre falso y **el bloque de impacto en caja dejaría de ofrecerse sin ningún error visible**. La exigencia de cuenta bancaria para los `kind` bancarios SHALL permanecer.

#### Scenario: Efectivo con caja abierta

- **GIVEN** una sesión de caja abierta en la cuenta
- **WHEN** el usuario elige una forma de pago de `kind = 'cash'` en el modal de cobro
- **THEN** la afirmación de impacto en caja aparece marcada, nombrando la sesión

#### Scenario: Efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta
- **WHEN** el usuario elige una forma de pago de `kind = 'cash'` en el modal de cobro
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta
- **AND** el cobro puede registrarse de todos modos, sin impacto en el arqueo

#### Scenario: El bloque de caja se ofrece con la forma de pago renombrada

- **GIVEN** una forma de pago de `kind = 'cash'` que el usuario renombró a "Caja chica"
- **AND** una sesión de caja abierta
- **WHEN** el usuario la elige en el modal de cobro
- **THEN** la afirmación de impacto en caja aparece marcada igual, porque la condición se evalúa sobre el `kind` y no sobre el nombre ni sobre el identificador

#### Scenario: Método bancario no ofrece el bloque de caja

- **WHEN** el usuario elige una forma de pago de `kind` bancario
- **THEN** el bloque de caja no se muestra y el selector de cuenta bancaria sigue siendo obligatorio

#### Scenario: El selector no ofrece cuenta corriente

- **WHEN** el usuario abre el selector de forma de pago en el modal de cobro
- **THEN** las formas de pago de `kind = 'credit'` no aparecen entre las opciones

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** un cobro en efectivo con sesión abierta
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** el cobro se registra sin movimiento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el modal de cobro se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
- **AND** el desplegable del selector se despliega dentro del modal con todas sus opciones alcanzables

## ADDED Requirements

### Requirement: El historial de cuenta corriente nombra la forma de pago configurada

El sistema SHALL exponer, para cada movimiento de tipo `payment_received` del historial de cuenta corriente, el **nombre** de la forma de pago con la que se registró el cobro, resuelto desde el catálogo a través de la imputación del documento, de modo que el usuario lea la etiqueta que él mismo configuró y no un término genérico.

Un movimiento cuyo cobro no tenga forma de pago imputada —los anteriores a este cambio, y los registrados sin imputar— SHALL exponer el dato vacío, y la superficie SHALL omitir la mención en lugar de mostrar un valor inventado. Un movimiento de un tipo distinto de `payment_received` SHALL exponer el dato vacío.

#### Scenario: Cobro imputado muestra el nombre configurado

- **GIVEN** un cobro imputado a una forma de pago que el usuario renombró a "Banco Nación"
- **WHEN** se consulta el historial de cuenta corriente del cliente
- **THEN** el movimiento del cobro expone "Banco Nación"

#### Scenario: Cobro histórico sin imputar

- **GIVEN** un cobro anterior a este cambio, sin forma de pago imputada
- **WHEN** se consulta el historial
- **THEN** el movimiento expone el dato vacío y la superficie no muestra ninguna forma de pago

#### Scenario: Cobro imputado a una forma de pago desactivada

- **GIVEN** un cobro imputado a una forma de pago que después fue dada de baja
- **WHEN** se consulta el historial
- **THEN** el movimiento sigue exponiendo su nombre, porque la baja es desactivación y preserva la imputación histórica

#### Scenario: Movimiento que no es un cobro

- **WHEN** se consulta un movimiento de tipo `sale`, `credit_note`, `adjustment` o una reversa
- **THEN** expone el dato de forma de pago vacío
