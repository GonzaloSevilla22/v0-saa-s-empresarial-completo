## ADDED Requirements

### Requirement: Editing a form sale adjusts its accounting trail instead of being blocked

`rpc_atomic_update_sale_operation` regenerates `operation_id` on every edit (reverse the old rows, delete them, apply new rows under a new `operation_id`) and SHALL NOT gain any new rejection guard for having an accounting event or entry (override of 2026-08-20 — see the `operation-edit-context` capability for the guards that remain unchanged). Instead, in the same transaction as the edit, the system SHALL resolve the accounting trail of the operation's old `operation_id` into exactly one of three cases and act accordingly: (1) no event was ever emitted for it — no accounting action is taken; (2) a `SaleOperationCreated` or `SaleOperationAdjusted` event for it is still pending (`processed_at IS NULL`) — the system SHALL lock that event row with `SELECT ... FOR UPDATE` (not `SKIP LOCKED`, so the edit waits for the relay's batch transaction rather than racing it), SHALL re-check `processed_at` after acquiring the lock in case the relay finished while the edit waited, and, only if still pending, SHALL update that event's payload and aggregate reference in place to the new operation's values rather than emitting a second event; (3) a `journal_entries` row for it is already `posted` — the system SHALL emit a new `SaleOperationAdjusted` event carrying both the old and the new `operation_id`, as a plain `INSERT` with no exception handler for the same reason the original producer has none (D6): swallowing the failure would silently reproduce the defect this change fixes.

#### Scenario: Editing before the relay processes replaces the pending event in place

- **WHEN** a form sale is edited while its `SaleOperationCreated` event is still `processed_at IS NULL`
- **THEN** no second event is inserted; the existing event's `aggregate_id` and payload are updated to the edited operation's values, and once the relay processes it exactly one journal entry exists, referencing the new `operation_id`

#### Scenario: Editing after the relay processes emits an adjustment event

- **WHEN** a form sale is edited after its entry has been posted
- **THEN** a `SaleOperationAdjusted` event is inserted in the same transaction as the edit, carrying `old_operation_id` (the entry to reverse) and `new_operation_id` (the entry to create), and no existing event is mutated

#### Scenario: A concurrent relay run does not race the in-place replace

- **WHEN** an edit tries to lock a pending event for in-place replacement at the same moment the relay's batch transaction already holds that row
- **THEN** the edit waits for the relay's transaction to finish rather than proceeding against a stale lock, and re-checks whether the event is still pending before deciding between in-place replacement and emitting an adjustment event

#### Scenario: A chained edit before the relay processes collapses into one adjustment event

- **WHEN** an already-adjusted-but-still-pending operation (its `SaleOperationAdjusted` event not yet processed) is edited again
- **THEN** that pending event's target operation and edited values are updated in place, its original `old_operation_id` (the entry to reverse) is preserved unchanged, and no additional event is inserted for the second edit

## MODIFIED Requirements

### Requirement: JournalEntry consumer (Consumer 3)

