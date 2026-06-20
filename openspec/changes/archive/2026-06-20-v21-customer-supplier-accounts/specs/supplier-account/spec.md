# supplier-account

## ADDED Requirements

### Requirement: Agregado SupplierAccount con saldo materializado
El sistema SHALL proveer un agregado `SupplierAccount` (tabla `supplier_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `supplier_id` (FK→`suppliers`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado: lo que se le debe al proveedor), `created_by`, `created_at`. SHALL existir a lo sumo **una** `SupplierAccount` por `(account_id, supplier_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER`; la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

#### Scenario: crear cuenta corriente de un proveedor
- **WHEN** se crea una `SupplierAccount` para un proveedor de la cuenta
- **THEN** existe una fila en `supplier_accounts` con `balance = 0` y `(account_id, supplier_id)` único

#### Scenario: una sola cuenta por proveedor
- **WHEN** se intenta crear una segunda `SupplierAccount` para el mismo `(account_id, supplier_id)`
- **THEN** la operación es idempotente y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `supplier_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

### Requirement: Ledger append-only de movimientos del proveedor con balance_after
El sistema SHALL proveer un ledger `supplier_account_movements` (`id`, `supplier_account_id` FK→`supplier_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `purchase|payment_made|debit_note|adjustment`, `reference_id uuid` nullable, `created_by`, `created_at`). El ledger SHALL ser **append-only** (RLS solo SELECT, sin UPDATE/DELETE). Cada movimiento SHALL persistir su `balance_after`, computado a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

#### Scenario: movimiento persiste balance_after
- **WHEN** se postea un movimiento de `amount = 1000` (purchase) sobre una cuenta con `balance = 0`
- **THEN** la fila del ledger tiene `balance_after = 1000` y la cabecera `supplier_accounts.balance` queda en `1000`

#### Scenario: ledger es append-only
- **WHEN** un usuario intenta UPDATE o DELETE sobre `supplier_account_movements`
- **THEN** la operación es denegada por RLS

#### Scenario: movement_type fuera del dominio es rechazado
- **WHEN** se intenta insertar un movimiento con `movement_type = 'sale'` (tipo de cliente, no de proveedor)
- **THEN** el CHECK rechaza la fila (`check_violation`)

### Requirement: Helper intra-transacción c30_register_supplier_account_movement
El sistema SHALL proveer `public.c30_register_supplier_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC**, que **NO abre transacción propia**, espejo exacto de `c30_register_customer_account_movement`: lock de cabecera con `FOR UPDATE`, `balance_after = balance + p_amount`, INSERT append-only, UPDATE de la cabecera, RETURN id. La acumulación SHALL usar UPDATE-then-INSERT, nunca `ON CONFLICT DO UPDATE` con delta.

#### Scenario: el helper serializa con FOR UPDATE
- **WHEN** dos movimientos concurrentes sobre la misma `SupplierAccount` se postean
- **THEN** el lock de cabecera los serializa y ambos quedan reflejados en el saldo final

#### Scenario: el helper no es callable desde authenticated
- **WHEN** el rol `authenticated` intenta invocar el helper directamente
- **THEN** la llamada es denegada (REVOKE de PUBLIC)

### Requirement: PaymentMade reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_made(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_purchase_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `SupplierAccount`; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_made'`; (d) invoca el helper con `amount` negativo (`payment_made` reduce lo que se debe); (e) inserta una fila en `payments_made`. Un pago que excede el saldo sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar pago disminuye el saldo
- **WHEN** se registra un `PaymentMade` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `supplier_account_movement` de tipo `payment_made` con `amount = −400` y `balance_after = 600`, y una fila en `payments_made`

#### Scenario: pago idempotente no duplica
- **WHEN** se llama `rpc_register_payment_made` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo pago, el saldo se reduce una sola vez y la segunda llamada devuelve el resultado original

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentMade` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

### Requirement: Cargo manual de compra a crédito en cta cte de proveedor
El sistema SHALL proveer `rpc_register_supplier_charge(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que postea un movimiento de tipo `purchase` (`amount` positivo) en la `SupplierAccount`, incrementando lo que se le debe al proveedor. Es el camino de integración **manual** (OQ-3 default = opción B): el flujo de compras de stock (`rpc_create_purchase_operation`) permanece sin cambios y NO postea automáticamente a la cta cte.

#### Scenario: cargar compra a crédito aumenta el saldo del proveedor
- **WHEN** se registra un cargo de 1500 sobre la `SupplierAccount` de un proveedor con `balance = 0`
- **THEN** la cuenta queda en `balance = 1500` con un movimiento de tipo `purchase`, `amount = +1500`, `balance_after = 1500`

#### Scenario: el flujo de compras de stock no toca la cta cte
- **WHEN** se crea una compra de stock vía `rpc_create_purchase_operation`
- **THEN** no se crea ningún `supplier_account_movement` (la cta cte de proveedor se alimenta solo por comandos explícitos en C-30)
