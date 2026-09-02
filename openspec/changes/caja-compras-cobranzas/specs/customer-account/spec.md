## MODIFIED Requirements

### Requirement: PaymentReceived reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL, p_cash_session_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `CustomerAccount` del cliente; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_received'`; (d) invoca el helper con `amount` negativo (`payment_received` reduce la deuda); (e) inserta una fila en `payments_received`; (f) **rutea el ingreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` positivo (ingreso), `movement_type` derivado (`transfer_in` para transfer/check, `card_settlement` para card), `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro; cuando es `cash` **y se informa `p_cash_session_id`** SHALL invocar el helper intra-transaccional de caja con `amount` positivo, `movement_type = 'payment_received'` y referencia al cobro, sin tocar el ledger bancario; cuando es `cash` **sin** `p_cash_session_id` SHALL registrar el cobro sin efecto sobre ningún libro de dinero; (g) emite el evento `PaymentReceived` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`.

Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Informar `p_cash_session_id` con un método distinto de `cash` SHALL rechazarse con `P0422 cash_optin_requires_cash_kind`, y con una sesión que no esté `open` SHALL rechazarse con `P0422 cash_optin_requires_open_session`; la pertenencia de la sesión a la cuenta la aporta el punto de paso obligado del registro de movimientos de caja. El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia: un replay SHALL devolver el resultado original sin registrar un segundo movimiento.

Los parámetros `p_payment_method`, `p_bank_account_id` y `p_cash_session_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`/`NULL`): las firmas y llamadas previas siguen funcionando y conservan su comportamiento —un cobro en efectivo sin sesión informada no toca ningún libro, exactamente como antes de este cambio. La firma extendida SHALL quedar como **única firma viva** de la función: la firma anterior SHALL eliminarse en la misma migración en lugar de convivir como sobrecarga. Un cobro que excede el saldo deudor sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar cobro disminuye el saldo
- **WHEN** se registra un `PaymentReceived` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `customer_account_movement` de tipo `payment_received` con `amount = −400` y `balance_after = 600`, y una fila en `payments_received`

#### Scenario: cobro idempotente no duplica
- **WHEN** se llama `rpc_register_payment_received` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo cobro, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si es método bancario), se inserta un solo `cash_movement` (si se informó sesión de caja) y la segunda llamada devuelve el resultado original (`replayed = true`)

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentReceived` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: sin permiso de escritura es rechazado
- **WHEN** un usuario sin rol owner/admin intenta registrar un cobro
- **THEN** la operación falla con `P0401`

#### Scenario: cobro por transferencia registra movimiento bancario en la misma transacción
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `CustomerAccount` queda en `balance = 600` (con su `customer_account_movement` `payment_received` de `amount = −400`), existe una fila en `payments_received`, y existe un `bank_movement` de `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: cobro en efectivo con sesión de caja ingresa al cajón
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'cash'` informando una sesión de caja abierta, sobre una cuenta con `balance = 1000`
- **THEN** el saldo del cliente se reduce a 600, existe una fila en `payments_received`, y existe un `cash_movement` de tipo `payment_received` con `amount = +400` y referencia al cobro, todo atómico en un solo commit
- **AND** no se inserta ninguna fila en `bank_movements`

#### Scenario: cobro en efectivo sin sesión de caja no toca ningún libro de dinero
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'cash'` sin informar sesión de caja
- **THEN** el saldo del cliente se reduce a 600 y NO se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: sesión de caja con método no efectivo es rechazada
- **WHEN** se registra un `PaymentReceived` con `payment_method = 'transfer'` informando una sesión de caja
- **THEN** la operación falla con `P0422 cash_optin_requires_cash_kind` y no se inserta ni el cobro, ni el movimiento de cuenta corriente, ni el movimiento bancario, ni el de caja

#### Scenario: sesión de caja cerrada es rechazada
- **WHEN** se registra un `PaymentReceived` en efectivo informando una sesión de caja que no está `open`
- **THEN** la operación falla con `P0422 cash_optin_requires_open_session` y no se inserta ninguna fila

#### Scenario: método bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentReceived` con `payment_method = 'transfer'` y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400` cuando falta la cuenta, `P0412` cuando la cuenta no existe o está inactiva) y no se inserta ni el cobro ni el movimiento bancario

#### Scenario: cobro sin payment_method usa el default retrocompatible
- **WHEN** un llamador previo invoca `rpc_register_payment_received` sin `p_payment_method` ni `p_cash_session_id`
- **THEN** la operación se comporta como `cash` sin impacto en libros de dinero — la firma extendida no rompe a los llamadores existentes

#### Scenario: no queda una sobrecarga con la firma anterior
- **WHEN** se inspeccionan las funciones de registro de cobro tras la migración
- **THEN** existe exactamente una definición viva, con la firma extendida y sus permisos re-otorgados explícitamente

## ADDED Requirements

### Requirement: La superficie de cobro ofrece el impacto en caja pre-marcado y explica cuándo no aplica

La interfaz de registro de un cobro de cuenta corriente SHALL ofrecer, cuando el método de pago elegido es efectivo, la afirmación del impacto en caja **pre-marcada** si existe una sesión abierta, y SHALL mostrar el motivo concreto cuando no la hay, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado: cobrar en efectivo es, literalmente, poner plata en el cajón, y el estado previo a este cambio —el cobro que nunca llega al arqueo— se reproduciría si el usuario tuviera que acordarse de marcarlo.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean los formularios de venta, gasto y compra, adaptando únicamente el texto del motivo; la autoridad sobre la decisión SHALL seguir siendo el servidor. El selector de método de pago y la exigencia de cuenta bancaria para los métodos bancarios SHALL permanecer sin cambios.

#### Scenario: Efectivo con caja abierta

- **GIVEN** una sesión de caja abierta en la cuenta
- **WHEN** el usuario elige "Efectivo" en el modal de cobro
- **THEN** la afirmación de impacto en caja aparece marcada, nombrando la sesión

#### Scenario: Efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta
- **WHEN** el usuario elige "Efectivo" en el modal de cobro
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta
- **AND** el cobro puede registrarse de todos modos, sin impacto en el arqueo

#### Scenario: Método bancario no ofrece el bloque de caja

- **WHEN** el usuario elige transferencia, tarjeta o cheque
- **THEN** el bloque de caja no se muestra y el selector de cuenta bancaria sigue siendo obligatorio

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** un cobro en efectivo con sesión abierta
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** el cobro se registra sin movimiento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el modal de cobro se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
