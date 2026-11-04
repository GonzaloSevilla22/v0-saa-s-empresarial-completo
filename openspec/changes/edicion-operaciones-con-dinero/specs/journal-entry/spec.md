## MODIFIED Requirements

### Requirement: CreditNoteIssued reverses the original entry

On a `CreditNoteIssued` event the system SHALL post a mirror (reversal) entry. It SHALL locate the currently-valid original entry by trying the two sale conventions in order: first `source_doc_type='SalesOrder'` with `source_doc_ref` equal to the original sales order (from `source_sales_order_id` in the payload); then, when none is found, `source_doc_type='SaleOperation'` with `source_doc_ref` equal to that order's `sale_operation_id`. The second convention covers a form sale that was promoted to an order, and a POS sale whose entry was replaced by an edit. Both lookups SHALL require `status='posted'` and `reversal_of IS NULL`, and SHALL be scoped to the event's account.

It SHALL create a new entry whose lines invert each original line's `side` (debit↔credit), with `reversal_of` set to the original entry id and `status='posted'`, and mark the original entry `status='reversed'`. The mirror entry SHALL also balance. If no original entry can be found under either convention, the posting function SHALL raise so the event is retried.

#### Scenario: Credit note mirrors and marks the original

- **WHEN** a `CreditNoteIssued` event referencing an existing posted sale entry is processed
- **THEN** a new entry is created with inverted debit/credit lines and `reversal_of` pointing to the original, the original entry's `status` becomes `'reversed'`, and the mirror entry balances

#### Scenario: Credit note before the original entry exists

- **WHEN** a `CreditNoteIssued` event is processed but no posted entry exists yet for the referenced sale under either convention
- **THEN** the posting function raises, the credit-note event stays unprocessed (`processed_at IS NULL`), and it is retried on a later relay run (after the original entry posts)

#### Scenario: Credit note on a sale whose entry is a SaleOperation entry

- **GIVEN** a POS sale whose `SalesOrder` entry was replaced by a `SaleOperation` entry through an edit, and that was later invoiced and authorized
- **WHEN** a `CreditNoteIssued` event for its order is processed
- **THEN** the consumer resolves the `SaleOperation` entry through the order's `sale_operation_id` and reverses it, instead of retrying forever

### Requirement: SaleOperationAdjusted posts a contra-entry and a new entry

On a `SaleOperationAdjusted` event the system SHALL post two `journal_entries` rows:

- a **contra-entry** that exactly reverses the currently-valid entry of the operation, mirroring the copy-with-flipped-sides technique the `CreditNoteIssued` branch already uses;
- a **new entry**, computed from `payload.new_operation_id` and the edited values, using the same account routing as `SaleOperationCreated`. The debit-account decision SHALL be read from one shared mapping so the two branches cannot diverge.

The currently-valid entry SHALL be resolved by trying the two sale conventions in order, both requiring `status='posted'` and `reversal_of IS NULL` and scoped to the event's account:

1. `source_doc_type='SaleOperation'` and `source_doc_ref = payload.old_operation_id`;
2. when none is found and the payload carries a `sales_order_id`, `source_doc_type='SalesOrder'` and `source_doc_ref = payload.sales_order_id` (a sale born in the POS or converted from a quote).

Because an edit keeps the operation's identifier, `old_operation_id` and `new_operation_id` are normally equal, and the contra-entry of a previous adjustment shares its reference with the entry it reversed. The `reversal_of IS NULL` filter is what keeps the lookup from selecting a contra-entry.

The new entry SHALL be a `SaleOperation` entry on `new_operation_id`. The system SHALL mark the reversed entry's `status` as `'reversed'`. Because the partial unique index on `journal_entries.source_event_id` allows at most one entry per source event, the system SHALL stamp `source_event_id` on the new entry only, leaving the contra-entry's `source_event_id` null.

