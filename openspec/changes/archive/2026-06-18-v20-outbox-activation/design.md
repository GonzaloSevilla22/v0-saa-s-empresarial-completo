## Context

The Transactional Outbox (`public.events`, DEC-20) is half-wired: producers exist (`SaleConfirmed` is emitted inside `rpc` `SalesOrder.confirm()` since C-29, migration `supabase/migrations/20260702000001_c29_quote_salesorder.sql` lines ~574-589) but there is no relay and no consumers. PA-21 (resolved 2026-06-10) caps V2.0 consumers to **AuditLog + EmailNotification**.

Two hard constraints shape this design:

1. **Schema drift.** `public.events` differs between environments. CI builds it from the stub `supabase/migrations/20260517000000_ci_compat_stubs.sql` = `(id, company_id NULLABLE, title, created_at)` — no `entity_type`. PROD carries the original (non-migration) schema with `company_id`/`entity_type` `NOT NULL` (legacy company-based event design). C-29's reshape (`ADD COLUMN IF NOT EXISTS account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at, processed_at`) added the V2 columns; the hotfix `supabase/migrations/20260702000002_c29_hotfix_events_outbox_nullable.sql` then dropped `NOT NULL` from the legacy columns **only where they existed** (drift-tolerant `DO $$ ... IF EXISTS`). The hotfix header is the canonical drift writeup and leaves the explicit TODO for C-25: formalize the canonical schema in migration history. This is the C-29 PROD outage's root cause class — a migration that passes CI and breaks PROD.

2. **Existing precedents to mirror, not reinvent.** The codebase already ships a relay (C-27 `relay-process-pending-cae`, `supabase/migrations/20260627000001_c27_fiscal_profile.sql` lines ~428-451) as a pg_cron job; the email path is DEC-09 (`email_logs` → DB webhook → Edge Function → Resend); idempotency is `operation_idempotency` (`supabase/migrations/20260528161955_operation_idempotency.sql`). Project hard rules: backend uses JWT-passthrough, never `service_role`; RLS stays on every public table; migrations apply via `npx supabase db push`.

Constraints: account-based tenancy (`account_id`, org-scoped RLS); strict TDD on apply (pytest + pytest-asyncio); CI auto-applies migrations + deploys Edge Functions on merge to `main`.

## Goals / Non-Goals

**Goals:**
- Activate the outbox end-to-end: relay + AuditLog + EmailNotification consumers + the two missing producers (`PurchaseCreated`, `StockAdjusted`).
- Reconcile the `events` drift in migration history so CI and PROD converge (idempotent, drift-tolerant migration).
- Idempotent consumers via `operation_idempotency` keyed by `(event_id, consumer_type)` — a re-processed event produces exactly one `audit_logs` row.
- Retry semantics: a consumer/relay failure leaves `events.processed_at` NULL so the next run retries; processed events are never reprocessed into duplicate side-effects.

**Non-Goals:**
- AI/reporting/accounting (`JournalEntry`) consumers — deferred to V2.1 (PA-21, DEC-20). Do NOT add them.
- Re-creating the `SaleConfirmed` producer — it already exists (C-29).
- Introducing a message broker / LISTEN-NOTIFY (the V2 model defers a broker until the outbox "duele", §5.9 `modelo-dominio-aliadata-v2.md`).
- Dropping the `events` legacy columns destructively in a way that risks PROD (see Decision 2).
- Migrating IA/OCR off Edge Functions (DEC-15).

## Decisions

### Decision 1 — Relay mechanism: pure-SQL plpgsql function invoked by pg_cron (pivot from original design)

**Chosen (updated 2026-06-18, C-25 apply):** pg_cron job `relay-process-outbox` running every minute calls `public.rpc_process_outbox_dispatch(100)` directly — a `SECURITY DEFINER` plpgsql function that performs the full dispatch loop in-DB (no HTTP, no pg_net, no Render cold-start in the hot loop). The function: selects up to 100 pending events via `FOR UPDATE SKIP LOCKED`; runs AuditLog first (mandatory), then EmailNotification for in-scope types; uses `ON CONFLICT DO NOTHING` on `operation_idempotency` for idempotency; wraps each event in `BEGIN/EXCEPTION/END` so one bad event never aborts the batch; marks `processed_at = now()` only after all active consumers succeed; returns the count of processed events.

The Python relay (`OutboxRelayService` + `POST /outbox/process-pending`) is **retained as a manual/secondary trigger** — it is not deleted. It remains valid for on-demand dispatch and debugging.

**IMPORTANT — C-27 CAE relay cannot use this pattern:** C-27's AFIP/WSFE relay calls an external SOAP service — a side-effect that cannot run inside a plpgsql function. C-27's trigger gap (pg_cron → HTTP → Render backend) is out of scope for C-25.

