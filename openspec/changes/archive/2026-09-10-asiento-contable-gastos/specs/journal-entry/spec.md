## MODIFIED Requirements

### Requirement: Out-of-scope events do not post entries

The JournalEntry posting SHALL run only for the event types `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, `ExpenseCreated`, `ExpenseAdjusted`, and `ExpenseDeleted` — the fourteen canonical types (see `transactional-outbox`, "El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate"). Events of other types (`CashSessionClosed`, `StockAdjusted`, `SupplierAccountCharged`, `CustomerAccountCharged`, and any other) SHALL NOT produce a journal entry in this version.

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

#### Scenario: The expense events are in scope

- **WHEN** the relay processes an `ExpenseCreated`, `ExpenseAdjusted` or `ExpenseDeleted` event
- **THEN** the JournalEntry consumer posts the corresponding entry, contra-entry/new-entry pair, or contra-entry, instead of treating it as out of scope

### Requirement: List posted entries (read endpoint)

The system SHALL expose a minimal read path to list an account's journal entries (most recent first), returning each entry's `posted_at`, `status`, `source_doc_type`, and its lines (`account_code`, `side`, `amount`, `cost_center_id`). If implemented as a backend endpoint, it SHALL follow the 3-layer FastAPI architecture (routers → services → repositories) with JWT-passthrough and SHALL NOT use `service_role`.

The read path SHALL accept optional filters by date range, by `source_doc_type`, by `source_doc_ref` and by `status`, applied server-side, and SHALL keep the standard `{items,total,page,pages}` envelope and the `posted_at DESC` ordering it already has. A call with no filters SHALL behave exactly as before.

The filters SHALL be added to the existing read path. The system SHALL NOT introduce a second endpoint returning the same entries under different criteria.

The read path SHALL remain read-only: the relay is the only writer of journal entries. Every filter combination SHALL stay scoped to the caller's account.

#### Scenario: List returns entries scoped to the caller's account

- **WHEN** a caller requests the list of journal entries
- **THEN** the result contains only entries for the caller's account, ordered by `posted_at` descending, each with its debit/credit lines

#### Scenario: Filter by period and document type

- **WHEN** the endpoint is called with a date range and `source_doc_type = 'Expense'`
- **THEN** it returns only expense entries posted within that range, in the standard envelope

#### Scenario: Filter by document reference

- **WHEN** the endpoint is called with the `source_doc_ref` of one expense
- **THEN** it returns that expense's live entry and any contra-entries referencing the same document

#### Scenario: Unfiltered call is unchanged

- **WHEN** the endpoint is called with no filters
- **THEN** it behaves exactly as before, returning the account's entries ordered by `posted_at` descending

#### Scenario: Filters do not cross accounts

- **WHEN** any filter combination is used
- **THEN** the result stays scoped to the caller's account

### Requirement: Preservación de las ramas contables existentes
La incorporación de ramas nuevas al consumidor contable —las de borrado, las de anulación de pago y las de gasto— SHALL dejar intactas las ramas de evento ya existentes, incluido el tratamiento fiscal de `SaleConfirmed`, el ruteo bancario de `PaymentReceived` y `PaymentMade`, y el mapeo de cuentas de `SaleOperationCreated` y `PurchaseCreated`.

Toda reescritura del consumidor contable SHALL partir de su definición **viva** en la base de datos, verificada por hash antes de modificarla, y no del último archivo de migración: las dos han divergido al menos una vez en la historia del proyecto, y el consumidor concentra el mapeo contable de todos los caminos de negocio.

Una rama nueva SHALL agregarse sin alterar el orden ni las condiciones de las ramas previas, de modo que un evento de un tipo preexistente recorra exactamente el mismo camino que antes del cambio.

#### Scenario: Evento fuera del alcance de borrado
- **WHEN** se procesa cualquier evento distinto de los de borrado
- **THEN** su asiento se postea con el mismo resultado observable que antes del cambio

#### Scenario: Las ramas de alta de pago no cambian de comportamiento
- **WHEN** se procesa un `PaymentReceived` o un `PaymentMade` después de incorporar las ramas de anulación
- **THEN** su asiento se postea idéntico al que producía antes, con el mismo ruteo entre cuenta de caja y cuenta de banco

#### Scenario: Las ramas de venta y compra no cambian al incorporar el gasto
- **WHEN** se procesa un `SaleConfirmed`, un `SaleOperationCreated` o un `PurchaseCreated` después de incorporar las ramas de gasto
- **THEN** su asiento se postea idéntico al que producía antes, con las mismas cuentas, los mismos importes y la misma fecha

#### Scenario: La reescritura parte de la definición viva
- **WHEN** se modifica el consumidor contable
- **THEN** el punto de partida es su definición vigente en la base de datos, verificada por hash antes de escribir el cambio

## ADDED Requirements

### Requirement: ExpenseCreated posts an expense entry

On an `ExpenseCreated` event the system SHALL post one entry with `source_doc_type = 'Expense'` and the expense identifier as `source_doc_ref`.

The debit side SHALL be a single line to `5300 Gastos` for the expense total, carrying the expense's `cost_center_id` when present — the same analytic treatment `5100 CMV/Compras` receives on the purchase branch. The expense has no discriminated VAT breakdown, so the entry SHALL NOT produce a `5200 IVA Crédito Fiscal` line.

The credit side SHALL be a single line for the total, to the account resolved by a dedicated mapping function from the payment-method `kind` carried in the payload: `1110 Banco` for `transfer`, `card`, `check` and `wallet`; `1100 Caja` for `cash`, `other` and an absent payment method. The mapping SHALL be the mirror of `_journal_sale_debit_account` minus its `credit`/`1300` case, which the expense rejects at creation time.

The entry SHALL be dated by the expense's own business date, carried in the payload as a plain date and converted to an instant in the business time zone, and SHALL NOT be dated by the relay run — the same rule already governing the form-sale entry.

#### Scenario: Cash expense

- **WHEN** an `ExpenseCreated` event with `kind = 'cash'` is posted
- **THEN** the entry has debit `5300 Gastos` = total (carrying the expense's `cost_center_id`) and credit `1100 Caja` = total, and it balances

#### Scenario: Bank-settled expense

- **WHEN** an `ExpenseCreated` event with `kind` of `transfer`, `card`, `check` or `wallet` is posted
- **THEN** the credit line is `1110 Banco` = total, mirroring the bank movement the same expense registered

#### Scenario: Expense with no imputed payment method

- **WHEN** an `ExpenseCreated` event with a null `kind` is posted
- **THEN** the credit line is `1100 Caja` = total, and not `2100 Proveedores`

#### Scenario: The entry carries the expense date

- **GIVEN** an expense dated on a day earlier than the relay run
- **WHEN** its entry is posted
- **THEN** `posted_at` corresponds to the expense's business date in the business time zone, not to the relay run

### Requirement: ExpenseAdjusted posts a contra-entry and a new entry

On an `ExpenseAdjusted` event the system SHALL locate the expense's live entry by `(source_doc_type = 'Expense', source_doc_ref = expense_id, status = 'posted', reversal_of IS NULL, account_id)`, post a contra-entry with every line's side inverted and `reversal_of` pointing at it, mark the original `reversed`, and then post a new entry with the edited values through the same mapping used by `ExpenseCreated`.

The contra-entry SHALL be dated at the moment of the correction; the new entry SHALL be dated by the expense's business date.

When no live entry is found the consumer SHALL raise `P0451`, leaving the event pending for retry, and SHALL NOT post the new entry on its own — an adjustment without its reversal would double-count the expense.

Both the contra-entry and the new entry SHALL balance, and the contra-entry's balance SHALL be validated individually, as the sale-adjustment branch already does.

A contra-entry SHALL NOT itself be a candidate for the "live entry" lookup: at every point in time there SHALL exist at most one live (`posted`, `reversal_of IS NULL`) entry per expense. Omitting `reversal_of IS NULL` from the lookup key would let a second adjustment match the first adjustment's own contra-entry instead of the entry it actually reversed, reversing the wrong amount and double-counting the expense in `5300 Gastos`.

#### Scenario: Editing an expense adjusts its trail

- **WHEN** an `ExpenseAdjusted` event is posted for an expense with a live entry
- **THEN** the original entry is `reversed`, a contra-entry referencing it exists, and a new entry with the edited amount is posted
- **AND** all three entries balance

#### Scenario: Adjustment before its creation event

- **WHEN** an `ExpenseAdjusted` event is processed before the expense's `ExpenseCreated` event
- **THEN** it raises `P0451`, the event stays pending, the batch continues, and the pair posts correctly on the run after the creation entry exists

#### Scenario: A second edit of the same expense

- **GIVEN** an expense that has already been adjusted once, with its contra-entry and its replacement live entry both posted
- **WHEN** a second `ExpenseAdjusted` event is posted for the same expense
- **THEN** the lookup finds the replacement entry (not the first contra-entry) as the live entry, reverses only that one, and posts a second replacement
- **AND** exactly one live entry exists for the expense afterward, and the net balance of `5300 Gastos` for the expense equals the latest edited amount

### Requirement: ExpenseDeleted posts a contra-entry

On an `ExpenseDeleted` event the system SHALL locate the expense's live entry by `(source_doc_type = 'Expense', source_doc_ref = expense_id, status = 'posted', reversal_of IS NULL, account_id)`, post a contra-entry with every line's side inverted, its `cost_center_id` preserved per line, and `reversal_of` pointing at the original, and mark the original `reversed`.

The contra-entry SHALL be the only entry of the event and SHALL therefore carry its own `source_event_id`, keeping the event-to-entry trail complete — the same shape as `PurchaseDeleted`.

The lookup SHALL NOT read the `expenses` row: expense deletion is physical and the row no longer exists when the relay runs. The entry's own `source_doc_ref` is the only reference needed.

When no live entry is found the consumer SHALL raise `P0451` and leave the event pending for retry.

A contra-entry SHALL NOT itself be a candidate for the "live entry" lookup, the same invariant `ExpenseAdjusted` relies on: at every point in time there SHALL exist at most one live (`posted`, `reversal_of IS NULL`) entry per expense, so a delete after a prior edit reverses the edited entry, not the edit's own contra-entry.

#### Scenario: Deleting an expense reverses its entry

- **WHEN** an `ExpenseDeleted` event is posted for an expense with a live entry
- **THEN** the original entry is marked `reversed` and a contra-entry with inverted sides and the same amounts exists, referencing it
- **AND** the contra-entry balances and carries its own `source_event_id`

#### Scenario: Deleting an expense that was edited first

- **GIVEN** an expense that was created and then adjusted once, leaving one contra-entry and one live replacement entry
- **WHEN** its `ExpenseDeleted` event is posted
- **THEN** the lookup finds the replacement entry as the live one, reverses only that one, and afterward zero live entries exist for the expense and the net balance of `5300 Gastos` for the expense is zero

#### Scenario: The contra-entry does not depend on the deleted row

- **GIVEN** an expense whose row has already been deleted
- **WHEN** the relay processes its `ExpenseDeleted` event
- **THEN** the contra-entry posts, resolved entirely from the entry's `source_doc_ref`

#### Scenario: Cost centers survive the reversal

- **GIVEN** an entry whose debit line carries a `cost_center_id`
- **WHEN** its contra-entry is posted
- **THEN** the reversed line carries the same `cost_center_id`

### Requirement: The expense counterparty account is resolved by a shared mapping function

The mapping from payment-method `kind` to the expense's counterparty account SHALL live in a dedicated `IMMUTABLE` SQL function, `_journal_expense_credit_account(p_kind text)`, and SHALL NOT be an inline `CASE` repeated across the expense branches.

The function SHALL be `SECURITY INVOKER` and SHALL carry the same authorization posture as `_journal_sale_debit_account`: no `EXECUTE` for `anon` and none for `authenticated`, since only the posting helper invokes it.

#### Scenario: The mapping is verifiable in isolation

- **WHEN** the mapping function is invoked with each of `transfer`, `card`, `check`, `wallet`, `cash`, `other` and `NULL`
- **THEN** it returns `1110` for the first four and `1100` for the rest, without any expense, event or entry existing

#### Scenario: The mapping function is not exposed

- **WHEN** the live grants of the mapping function are inspected
- **THEN** neither `anon` nor `authenticated` holds `EXECUTE` on it