The contra-entry SHALL carry `reversal_of` pointing at the entry it reverses and `posted_at` at the processing instant, following the same dating convention `CreditNoteIssued` already uses for its own reversal. If no currently-valid entry is found under either convention, the system SHALL raise for retry using the same `P0451` code `CreditNoteIssued` already uses for a missing original entry, rather than introducing a new error code. Each of the two entries SHALL independently satisfy the Σdébito=Σcrédito balance assertion.

#### Scenario: An edit after posting produces a contra-entry and a new entry

- **WHEN** a `SaleOperationAdjusted` event is processed whose operation has a posted entry of 15000 debiting `1100 Caja`, and whose new values total 9000 with `payment_method='transfer'`
- **THEN** the original entry is marked `status='reversed'`, a contra-entry balances with credit `1100 Caja` = 15000 and debit `4100 Ventas` = 15000, a new entry balances with debit `1110 Banco` = 9000 and credit `4100 Ventas` = 9000, and — reading the original, the contra-entry and the new entry together as the operation's full lineage — the net `4100 Ventas` balance they leave is a credit of 9000, the new total and not the old one

#### Scenario: The pair is fully traceable

- **WHEN** a `SaleOperationAdjusted` event is processed
- **THEN** the contra-entry's `reversal_of` points at the entry it reverses, and the new entry's `source_doc_ref` names the operation, so the lineage is reconstructible from `journal_entries` alone

#### Scenario: A chained edit reverses the currently-valid entry, not the original

- **WHEN** an already-adjusted operation is edited again, producing a second `SaleOperationAdjusted` event for the same operation identifier
- **THEN** the second adjustment's contra-entry reverses the entry the FIRST adjustment created, not the first adjustment's contra-entry nor the original entry (both of which share the reference), and after both adjustments exactly one non-contra entry for that operation has `status='posted'`

#### Scenario: An edit of a POS sale adjusts its SalesOrder entry

- **GIVEN** a POS sale whose `SaleConfirmed` entry is posted under `source_doc_type='SalesOrder'`
- **WHEN** a `SaleOperationAdjusted` event carrying its `sales_order_id` is processed
- **THEN** the `SalesOrder` entry is reversed by a contra-entry and marked `reversed`, and a new `SaleOperation` entry is posted for the operation with the edited values

#### Scenario: A missing original entry retries instead of failing the batch

- **WHEN** a `SaleOperationAdjusted` event is processed and no currently-valid entry exists under either convention
- **THEN** the branch raises with `P0451`, `processed_at` stays `NULL` for retry, and the relay continues with the rest of the batch

### Requirement: Out-of-scope events do not post entries