**Alternatives considered (updated):**
- *pg_cron + Python backend endpoint (original design).* Superseded by this pivot. The Render cold-start (~50s) was the documented risk; eliminating the HTTP hop removes it entirely for the outbox relay. The Python backend is kept as a secondary trigger.
- *Edge Function relay.* Rejected: adds a second runtime for the same job; inconsistent ops.
- *Python worker (ARQ) / standalone loop.* Rejected: ARQ workers explicitly postponed (DEC-15).

**Trade-off:** The plpgsql function runs inside Postgres — no network hop for the hot loop. Email consumer is an `email_logs` INSERT (fine in SQL, DEC-09 path unchanged). Testability: static SQL assertions verify the function's behavior; the Python relay keeps the business logic in a separately-testable Python layer for future consumer additions. Governance HIGH: function is `SECURITY DEFINER`, `REVOKE`d from `anon`/`PUBLIC`, rationale documented (cross-account dispatch without service_role — Decision 4). Accepted.

### Decision 2 — Legacy `events` columns (`company_id`, `entity_type`, `title`): keep nullable-legacy, documented, NOT dropped

**Chosen:** Keep `company_id`, `entity_type`, `title` as **nullable legacy columns** and formalize the canonical schema additively in migration history. The reconciliation migration: (a) re-asserts the V2 columns with `ADD COLUMN IF NOT EXISTS`; (b) guards each legacy column with `DO $$ IF EXISTS ... ALTER COLUMN ... DROP NOT NULL` (idempotent, no-op where already nullable or absent); (c) adds the relay partial index; (d) `COMMENT`s the table documenting the canonical outbox contract and the legacy columns as inert. No `DROP COLUMN`.

**Alternatives considered:**
- *Drift-tolerant DROP of the legacy columns.* Rejected as higher-risk now: the table in PROD is **outside** migration history, so a `DROP COLUMN IF EXISTS` would diverge CI (no `entity_type` to drop) from PROD, and any forgotten dependency (triggers/views/old code) on those columns would break PROD silently — the exact failure mode C-25 exists to prevent. Dropping inert columns is pure cleanup with zero functional gain and non-zero PROD risk. Deferred to a later dedicated cleanup once PROD is provably aligned to migration history.

**Trade-off:** three inert nullable columns linger on the table. Cost: cosmetic. Benefit: the reconciliation migration is provably safe in both CI and PROD. This is the lower-risk option and is recommended.

### Decision 3 — EmailNotification dispatch: reuse the DEC-09 path (`email_logs` INSERT), do not call Resend directly

**Chosen:** The EmailNotification consumer, for `sale_created` / `stock_adjusted` / `plan_changed` events, **INSERTs a row into `public.email_logs`** (`supabase/migrations/20250101000008_email_logs.sql`). The existing DB webhook → Edge Function → Resend pipeline (DEC-09) delivers it. The relay never holds an SMTP/Resend call in its transaction.

**Alternatives considered:**
- *Relay calls Resend directly.* Rejected: duplicates the mailer, loses DEC-09's retry/dedup/audit, and couples the relay to Resend uptime. `email_logs` already has a `UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)` dedup constraint that complements consumer idempotency.

**Trade-off:** extra hop (webhook latency) — explicitly accepted by DEC-09. Email is not synchronous with the user action.

### Decision 4 — Relay auth/RLS model: an explicitly-owned SECURITY DEFINER relay, no `service_role`, tenant RLS untouched for users

**Chosen:** Normal-user RLS on `events` stays **SELECT-only by `account_id`** (policy `events_select`, unchanged). The relay must read ALL pending rows across accounts and UPDATE `processed_at` — it does this through a narrowly-scoped, explicitly-owned `SECURITY DEFINER` RPC (e.g. `rpc_process_outbox_batch`) owned by a privileged role (table owner), the same trust model as the existing `SECURITY DEFINER` operation RPCs and C-27's emit RPC. The Python backend invokes it via JWT-passthrough; the RPC's owner bypasses RLS for the relay query only, with a documented narrow rationale. **No `service_role` in app/backend code** (project hard rule). The AuditLog/EmailNotification writes happen inside that same definer scope so they are not blocked by the consumers' table RLS (no INSERT policy is granted to `authenticated` on `audit_logs`/`email_logs`/`operation_idempotency`, consistent with how those tables are written today).

