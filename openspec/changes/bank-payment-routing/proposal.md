## Why

C1 (`bank-account-ledger`, PR #243, live in prod) built an operational bank ledger (`bank_movements` + the intra-transaction helper `_register_bank_movement`) but **nothing writes to it from real financial events yet**, and the double-entry accounting account `1110 Banco` is still "reserved" — nobody posts there. Today every non-cash payment is mis-recorded: the C-30 payment RPCs (`rpc_register_payment_received` / `rpc_register_payment_made`) do **not capture a payment method at all**, and `_journal_post_from_event` maps **all** `PaymentReceived`/`PaymentMade` and `SaleConfirmed payment_method='other'` to `1100 Caja`, so a bank transfer is booked as cash. This is C2 of the 3-change BankReconciliation sequence — it makes real money movements populate the bank ledger and post to `1110`, which is the precondition for C3 (`bank-reconciliation`) to have anything to reconcile against a bank statement.

## What Changes

- **Capture payment method on the money RPCs.** Add `p_payment_method` (and a nullable `p_bank_account_id`) to `rpc_register_payment_received` and `rpc_register_payment_made`. Both are new **optional trailing params** so existing callers keep working (default `cash`), then callers are updated to pass the method.
- **Route the operational ledger intra-transaction.** When method is a bank method (transfer/card/check) → the payment RPC calls `_register_bank_movement(...)` in the same commit (mirror of how `cash` already flows to `cash_movements` via `c28_register_cash_movement`), keeping `bank_movements` atomic with the payment and its cuenta-corriente movement. When `cash` → existing cash path (unchanged).
- **Route the accounting posting (async).** `_journal_post_from_event` reads `payment_method` from the event payload and posts the bank leg to `1110 Banco` (transfer/card) vs `1100 Caja` (cash). The C-30 producers already emit the payload; C2 adds `payment_method` (+ `bank_account_id`) to the `PaymentReceived`/`PaymentMade` event payloads.
- **Reinterpret `SaleConfirmed payment_method`.** Today `other`→`1100`. C2 routes the sale's bank leg to `1110` when the sale was paid by a bank method. **The exact taxonomy for sales is an OPEN PO decision** (see design.md): whether `other` becomes "bank", or explicit `transfer`/`card` methods are added to `sales_orders.payment_method`. **Do NOT guess** — this is flagged for PO sign-off.
- **Reserve `card_settlement` nuance to C3.** Card gross ≠ net-deposited (commission + withholdings). C2 books the gross amount to the bank ledger/`1110`; the fee/tax legs stay manual (`fee`/`tax_debit` movement types, already reserved by C1) and are reconciled in C3.
- **Backend + frontend wiring.** FastAPI service/repo layers and the cobro/pago UI gain a payment-method selector and (for bank methods) a bank-account selector.

## Capabilities

### New Capabilities
_None._ C2 wires existing ledgers together; no new spec capability is introduced. (The bank ledger tables/helper are C1; the journal is `journal-entry-outbox`.)

### Modified Capabilities
- `customer-account`: `rpc_register_payment_received` gains `payment_method` + `bank_account_id`; bank-method cobros register a `bank_movement` intra-tx and emit the method in the `PaymentReceived` event payload.
- `supplier-account`: `rpc_register_payment_made` gains `payment_method` + `bank_account_id`; bank-method pagos register a `bank_movement` intra-tx and emit the method in the `PaymentMade` event payload.
- `journal-entry`: `_journal_post_from_event` routes the bank leg of `PaymentReceived`/`PaymentMade`/`SaleConfirmed` to `1110 Banco` vs `1100 Caja` based on the payload's payment method (was hardcoded to `1100`).
- `bank-movement`: the `bank_movements` ledger gains its first automated (non-manual) writers — the payment RPCs source movements with `source_doc_type` = `payment_received`/`payment_made` and `movement_type` = `transfer_in`/`transfer_out`/`card_settlement`.

## Impact

- **DB migration** (`supabase/migrations/20260804000006_bank_payment_routing.sql`): `CREATE OR REPLACE` of `rpc_register_payment_received`, `rpc_register_payment_made`, `_journal_post_from_event`; possibly `ALTER` of `sales_orders.payment_method` CHECK (pending PO taxonomy decision) + `CREATE OR REPLACE _c29_confirm_order_core` if sales routing is in scope. Governance **ALTA** (touches money RPCs + the double-entry function). **Apply blocked on PO design sign-off** (same as `journal-entry-outbox`).
- **Accounting correctness**: `1110 Banco` starts receiving postings; the `journal_entries`/`journal_lines` mix shifts. Historical postings unchanged (no backfill — recommended; see design.md).
- **Runtime prerequisite**: C2's `1110` postings ride on the outbox Consumer 3 (`_journal_post_from_event`) actually processing events. It was crashing on every event and was just fixed by `20260804000005_fix_outbox_consumer_idempotency.sql` (#247). **Outbox-consumer health must be verified end-to-end (read-only via MCP) at apply time** — if still crashing, it is a blocking prereq hotfix outside C2 scope (a possible 4th blocker on `audit_logs.company_id NOT NULL` was noted in prod).
- **Backend (FastAPI)**: payment service/repository signatures + Pydantic schemas gain `payment_method` / `bank_account_id`.
- **Frontend (Next.js)**: cobro/pago forms gain a method selector and a conditional bank-account picker.
- **Unblocks** C3 `bank-reconciliation` (matching real bank movements against imported statements).
