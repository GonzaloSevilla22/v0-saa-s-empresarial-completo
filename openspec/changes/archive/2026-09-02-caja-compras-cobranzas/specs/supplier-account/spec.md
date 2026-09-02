## MODIFIED Requirements

### Requirement: PaymentMade reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_made(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_purchase_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL, p_cash_session_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `SupplierAccount`; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_made'`; (d) invoca el helper con `amount` negativo (`payment_made` reduce lo que se debe); (e) inserta una fila en `payments_made`; (f) **rutea el egreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` negativo (egreso), `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` y `source_doc_ref` = id del pago; cuando es `cash` **y se informa `p_cash_session_id`** SHALL invocar el helper intra-transaccional de caja con `amount` negativo, `movement_type = 'payment_made'` y referencia al pago, sin tocar el ledger bancario; cuando es `cash` **sin** `p_cash_session_id` SHALL registrar el pago sin efecto sobre ningún libro de dinero; (g) emite el evento `PaymentMade` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`.

Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Informar `p_cash_session_id` con un método distinto de `cash` SHALL rechazarse con `P0422 cash_optin_requires_cash_kind`, y con una sesión que no esté `open` SHALL rechazarse con `P0422 cash_optin_requires_open_session`; la pertenencia de la sesión a la cuenta la aporta el punto de paso obligado del registro de movimientos de caja. El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia: un replay SHALL devolver el resultado original sin registrar un segundo movimiento.

Los parámetros `p_payment_method`, `p_bank_account_id` y `p_cash_session_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`/`NULL`) y conservan el comportamiento previo cuando no se informan. La firma extendida SHALL quedar como **única firma viva** de la función: la firma anterior SHALL eliminarse en la misma migración en lugar de convivir como sobrecarga. Un pago que excede el saldo sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar pago disminuye el saldo
- **WHEN** se registra un `PaymentMade` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `supplier_account_movement` de tipo `payment_made` con `amount = −400` y `balance_after = 600`, y una fila en `payments_made`

#### Scenario: pago idempotente no duplica
- **WHEN** se llama `rpc_register_payment_made` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo pago, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si es método bancario), se inserta un solo `cash_movement` (si se informó sesión de caja) y la segunda llamada devuelve el resultado original

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentMade` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: pago por transferencia registra egreso bancario en la misma transacción
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `SupplierAccount` queda en `balance = 600`, existe una fila en `payments_made`, y existe un `bank_movement` de `amount = −400`, `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: pago en efectivo con sesión de caja sale del cajón
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'cash'` informando una sesión de caja abierta, sobre una cuenta con `balance = 1000`
- **THEN** el saldo del proveedor se reduce a 600, existe una fila en `payments_made`, y existe un `cash_movement` de tipo `payment_made` con `amount = −400` y referencia al pago, todo atómico en un solo commit
- **AND** no se inserta ninguna fila en `bank_movements`

#### Scenario: pago en efectivo sin sesión de caja no toca ningún libro de dinero
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'cash'` sin informar sesión de caja
- **THEN** el saldo del proveedor se reduce a 600 y NO se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: sesión de caja con método no efectivo es rechazada
- **WHEN** se registra un `PaymentMade` con `payment_method = 'transfer'` informando una sesión de caja
- **THEN** la operación falla con `P0422 cash_optin_requires_cash_kind` y no se inserta ninguna fila

#### Scenario: sesión de caja cerrada es rechazada
- **WHEN** se registra un `PaymentMade` en efectivo informando una sesión de caja que no está `open`
- **THEN** la operación falla con `P0422 cash_optin_requires_open_session` y no se inserta ninguna fila

#### Scenario: método bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentMade` con `payment_method = 'transfer'` y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400`/`P0412`) y no se inserta ni el pago ni el movimiento bancario

#### Scenario: no queda una sobrecarga con la firma anterior
- **WHEN** se inspeccionan las funciones de registro de pago tras la migración
- **THEN** existe exactamente una definición viva, con la firma extendida y sus permisos re-otorgados explícitamente

## ADDED Requirements

### Requirement: La superficie de pago a proveedor ofrece el impacto en caja pre-marcado y explica cuándo no aplica

La interfaz de registro de un pago a proveedor SHALL ofrecer, cuando el método de pago elegido es efectivo, la afirmación del impacto en caja **pre-marcada** si existe una sesión abierta, y SHALL mostrar el motivo concreto cuando no la hay, sin ocultar el bloque en silencio. Es el espejo exacto de la superficie de cobro, y SHALL reutilizar la misma resolución de condiciones compartida en lugar de reimplementarla.

#### Scenario: Efectivo con caja abierta

- **GIVEN** una sesión de caja abierta en la cuenta
- **WHEN** el usuario elige "Efectivo" en el modal de pago a proveedor
- **THEN** la afirmación de impacto en caja aparece marcada, nombrando la sesión

#### Scenario: Efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta
- **WHEN** el usuario elige "Efectivo" en el modal de pago a proveedor
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta
- **AND** el pago puede registrarse de todos modos, sin impacto en el arqueo

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** un pago en efectivo con sesión abierta
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** el pago se registra sin movimiento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el modal de pago se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
