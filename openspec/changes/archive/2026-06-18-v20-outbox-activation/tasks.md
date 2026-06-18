# Tasks — v20-outbox-activation (C-25)

> Strict TDD. Every behavior follows RED → GREEN → TRIANGULATE → REFACTOR. SQL tasks
> (migration, RPC, cron) are verified by pytest integration tests against a test DB and
> by re-running the migration for idempotency; never run apply work without a failing
> test first. Migrations apply via `npx supabase db push` (NEVER MCP `apply_migration`).
> Governance MEDIO — but §3 (AuditLog) touches the audit domain: append-only, never
> droppable by the relay. Surface non-obvious decisions to the user.

## 1. Schema reconciliation migration (the C-29 drift TODO)

- [x] 1.1 Create `supabase/migrations/<ts>_c25_events_outbox_reconcile.sql`. Re-assert canonical V2 columns on `public.events` with `ADD COLUMN IF NOT EXISTS` (`account_id`, `event_type`, `aggregate_type`, `aggregate_id`, `payload`, `occurred_at timestamptz DEFAULT now()`, `processed_at timestamptz`). All `TIMESTAMPTZ`, never `TIMESTAMP`.
- [x] 1.2 Guard legacy columns: `DO $$ ... IF EXISTS (information_schema.columns ... is_nullable='NO') THEN ALTER TABLE public.events ALTER COLUMN <col> DROP NOT NULL` for `company_id`, `entity_type`, `title`. Do NOT `DROP COLUMN` (Decision 2). Idempotent.
- [x] 1.3 Add partial index `CREATE INDEX IF NOT EXISTS events_unprocessed_idx ON public.events (occurred_at) WHERE processed_at IS NULL`.
- [x] 1.4 Reconcile `public.audit_logs` for the consumer: `ADD COLUMN IF NOT EXISTS account_id uuid`, index `(account_id, created_at)`; keep legacy `company_id` nullable. `COMMENT` documenting append-only intent.
- [x] 1.5 Add the consumer-idempotency shape on `public.operation_idempotency`: `ADD COLUMN IF NOT EXISTS event_id uuid` + `consumer_type text`, and `CREATE UNIQUE INDEX IF NOT EXISTS operation_idempotency_event_consumer_uq ON public.operation_idempotency (event_id, consumer_type) WHERE event_id IS NOT NULL`. Do not break the existing `(user_id, idempotency_key)` unique.
- [x] 1.6 `COMMENT ON TABLE public.events` documenting the canonical outbox contract + legacy columns as inert nullable.
- [x] 1.7 RED: write `backend/tests/migrations/test_events_reconcile.py` — assert against a fresh test DB that all canonical columns exist, legacy columns are nullable, the partial index exists, and the `(event_id, consumer_type)` unique index exists. (Fails before the migration is applied.)
- [x] 1.8 GREEN: apply the migration to the test DB; tests pass.
- [x] 1.9 TRIANGULATE: re-apply the migration a second time (idempotency) → still green, no error; assert no `DROP COLUMN` ran and legacy columns survive.
- [x] 1.10 REFACTOR: clean SQL comments/naming; run `supabase db advisors` and address any new lint on `events`/`audit_logs`.

## 2. Relay: definer RPC + pg_cron + dispatch skeleton