**Alternatives considered:**
- *Broaden `events` RLS so the API role can read all pending.* Rejected — that is a BOLA/IDOR hole (any user reads every account's events).
- *`service_role` in the backend.* Rejected — violates the project hard rule (JWT-passthrough only).

**Trade-off:** `SECURITY DEFINER` is used deliberately for the relay. The supabase skill warns against `SECURITY DEFINER` to paper over permission errors — the documented exception is exactly "a relay that must bypass RLS, as an explicitly-owned function with a narrow rationale". We scope it to the relay RPC only and `REVOKE` from `anon`/`PUBLIC`, granting EXECUTE narrowly.

### Decision 5 — Idempotency key shape

Reuse `operation_idempotency` with a new logical key `(event_id, consumer_type)`. Because that table's current UNIQUE is `(user_id, idempotency_key)` and is `user_id`-scoped (FK to `auth.users`), the migration adds a dedicated **partial unique index / companion column** for consumer idempotency rather than overloading the user-scoped key — the apply agent picks the minimal shape (a `consumer_type text` + `event_id uuid` pair with `UNIQUE (event_id, consumer_type)`), written via `INSERT ... ON CONFLICT DO NOTHING` (upsert, never SELECT-then-INSERT). On conflict the consumer skips its side-effect → exactly-once audit row.

## Risks / Trade-offs

- **[Reconciliation migration breaks PROD like C-29 did]** → The migration is additive + guarded only (`ADD COLUMN IF NOT EXISTS`, `DO $$ IF EXISTS ... DROP NOT NULL`, `CREATE INDEX IF NOT EXISTS`, no destructive DDL). Tested by applying to a CI-shaped DB and reasoning against the documented PROD shape. No `DROP COLUMN`.
- **[Audit entries lost on relay failure]** (CRITICAL-adjacent: `audit_logs` is the audit domain) → AuditLog runs first per event; `processed_at` is set **only after** the audit row is committed. If the audit INSERT fails, the event stays unprocessed (NULL) and is retried — an event is never marked processed without its audit row. Audit rows are append-only (no UPDATE/DELETE policy for `authenticated`); the relay only INSERTs, never mutates/deletes audit rows. Apply-time guards live in tasks.md.
- **[Double-processing under concurrent relay runs]** → `FOR UPDATE SKIP LOCKED` on the pending select + `(event_id, consumer_type)` unique idempotency means two overlapping runs cannot double-apply a consumer.
- **[Partial consumer success]** (audit ok, email fails) → Each consumer's idempotency row is independent. The relay marks `processed_at` only when ALL in-scope consumers for that event succeeded; a failed email leaves `processed_at` NULL and retries — AuditLog's idempotency row prevents a duplicate audit on retry. (Apply agent confirms this ordering in tests.)
- **[`events` table never partitioned / grows unbounded]** → Out of scope for V2.0; the partial index `WHERE processed_at IS NULL` keeps the relay query cheap regardless of processed volume. A retention/archive job is a V2.1+ concern.
- **[Producers split the event INSERT into a second connection]** → Hard rule in tasks: the `PurchaseCreated`/`StockAdjusted` INSERT goes in the SAME repository/RPC transaction as the mutation (DEC-20). Tests assert the event row rolls back if the mutation rolls back.

## Migration Plan

1. **Reconciliation migration** (`supabase/migrations/<ts>_c25_events_outbox_reconcile.sql`): additive + guarded canonical reshape of `public.events`; partial index `WHERE processed_at IS NULL`; `account_id` reconciliation/index on `audit_logs` as needed for the consumer; `(event_id, consumer_type)` idempotency shape on `operation_idempotency`; `rpc_process_outbox_batch` (SECURITY DEFINER, REVOKE from anon/PUBLIC); pg_cron `relay-process-outbox`. Applied via `npx supabase db push`.
2. **Backend**: relay service + repository (dispatch routing, consumer handlers for AuditLog + EmailNotification, idempotency), `PurchaseCreated`/`StockAdjusted` producers wired into existing purchase-create / stock-adjust transactions. 3-layer.
3. **Verify**: pytest green (producers, dispatch routing, idempotency, retry-on-failure); `supabase db advisors` after schema/RLS changes.
4. **Rollback**: drop the pg_cron job (`SELECT cron.unschedule('relay-process-outbox')`) to stop dispatch instantly; producers are additive INSERTs (events accumulate unprocessed, harmless). The reconciliation migration is additive — no data rollback needed.

## Open Questions

- **Batch size / cadence for the relay.** Default to C-27's 1-minute tick + a modest `LIMIT` (e.g. 100) per run; revisit only if backlog grows. (Non-blocking — apply agent picks a sane default.)
- **`audit_logs` account_id backfill scope.** The stub `audit_logs` has `company_id` (legacy). The consumer writes `account_id`; confirm with PO whether historical `audit_logs` rows need backfill or only forward-fill applies (forward-fill assumed — audit is append-only and the outbox starts empty). Non-blocking for apply.
