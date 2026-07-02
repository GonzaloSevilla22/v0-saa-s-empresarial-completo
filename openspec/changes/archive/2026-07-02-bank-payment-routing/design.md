## Context

C2 is the middle change of the 3-change BankReconciliation V2.5 sequence (`bank-account-ledger` C1 ✅ → **`bank-payment-routing` C2** → `bank-reconciliation` C3). C1 (PR #243, migration `20260804000002`, live in prod) built the operational bank ledger and the intra-transaction helper `_register_bank_movement(p_bank_account_id, p_amount, p_type, p_source_doc_type, p_source_doc_ref, p_value_date, p_branch_id, p_description)` — deliberately the **contract for C2** (the exact analog of how `c28_register_cash_movement` became the contract that C-29's sale hot path reused). C1 writes only manual movements and, by design, does NOT post to the accounting account `1110 Banco`.

Current gaps C2 closes (grounded in code):
- **No method captured at the source.** `rpc_register_payment_received(p_idempotency_key, p_client_id, p_amount, p_reference_sale_id)` and `rpc_register_payment_made(p_idempotency_key, p_supplier_id, p_amount, p_reference_purchase_id)` (migration `20260720000001`) have no payment-method parameter. A transfer and cash are indistinguishable.
- **Journal maps everything to cash.** `_journal_post_from_event` (migration `20260803000001`) posts `PaymentReceived` as debit `1100 Caja`, `PaymentMade` as credit `1100 Caja`, and `SaleConfirmed` cash/`other` as `1100 Caja` — ignoring method. `1110 Banco` is in the hardcoded chart-of-accounts comment but nobody posts there.
- **The producers already emit the payload.** `rpc_register_payment_received/made` emit `PaymentReceived`/`PaymentMade` events; `_c29_confirm_order_core` emits `SaleConfirmed` with `payment_method` already in the payload. C2 enriches the two payment payloads with `payment_method` (+ `bank_account_id`).

**Architectural principle (restated from C1 — the spine of this change): two ledgers synchronized by the outbox.** `bank_movements` is the OPERATIONAL ledger (source of truth of the bank balance, and the basis C3 reconciles against a bank statement) — written **intra-transaction** by the payment RPC via `_register_bank_movement`. The accounting account `1110 Banco` is the ACCOUNTING mirror — written **asynchronously** by `_journal_post_from_event` (outbox Consumer 3). C2 wires BOTH sides. Reconciliation (C3) always operates on `bank_movements`, never on the journal.

**Governance: ALTA.** C2 modifies the money RPCs and the double-entry posting function (`_journal_post_from_event`). Per project + JR governance, the design must be **signed off by the PO before any apply** — same gate that `journal-entry-outbox` used. This artifact set STOPS at planning; no implementation.

## Goals / Non-Goals

**Goals:**
- Capture payment method on `rpc_register_payment_received` / `rpc_register_payment_made` (additive, backward-compatible params).
- Route the OPERATIONAL leg intra-tx: bank methods → `_register_bank_movement`; cash → existing cash path (unchanged).
- Route the ACCOUNTING leg async: `_journal_post_from_event` posts the bank leg of `PaymentReceived`/`PaymentMade`/`SaleConfirmed` to `1110 Banco` vs `1100 Caja` by payload method.
- Enrich the `PaymentReceived`/`PaymentMade` event payloads with `payment_method` (+ `bank_account_id`).
- Backend (FastAPI) + frontend (Next.js) wiring so the cobro/pago UI captures method and (for bank methods) a bank account.

**Non-Goals:**
- **Card settlement net-vs-gross** (commission + withholdings). C2 books the gross to the bank ledger/`1110`; the `fee`/`tax_debit` legs stay manual (types reserved by C1) and are handled in C3. (Open question below on whether card is even in the C2 taxonomy.)
- **Reconciliation / statement import / matching** — that is C3.
- **Backfill of historical payments** (recommended: leave as-is; see Decisions).
- **Configurable chart of accounts / accounting UI** — deferred to V2.6 (journal-entry-outbox follow-up).
- **Multi-currency bank accounts** — deferred (C1 left `currency` defaulting to ARS).
- **CBU check-digit validation** — deferred (C1 note).

## Decisions

### D1 — Payment method is an additive, optional, backward-compatible parameter
Add `p_payment_method text DEFAULT 'cash'` and `p_bank_account_id uuid DEFAULT NULL` as **trailing** params on both payment RPCs. Existing callers (and the smoke-tested prod path) keep working with the `cash` default. `CREATE OR REPLACE` with new trailing DEFAULT params does not change the existing overload signature that clients call today; callers are then migrated to pass the method explicitly.
- **Alternative rejected:** a new column on `payments_received`/`payments_made` only (no routing) — insufficient; the routing (bank_movement + journal) is the whole point.
- **Alternative rejected:** a separate `rpc_register_bank_payment_*` — duplicates the idempotency/overpayment/event logic; higher risk on money RPCs.

### D2 — Operational routing mirrors the cash path exactly
Inside each payment RPC, after the cuenta-corriente movement, branch on method:
- `cash` → existing behavior (customer/supplier collections do not currently touch `cash_movements`; leave untouched — see D6).
- bank method → `PERFORM _register_bank_movement(p_bank_account_id, ±amount, <type>, '<payment_received|payment_made>', v_payment_id, ...)` in the SAME transaction. This is byte-for-byte the pattern `_c29_confirm_order_core` uses for `c28_register_cash_movement`. Atomicity: if the payment fails (e.g. `P0409` overpayment), the bank_movement rolls back with it.
- Sign convention: cobro (received) → `+amount` (`transfer_in`); pago (made) → `−amount` (`transfer_out`). Matches C1's signed-amount ledger.

### D3 — Accounting routing reads method from the payload
`_journal_post_from_event` already reads `v_payment_method := v_payload->>'payment_method'` for `SaleConfirmed`. Generalize:
- Add a small helper predicate (inline `IF`) "is bank method" → post the bank leg to `1110`, else `1100`.
- `PaymentReceived`: debit `1110`(bank)/`1100`(cash) → credit `1300` (unchanged).
- `PaymentMade`: debit `2100` (unchanged) → credit `1110`(bank)/`1100`(cash).
- `SaleConfirmed`: debit `1110`(bank)/`1100`(cash/other-per-PO)/`1300`(credit) → credit `4100`(+`4200`) (unchanged).
- Balance ASSERT (P0450) is untouched; only which cash/bank account carries the existing amount changes, so entries still balance.
- **Producer change:** `rpc_register_payment_received/made` add `payment_method` (+ `bank_account_id`) to the emitted event payload. Missing method in the payload defaults to cash → `1100` (backward compatible with the 3 in-flight/backlogged events).

### D4 — Method taxonomy (RECOMMENDED — pending PO confirmation, see OQ-2)
Recommended `p_payment_method` domain for the **payment RPCs**: `{cash, transfer, card, check}` plus (already existing on sales) `credit` semantics handled sale-side, not payment-side. Mapping:
| method | operational ledger | journal leg |
|--------|--------------------|-------------|
| `cash` | (existing cash path) | `1100 Caja` |
| `transfer` | `bank_movements` (`transfer_in`/`transfer_out`) | `1110 Banco` |
| `check` | `bank_movements` (`transfer_in`/`transfer_out`) — treated as bank in C2 | `1110 Banco` |
| `card` | `bank_movements` (`card_settlement`, gross) | `1110 Banco` (gross; fee/tax deferred to C3) |
Enforce the domain with an explicit `IF p_payment_method NOT IN (...) THEN RAISE P0400`. **Do not** add a DB CHECK column enum yet (keeps the surface small; the RPC guard is enough).

### D5 — Migration & gate pattern copied verbatim from C1
Migration `20260804000006_bank_payment_routing.sql` (next free timestamp; latest on main is `20260804000005`). `CREATE OR REPLACE` the three functions + producer edits; optional `ALTER sales_orders.payment_method` + `CREATE OR REPLACE _c29_confirm_order_core` only if sales-side routing is in scope (OQ-4). Reuse C1's DB-gate discipline exactly:
- PL/pgSQL forbids explicit `SAVEPOINT`/`ROLLBACK TO SAVEPOINT` → use `BEGIN/EXCEPTION` sub-blocks; success-path mutating gates revert via a `GATE_ROLLBACK_SENTINEL` RAISE captured in the handler.
- Data-mutating gates (any that need real FK parents: `accounts`→`auth.users`, `bank_accounts`, `clients`/`suppliers`) run ONLY in an empty CI DB, gated by `SELECT count(*)=0 FROM accounts`, with a synthetic anchor wrapped in `BEGIN/EXCEPTION` (skips silently if the `handle_new_user` trigger errors). In prod (accounts non-empty) they are skipped → zero mutation. Copy the DO-block skeleton from `20260804000002`.
- Docker is NOT available locally → CI `validate-kpis` (which does `supabase db reset` on an empty DB) is the ONLY migration validator. Iterate carefully (~1.5 min/cycle).
- ERRCODE space: reuse project P04xx (`P0400` invalid method/missing bank account, `P0401` writer, `P0412` bank account not found/inactive — all already defined).

### D6 — No backfill; cash collections stay off both the bank AND cash ledgers (as today)
Historical `payments_received/made` have no method → treated as cash, journal already posted them to `1100`. **Recommend: no backfill** (low value, touches accounting history). Note it explicitly for the PO. Also note: today's `cash` customer/supplier collections do NOT write to `cash_movements` (only sales via C-28 do); C2 does not change that — a `cash` collection remains a pure cuenta-corriente + journal `1100` operation. Wiring cash collections into a cash session is out of scope.

## Risks / Trade-offs

- **[Money RPCs — regression risk]** → additive trailing params + `cash` default preserve the current signature and behavior; the smoke-tested prod path is unchanged unless a caller opts into a bank method. Full RED→GREEN→TRIANGULATE gates on both RPCs.
- **[Double-entry function edit is ALTA]** → the change is a targeted account-code swap on existing balanced legs (amount unchanged), so the balance ASSERT (P0450) still holds; TRIANGULATE with cash-vs-bank cases for all three event types. PO sign-off required before apply.
- **[Outbox consumer must be healthy for `1110` to appear]** → the `1110` posting rides on Consumer 3 actually processing events. It was crashing on every event (null `operation_id`, `operation_kind` CHECK, `user_id` FK) and was fixed by `20260804000005_fix_outbox_consumer_idempotency.sql` (#247). A possible **4th blocker** (`audit_logs.company_id NOT NULL`) was noted in prod. **VERIFICATION PREREQUISITE before C2 apply:** confirm end-to-end (read-only via MCP on project `gxdhpxvdjjkmxhdkkwyb`) that events are moving from `processed_at IS NULL` to processed AND that `journal_entries` are being written. If still crashing, it is a **blocking prereq hotfix outside C2 scope** — do not apply C2 on a broken relay (the operational `bank_movements` would be correct but `1110` would silently never post).
- **[card gross ≠ net deposited]** → C2 books gross only; fee/tax reconciliation is explicitly C3. If the PO wants card excluded from C2 entirely (OQ-2), drop `card`/`card_settlement` from the C2 taxonomy and treat it as manual until C3.
- **[Which bank account for a transfer]** → see OQ-1; guessing a default could post to the wrong account. Recommendation is an explicit RPC param (UI picks); marked for PO.
- **[Sales-side scope creep]** → routing the sale's own bank leg (OQ-4) may pull in `_c29_confirm_order_core` (the hot path) and a `sales_orders.payment_method` enum change. Keep it separable: the journal-side `SaleConfirmed` routing (async, low risk) can ship even if the sale-side operational bank_movement is deferred.

## Migration Plan

1. **PREREQ (blocking, not code):** PO signs off this design (governance ALTA) AND outbox-consumer health verified end-to-end via MCP read-only (see risk above).
2. Author `supabase/migrations/20260804000006_bank_payment_routing.sql`: `CREATE OR REPLACE` `rpc_register_payment_received`, `rpc_register_payment_made` (new trailing params + method routing + enriched payload), `_journal_post_from_event` (bank-vs-cash routing) + DO-block gates.
3. (If OQ-4 = in scope) `ALTER sales_orders.payment_method` CHECK + `CREATE OR REPLACE _c29_confirm_order_core` for sale-side operational routing.
4. Backend: extend Pydantic schemas + service/repository signatures for `payment_method` / `bank_account_id`.
5. Frontend: method selector + conditional bank-account picker in the cobro/pago forms.
6. Merge → CI `validate-kpis` gates the migration → CI deploys (Vercel + `db push` to `gxdhpxvdjjkmxhdkkwyb`). Backend redeploys on Render.
7. Post-deploy: MCP read-only verify a bank cobro produces (a) a `bank_movement` and (b) a `1110` journal entry after the relay tick.

**Rollback:** `CREATE OR REPLACE` the three functions back to their prior definitions (from `20260720000001` and `20260803000001`); if the CHECK was altered, revert it. No data loss — new columns/params only; `bank_movements` rows already written stay valid (they are the operational truth). Documented in the migration header per project convention.

## Open Questions — RESOLVED (PO sign-off 2026-07-01, implemented in `20260804000007_bank_payment_routing.sql`)

> All 5 decided before apply. Recorded here for the historical record — no longer open.

- **OQ-1 (target bank account for a transfer) — RESOLVED: explicit param.** `p_bank_account_id uuid` added to both payment RPCs; the UI picks the account (no per-org default). Validated to belong to the caller's `account_id` and to be `is_active` (else `P0400`/`P0412`).
- **OQ-2 (method taxonomy) — RESOLVED: `{cash, transfer, card, check}`, card INCLUDED in C2, booked GROSS.** `card` books the full amount to `bank_movements`/`1110` via `card_settlement`; fee/tax/settlement-netting is explicitly deferred to C3 — not modeled here. `check` treated as bank (`transfer_in`/`transfer_out`).
- **OQ-3 (SaleConfirmed `payment_method='other'`) — RESOLVED: extend the sales enum.** `sales_orders.payment_method` CHECK extended from `{cash, other, credit}` to `{cash, transfer, card, other, credit}`. `other` mapping to `1100 Caja` is UNCHANGED. Routing: cash/other→`1100`, transfer/card→`1110`, credit→`1300` (unchanged).
- **OQ-4 (sales-side operational routing) — RESOLVED: journal-only in C2.** No `bank_movement` is written from the sale path; `_c29_confirm_order_core` is untouched beyond the OQ-3 CHECK. The sale's `1110` posting is async via `_journal_post_from_event`. Sale-side operational `bank_movement` is deferred to a later change.
- **OQ-5 (backfill) — RESOLVED: none.** Historical payments stay as cash. The new `p_payment_method` param defaults to `'cash'`.
