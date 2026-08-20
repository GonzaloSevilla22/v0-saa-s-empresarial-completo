## ADDED Requirements

### Requirement: SaleOperationCreated posts a form-sale entry

On a `SaleOperationCreated` event the system SHALL post one entry whose `source_doc_type` is `'SaleOperation'` and whose `source_doc_ref` is the sale `operation_id`, mirroring the operation-level shape already used by `PurchaseCreated` and deliberately distinct from the `'SalesOrder'` key space so the two sale populations stay separable. The debit side SHALL be routed by the `payment_method` carried in the payload, using the same vocabulary as `SaleConfirmed`: `1300 Deudores por Ventas` for the total when the method is `credit`; `1110 Banco` for the total when the method is bank-settled (`transfer`, `card`, `check`, `wallet`); `1100 Caja` for the total when the method is `cash` or `other`. When **no payment method is imputed** the debit side SHALL be `1100 Caja`, and SHALL NOT be `1300 Deudores por Ventas`: with no imputed method the creating transaction posts no `customer_account_movements` charge, so debiting receivables would create a balance that no subledger backs and that the customer-account surface would immediately contradict. This is the one point where the sale branch deliberately diverges from the `PurchaseCreated` default of `credit`, because a purchase with no imputed method still names an identifiable creditor (`purchases.supplier_id`) while a sale with no imputed method has no matching party charge. The credit side SHALL be a single `4100 Ventas` line for the total, without discriminating IVA, because a sale born in the sale form has no `sales_order` and therefore can have no `fiscal_document_id` to read `neto`/`iva_amount` from — this is the same treatment the consumer already applies to a sale without a fiscal document and to every purchase posted to date. All lines SHALL carry `cost_center_id = NULL`, because `sales` has no cost-center column.

#### Scenario: Sale with no imputed payment method debits cash

- **WHEN** a `SaleOperationCreated` event with `payment_method` absent or null is posted for a form sale of 15000
- **THEN** the entry has debit `1100 Caja` = 15000 and a single credit `4100 Ventas` = 15000, it balances, and no `1300 Deudores por Ventas` line is created

#### Scenario: Credit sale from the form debits receivables

- **WHEN** a `SaleOperationCreated` event with `payment_method='credit'` is posted for a form sale of 700
- **THEN** the entry has debit `1300 Deudores por Ventas` = 700 and credit `4100 Ventas` = 700, matching the `customer_account_movements` charge the same transaction posted

#### Scenario: Bank-settled sale from the form debits the bank account

- **WHEN** a `SaleOperationCreated` event with `payment_method='transfer'` (or `card`, `check`, `wallet`) is posted for a form sale of 9000
- **THEN** the entry has debit `1110 Banco` = 9000 and credit `4100 Ventas` = 9000, and it balances

#### Scenario: The entry references the operation, not a sales order

- **WHEN** any `SaleOperationCreated` event is posted
- **THEN** the entry carries `source_doc_type='SaleOperation'` and `source_doc_ref = operation_id`, and no row in `sales_orders` is created, read or referenced for it

#### Scenario: Revenue is never split into IVA for a form sale

- **WHEN** a `SaleOperationCreated` event is posted for an account that issues Factura A
- **THEN** the credit side is still a single `4100 Ventas` line for the total and no `4200 IVA Débito Fiscal` line is created, because the operation carries no fiscal document from which a discriminated IVA amount could be read

### Requirement: The form-sale entry is dated by the sale, not by the relay run

The `SaleOperationCreated` branch SHALL set `posted_at` from the sale's own date carried in the event payload, resolved in the project's reporting timezone, and SHALL fall back to the processing instant only when the payload carries no date. The date SHALL be anchored to midday of the local day before conversion, so that no offset shift can move the entry to an adjacent day, and the timezone SHALL be taken from the same definition that `public.reporting_local_today()` uses rather than from a second hardcoded literal. This SHALL apply to the `SaleOperationCreated` branch only; the five pre-existing branches keep posting at the relay instant and SHALL NOT be changed by this requirement.

#### Scenario: A back-dated sale posts to its own month

- **WHEN** a sale dated the 28th of the previous month is registered from the form today and its event is processed today
- **THEN** the resulting entry's `posted_at` falls on the 28th of the previous month in the reporting timezone, not on today

#### Scenario: A same-day sale posts to today

- **WHEN** a sale dated today is registered and processed within the minute
- **THEN** the entry's `posted_at` falls on today in the reporting timezone

#### Scenario: The existing branches keep their behaviour

- **WHEN** a `SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade` or `CreditNoteIssued` event is processed
- **THEN** its entry is still posted at the relay run instant, unchanged by this requirement

### Requirement: SaleOperationAdjusted posts a contra-entry and a new entry

On a `SaleOperationAdjusted` event the system SHALL post two `journal_entries` rows: a contra-entry that exactly reverses the currently-valid entry identified by `source_doc_type='SaleOperation'`, `source_doc_ref = payload.old_operation_id` and `status='posted'` (mirroring the copy-with-flipped-sides technique the `CreditNoteIssued` branch already uses), and a new entry computed from `payload.new_operation_id` and the edited values using the same account routing as `SaleOperationCreated` (the debit-account decision SHALL be read from one shared mapping so the two branches cannot diverge). The system SHALL mark the reversed entry's `status` as `'reversed'`. Because the partial unique index on `journal_entries.source_event_id` allows at most one entry per source event, the system SHALL stamp `source_event_id` on the new entry only, leaving the contra-entry's `source_event_id` null. The contra-entry SHALL carry `reversal_of` pointing at the entry it reverses and `posted_at` at the processing instant, following the same dating convention `CreditNoteIssued` already uses for its own reversal. If no currently-valid entry is found for `payload.old_operation_id`, the system SHALL raise for retry using the same `P0451` code `CreditNoteIssued` already uses for a missing original entry, rather than introducing a new error code. Each of the two entries SHALL independently satisfy the Σdébito=Σcrédito balance assertion.

