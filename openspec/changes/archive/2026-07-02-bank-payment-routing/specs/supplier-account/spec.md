## MODIFIED Requirements

### Requirement: PaymentMade reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_made(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_purchase_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `SupplierAccount`; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_made'`; (d) invoca el helper con `amount` negativo (`payment_made` reduce lo que se debe); (e) inserta una fila en `payments_made`; (f) **rutea el egreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` negativo (egreso), `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` y `source_doc_ref` = id del pago; cuando es `cash` SHALL seguir el camino de caja existente sin tocar el ledger bancario; (g) emite el evento `PaymentMade` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`. Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Los parámetros `p_payment_method` y `p_bank_account_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`). Un pago que excede el saldo sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: pago por transferencia registra egreso bancario en la misma transacción
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `SupplierAccount` queda en `balance = 600`, existe una fila en `payments_made`, y existe un `bank_movement` de `amount = −400`, `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: pago en efectivo no toca el ledger bancario
- **WHEN** se registra un `PaymentMade` de 400 con `payment_method = 'cash'`
- **THEN** el saldo del proveedor se reduce a 600 y NO se inserta ninguna fila en `bank_movements`

#### Scenario: método bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentMade` con `payment_method = 'transfer'` y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400`/`P0412`) y no se inserta ni el pago ni el movimiento bancario

#### Scenario: registrar pago disminuye el saldo
- **WHEN** se registra un `PaymentMade` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `supplier_account_movement` de tipo `payment_made` con `amount = −400` y `balance_after = 600`, y una fila en `payments_made`

#### Scenario: pago idempotente no duplica
- **WHEN** se llama `rpc_register_payment_made` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo pago, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si es método bancario) y la segunda llamada devuelve el resultado original

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentMade` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`