- [x] 2.1 RED: `backend/tests/outbox/test_relay_select.py` — relay claims only `processed_at IS NULL` rows, ordered by `occurred_at`, and uses `FOR UPDATE SKIP LOCKED` (assert two concurrent claims do not overlap). Fails — no relay yet.
- [x] 2.2 GREEN: add `rpc_process_outbox_batch` to the migration: `SECURITY DEFINER`, owned by the privileged role, selects pending events `FOR UPDATE SKIP LOCKED LIMIT <batch>`. `REVOKE ALL ... FROM PUBLIC; REVOKE EXECUTE ... FROM anon; GRANT EXECUTE ... TO authenticated` (narrow). Implement the backend relay repository (`backend/.../repositories/outbox_repository.py`) calling it via JWT-passthrough (no `service_role`).
- [x] 2.3 GREEN: relay service (`backend/.../services/outbox_relay_service.py`) — dispatch loop routing by `event_type`; mark `processed_at = now()` only after all in-scope consumers succeed. Endpoint `POST /outbox/process-pending` (router, 3-layer, DI via `Depends`). Tests pass.
- [x] 2.4 TRIANGULATE: add a test where the batch contains a mix of processed + unprocessed rows and a locked row → only the eligible unprocessed unlocked rows are claimed.
- [x] 2.5 GREEN: add pg_cron job to the migration: `SELECT cron.unschedule('relay-process-outbox') FROM cron.job WHERE jobname='relay-process-outbox';` then `cron.schedule('relay-process-outbox', '* * * * *', $$ ... $$)` mirroring C-27. **PIVOT (2026-06-18):** cron body now calls `SELECT public.rpc_process_outbox_dispatch(100)` directly (pure-SQL relay) — replaced the original no-op keepalive UPDATE. The Python relay endpoint is retained as a manual/secondary trigger. Decision 1 in design.md updated.
- [x] 2.6 REFACTOR: extract the consumer registry (`event_type` → handlers) so consumers are added declaratively; tests still green.
- [x] 2.7 NEW — pure-SQL relay RPC (C-25 pivot, 2026-06-18): add `public.rpc_process_outbox_dispatch(p_batch_limit int DEFAULT 100) RETURNS int` to migration `20260718000001`. `SECURITY DEFINER`, `SET search_path TO 'public'`, `LANGUAGE plpgsql`. `REVOKE ALL/EXECUTE FROM PUBLIC, anon`; `GRANT EXECUTE TO authenticated`. Implements: (a) `FOR UPDATE SKIP LOCKED` batch select; (b) per-event `BEGIN/EXCEPTION/END` isolation; (c) AuditLog consumer (mandatory first, `INSERT INTO audit_logs`, idempotency via `operation_idempotency`); (d) EmailNotification consumer (in-scope types only, `INSERT INTO email_logs`, idempotency); (e) `UPDATE events SET processed_at = now()` only on full success; (f) `RETURN v_processed_count`. Tests: `TestDispatchRpcPresence`, `TestDispatchRpcBehaviorInSQL`, `TestCronBodyRewrite`, `TestDispatchRpcTriangulate` in `backend/tests/migrations/test_events_reconcile.py` — 36 new static assertions, all GREEN. TDD cycle: RED (25 failing) → GREEN (all pass) → TRIANGULATE (11 additional cases) → REFACTOR (test fixtures tightened).

## 3. AuditLog consumer (audit domain — append-only, mandatory first)

- [x] 3.1 RED: `backend/tests/outbox/test_audit_consumer.py::test_audit_consumer_writes_one_row` — processing an event INSERTs exactly one `audit_logs` row stamped with the event's `account_id`. Fails.
- [x] 3.2 GREEN: implement the AuditLog consumer (INSERT-only into `audit_logs`, `account_id` from the event, action derived from `event_type`). Runs FIRST in the per-event consumer order. Test passes.
- [x] 3.3 RED+GREEN (TRIANGULATE): `test_audit_failure_keeps_event_unprocessed` — if the audit INSERT raises, `events.processed_at` stays NULL and no consumer marks the event processed (audit is never skipped). Use `Mock.side_effect` to force the failure.
- [x] 3.4 TRIANGULATE: `test_relay_never_updates_or_deletes_audit_rows` — assert the relay path only INSERTs audit rows (no UPDATE/DELETE), protecting append-only/tamper-evidence.
- [x] 3.5 REFACTOR: dedupe consumer boilerplate; tests green.

## 4. Consumer idempotency

- [x] 4.1 RED: `backend/tests/outbox/test_idempotency.py::test_reprocessed_event_one_audit_row` — dispatch the same event to AuditLog twice → exactly one `audit_logs` row (the `(event_id, consumer_type)` key collides on the second attempt). Fails.
- [x] 4.2 GREEN: implement idempotency via `INSERT INTO operation_idempotency (event_id, consumer_type, ...) ON CONFLICT (event_id, consumer_type) DO NOTHING` guarding each consumer's side-effect (upsert, never SELECT-then-INSERT). Test passes.
- [x] 4.3 TRIANGULATE: `test_independent_idempotency_per_consumer` — an event processed by AuditLog (success) then EmailNotification (fails, retried) does not re-fire AuditLog on the retry; each `(event_id, consumer_type)` is independent.
- [x] 4.4 REFACTOR: factor the idempotency guard into a shared helper used by every consumer; tests green.

