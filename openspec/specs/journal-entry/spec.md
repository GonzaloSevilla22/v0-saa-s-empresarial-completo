# journal-entry Specification

## Purpose
Journal de partida doble (`journal_entries`/`journal_lines`) posteado asincrónicamente por el Consumer 3 del outbox a partir de eventos de dominio (`SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`). Entregado en `journal-entry-outbox` (V2.5, 2026-06-27). Extendido en `bank-payment-routing` (V2.5 C2, 2026-07-02): la contrapartida de venta/cobro/pago por método bancario rutea a `1110 Banco` en vez de `1100 Caja`, leyendo `payment_method` del payload del evento.
## Requirements
### Requirement: Double-entry journal schema

The system SHALL persist accounting entries in two tables: `public.journal_entries` (entry header) and `public.journal_lines` (debit/credit lines). `journal_entries` SHALL carry `id uuid PK`, `account_id uuid NOT NULL` (tenant key), `posted_at timestamptz`, `source_event_id uuid` referencing `public.events`, `source_doc_type text`, `source_doc_ref uuid`, `status text CHECK (status IN ('posted','reversed'))`, `reversal_of uuid` (self-reference, nullable), and `created_at timestamptz`. `journal_lines` SHALL carry `id uuid PK`, `entry_id uuid NOT NULL` referencing `journal_entries` `ON DELETE CASCADE`, `account_id uuid NOT NULL` (denormalized from the parent entry for RLS), `account_code text NOT NULL`, `cost_center_id uuid` (nullable, referencing `cost_centers` `ON DELETE SET NULL`), `side text CHECK (side IN ('debit','credit'))`, `amount numeric(14,2) CHECK (amount > 0)`, and `line_no int`. Account codes SHALL be drawn from a fixed hardcoded chart of ~10 Argentine codes (`1100` Caja, `1110` Banco, `1300` Deudores por Ventas, `2100` Proveedores, `4100` Ventas, `4200` IVA Débito Fiscal, `5100` CMV/Compras, `5200` IVA Crédito Fiscal, `5300` Gastos reservado); there SHALL NOT be a chart-of-accounts FK table in this version.

#### Scenario: Entry and lines tables exist with the required shape

- **WHEN** the migration completes
- **THEN** `journal_entries` and `journal_lines` exist with the columns and CHECK constraints above, `journal_lines.entry_id` cascades on delete, and `journal_lines.cost_center_id` sets null when its `cost_centers` row is deleted

#### Scenario: account_code stored as free text without an FK table

- **WHEN** a journal line is posted for account `4100`
- **THEN** the `account_code` value `'4100'` is stored as text on `journal_lines` with no foreign key to a chart-of-accounts table, so a future FK migration can reference it as the natural key without rewriting historical rows

### Requirement: Balanced entry invariant

Every posted journal entry SHALL satisfy `SUM(amount WHERE side='debit') = SUM(amount WHERE side='credit')`. The invariant SHALL be enforced by an ASSERT (or explicit `RAISE EXCEPTION ... USING ERRCODE`) inside the posting function, not by a table `CHECK` constraint (a Postgres `CHECK` cannot evaluate cross-row aggregates). When the balance check fails, the posting function SHALL raise, leaving the source event unprocessed for retry, and SHALL NOT abort the rest of the batch.

#### Scenario: Balanced entry is posted

- **WHEN** the posting function computes lines whose debit total equals the credit total
- **THEN** the entry and its lines are inserted and the entry's `status` is `'posted'`

#### Scenario: Unbalanced entry is rejected and retried

- **WHEN** the posting function computes lines whose debit total does not equal the credit total
- **THEN** it raises an exception, no `journal_entries`/`journal_lines` rows for that event are committed, the source event keeps `processed_at IS NULL` for retry, and the batch continues with the next event

### Requirement: Idempotent posting by source event

Each source event SHALL produce at most one journal entry. `journal_entries` SHALL enforce idempotency via a partial unique index on `source_event_id` `WHERE source_event_id IS NOT NULL`, mirroring the C-25 `(event_id, consumer_type)` style. Re-processing the same event SHALL NOT create a second entry.

#### Scenario: Re-processed event does not duplicate the entry

- **WHEN** the same outbox event is dispatched to the JournalEntry consumer twice
- **THEN** the second attempt collides on the `source_event_id` unique index (or on the `(event_id, 'JournalEntry')` idempotency slot) and no second `journal_entries` row is created

### Requirement: SaleConfirmed posts a sale entry

