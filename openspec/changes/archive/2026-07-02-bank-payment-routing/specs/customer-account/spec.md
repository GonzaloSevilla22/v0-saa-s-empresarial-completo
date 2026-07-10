## MODIFIED Requirements

### Requirement: PaymentReceived reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `CustomerAccount` del cliente; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_received'`; (d) invoca el helper con `amount` negativo (`payment_received` reduce la deuda); (e) inserta una fila en `payments_received`; (f) **rutea el ingreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` positivo (ingreso), `movement_type` derivado (`transfer_in` para transfer/check, `card_settlement` para card), `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro; cuando es `cash` SHALL seguir el camino de caja existente sin tocar el ledger bancario; (g) emite el evento `PaymentReceived` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`. Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Los parámetros `p_payment_method` y `p_bank_account_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`): las firmas y llamadas previas siguen funcionando. Un cobro que excede el saldo deudor sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: cobro por transferencia registra movimiento bancario en la misma transacción
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `CustomerAccount` queda en `balance = 600` (con su `customer_account_movement` `payment_received` de `amount = −400`), existe una fila en `payments_received`, y existe un `bank_movement` de `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: cobro en efectivo no toca el ledger bancario
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'cash'`
- **THEN** el saldo del cliente se reduce a 600 y NO se inserta ninguna fila en `bank_movements` (se conserva el comportamiento previo de caja)

#### Scenario: método bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentReceived` con `payment_method = 'transfer'` y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400` cuando falta la cuenta, `P0412` cuando la cuenta no existe o está inactiva) y no se inserta ni el cobro ni el movimiento bancario

#### Scenario: cobro sin payment_method usa el default retrocompatible
- **WHEN** un llamador previo invoca `rpc_register_payment_received` sin `p_payment_method`
- **THEN** la operación se comporta como `cash` (sin `bank_movement`) — la firma extendida no rompe a los llamadores existentes

#### Scenario: registrar cobro disminuye el saldo
- **WHEN** se registra un `PaymentReceived` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `customer_account_movement` de tipo `payment_received` con `amount = −400` y `balance_after = 600`, y una fila en `payments_received`

#### Scenario: cobro idempotente no duplica
- **WHEN** se llama `rpc_register_payment_received` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo cobro, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si es método bancario) y la segunda llamada devuelve el resultado original (`replayed = true`)

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentReceived` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: sin permiso de escritura es rechazado
- **WHEN** un usuario sin rol owner/admin intenta registrar un cobro
- **THEN** la operación falla con `P0401`
