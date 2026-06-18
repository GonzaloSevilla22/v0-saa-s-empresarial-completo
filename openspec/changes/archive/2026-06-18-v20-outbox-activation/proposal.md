## Why

The `events` table (the Transactional Outbox of DEC-20) exists and producers already write to it (`SaleConfirmed` is emitted inside `SalesOrder.confirm()` since C-29), but **nothing reads it** — there is no relay and no consumers, so audit and email side-effects that DEC-20/DEC-09 deferred to the outbox never happen. C-25 is the last pending change of Phase 6 (V2.0 retirada de deuda): it activates the outbox end-to-end (relay + AuditLog + EmailNotification consumers + the remaining producers).

Equally important, C-29's production hotfix left `public.events` in a **drifted state** (PROD carries legacy `company_id`/`entity_type`/`title` NOT NULL columns that do not exist in CI; the V2 columns were added via `ADD COLUMN IF NOT EXISTS` outside a canonical reshape). The same drift caused the C-29 PROD outage that passed CI. C-25 must formalize the canonical outbox schema in migration history so CI and PROD converge before more consumers depend on it.

## What Changes

- **Reconcile the `events` schema drift** (the C-29 TODO): a single idempotent, drift-tolerant migration that formalizes the canonical V2 outbox columns and resolves the legacy `company_id`/`entity_type`/`title` columns in migration history, so CI and PROD converge. Add the relay's partial index `WHERE processed_at IS NULL`.
- **Relay**: a pg_cron job (mirroring the established C-27 `relay-process-pending-cae` pattern) that periodically dispatches unprocessed events. It selects `events WHERE processed_at IS NULL` with `FOR UPDATE SKIP LOCKED`, routes by `event_type` to each consumer, sets `processed_at` on success, and leaves it NULL on failure (retried next run).
- **Consumer AuditLog** (mandatory first): one append-only `audit_logs` row per processed event.
- **Consumer EmailNotification**: for `sale_created` / `stock_adjusted` / `plan_changed` event types, emits via the existing DEC-09 email path (INSERT into `email_logs` → DB webhook → Edge Function → Resend). It does **not** call Resend directly.
- **Producers** (new): emit `PurchaseCreated` and `StockAdjusted` from the backend Python mutations, INSERT into `events` inside the **same transaction** as the mutation (DEC-20). `SaleConfirmed` already exists (C-29) — not re-created.
- **Idempotency**: each consumer reuses `operation_idempotency` keyed by `(event_id, consumer_type)`; a duplicate-processed event must not produce a second `audit_logs` row.
- **Scope cap (PA-21, resolved)**: V2.0 consumers are **only** AuditLog + EmailNotification. AI/reporting consumers are explicitly deferred to V2.1 and are NOT added here.

## Capabilities

### New Capabilities
- `transactional-outbox`: The events outbox lifecycle — canonical schema, the relay (dispatch loop, ordering, locking, retry semantics), consumer routing by `event_type`, the AuditLog and EmailNotification consumers, consumer idempotency, the producer contract (event INSERT in the mutation transaction), and the relay's RLS/auth model.

### Modified Capabilities
<!-- No existing capability changes its requirements. SaleConfirmed producer (sale-line-items / sales-order) already emits to the outbox as of C-29 and is referenced, not modified. -->

## Impact

- **DB schema**: `public.events` (canonical reshape + partial index), new unique key on `operation_idempotency` for `(event_id, consumer_type)`, `audit_logs` (account_id reconciliation for the consumer write). New pg_cron job `relay-process-outbox`.
- **Backend Python**: new outbox relay service + repository (dispatch + consumer handlers), new `PurchaseCreated` / `StockAdjusted` producers wired into the purchase-create and stock-adjust RPC/repository transactions. 3-layer: routers → services → repositories.
- **Email infra**: reuses the existing `email_logs` → webhook → Resend path (DEC-09); no new mailer.
- **Governance**: MEDIO overall, but the AuditLog consumer writes the audit domain (append-only, tamper-evident, never droppable by the relay) — see design.md.
- **Migrations**: applied via `npx supabase db push` (CLI), never MCP `apply_migration`. The reconciliation migration MUST be idempotent + drift-tolerant (`ADD COLUMN IF NOT EXISTS`, guarded `ALTER`, `IF EXISTS` checks) or C-25 repeats the C-29 PROD break.
- **Tests**: pytest + pytest-asyncio for producers, relay dispatch routing, idempotency, and retry-on-failure.