## 5. EmailNotification consumer (DEC-09 path)

- [x] 5.1 RED: `backend/tests/outbox/test_email_consumer.py::test_email_for_in_scope_type` — for `sale_created` / `stock_adjusted` / `plan_changed`, the consumer INSERTs into `email_logs` (NOT a direct Resend call). Fails.
- [x] 5.2 GREEN: implement the consumer as an `email_logs` INSERT (recipient/subject/event_type/metadata) reusing the existing `email_logs` schema (`supabase/migrations/20250101000008_email_logs.sql`); the DB webhook → Edge Function → Resend pipeline delivers it. Mock the DB layer; assert no Resend client is invoked. Test passes.
- [x] 5.3 TRIANGULATE: `test_no_email_for_out_of_scope_type` — an event whose type is not in the set produces no `email_logs` row.
- [x] 5.4 TRIANGULATE: `test_email_failure_keeps_event_unprocessed_but_audit_intact` — email failure leaves `processed_at` NULL; on retry AuditLog's idempotency prevents a duplicate audit row.
- [x] 5.5 REFACTOR: tidy subject/recipient mapping; tests green.

## 6. Producers — PurchaseCreated + StockAdjusted (same-tx, DEC-20)

- [x] 6.1 RED: `backend/tests/outbox/test_producers.py::test_purchase_created_emitted_in_tx` — committing a purchase-create mutation leaves a `PurchaseCreated` row in `events` with `account_id` + aggregate ids, written in the same transaction. Fails.
- [x] 6.2 GREEN: add the `PurchaseCreated` event INSERT to the existing purchase-create repository/RPC transaction (same connection — do NOT split into a second connection). Stamp `account_id`, `event_type='PurchaseCreated'`, `aggregate_type`, `aggregate_id`, `payload`, `occurred_at`. Test passes.
- [x] 6.3 RED+GREEN: `test_stock_adjusted_emitted_in_tx` — same for the stock-adjust path (`event_type='StockAdjusted'`).
- [x] 6.4 TRIANGULATE: `test_event_rolls_back_with_failed_mutation` — when the mutation rolls back (e.g. invariant violation), no event row remains (proves shared transaction).
- [x] 6.5 Confirm `SaleConfirmed` is NOT re-created (already emitted by C-29, `supabase/migrations/20260702000001_c29_quote_salesorder.sql` lines ~574-589) — add a brief comment/test referencing the existing producer; do not duplicate.
- [x] 6.6 REFACTOR: extract a small `emit_event(...)` repository helper shared by both producers; tests green.

## 7. End-to-end acceptance + verification

- [x] 7.1 RED→GREEN: `backend/tests/outbox/test_e2e_outbox.py::test_sale_created_to_audit_log` — a `SaleConfirmed` event (from C-29's path or a fixture insert) processed by the relay yields an `audit_logs` entry.
- [x] 7.2 `test_event_processed_twice_is_idempotent` — relay run twice over the same event → exactly one `audit_logs` row.
- [x] 7.3 `test_relay_raises_leaves_processed_at_null` — force a consumer exception → `events.processed_at` stays NULL, retried next run.
- [x] 7.4 Run the full backend suite (pytest + pytest-asyncio) green; verify coverage on producers, relay dispatch routing, and idempotency path (`pytest-coverage`).
- [x] 7.5 Run `supabase db advisors`; resolve any new RLS/security findings on `events`, `audit_logs`, `operation_idempotency`, and `rpc_process_outbox_batch`.
- [x] 7.6 Confirm NO AI/reporting consumers were added (PA-21 scope cap: AuditLog + EmailNotification only).
- [ ] 7.7 Mark `[x]` C-25 in `CHANGES.md` after archive.