The JournalEntry posting SHALL run only for the event types `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PurchaseAdjusted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, `ExpenseCreated`, `ExpenseAdjusted`, and `ExpenseDeleted` — the fifteen canonical types (see `transactional-outbox`, "El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate"). Events of other types (`CashSessionClosed`, `StockAdjusted`, `SupplierAccountCharged`, `CustomerAccountCharged`, and any other) SHALL NOT produce a journal entry in this version.

The expense event types SHALL be named `ExpenseCreated`, `ExpenseAdjusted` and `ExpenseDeleted`. The name `ExpenseRegistered`, listed in earlier versions of this requirement as an example of a deferred type, SHALL NOT be used: no producer ever emitted it, and the expense trail is served by the three types above.

#### Scenario: Deferred event type is ignored

- **WHEN** the relay processes an event of type `StockAdjusted` or `CashSessionClosed`
- **THEN** the JournalEntry consumer does nothing for that event and no `journal_entries` row is created

#### Scenario: The form-sale event is in scope

- **WHEN** the relay processes a `SaleOperationCreated` event
- **THEN** the JournalEntry consumer posts an entry for it instead of treating it as out of scope

#### Scenario: The form-sale adjustment event is in scope

- **WHEN** the relay processes a `SaleOperationAdjusted` event
- **THEN** the JournalEntry consumer posts the contra-entry/new-entry pair for it instead of treating it as out of scope

#### Scenario: The purchase adjustment event is in scope

- **WHEN** the relay processes a `PurchaseAdjusted` event
- **THEN** the JournalEntry consumer posts the contra-entry/new-entry pair for it instead of treating it as out of scope

#### Scenario: The expense events are in scope

- **WHEN** the relay processes an `ExpenseCreated`, `ExpenseAdjusted` or `ExpenseDeleted` event
- **THEN** the JournalEntry consumer posts the corresponding entry, contra-entry/new-entry pair, or contra-entry, instead of treating it as out of scope

## ADDED Requirements

### Requirement: PurchaseAdjusted posts a contra-entry and a new entry

On a `PurchaseAdjusted` event the system SHALL post two `journal_entries` rows:

- a **contra-entry** that exactly reverses the currently-valid `Purchase` entry of the operation, with the same flipped-sides copy that `PurchaseDeleted` uses, preserving each line's `cost_center_id`;
- a **new `Purchase` entry** on `payload.new_operation_id`, computed from the edited values carried in the payload (total, `payment_method` kind, `cost_center_id`, IVA breakdown when present), using the same account mapping as `PurchaseCreated`. The mapping SHALL be shared so the two branches cannot diverge.

The currently-valid entry SHALL be resolved by `source_doc_type='Purchase'`, `source_doc_ref = payload.old_operation_id`, `status='posted'` and `reversal_of IS NULL`, scoped to the event's account. The payload mirrors the shape of `SaleOperationAdjusted`: once the edit keeps the operation's identifier, `old_operation_id` and `new_operation_id` are equal.

The original entry SHALL be marked `reversed`. Only the new entry SHALL carry `source_event_id`. The contra-entry SHALL be dated at the processing instant, and the new entry at the purchase's business date. A missing currently-valid entry SHALL raise `P0451` for retry. Each entry SHALL balance on its own, failing with `P0450` otherwise.

#### Scenario: Editing a posted cash purchase

- **GIVEN** a purchase whose `Purchase` entry debits `5100` and credits `1100 Caja` for 4000
- **WHEN** a `PurchaseAdjusted` event with total 4500 and `payment_method='cash'` is processed
- **THEN** the original entry is marked `reversed`, a contra-entry credits `5100` and debits `1100` for 4000, and a new entry debits `5100` and credits `1100` for 4500, all balanced

#### Scenario: Changing a purchase from cash to credit

- **WHEN** a `PurchaseAdjusted` event moves a posted cash purchase to `payment_method='credit'`
- **THEN** the new entry credits `2100 Proveedores` instead of `1100 Caja`

#### Scenario: Adjustment processed before the creation entry

- **GIVEN** a `PurchaseAdjusted` event whose `PurchaseCreated` has not been processed yet
- **WHEN** the relay processes the adjustment first
- **THEN** it fails with `P0451`, stays pending, and posts correctly on a later run after the creation entry exists

### Requirement: El asiento vigente de un documento excluye los contra-asientos

Toda rama del consumidor contable que busque el asiento vigente de un documento para revertirlo SHALL filtrar `status = 'posted'` **y** `reversal_of IS NULL`, ordenando por `posted_at` y `created_at` descendentes. Las ramas alcanzadas son `SaleOperationAdjusted`, `SaleOperationDeleted`, `PurchaseAdjusted`, `PurchaseDeleted`, `CreditNoteIssued`, `ExpenseAdjusted` y `ExpenseDeleted`. Con identificadores de operación estables, el contra-asiento de una corrección anterior comparte referencia con el asiento vigente, y sin el filtro la búsqueda podría revertir un contra-asiento.

#### Scenario: Borrar una venta editada revierte el asiento vigente
- **GIVEN** una venta del formulario editada una vez después de asentada, con su asiento original revertido, su contra-asiento y su asiento nuevo, los tres con la misma referencia
- **WHEN** se procesa su `SaleOperationDeleted`
- **THEN** el contra-asiento del borrado revierte el asiento nuevo y no el contra-asiento de la edición
