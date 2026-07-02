# customer-account

> Synced from change `v21-customer-supplier-accounts` (C-30) — 2026-06-20

## Purpose

Cuentas corrientes de clientes: agregado `CustomerAccount` con saldo materializado + ledger append-only `customer_account_movements`. Permite registrar ventas a crédito (integración con C-29 `SalesOrder.confirm()`), cobros idempotentes, notas de crédito y ajustes manuales, todo mediante RPCs `SECURITY DEFINER` que preservan la invariante del saldo mediante `SELECT ... FOR UPDATE`. Cierra la Fase 7 del roadmap V2.

## Requirements

### Requirement: Agregado CustomerAccount con saldo materializado
El sistema SHALL proveer un agregado `CustomerAccount` (tabla `customer_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `client_id` (FK→`clients`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado), `created_by`, `created_at`. SHALL existir a lo sumo **una** `CustomerAccount` por `(account_id, client_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER` (sin INSERT/UPDATE directo del rol `authenticated`); la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

#### Scenario: crear cuenta corriente de un cliente
- **WHEN** se crea una `CustomerAccount` para un cliente de la cuenta
- **THEN** existe una fila en `customer_accounts` con `balance = 0` y `(account_id, client_id)` único

#### Scenario: una sola cuenta por cliente
- **WHEN** se intenta crear una segunda `CustomerAccount` para el mismo `(account_id, client_id)`
- **THEN** la operación es idempotente (no crea una segunda fila) y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `customer_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

### Requirement: Ledger append-only de movimientos con balance_after
El sistema SHALL proveer un ledger `customer_account_movements` (`id`, `customer_account_id` FK→`customer_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `sale|payment_received|credit_note|adjustment`, `reference_id uuid` nullable, `created_by`, `created_at`). El ledger SHALL ser **append-only**: la RLS SHALL tener únicamente política SELECT (sin UPDATE ni DELETE). Cada movimiento SHALL persistir su `balance_after` (saldo de la cuenta tras aplicar el movimiento). El `balance_after` SHALL computarse a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

#### Scenario: movimiento persiste balance_after
- **WHEN** se postea un movimiento de `amount = 1000` sobre una cuenta con `balance = 0`
- **THEN** la fila del ledger tiene `balance_after = 1000` y la cabecera `customer_accounts.balance` queda en `1000`

#### Scenario: ledger es append-only
- **WHEN** un usuario intenta UPDATE o DELETE sobre `customer_account_movements`
- **THEN** la operación es denegada por RLS (no hay política de UPDATE/DELETE)

#### Scenario: movement_type fuera del dominio es rechazado
- **WHEN** se intenta insertar un movimiento con `movement_type = 'foo'`
- **THEN** el CHECK rechaza la fila (`check_violation`)

#### Scenario: balance_after acumula correctamente en movimientos sucesivos
- **WHEN** sobre una cuenta en `balance = 0` se postea `+1000` (sale) y luego `−400` (payment_received)
- **THEN** el primer movimiento tiene `balance_after = 1000`, el segundo `balance_after = 600`, y la cabecera queda en `600`

### Requirement: Helper intra-transacción c30_register_customer_account_movement
El sistema SHALL proveer `public.c30_register_customer_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC** (callable solo desde RPCs `SECURITY DEFINER`), que **NO abre transacción propia**. El helper SHALL: (a) lockear la fila de cabecera con `SELECT ... FOR UPDATE`; (b) computar `balance_after = balance + p_amount`; (c) INSERT append-only en `customer_account_movements` con `created_by = auth.uid()`; (d) UPDATE de `customer_accounts.balance`; (e) RETURN el id del movimiento. La acumulación del saldo SHALL usar UPDATE-then-INSERT bajo `FOR UPDATE`, **nunca** `INSERT ... ON CONFLICT DO UPDATE` con delta.

#### Scenario: el helper serializa con FOR UPDATE sobre la cabecera
- **WHEN** dos movimientos concurrentes sobre la misma cuenta se postean
- **THEN** el lock de fila de cabecera los serializa y cada uno computa `balance_after` sobre el saldo del otro ya commiteado (sin perder ninguno)

#### Scenario: el helper no es callable desde el rol authenticated
- **WHEN** el rol `authenticated` intenta `SELECT c30_register_customer_account_movement(...)`
- **THEN** la llamada es denegada (REVOKE de PUBLIC); solo los RPCs `SECURITY DEFINER` pueden invocarlo

### Requirement: PaymentReceived reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `CustomerAccount` del cliente; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_received'`; (d) invoca el helper con `amount` negativo (`payment_received` reduce la deuda); (e) inserta una fila en `payments_received`; (f) **rutea el ingreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` positivo (ingreso), `movement_type` derivado (`transfer_in` para transfer/check, `card_settlement` para card), `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro; cuando es `cash` SHALL seguir el camino de caja existente sin tocar el ledger bancario; (g) emite el evento `PaymentReceived` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`. Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Los parámetros `p_payment_method` y `p_bank_account_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`): las firmas y llamadas previas siguen funcionando. Un cobro que excede el saldo deudor sin marca de anticipo SHALL fallar con `P0409`.

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

## Implementation Notes

- **Tablas**: `customer_accounts`, `customer_account_movements`, `payments_received` (migración `20260720000001_c30_customer_supplier_accounts.sql`)
- **Helpers**: `c30_register_customer_account_movement` (REVOKE de PUBLIC), `c30_get_or_create_customer_account` (lazy auto-create idempotente vía ON CONFLICT), `_register_bank_movement` (invocado desde `rpc_register_payment_received` para métodos bancarios, C2 `bank-payment-routing`)
- **RPCs**: `rpc_create_customer_account`, `rpc_register_payment_received` (extendida en C2 con `p_payment_method`/`p_bank_account_id`) — ambos SECURITY DEFINER, REVOKE de PUBLIC/anon + GRANT a authenticated
- **RLS**: solo política SELECT en las 3 tablas (`account_id IN (SELECT current_account_ids())`); escritura append-only via RPC definer
- **Integración C-29**: `_c29_confirm_order_core` (C-29) llama `c30_register_customer_account_movement` para `payment_method='credit'`; `CHECK (payment_method IN ('cash','other','credit'))` en `sales_orders` ampliado en C-30
- **Backend**: `backend/schemas/customer_accounts.py`, `backend/repositories/customer_account_repository.py`, `backend/services/customer_accounts.py`, `backend/routers/customer_accounts.py`
- **Frontend**: `frontend/app/(dashboard)/clientes/[id]/cuenta/page.tsx` con Server Component + hooks React Query
- **Smoke prod**: 2026-06-20 — migración `20260720000001` + hotfix `20260720000002` LIVE; 7/7 smoke cases OK
- **C2 bank-payment-routing** (2026-07-02, PR #249): `rpc_register_payment_received` rutea cobros bancarios a `bank_movements` vía `_register_bank_movement`; migración `20260804000007_bank_payment_routing.sql`. Ver `bank-movement` spec.
