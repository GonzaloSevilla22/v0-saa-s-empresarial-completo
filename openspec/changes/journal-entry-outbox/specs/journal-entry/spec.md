## ADDED Requirements

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

On a `SaleConfirmed` event the system SHALL post one entry. The debit side SHALL be `1100 Caja` for the total when `payment_method` is `cash` or `other`, or `1300 Deudores por Ventas` for the total when `payment_method` is `credit`. The credit side SHALL be `4100 Ventas` for the net plus `4200 IVA Débito Fiscal` for the IVA amount when the linked fiscal document is Factura A/B with discriminated IVA (`comprobante_type IN ('factura_a','factura_b')` AND `neto`/`iva_amount` present), or a single `4100 Ventas` line for the total when the sale is Factura C, has no fiscal document, or has no IVA breakdown. The net/IVA breakdown SHALL be obtained by joining `sales_orders.fiscal_document_id` to `fiscal_documents`. Revenue lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash sale, monotributista (Factura C), single revenue line

- **WHEN** a `SaleConfirmed` event with `payment_method='cash'` is posted for a sale whose fiscal document is `factura_c` (no IVA breakdown)
- **THEN** the entry has debit `1100 Caja` = total and a single credit `4100 Ventas` = total, and it balances

#### Scenario: Credit sale, Responsable Inscripto (Factura A/B), discriminated IVA

- **WHEN** a `SaleConfirmed` event with `payment_method='credit'` is posted for a sale whose fiscal document is `factura_a` with `neto` and `iva_amount` set
- **THEN** the entry has debit `1300 Deudores por Ventas` = total, credit `4100 Ventas` = neto, credit `4200 IVA Débito Fiscal` = iva_amount, and it balances

### Requirement: PurchaseCreated posts a purchase entry

On a `PurchaseCreated` event the system SHALL post one entry. The debit side SHALL be `5100 CMV/Compras` for the net (with `cost_center_id` taken from the purchase) plus `5200 IVA Crédito Fiscal` for the IVA amount when the purchase has discriminated IVA, or a single `5100 CMV/Compras` line for the total when there is no IVA breakdown. The credit side SHALL be `2100 Proveedores` for the total on a credit purchase, or `1100 Caja` for the total on a cash purchase. The `cost_center_id` SHALL be resolved from the event payload, or by lookup to `purchases` (all lines of the operation share the same cost center). IVA crédito fiscal lines SHALL have `cost_center_id = NULL`.

#### Scenario: Cash purchase without IVA breakdown

- **WHEN** a `PurchaseCreated` cash event is posted with no IVA breakdown
- **THEN** the entry has debit `5100 CMV/Compras` = total (carrying the purchase's `cost_center_id`) and credit `1100 Caja` = total, and it balances

#### Scenario: Credit purchase with discriminated IVA

- **WHEN** a `PurchaseCreated` credit event is posted with `neto` and `iva_amount` set
- **THEN** the entry has debit `5100 CMV/Compras` = neto (with `cost_center_id`) plus debit `5200 IVA Crédito Fiscal` = iva_amount (with `cost_center_id = NULL`) and credit `2100 Proveedores` = total, and it balances

### Requirement: PaymentReceived posts a collection entry

On a `PaymentReceived` event (customer paying down their account) the system SHALL post one entry with debit `1100 Caja` for the amount and credit `1300 Deudores por Ventas` for the amount, both with `cost_center_id = NULL`.

#### Scenario: Customer collection

- **WHEN** a `PaymentReceived` event with `amount` is posted
- **THEN** the entry has debit `1100 Caja` = amount and credit `1300 Deudores por Ventas` = amount, and it balances

### Requirement: PaymentMade posts a supplier-payment entry

On a `PaymentMade` event (payment to a supplier) the system SHALL post one entry with debit `2100 Proveedores` for the amount and credit `1100 Caja` for the amount, both with `cost_center_id = NULL`. The triggering event type is `PaymentMade` (aggregate `SupplierAccount`), as emitted by the C-30 supplier-payment producer.

#### Scenario: Supplier payment

- **WHEN** a `PaymentMade` event with `amount` is posted
- **THEN** the entry has debit `2100 Proveedores` = amount and credit `1100 Caja` = amount, and it balances

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

### Requirement: Out-of-scope events do not post entries

The JournalEntry posting SHALL run only for the V1 event types `SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`, and `CreditNoteIssued`. Events of other types (`ExpenseRegistered`, `CashSessionClosed`, `StockAdjusted`, `SupplierAccountCharged`, `CustomerAccountCharged`, and any other) SHALL NOT produce a journal entry in this version.

#### Scenario: Deferred event type is ignored

- **WHEN** the relay processes an event of type `StockAdjusted` or `CashSessionClosed`
- **THEN** the JournalEntry consumer does nothing for that event and no `journal_entries` row is created