The relay `rpc_process_outbox_dispatch` SHALL include a third consumer, JournalEntry, that posts a double-entry accounting record for in-scope events. It SHALL run inside the same per-event `BEGIN/EXCEPTION/END` isolation block as the AuditLog and EmailNotification consumers, after them, so a posting failure for one event does not abort the batch. It SHALL run only for events of type `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, or `CreditNoteIssued`, and SHALL be a no-op for all other event types. The relay's dispatch filter and the helper's own filter SHALL list the same set of types, so an event type added to one and not the other cannot silently stop posting. It SHALL be idempotent, keyed by `(event_id, 'JournalEntry')` in `operation_idempotency` (`INSERT ... ON CONFLICT DO NOTHING`) reinforced by a partial unique index on `journal_entries.source_event_id`. The mapping logic SHALL live in a helper function `_journal_post_from_event(event_row)` (`SECURITY DEFINER`, `SET search_path = public`). The consumer SHALL NOT use `service_role` and SHALL NOT make HTTP/`pg_net` calls.

#### Scenario: In-scope event posts an entry through Consumer 3

- **WHEN** the relay processes a `SaleConfirmed` event that has no existing journal entry
- **THEN** Consumer 3 calls `_journal_post_from_event`, which inserts a balanced `journal_entries` row plus its `journal_lines`, after Consumers 1 and 2 have run for that event

#### Scenario: Out-of-scope event is skipped by Consumer 3

- **WHEN** the relay processes an event whose type is not in `{SaleConfirmed, PurchaseCreated, SaleOperationCreated, SaleOperationAdjusted, PaymentReceived, PaymentMade, CreditNoteIssued}`
- **THEN** Consumer 3 does nothing for that event while Consumers 1 and 2 still run normally

#### Scenario: The form-sale event reaches the consumer through both filters

- **WHEN** the relay processes a `SaleOperationCreated` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and an entry is posted

#### Scenario: The form-sale adjustment event reaches the consumer through both filters

- **WHEN** the relay processes a `SaleOperationAdjusted` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and the contra-entry/new-entry pair is posted

#### Scenario: Re-processed event does not post a second entry

- **WHEN** the same in-scope event is dispatched to Consumer 3 twice
- **THEN** the `(event_id, 'JournalEntry')` idempotency slot collides on the second attempt (and/or the `source_event_id` unique index), and exactly one journal entry exists for that event

#### Scenario: Posting failure leaves the event for retry without aborting the batch

- **WHEN** `_journal_post_from_event` raises (e.g. an unbalanced entry, or a `CreditNoteIssued` whose original entry has not posted yet)
- **THEN** the event's `processed_at` stays `NULL`, the event is retried on the next relay run, and the relay continues processing the remaining events in the batch

### Requirement: JournalEntry-producing outbox events

The change SHALL ensure the journal-posting events are emitted into `public.events` in the same transaction as their mutation. `SaleConfirmed` (C-29), `PurchaseCreated`, `PaymentReceived` (C-30), `PaymentMade` (C-30) and `CreditNoteIssued` producers already exist and SHALL NOT be re-created. The change SHALL add a `SaleOperationCreated` producer to `rpc_create_sale_operation_v2`, the live path of the sale form, which until now emitted no event at all and therefore produced no accounting entry for the majority of the application's sales. The producer SHALL emit the event after the cash, current-account and bank effects of the same transaction, SHALL stamp `aggregate_type = 'SaleOperation'` and `aggregate_id = operation_id`, and SHALL carry `account_id`, `operation_id`, the canonical `total`, the sale date used as the accounting date, the client reference, and the payment-method `kind` derived server-side from the imputed payment method. The emitted `payment_method` SHALL be the raw derived `kind`, with no `COALESCE` to a default: the payload SHALL report what happened, and any presumption for an unimputed method SHALL live in the consumer branch, because emitting a fixed literal misstates every operation that was in fact settled otherwise. The producer SHALL be a plain `INSERT` with no exception handler: swallowing a failed event insert while the sale commits would reproduce, silently and irrecoverably, the very defect this producer exists to fix.

#### Scenario: SaleOperationCreated emitted in the sale transaction

- **WHEN** a sale-create mutation from the sale form commits
- **THEN** a `SaleOperationCreated` event row exists in `events` with the sale's `account_id`, `operation_id`, canonical total and sale date, written in the same transaction as the sale lines and the stock movements

#### Scenario: Event rolls back with a failed sale

- **WHEN** a sale-create mutation rolls back (e.g. insufficient stock, or a credit sale without a client)
- **THEN** no `SaleOperationCreated` event row remains, because the event `INSERT` shares the mutation's transaction

#### Scenario: The payload reports the real payment method, including its absence

- **WHEN** a sale is registered from the form with no payment method imputed
- **THEN** the emitted payload carries a null `payment_method` rather than a defaulted literal, and the consumer branch is what decides the resulting account

#### Scenario: A POS sale still emits only SaleConfirmed

- **WHEN** a sale is confirmed through the POS path
- **THEN** exactly one `SaleConfirmed` event is emitted for it and no `SaleOperationCreated` event, so the two paths never double-post an entry for the same sale

#### Scenario: PurchaseCreated emitted in the purchase transaction

- **WHEN** a purchase-create mutation commits
- **THEN** a `PurchaseCreated` event row exists in `events` with the purchase's `account_id`, `operation_id`, total, and `cost_center_id`, written in the same transaction as the purchase

#### Scenario: CreditNoteIssued carries the original sale reference

- **WHEN** a credit-note mutation commits
- **THEN** a `CreditNoteIssued` event row exists in `events` whose payload references the original sales order / fiscal document, so the reversal consumer can find and reverse the original journal entry
