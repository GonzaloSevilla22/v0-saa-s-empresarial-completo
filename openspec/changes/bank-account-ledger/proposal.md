## Why

El sistema mueve dinero en efectivo (`cash_movements`, C-28) y en cuentas corrientes (C-30), pero **no tiene dónde representar el dinero en el banco**: las transferencias, acreditaciones de tarjeta y débitos bancarios hoy no tienen ledger propio. El plan de cuentas contable ya reserva la cuenta `1110 Banco` (migración `journal-entry-outbox`), pero **nadie postea ahí todavía**. Antes de poder rutear pagos al banco (C2) o conciliar contra el extracto bancario (C3), hace falta el agregado que sostenga el saldo bancario: una `BankAccount` con su ledger operacional `bank_movements`.

Este es el **change C1 de la secuencia de 3 de BankReconciliation** (V2.5 Finanzas): `bank-account-ledger` (C1) → `bank-payment-routing` (C2) → `bank-reconciliation` (C3). C1 entrega un dominio bancario **autónomo, con carga manual únicamente**, más las costuras (seams) documentadas para C2/C3 — sin construirlas.

## What Changes

- **NUEVO `bank_accounts`** (root, tenancy directa por `account_id` — a nivel organización, NO scoped a sucursal como las cajas): cuenta bancaria con `bank_name`, `cbu` (22 dígitos, validado), `alias`, `currency`, `opening_balance`/`opening_date`, `is_active`.
- **NUEVO `bank_movements`** (ledger append-only, espejo exacto de `cash_movements`): `amount` con signo (+ ingreso, − egreso), `balance_after` (saldo corriente), `movement_type` con CHECK que **fija ya el enum completo** (`transfer_in`, `transfer_out`, `card_settlement`, `fee`, `tax_debit`, `interest`, `manual_adjustment`), `value_date` (fecha valor bancaria), `branch_id` nullable (analítica), `source_doc_type`/`source_doc_ref`, `description`. Se denormaliza `account_id` para RLS sin subquery por fila.
- **NUEVO helper intra-transacción `_register_bank_movement(...)`** (SECURITY DEFINER, `SET search_path`, calcula `balance_after`, append-only, REVOKE de PUBLIC) — **este es el contrato C1→C2**, análogo exacto de `c28_register_cash_movement` que C-29 reutilizó.
- **NUEVAS RPCs públicas** (SECURITY DEFINER, guard `is_account_writer`, GRANT a `authenticated`): `rpc_create_bank_account`, `rpc_update_bank_account` (editar `name`/`is_active`/etc.), `rpc_register_bank_movement` (**carga manual** — solo acepta el subconjunto `transfer_in`/`transfer_out`/`manual_adjustment`; rechaza los tipos reservados a C2/C3).
- **RLS**: SELECT por `account_id`; escritura SOLO vía RPCs SECURITY DEFINER (sin policy INSERT/UPDATE/DELETE directa). Índices en `bank_account_id`, `value_date`, `account_id`.
- **C1 NO postea al journal** (`1110 Banco` sigue reservado y vacío) — ese cableado es de C2. **C1 NO toca** las RPCs de pago de C-30, ni captura `payment_method`, ni hace matching/import de extractos.

## Capabilities

### New Capabilities
- `bank-account`: la cuenta bancaria (`BankAccount`) como agregado root org-level — creación, edición, validación de CBU, soft-deactivate (`is_active`), saldo de apertura. RLS directa por `account_id`.
- `bank-movement`: el ledger operacional append-only de movimientos bancarios con signo y `balance_after`, su taxonomía `movement_type`, el helper transaccional reutilizable `_register_bank_movement` (contrato C1→C2) y la RPC pública de carga manual.

### Modified Capabilities
<!-- Ninguna: capacidades nuevas en greenfield. C1 no modifica requisitos de specs existentes (cash-session, journal-entry, customer-supplier-accounts permanecen intactas). -->

## Impact

- **DB / Supabase Postgres**: nueva migración `supabase/migrations/20260804000002_bank_account_ledger.sql` (timestamp libre verificado; última existente `20260803000003`). 2 tablas nuevas, 1 helper, 3 RPCs, RLS + índices. Aplicada SOLO vía `npx supabase db push` (CI al mergear) — NUNCA MCP `apply_migration`.
- **Tablas NUEVAS (greenfield)**: no existe ninguna tabla `bank_*` (confirmado en `supabase/migrations/`). La regla dura "ninguna feature nueva sobre tablas en retirada" (RN-97) **no aplica** — no se toca ninguna tabla legacy ni en retirada.
- **Plan de cuentas**: ninguno (la cuenta `1110 Banco` queda reservada; C1 no la usa).
- **Seams forward-compat (documentadas, NO construidas)**: C2 llamará a `_register_bank_movement` desde las RPCs de pago y posteará a `1110`; C3 agregará columnas aditivas nullable (`statement_line_id`, `reconciliation_status`, `reconciled_at`) + tablas de extracto/sesión de conciliación.
- **Governance**: MEDIO (tablas aisladas nuevas + RPCs manuales; no toca el hot path de venta/pago ni dinero real existente).
