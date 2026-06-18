# Transactional Outbox Specification

## Purpose

Provides a canonical transactional outbox pattern for EIE domain events. Events are durably stored in `public.events` during mutations, processed asynchronously by a relay (pg_cron), and dispatched to consumers (AuditLog, EmailNotification) with idempotency, retry logic, and multi-tenant authorization via SECURITY DEFINER RPC.

---

## Requirements

### Requirement: Canonical events outbox schema

The `public.events` table SHALL be the single transactional outbox with a canonical V2 schema formalized in migration history: `id`, `account_id`, `event_type text`, `aggregate_type text`, `aggregate_id uuid`, `payload jsonb`, `occurred_at timestamptz DEFAULT now()`, and `processed_at timestamptz` where `NULL` means unprocessed. The reconciliation migration SHALL be idempotent and drift-tolerant so it converges CI and PROD without destructive DDL. Legacy columns (`company_id`, `entity_type`, `title`) SHALL be kept as nullable legacy columns, not dropped.

#### Scenario: Migration applies on a CI-shaped events table

- **WHEN** the reconciliation migration runs against a database whose `events` table is the CI stub (`id, company_id NULLABLE, title, created_at`, no `entity_type`)
- **THEN** it completes without error, the canonical V2 columns are present (added if missing), and no `entity_type`-not-found error occurs because all alterations are guarded by `IF EXISTS` / `ADD COLUMN IF NOT EXISTS`

#### Scenario: Migration applies on a drifted PROD-shaped events table

- **WHEN** the reconciliation migration runs against a database whose `events` table carries legacy `company_id`/`entity_type` as `NOT NULL`
- **THEN** those legacy columns are altered to nullable, the V2 columns remain intact, no column is dropped, and re-running the migration is a no-op

#### Scenario: Relay query has a supporting partial index

- **WHEN** the migration completes
- **THEN** a partial index on `events (occurred_at)` (or `events (processed_at)`) `WHERE processed_at IS NULL` exists so the relay's pending-row scan does not table-scan

### Requirement: Outbox relay dispatch

A relay SHALL periodically select unprocessed events (`processed_at IS NULL`) ordered by `occurred_at`, using `FOR UPDATE SKIP LOCKED` to avoid double-processing under concurrent runs, route each event to the consumers registered for its `event_type`, and set `processed_at = now()` only after all in-scope consumers for that event succeed. The relay SHALL be scheduled via pg_cron (mirroring the C-27 relay pattern) and SHALL NOT use `service_role`.

#### Scenario: Pending event is dispatched and marked processed

- **WHEN** the relay runs and finds an event with `processed_at IS NULL`
- **THEN** it dispatches the event to every consumer registered for its `event_type`, and on success sets `processed_at = now()` for that event

#### Scenario: Concurrent relay runs do not double-process

- **WHEN** two relay invocations overlap on the same pending events
- **THEN** `FOR UPDATE SKIP LOCKED` ensures each pending event is claimed by at most one run, so no consumer side-effect is applied twice

#### Scenario: Consumer failure leaves the event for retry

- **WHEN** a consumer raises while processing an event
- **THEN** `processed_at` for that event stays `NULL` and the event is retried on the next relay run

### Requirement: AuditLog consumer

The relay SHALL include an AuditLog consumer (mandatory, first) that writes exactly one append-only row into `public.audit_logs` per processed event, stamped with the event's `account_id`. An event SHALL NOT be marked `processed_at` unless its audit row is committed. The relay SHALL only INSERT audit rows and SHALL NOT update or delete existing audit rows.

#### Scenario: Audit row written per processed event

- **WHEN** the relay processes an event through the AuditLog consumer
- **THEN** exactly one `audit_logs` row is inserted for that event, carrying the event's `account_id` and an action derived from `event_type`

#### Scenario: Audit failure blocks marking processed

- **WHEN** the AuditLog consumer fails to write its row
- **THEN** the event's `processed_at` remains `NULL` and no later consumer marks the event processed, so the audit entry is never skipped

### Requirement: EmailNotification consumer

The relay SHALL include an EmailNotification consumer that, for events of type `sale_created`, `stock_adjusted`, or `plan_changed`, emits the notification by inserting into `public.email_logs` (the DEC-09 path: DB webhook → Edge Function → Resend). The consumer SHALL NOT call Resend directly and SHALL NOT run for event types outside that set.

#### Scenario: Email emitted via email_logs for an in-scope event type

- **WHEN** the relay processes an event of type `sale_created`, `stock_adjusted`, or `plan_changed`
- **THEN** the EmailNotification consumer inserts a row into `email_logs` (not a direct Resend call) so the existing webhook pipeline delivers it

#### Scenario: No email for out-of-scope event types

- **WHEN** the relay processes an event whose type is not in `{sale_created, stock_adjusted, plan_changed}`
- **THEN** the EmailNotification consumer does nothing for that event

### Requirement: Consumer idempotency

Each consumer SHALL be idempotent, keyed by `(event_id, consumer_type)` reusing the `operation_idempotency` ledger via `INSERT ... ON CONFLICT DO NOTHING`. Processing the same event twice for the same consumer SHALL produce exactly one side-effect (e.g. one `audit_logs` row).

#### Scenario: Re-processed event does not duplicate the audit row

- **WHEN** the same event is dispatched to the AuditLog consumer twice (e.g. after a retry)
- **THEN** the `(event_id, consumer_type)` idempotency key collides on the second attempt, the consumer skips its side-effect, and `audit_logs` contains exactly one row for that event

#### Scenario: Independent idempotency per consumer

- **WHEN** an event is processed by both AuditLog and EmailNotification
- **THEN** each consumer records its own `(event_id, consumer_type)` key, so a retry that re-runs only the failed consumer does not re-fire the one that already succeeded

### Requirement: Outbox producers

Backend mutations SHALL emit domain events into `public.events` inside the SAME transaction as the mutation (DEC-20). C-25 SHALL add `PurchaseCreated` and `StockAdjusted` producers; the `SaleConfirmed` producer already exists (C-29) and SHALL NOT be re-created. Each emitted event SHALL stamp `account_id`, `event_type`, `aggregate_type`, `aggregate_id`, `payload`, and `occurred_at`.

#### Scenario: PurchaseCreated emitted in the purchase transaction

- **WHEN** a purchase-create mutation commits
- **THEN** a `PurchaseCreated` event row exists in `events` with the purchase's `account_id` and aggregate identifiers, written in the same transaction

#### Scenario: Event rolls back with a failed mutation

- **WHEN** a `StockAdjusted`-producing mutation rolls back (e.g. invariant violation)
- **THEN** no `StockAdjusted` event row remains, because the event INSERT shares the mutation's transaction

### Requirement: Relay authorization model

The relay SHALL read all pending events across accounts and update `processed_at` through an explicitly-owned `SECURITY DEFINER` RPC with EXECUTE revoked from `anon`/`PUBLIC`, without weakening tenant RLS for normal users. Normal-user RLS on `events` SHALL remain SELECT-only scoped by `account_id`, and the API/`service_role` key SHALL NOT be used to bypass RLS in application code.

#### Scenario: Normal user cannot read another account's events

- **WHEN** an authenticated user queries `events` directly
- **THEN** RLS returns only rows for that user's `account_id`, never other accounts' events

#### Scenario: Relay processes across accounts via the definer RPC

- **WHEN** the pg_cron relay invokes the outbox-processing RPC
- **THEN** the `SECURITY DEFINER` owner bypasses RLS for the relay's pending scan and `processed_at` update only, with EXECUTE not granted to `anon`/`PUBLIC`, and no `service_role` key used in app code
