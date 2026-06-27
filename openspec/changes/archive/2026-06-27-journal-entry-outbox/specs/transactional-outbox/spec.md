## ADDED Requirements

### Requirement: JournalEntry consumer (Consumer 3)

The relay `rpc_process_outbox_dispatch` SHALL include a third consumer, JournalEntry, that posts a double-entry accounting record for in-scope events. It SHALL run inside the same per-event `BEGIN/EXCEPTION/END` isolation block as the AuditLog and EmailNotification consumers, after them, so a posting failure for one event does not abort the batch. It SHALL run only for events of type `SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`, or `CreditNoteIssued`, and SHALL be a no-op for all other event types. It SHALL be idempotent, keyed by `(event_id, 'JournalEntry')` in `operation_idempotency` (`INSERT ... ON CONFLICT DO NOTHING`) reinforced by a partial unique index on `journal_entries.source_event_id`. The mapping logic SHALL live in a helper function `_journal_post_from_event(event_row)` (`SECURITY DEFINER`, `SET search_path = public`). The consumer SHALL NOT use `service_role` and SHALL NOT make HTTP/`pg_net` calls.

#### Scenario: In-scope event posts an entry through Consumer 3

- **WHEN** the relay processes a `SaleConfirmed` event that has no existing journal entry
- **THEN** Consumer 3 calls `_journal_post_from_event`, which inserts a balanced `journal_entries` row plus its `journal_lines`, after Consumers 1 and 2 have run for that event

#### Scenario: Out-of-scope event is skipped by Consumer 3

- **WHEN** the relay processes an event whose type is not in `{SaleConfirmed, PurchaseCreated, PaymentReceived, PaymentMade, CreditNoteIssued}`
- **THEN** Consumer 3 does nothing for that event while Consumers 1 and 2 still run normally

#### Scenario: Re-processed event does not post a second entry

- **WHEN** the same in-scope event is dispatched to Consumer 3 twice
- **THEN** the `(event_id, 'JournalEntry')` idempotency slot collides on the second attempt (and/or the `source_event_id` unique index), and exactly one journal entry exists for that event

#### Scenario: Posting failure leaves the event for retry without aborting the batch

- **WHEN** `_journal_post_from_event` raises (e.g. an unbalanced entry, or a `CreditNoteIssued` whose original entry has not posted yet)
- **THEN** the event's `processed_at` stays `NULL`, the event is retried on the next relay run, and the relay continues processing the remaining events in the batch

### Requirement: JournalEntry-producing outbox events

The change SHALL ensure the five V1 journal-posting events are emitted into `public.events` in the same transaction as their mutation. `SaleConfirmed` (C-29), `PaymentReceived` (C-30), and `PaymentMade` (C-30) producers already exist and SHALL NOT be re-created. The change SHALL add a `PurchaseCreated` producer to `rpc_create_purchase_operation` (no live producer exists despite prior spec text) and a `CreditNoteIssued` producer that carries a reference to the original sale/document so the JournalEntry consumer can locate the entry to reverse.

#### Scenario: PurchaseCreated emitted in the purchase transaction

- **WHEN** a purchase-create mutation commits
- **THEN** a `PurchaseCreated` event row exists in `events` with the purchase's `account_id`, `operation_id`, total, and `cost_center_id`, written in the same transaction as the purchase

#### Scenario: CreditNoteIssued carries the original sale reference

- **WHEN** a credit-note mutation commits
- **THEN** a `CreditNoteIssued` event row exists in `events` whose payload references the original sales order / fiscal document, so the reversal consumer can find and reverse the original journal entry