#### Scenario: An edit after posting produces a contra-entry and a new entry

- **WHEN** a `SaleOperationAdjusted` event is processed whose `old_operation_id` names an operation with a posted entry of 15000 debiting `1100 Caja`, and whose new values total 9000 with `payment_method='transfer'`
- **THEN** the original entry is marked `status='reversed'`, a contra-entry balances with credit `1100 Caja` = 15000 and debit `4100 Ventas` = 15000, a new entry balances with debit `1110 Banco` = 9000 and credit `4100 Ventas` = 9000, and — reading the original, the contra-entry and the new entry together as the operation's full lineage — the net `4100 Ventas` balance they leave is a credit of 9000 (the original's credit and the contra-entry's debit cancel exactly, leaving only the new entry's credit), the new total and not the old one

#### Scenario: The pair is fully traceable

- **WHEN** a `SaleOperationAdjusted` event is processed
- **THEN** the contra-entry's `reversal_of` points at the original entry and its `source_doc_ref` still names `old_operation_id`, while the new entry's `source_doc_ref` names `new_operation_id`, so `old_operation_id → reversal_of → new_operation_id` is reconstructible from `journal_entries` alone

#### Scenario: A chained edit reverses the currently-valid entry, not the original

- **WHEN** an already-adjusted operation (whose first adjustment already posted a contra-entry and a new entry) is edited again, producing a second `SaleOperationAdjusted` event whose `old_operation_id` names the operation the first adjustment's new entry left in place
- **THEN** the second adjustment's contra-entry reverses the entry the FIRST adjustment created (the currently-valid one, `status='posted'`), not the entry from the original `SaleOperationCreated` (already `status='reversed'` since the first adjustment), and after both adjustments exactly one entry for that operation lineage has `status='posted'`

#### Scenario: A missing original entry retries instead of failing the batch

- **WHEN** a `SaleOperationAdjusted` event is processed and no `posted` entry exists for its `old_operation_id`
- **THEN** the branch raises with `P0451`, `processed_at` stays `NULL` for retry, and the relay continues with the rest of the batch

### Requirement: Historical operations are regularised through the real consumer

Backfilling accounting entries for operations that predate their producer SHALL be done by emitting the corresponding domain events into `public.events` and letting the production relay consumer post them, and SHALL NOT be done by inserting into `journal_entries`/`journal_lines` directly, so that a single definition of how an operation is posted exists. Backfill events SHALL carry `source = 'backfill'` in their payload so the batch is identifiable and reversible, SHALL carry the operation's own date as the accounting date, and SHALL be emitted only for operations that have no event of that type yet, so re-running the backfill is a no-op. The backfill SHALL be gated on explicit product-owner sign-off with the expected counts stated in advance, because it writes accounting records against live user data; the backfilled operations remain editable exactly like any other operation with a posted entry (override of 2026-08-20 — see the `operation-edit-context` capability), an edit after backfill simply produces a `SaleOperationAdjusted` contra-entry/new-entry pair like any other post-processed edit.

#### Scenario: Backfilled sale operations post through the same branch as live ones

- **WHEN** the sale backfill is run for form operations that have no `SaleOperationCreated` event
- **THEN** one event per operation is inserted with `source='backfill'` and the sale's own date, the relay posts one balanced entry per event through the same branch that serves live sales, and no direct insert into `journal_entries` occurs

#### Scenario: Re-running the backfill posts nothing new

- **WHEN** the backfill statement is executed a second time
- **THEN** no additional events are inserted because every target operation already has one, and no additional entries are posted

#### Scenario: Historical purchases are regularised by the existing branch

- **WHEN** the purchase backfill is run for operations created before the `PurchaseCreated` producer existed
- **THEN** one `PurchaseCreated` event per operation is emitted and the existing purchase branch posts the entries, with no new consumer code involved

## MODIFIED Requirements

### Requirement: Out-of-scope events do not post entries

The JournalEntry posting SHALL run only for the event types `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, and `CreditNoteIssued`. Events of other types (`ExpenseRegistered`, `CashSessionClosed`, `StockAdjusted`, `SupplierAccountCharged`, `CustomerAccountCharged`, and any other) SHALL NOT produce a journal entry in this version.

#### Scenario: Deferred event type is ignored

- **WHEN** the relay processes an event of type `StockAdjusted` or `CashSessionClosed`
- **THEN** the JournalEntry consumer does nothing for that event and no `journal_entries` row is created

#### Scenario: The form-sale event is in scope

- **WHEN** the relay processes a `SaleOperationCreated` event
- **THEN** the JournalEntry consumer posts an entry for it instead of treating it as out of scope

#### Scenario: The form-sale adjustment event is in scope

- **WHEN** the relay processes a `SaleOperationAdjusted` event
- **THEN** the JournalEntry consumer posts the contra-entry/new-entry pair for it instead of treating it as out of scope
