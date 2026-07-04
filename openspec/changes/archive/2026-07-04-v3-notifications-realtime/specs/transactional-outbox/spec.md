## ADDED Requirements

### Requirement: Notification consumer (Consumer 4)

The relay `rpc_process_outbox_dispatch` SHALL include a fourth consumer, Notification, that projects in-scope domain events into `public.notifications` rows for the in-app notification bell. It SHALL run inside the same per-event `BEGIN/EXCEPTION/END` isolation block as Consumers 1-3, after them, so a projection failure for one event does not abort the batch. It SHALL run only for events of type `StockBelowMinimum`, `CashSessionClosed`, `FiscalDocumentRejected`, `QuoteAccepted`, or `TransferDispatched`, and SHALL be a no-op for all other event types. It SHALL be idempotent, keyed by `(event_id, 'Notification')` in `operation_idempotency` via `INSERT ... ON CONFLICT DO NOTHING` (`operation_kind = 'event_consumer'`, the existing marker kind). The projection logic — including audience resolution by role and severity assignment — SHALL live in a helper function `_notification_from_event(event_row)` (`SECURITY DEFINER`, `SET search_path = public`), with EXECUTE revoked from `anon`/`PUBLIC`/`authenticated`. The consumer SHALL NOT use `service_role` and SHALL NOT make HTTP / `pg_net` calls. A `CashSessionClosed` event with a zero difference SHALL NOT produce a notification.

#### Scenario: In-scope event projects a notification through Consumer 4

- **WHEN** the relay processes a `StockBelowMinimum` event that has no existing `(event_id, 'Notification')` idempotency slot
- **THEN** Consumer 4 calls `_notification_from_event`, which inserts a `notifications` row with the resolved audience and severity, after Consumers 1-3 have run for that event

#### Scenario: Out-of-scope event is skipped by Consumer 4

- **WHEN** the relay processes an event whose type is not in `{StockBelowMinimum, CashSessionClosed, FiscalDocumentRejected, QuoteAccepted, TransferDispatched}`
- **THEN** Consumer 4 does nothing for that event while Consumers 1-3 still run normally

#### Scenario: Re-processed event does not create a second notification

- **WHEN** the same in-scope event is dispatched to Consumer 4 twice (e.g. after a retry)
- **THEN** the `(event_id, 'Notification')` idempotency slot collides on the second attempt, the consumer skips its side-effect, and exactly one `notifications` row exists for that event

#### Scenario: Zero-difference cash close produces no notification

- **WHEN** the relay processes a `CashSessionClosed` event whose payload difference is zero
- **THEN** Consumer 4 inserts no `notifications` row and the event is still marked processed

#### Scenario: Projection failure leaves the event for retry without aborting the batch

- **WHEN** `_notification_from_event` raises while processing one event
- **THEN** that event's `processed_at` stays `NULL`, it is retried on the next relay run, and the relay continues processing the remaining events in the batch

### Requirement: Notification-producing outbox events

The change SHALL ensure the five notification-triggering events are emitted into `public.events` in the SAME transaction as their mutation (DEC-20). Producers that already exist SHALL NOT be re-created; those that do not SHALL be added: `StockBelowMinimum` (emitted when a stock movement leaves a product/branch at or below its minimum), `CashSessionClosed` (emitted on cash-session close, carrying the arqueo difference), `FiscalDocumentRejected` (emitted when CAE retrieval is rejected by ARCA), `QuoteAccepted` (emitted on quote acceptance), and `TransferDispatched` (emitted on stock-transfer dispatch, carrying the destination branch). Each emitted event SHALL stamp `account_id`, `event_type`, `aggregate_type`, `aggregate_id`, `payload`, and `occurred_at`, and the payload SHALL carry the fields the Notification consumer needs (e.g. `branch_id`, arqueo `difference`, `destination_branch_id`).

#### Scenario: CashSessionClosed emitted in the close transaction

- **WHEN** a cash-session close mutation commits
- **THEN** a `CashSessionClosed` event row exists in `events` with the account's `account_id`, the session aggregate id, and a payload carrying the arqueo `difference`, written in the same transaction as the close

#### Scenario: TransferDispatched carries the destination branch

- **WHEN** a stock-transfer dispatch mutation commits
- **THEN** a `TransferDispatched` event row exists in `events` whose payload references the destination branch, so the consumer can resolve the audience to that branch

#### Scenario: Producer event rolls back with a failed mutation

- **WHEN** a notification-producing mutation rolls back (e.g. an invariant violation on close)
- **THEN** no corresponding event row remains, because the event INSERT shares the mutation's transaction

## MODIFIED Requirements

### Requirement: Outbox relay dispatch

A relay SHALL periodically select unprocessed events (`processed_at IS NULL`) ordered by `occurred_at`, using `FOR UPDATE SKIP LOCKED` to avoid double-processing under concurrent runs, route each event to the consumers registered for its `event_type`, and set `processed_at = now()` only after all in-scope consumers for that event succeed. The relay SHALL run its consumers in order — AuditLog (1), EmailNotification (2), JournalEntry (3), Notification (4) — each inside the same per-event `BEGIN/EXCEPTION/END` isolation block, so a failure in any one consumer for an event leaves that event unprocessed for retry without aborting the batch. The relay SHALL be scheduled via pg_cron (mirroring the C-27 relay pattern) and SHALL NOT use `service_role`.

#### Scenario: Pending event is dispatched and marked processed

- **WHEN** the relay runs and finds an event with `processed_at IS NULL`
- **THEN** it dispatches the event to every consumer registered for its `event_type` (Consumers 1-4 as applicable), and on success sets `processed_at = now()` for that event

#### Scenario: Concurrent relay runs do not double-process

- **WHEN** two relay invocations overlap on the same pending events
- **THEN** `FOR UPDATE SKIP LOCKED` ensures each pending event is claimed by at most one run, so no consumer side-effect is applied twice

#### Scenario: Consumer failure leaves the event for retry

- **WHEN** a consumer raises while processing an event
- **THEN** `processed_at` for that event stays `NULL` and the event is retried on the next relay run, and the remaining events in the batch continue to be processed

### Requirement: Consumer idempotency

Each consumer SHALL be idempotent, keyed by `(event_id, consumer_type)` reusing the `operation_idempotency` ledger via `INSERT ... ON CONFLICT DO NOTHING` (with `operation_kind = 'event_consumer'`). Processing the same event twice for the same consumer SHALL produce exactly one side-effect (e.g. one `audit_logs` row, one `journal_entries` row, or one `notifications` row).

#### Scenario: Re-processed event does not duplicate the audit row

- **WHEN** the same event is dispatched to the AuditLog consumer twice (e.g. after a retry)
- **THEN** the `(event_id, consumer_type)` idempotency key collides on the second attempt, the consumer skips its side-effect, and `audit_logs` contains exactly one row for that event

#### Scenario: Independent idempotency per consumer

- **WHEN** an event is processed by multiple consumers (e.g. AuditLog and Notification)
- **THEN** each consumer records its own `(event_id, consumer_type)` key, so a retry that re-runs only the failed consumer does not re-fire the ones that already succeeded
