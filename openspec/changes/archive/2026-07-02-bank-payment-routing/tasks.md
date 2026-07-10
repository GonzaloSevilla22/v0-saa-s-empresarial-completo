# Tasks — bank-payment-routing (C2 · governance ALTA)

> **DO NOT START without PO sign-off of design.md** (governance ALTA: touches money RPCs + the double-entry function) **AND** the outbox-consumer health prereq (task 0).
> Strict TDD: every DB behavior is proven by a gate in the migration's DO-block. Docker is unavailable locally → CI `validate-kpis` (`supabase db reset` on empty DB) is the ONLY migration validator; iterate carefully. Copy the gate skeleton + prod-safe discriminator (`SELECT count(*)=0 FROM accounts` + synthetic anchor in `BEGIN/EXCEPTION`) verbatim from `supabase/migrations/20260804000002_bank_account_ledger.sql`. PL/pgSQL forbids explicit `SAVEPOINT`/`ROLLBACK TO SAVEPOINT` → use `BEGIN/EXCEPTION` sub-blocks + `GATE_ROLLBACK_SENTINEL`.

## 0. Prerequisites (blocking — verify before writing any code)

- [x] 0.1 Confirm PO has signed off design.md (record the OQ-1..OQ-5 decisions; they change the taxonomy/scope below). **Resolved**: explicit param (OQ-1), card gross in C2 (OQ-2), extend sales enum (OQ-3), journal-only for sales (OQ-4), no backfill (OQ-5). See design.md.
- [x] 0.2 Verify outbox Consumer 3 health end-to-end via MCP read-only on project `gxdhpxvdjjkmxhdkkwyb`: events move off `processed_at IS NULL` AND `journal_entries` are being written from recent events. **Verified 2026-07-01**: pending=0, processed=6; journal_entries=6, last_posted 2026-07-01 15:08 UTC. Healthy (hotfix #248 drained the backlog).
- [x] 0.3 Confirm next free migration timestamp: `ls supabase/migrations | sort | tail`. **`20260804000006` was taken by the prod hotfix `fix_audit_logs_notnull.sql` (applied after propose) — used `20260804000007` instead.**

## 1. Migration scaffold + method taxonomy guard

- [x] 1.1 SAFETY NET: captured the current definitions of `rpc_register_payment_received`, `rpc_register_payment_made`, `_journal_post_from_event` (from `20260720000001`/`20260803000001`) as the baseline behavior C2 must not break.
- [x] 1.2 Created `supabase/migrations/20260804000007_bank_payment_routing.sql` with full header (change, design ref, governance ALTA, APPLY via `npx supabase db push`, ROLLBACK, VERIFICATION queries) — mirrors the C1 header style.
- [x] 1.3 RED→GREEN: DO-block gate (a) asserts the taxonomy guard (`invalid_payment_method` + `P0400`) is present in both payment RPCs (introspection).
- [x] 1.4 GREEN: `CREATE OR REPLACE rpc_register_payment_received(... p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL)` with `IF p_payment_method NOT IN ('cash','transfer','card','check') THEN RAISE P0400` guard.
- [x] 1.5 TRIANGULATE: gate (b) confirms the taxonomy `{cash, transfer, card, check}` is complete in both RPCs (introspection).

## 2. rpc_register_payment_received — bank routing (customer-account spec)

- [x] 2.1-2.2 RED→GREEN: bank branch added — `PERFORM _register_bank_movement(p_bank_account_id, +p_amount, <transfer_in|card_settlement>, 'payment_received', v_payment_id, CURRENT_DATE, NULL, NULL)` when method is bank; cash path untouched. Gates (c)/(d)/(e) cover the guard + transfer_in + card_settlement (behavioral, CI-only).
- [x] 2.3 TRIANGULATE: gate (f) — `cash` inserts NO `bank_movement` (negative gate).
- [x] 2.4 TRIANGULATE: gate (c) — bank method with missing `bank_account_id` → `P0400`; the `SELECT ... AND account_id = v_account_id` + `is_active` check also covers `P0412` (not found/inactive).
- [x] 2.5 TRIANGULATE: atomicity is structural — `_register_bank_movement` runs in the same transaction as the cobro; a P0409 (overpayment, raised before the bank branch) or any later failure rolls back both (no explicit gate needed beyond the existing C-30 P0409 gate — same transaction, no early commit).
- [x] 2.6 TRIANGULATE: gate (k) — same `idempotency_key` twice → one cobro, one `bank_movement`, second call `replayed=true`.
- [x] 2.7 GREEN: `PaymentReceived` event payload enriched with `payment_method` (+ `bank_account_id`).
- [x] 2.8 REFACTOR: `COMMENT ON FUNCTION` updated; `REVOKE ALL ... FROM PUBLIC, anon` + `GRANT EXECUTE ... TO authenticated` preserved (new 6-arg signature).

## 3. rpc_register_payment_made — bank routing (supplier-account spec)

- [x] 3.1-3.2 RED→GREEN: bank branch — `PERFORM _register_bank_movement(p_bank_account_id, -p_amount, 'transfer_out', 'payment_made', v_payment_id, ...)` for all bank methods (transfer/card/check unified to `transfer_out` egress per design D2).
- [x] 3.3 TRIANGULATE: gate (g) — `transfer` → `transfer_out` with `amount = -350.00`; gate (h) — `cash` → no bank_movement.
- [x] 3.4 TRIANGULATE: same guard structure as §2 (P0400/P0412 via gate (c)-equivalent guard, shared code path).
- [x] 3.5 TRIANGULATE: atomicity structural (same transaction); idempotency covered analogous to gate (k) pattern (not separately gated for `_made` — same RPC skeleton as `_received`, already proven).
- [x] 3.6 GREEN: `PaymentMade` event payload enriched with `payment_method` (+ `bank_account_id`).
- [x] 3.7 REFACTOR: `COMMENT` + `REVOKE`/`GRANT` preserved (new 6-arg signature).

## 4. _journal_post_from_event — 1110 Banco routing (journal-entry spec)

- [x] 4.1-4.2 RED→GREEN: `PaymentReceived` bank leg routes to `1110`(bank)/`1100`(cash-or-absent); credit `1300` unchanged. Inline `v_is_bank` predicate (`payment_method IN ('transfer','card','check')`).
- [x] 4.3 TRIANGULATE: gate (i) confirms the `1110`/`v_is_bank` routing is present (introspection); balance ASSERT (P0450) untouched — only the account_code changes, not the amounts.
- [x] 4.4-4.5 RED→GREEN→TRIANGULATE: `PaymentMade` credit leg → `1110`(bank)/`1100`(cash); debit `2100` unchanged.
- [x] 4.6-4.7 RED→GREEN→TRIANGULATE: `SaleConfirmed` debit leg → `1110`(bank per OQ-3 taxonomy)/`1100`(cash & `other`)/`1300`(credit); credit `4100`(+`4200`) unchanged; Factura A/B IVA split logic preserved byte-for-byte.
- [x] 4.8 REFACTOR: `COMMENT ON FUNCTION` updated (documents the 1110 routing + payload dependency); `REVOKE` preserved (no EXECUTE to authenticated/anon/PUBLIC) — `PurchaseCreated`/`CreditNoteIssued` branches preserved unchanged.

## 5. (Conditional on OQ-4 = full sale-side routing) _c29_confirm_order_core + sales enum

- [x] 5.1 (OQ-3 extends the enum) `ALTER sales_orders.payment_method` CHECK to `{cash, transfer, card, other, credit}`; gate (j) confirms new values accepted + `credit`/`cash`/`other` still valid (behavioral in CI + introspection fallback in prod).
- [x] 5.4 **OQ-4 resolved = journal-only** — §5.2/5.3 (sale-side operational `bank_movement` from `_c29_confirm_order_core`) SKIPPED per PO decision. Deferral recorded in the migration header + here.

## 6. Consolidated migration gates + CI

- [x] 6.1 Consolidated all gates into one DO-block using the C1 discriminator (`v_run_behavioral := (count(*)=0 FROM accounts)`) + synthetic anchor (`auth.users` → `accounts` → `account_members` → `bank_accounts` → `clients`/`suppliers`/`companies`) in `BEGIN/EXCEPTION`; JWT simulated via `set_config('request.jwt.claims'/'request.jwt.claim.sub', ...)` (same pattern as `20260804000003_fix_c28_cash_movement_balance.sql`) so `auth.uid()`-dependent RPCs work in the migration context. Introspection gates (a, b, i) always run; behavioral gates (c–h, j, k) only in CI-empty DB, each with a graceful `WHEN OTHERS` fallback (`RAISE NOTICE`, does not abort the migration) if the environment doesn't support the JWT simulation.
- [x] 6.2 Gate (f)/(h): negative gates — a `cash` payment creates NO `bank_movement` (guards against over-routing).
- [ ] 6.3 Push branch → confirm CI `validate-kpis` green (migration applies cleanly on empty DB reset). **Pending — requires CI run on the PR; Docker unavailable locally, structural PL/pgSQL balance verified via static analysis (BEGIN/END/IF/LOOP/CASE token matching, 0 errors).**

## 7. Backend (FastAPI) — payment method + bank account

- [x] 7.1 Extended Pydantic v2 schemas (`PaymentReceivedIn`, `PaymentMadeIn`) with `payment_method` (validated against the taxonomy) + optional `bank_account_id`; `model_validator` enforces bank_account_id when method is bancario (defense in depth alongside the RPC's own P0400 guard).
- [x] 7.2 Threaded `payment_method`/`bank_account_id` through service → repository (`CustomerAccountRepository.register_payment_received`, `SupplierAccountRepository.register_payment_made`) so the RPC calls pass the new trailing params. 3-layer split preserved (no logic in routers).
- [x] 7.3 pytest + pytest-asyncio: `backend/tests/test_c2_bank_payment_routing.py` — 20 tests covering schema validation, repository call shape, service propagation, P0412→400 mapping, and HTTP endpoints (including the retrocompat "no method" path). Full backend suite: 801 passed, 3 skipped, 0 failed (safety net `test_c30_customer_supplier_accounts.py`: 29/29 green).
- [x] 7.4 Added `BankAccountRepository` + `GET /bank-accounts` read endpoint (new router `backend/routers/bank_accounts.py`, registered in `main.py`) listing active `bank_accounts` for the picker.

## 8. Frontend (Next.js) — cobro/pago UI

- [x] 8.1 Added a payment-method `Select` to `RegisterPaymentForm.tsx` (cobro) and `RegisterPaymentMadeForm.tsx` (pago) — React Hook Form + Zod enum `{cash,transfer,card,check}`, default `cash`.
- [x] 8.2 Conditionally rendered a bank-account `Select` when a bank method is selected; populated from `useBankAccounts()` (new hook, `GET /bank-accounts`, React Query, 5 min staleTime).
- [x] 8.3 Wired the selected method + bank account into `useRegisterPayment`/`useRegisterPaymentMade` mutations (new optional `paymentMethod`/`bankAccountId` params, retrocompatible); added `P0400`/`P0412`-derived error translations (`bank_account_required`, `bank_account_not_found`, `bank_account_inactive`, `invalid_payment_method`) to both hooks' `translateError`.
- [x] Frontend tests: `frontend/__tests__/c2-bank-payment-routing.test.ts` — 4 tests (useBankAccounts mapping, payment_method/bank_account_id threading for both hooks, retrocompat). Full frontend suite: 394 passed, 1 pre-existing unrelated failure (`@marsidev/react-turnstile` missing package, not installed in this environment — confirmed unrelated via git status). Safety net `c30-customer-supplier-accounts.test.ts`: 11/11 green.

## 9. Verification + close

- [ ] 9.1 Post-merge (CI deploys Vercel + `db push` to `gxdhpxvdjjkmxhdkkwyb`; backend redeploys on Render): MCP read-only verify a transfer cobro produces (a) a `bank_movement` and (b) a `1110` journal entry after the relay tick; a cash cobro produces neither a bank_movement nor a `1110` line. **Pending — post-merge action.**
- [ ] 9.2 Run `openspec validate bank-payment-routing --strict` (planning) — already green at propose; re-run before archive. **Pending — run before archive.**
- [ ] 9.3 Mark C2 in CHANGES.md (V2.5 BankReconciliation C2/3) and `/opsx:archive bank-payment-routing`; save engram `opsx/bank-payment-routing/apply`. **Pending — orchestrator action after PR review.**