On a `SaleConfirmed` event the system SHALL post one entry. The debit side SHALL be `1300 Deudores por Ventas` for the total when `payment_method` is `credit`; otherwise the debit side SHALL be the **bank/cash account routed by the sale's payment method**: `1110 Banco` for the total when `payment_method` denotes a bank-settled method (`transfer`, `card`, `check` or `wallet` per the PO-approved sales taxonomy), or `1100 Caja` for the total when `payment_method` is cash (and, until the PO decides otherwise, when `payment_method` is `other`). A digital wallet SHALL route to `1110 Banco` rather than `1100 Caja` because its proceeds never enter the physical cash drawer and settle through a processor account that is reconciled like a bank account. The credit side SHALL be `4100 Ventas` for the net plus `4200 IVA Débito Fiscal` for the IVA amount when the linked fiscal document is Factura A/B with discriminated IVA (`comprobante_type IN ('factura_a','factura_b')` AND `neto`/`iva_amount` present), or a single `4100 Ventas` line for the total when the sale is Factura C, has no fiscal document, or has no IVA breakdown. The net/IVA breakdown SHALL be obtained by joining `sales_orders.fiscal_document_id` to `fiscal_documents`. Revenue lines SHALL have `cost_center_id = NULL`. The bank-vs-cash routing SHALL be driven by the `payment_method` value carried in the `SaleConfirmed` payload.

#### Scenario: Cash sale, monotributista (Factura C), single revenue line

- **WHEN** a `SaleConfirmed` event with `payment_method='cash'` is posted for a sale whose fiscal document is `factura_c` (no IVA breakdown)
- **THEN** the entry has debit `1100 Caja` = total and a single credit `4100 Ventas` = total, and it balances

#### Scenario: Wallet sale routes to the bank account

- **WHEN** a `SaleConfirmed` event with `payment_method='wallet'` is posted for a sale of 9000 with no IVA breakdown
- **THEN** the entry has debit `1110 Banco` = 9000 and credit `4100 Ventas` = 9000, and it balances

#### Scenario: Credit sale routes to receivables

- **WHEN** a `SaleConfirmed` event with `payment_method='credit'` is posted for a sale of 9000 with no IVA breakdown
- **THEN** the entry has debit `1300 Deudores por Ventas` = 9000 and credit `4100 Ventas` = 9000, and it balances

### Requirement: PurchaseCreated posts a purchase entry

On a `PurchaseCreated` event the system SHALL post one entry. The debit side SHALL be `5100 CMV/Compras` for the net (with `cost_center_id` taken from the purchase) plus `5200 IVA Crédito Fiscal` for the IVA amount when the purchase has discriminated IVA, or a single `5100 CMV/Compras` line for the total when there is no IVA breakdown. The credit side SHALL be `1100 Caja` for the total when the payment method is cash, and `2100 Proveedores` for the total for every other payment method (`transfer`, `card`, `check`, `wallet`, `credit`, `other`) or when no payment method is imputed — the credit side routing SHALL NOT distinguish bank-settled methods from `credit`: unlike the sale-side consumer, the purchase-side consumer has no bank/cash predicate to extend, because a purchase paid by a bank-settled method still creates a liability to the supplier until reconciled, the same as an explicit `credit` purchase. The producer SHALL emit the payment method derived server-side from the imputed payment method of the purchase, and SHALL NOT emit a fixed literal: emitting `credit` unconditionally misstated every purchase that was in fact paid at the time, even though it happened to route to the correct account by coincidence (both `credit` and every non-cash method credit `2100 Proveedores`). The `cost_center_id` SHALL be resolved from the event payload, or by lookup to `purchases` (all lines of the operation share the same cost center). IVA crédito fiscal lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash purchase without IVA breakdown

- **WHEN** a `PurchaseCreated` cash event is posted with no IVA breakdown
- **THEN** the entry has debit `5100 CMV/Compras` = total (carrying the purchase's `cost_center_id`) and credit `1100 Caja` = total, and it balances

#### Scenario: Credit purchase with discriminated IVA

- **WHEN** a `PurchaseCreated` credit event is posted with `neto` and `iva_amount` set
- **THEN** the entry has debit `5100 CMV/Compras` = neto (with `cost_center_id`) plus debit `5200 IVA Crédito Fiscal` = iva_amount (with `cost_center_id = NULL`) and credit `2100 Proveedores` = total, and it balances

#### Scenario: The producer carries the real payment method, even though the posted account does not change

- **WHEN** a purchase is registered imputed to a payment method of `kind = 'transfer'`
- **THEN** the emitted `PurchaseCreated` payload carries `payment_method = 'transfer'` (not the literal `credit`) and the resulting entry still credits `2100 Proveedores` — the fix corrects what the payload *reports*, which downstream reporting depends on, not which account the entry posts to

#### Scenario: A purchase with no imputed payment method still posts to suppliers

- **WHEN** a purchase is registered without any payment method imputed
- **THEN** the emitted payload carries `payment_method = 'credit'` and the entry credits `2100 Proveedores` = total, preserving the historical behaviour

#### Scenario: A wallet purchase does not route to the bank account

- **WHEN** a purchase is registered imputed to a payment method of `kind = 'wallet'`
- **THEN** the emitted `PurchaseCreated` payload carries `payment_method = 'wallet'` and the resulting entry credits `2100 Proveedores`, not `1110 Banco` — the sale-side wallet→bank routing (see `SaleConfirmed` above) does not apply here, because the purchase-side consumer has no bank/cash predicate to extend

### Requirement: PaymentReceived posts a collection entry

On a `PaymentReceived` event (customer paying down their account) the system SHALL post one entry whose debit side is routed by the payment method carried in the event payload: `1110 Banco` for the amount when `payment_method` denotes a bank-settled method (`transfer`, `card`, `check` or `wallet`), or `1100 Caja` for the amount when `payment_method` is cash (or absent, for backward compatibility). The credit side SHALL be `1300 Deudores por Ventas` for the amount. Both lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash customer collection routes to 1100 Caja

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='cash'` (or no `payment_method`) is posted
- **THEN** the entry has debit `1100 Caja` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

#### Scenario: Bank customer collection routes to 1110 Banco

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='transfer'` (bank method) is posted
- **THEN** the entry has debit `1110 Banco` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

#### Scenario: Wallet customer collection routes to 1110 Banco

- **WHEN** a `PaymentReceived` event with `amount` and `payment_method='wallet'` is posted
- **THEN** the entry has debit `1110 Banco` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

### Requirement: PaymentMade posts a supplier-payment entry

On a `PaymentMade` event (payment to a supplier) the system SHALL post one entry with debit `2100 Proveedores` for the amount, and credit side routed by the payment method carried in the event payload: `1110 Banco` for the amount when `payment_method` denotes a bank-settled method (`transfer`, `card`, `check` or `wallet`), or `1100 Caja` for the amount when `payment_method` is cash (or absent, for backward compatibility). Both lines SHALL have `cost_center_id = NULL`. The triggering event type is `PaymentMade` (aggregate `SupplierAccount`), as emitted by the C-30 supplier-payment producer.

#### Scenario: Cash supplier payment routes to 1100 Caja

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='cash'` (or no `payment_method`) is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1100 Caja` = amount, and it balances

#### Scenario: Bank supplier payment routes to 1110 Banco

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='transfer'` (bank method) is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1110 Banco` = amount, and it balances

#### Scenario: Wallet supplier payment routes to 1110 Banco

- **WHEN** a `PaymentMade` event with `amount` and `payment_method='wallet'` is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1110 Banco` = amount, and it balances

### Requirement: CreditNoteIssued reverses the original entry

On a `CreditNoteIssued` event the system SHALL post a mirror (reversal) entry. It SHALL locate the original entry by its source document reference (`source_doc_type='SalesOrder'` and `source_doc_ref` equal to the original sales order, or via the `source_sales_order_id` carried in the event payload), create a new entry whose lines invert each original line's `side` (debit↔credit) with `reversal_of` set to the original entry id and `status='posted'`, and mark the original entry `status='reversed'`. The mirror entry SHALL also balance. If the original entry cannot be found, the posting function SHALL raise so the event is retried.

#### Scenario: Credit note mirrors and marks the original

- **WHEN** a `CreditNoteIssued` event referencing an existing posted sale entry is processed
- **THEN** a new entry is created with inverted debit/credit lines and `reversal_of` pointing to the original, the original entry's `status` becomes `'reversed'`, and the mirror entry balances

#### Scenario: Credit note before the original entry exists

- **WHEN** a `CreditNoteIssued` event is processed but no posted entry exists yet for the referenced sale
- **THEN** the posting function raises, the credit-note event stays unprocessed (`processed_at IS NULL`), and it is retried on a later relay run (after the original `SaleConfirmed` entry posts)

### Requirement: Entries are readable by account via RLS

`journal_entries` and `journal_lines` SHALL have row-level security enabled with a SELECT policy scoped by `account_id` (`account_id IN (SELECT current_account_ids())`). There SHALL be no INSERT/UPDATE/DELETE policy for `authenticated`, because all writes occur through the relay's `SECURITY DEFINER` function. `journal_lines` SHALL carry a denormalized `account_id` (copied from the parent entry) so its SELECT policy filters on an indexed column without a per-row subquery against `journal_entries`.

#### Scenario: User reads only their account's entries

- **WHEN** an authenticated user queries `journal_entries` or `journal_lines`
- **THEN** RLS returns only rows whose `account_id` is in the user's accounts, never another account's entries

#### Scenario: User cannot insert an entry directly

- **WHEN** an authenticated user attempts to INSERT into `journal_entries` or `journal_lines` directly
- **THEN** the write is rejected because no INSERT policy exists for `authenticated`; only the relay's `SECURITY DEFINER` function can write

### Requirement: List posted entries (read endpoint)

The system SHALL expose a minimal read path to list an account's journal entries (most recent first), returning each entry's `posted_at`, `status`, `source_doc_type`, and its lines (`account_code`, `side`, `amount`, `cost_center_id`). If implemented as a backend endpoint, it SHALL follow the 3-layer FastAPI architecture (routers → services → repositories) with JWT-passthrough and SHALL NOT use `service_role`.

#### Scenario: List returns entries scoped to the caller's account

- **WHEN** a caller requests the list of journal entries
- **THEN** the result contains only entries for the caller's account, ordered by `posted_at` descending, each with its debit/credit lines

### ADDED Requirement: SaleOperationCreated posts a form-sale entry

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

### ADDED Requirement: The form-sale entry is dated by the sale, not by the relay run

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

### ADDED Requirement: SaleOperationAdjusted posts a contra-entry and a new entry

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

### ADDED Requirement: Historical operations are regularised through the real consumer

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

### MODIFIED Requirement: Out-of-scope events do not post entries

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

### Requirement: Contra-asiento por borrado de una operación de venta
El consumidor contable SHALL postear, ante un evento `SaleOperationDeleted`, un contra-asiento que revierta exactamente el asiento vigente de la operación borrada y SHALL marcar ese asiento original como `reversed`, sin postear ningún asiento nuevo de reemplazo.

#### Scenario: Venta del formulario con asiento posteado
- **WHEN** se procesa un `SaleOperationDeleted` de una operación con asiento `posted` de tipo `SaleOperation`
- **THEN** se postea un contra-asiento con los lados invertidos línea por línea
- **AND** el contra-asiento referencia el asiento original en `reversal_of`
- **AND** el asiento original queda en estado `reversed`
- **AND** no se postea ningún asiento nuevo de reemplazo

#### Scenario: Venta del POS con asiento por orden
- **WHEN** se procesa un `SaleOperationDeleted` de una venta cuyo asiento vigente es de tipo `SalesOrder`
- **THEN** el consumidor resuelve el asiento original por la referencia de la orden
- **AND** postea el contra-asiento contra ese asiento

#### Scenario: Asiento original ausente
- **WHEN** se procesa un `SaleOperationDeleted` y no existe asiento `posted` para ninguna de las dos convenciones de referencia
- **THEN** el consumidor falla con el código de error `P0451`
- **AND** el evento queda pendiente para reintento sin abortar el lote

#### Scenario: Reproceso del mismo evento
- **WHEN** un `SaleOperationDeleted` ya consumido se vuelve a procesar
- **THEN** el consumidor no postea un segundo contra-asiento

### Requirement: Contra-asiento por borrado de una operación de compra
El consumidor contable SHALL postear, ante un evento `PurchaseDeleted`, un contra-asiento que revierta exactamente el asiento vigente de la compra borrada y SHALL marcar ese asiento original como `reversed`.

#### Scenario: Compra con asiento posteado
- **WHEN** se procesa un `PurchaseDeleted` de una compra con asiento `posted` de tipo `Purchase`
- **THEN** se postea un contra-asiento con los lados invertidos línea por línea
- **AND** el asiento original queda en estado `reversed`
- **AND** el centro de costo de cada línea se preserva en la reversión

### Requirement: Balance del contra-asiento de borrado
El consumidor contable SHALL validar que el contra-asiento de un borrado cumpla Σdébito = Σcrédito antes de darlo por posteado, fallando con el código de error `P0450` si no balancea.

#### Scenario: Contra-asiento desbalanceado
- **WHEN** el contra-asiento de un borrado no balancea
- **THEN** el consumidor falla con `P0450`
- **AND** el evento queda pendiente para reintento

### Requirement: Preservación de las ramas contables existentes
La incorporación de las ramas de borrado SHALL dejar intactas las ramas de evento ya existentes del consumidor contable, incluido el tratamiento fiscal de `SaleConfirmed`.

#### Scenario: Evento fuera del alcance de borrado
- **WHEN** se procesa cualquier evento distinto de los de borrado
- **THEN** su asiento se postea con el mismo resultado observable que antes del cambio

