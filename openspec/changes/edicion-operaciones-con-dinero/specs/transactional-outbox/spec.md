## MODIFIED Requirements

### Requirement: Editing a form sale adjusts its accounting trail instead of being blocked

`rpc_atomic_update_sale_operation` keeps the operation's `operation_id` on every edit: it reverses the old rows, deletes them and applies the new rows under the same `operation_id`, except for a legacy operation without one, which receives one. It SHALL NOT gain any rejection guard for having an accounting event or entry (override of 2026-08-20). In the same transaction as the edit, the system SHALL resolve the operation's accounting trail into exactly one of three cases and act accordingly:

1. **No creation event was ever emitted** for the operation (neither a `SaleOperationCreated` for its `operation_id` nor a `SaleConfirmed` for its sales order): no accounting action is taken.
2. **A `SaleOperationCreated` or `SaleOperationAdjusted` event for it is still pending** (`processed_at IS NULL`). The system SHALL:
   - lock that event row with `SELECT ... FOR UPDATE` (not `SKIP LOCKED`, so the edit waits for the relay's batch transaction rather than racing it);
   - re-check `processed_at` after acquiring the lock, in case the relay finished while the edit waited;
   - only if still pending, update that event's payload in place to the edited values rather than emitting a second event.
3. **Otherwise** — a form sale whose entry is already posted, or a sale born in the POS or converted from a quote, whose `SaleConfirmed` exists whether processed or not — the system SHALL emit a new `SaleOperationAdjusted` event carrying `old_operation_id` and `new_operation_id` (normally equal) and, for a sale with a sales order, its `sales_order_id`. The emission SHALL be a plain `INSERT` with no exception handler, for the same reason the original producer has none (D6): swallowing the failure would silently reproduce the defect this change fixes.

#### Scenario: Editing before the relay processes replaces the pending event in place

- **WHEN** a form sale is edited while its `SaleOperationCreated` event is still `processed_at IS NULL`
- **THEN** no second event is inserted; the existing event's payload is updated to the edited operation's values, and once the relay processes it exactly one journal entry exists for the operation

#### Scenario: Editing after the relay processes emits an adjustment event

- **WHEN** a form sale is edited after its entry has been posted
- **THEN** a `SaleOperationAdjusted` event is inserted in the same transaction as the edit, carrying the operation's identifier as both `old_operation_id` and `new_operation_id`, and no existing event is mutated

#### Scenario: Editing a POS sale emits an adjustment event with its sales order

- **WHEN** a sale confirmed through the POS is edited
- **THEN** a `SaleOperationAdjusted` event carrying its `sales_order_id` is inserted in the same transaction, so the consumer can resolve and reverse its `SalesOrder` entry

#### Scenario: A concurrent relay run does not race the in-place replace

- **WHEN** an edit tries to lock a pending event for in-place replacement at the same moment the relay's batch transaction already holds that row
- **THEN** the edit waits for the relay's transaction to finish rather than proceeding against a stale lock, and re-checks whether the event is still pending before deciding between in-place replacement and emitting an adjustment event

#### Scenario: A chained edit before the relay processes collapses into one adjustment event

- **WHEN** an already-adjusted-but-still-pending operation (its `SaleOperationAdjusted` event not yet processed) is edited again
- **THEN** that pending event's edited values are updated in place, its `old_operation_id` is preserved unchanged, and no additional event is inserted for the second edit

### Requirement: JournalEntry consumer (Consumer 3)

The relay `rpc_process_outbox_dispatch` SHALL include a third consumer, JournalEntry, that posts a double-entry accounting record for in-scope events.

- **Isolation.** It SHALL run inside the same per-event `BEGIN/EXCEPTION/END` isolation block as the AuditLog and EmailNotification consumers, after them, so a posting failure for one event does not abort the batch.
- **Scope.** It SHALL run only for events of type `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PurchaseAdjusted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, `ExpenseCreated`, `ExpenseAdjusted`, or `ExpenseDeleted` — the fifteen canonical types (see "El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate" below) — and SHALL be a no-op for all other event types.
- **Idempotency.** It SHALL be idempotent, keyed by `(event_id, 'JournalEntry')` in `operation_idempotency` (`INSERT ... ON CONFLICT DO NOTHING`), reinforced by a partial unique index on `journal_entries.source_event_id`.
- **Helper.** The mapping logic SHALL live in a helper function `_journal_post_from_event(event_row)` (`SECURITY DEFINER`, `SET search_path = public`).
- **Restrictions.** The consumer SHALL NOT use `service_role` and SHALL NOT make HTTP/`pg_net` calls.

#### Scenario: In-scope event posts an entry through Consumer 3

- **WHEN** the relay processes a `SaleConfirmed` event that has no existing journal entry
- **THEN** Consumer 3 calls `_journal_post_from_event`, which inserts a balanced `journal_entries` row plus its `journal_lines`, after Consumers 1 and 2 have run for that event

#### Scenario: Out-of-scope event is skipped by Consumer 3

- **WHEN** the relay processes an event whose type is not in the fifteen canonical types
- **THEN** Consumer 3 does nothing for that event while Consumers 1 and 2 still run normally

#### Scenario: The form-sale event reaches the consumer through both filters

- **WHEN** the relay processes a `SaleOperationCreated` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and an entry is posted

#### Scenario: The form-sale adjustment event reaches the consumer through both filters

- **WHEN** the relay processes a `SaleOperationAdjusted` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and the contra-entry/new-entry pair is posted

#### Scenario: The purchase adjustment event reaches the consumer through both filters

- **WHEN** the relay processes a `PurchaseAdjusted` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and the contra-entry/new-entry pair is posted

#### Scenario: The expense events reach the consumer through both filters

- **WHEN** the relay processes an `ExpenseCreated`, `ExpenseAdjusted` or `ExpenseDeleted` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and the corresponding entry is posted

#### Scenario: Re-processed event does not post a second entry

- **WHEN** the same in-scope event is dispatched to Consumer 3 twice
- **THEN** the `(event_id, 'JournalEntry')` idempotency slot collides on the second attempt (and/or the `source_event_id` unique index), and exactly one journal entry exists for that event

#### Scenario: Posting failure leaves the event for retry without aborting the batch

- **WHEN** `_journal_post_from_event` raises (e.g. an unbalanced entry, or a `CreditNoteIssued` whose original entry has not posted yet)
- **THEN** the event's `processed_at` stays `NULL`, the event is retried on the next relay run, and the relay continues processing the remaining events in the batch

### Requirement: El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate

El conjunto de tipos de evento que producen asiento contable SHALL estar declarado en **dos** lugares —el filtro del despachador del relay y el filtro del propio helper de posteo— y los dos SHALL enumerar **exactamente el mismo conjunto**.

Este invariante SHALL verificarse con un **gate automático** que extraiga los dos conjuntos de las definiciones vigentes en la base de datos y los compare, y SHALL NOT quedar sostenido únicamente por un comentario en el código. Una divergencia entre los dos filtros produce un evento que nunca postea su asiento —o que el despachador enruta hacia un helper que lo ignora— **sin levantar ningún error**: el modo de falla no es detectable por observación casual y ya se materializó otras veces en el sistema.

El gate SHALL ejecutarse en integración continua en cada cambio. Un gate escrito pero no cableado al flujo de verificación no verifica nada: la garantía que este requirement declara es la de una comprobación que **corre**, no la de un archivo que existe.

El gate SHALL incluir una **matriz de evasión ejecutada**: el mismo comparador SHALL correrse además contra textos sintéticos con una divergencia plantada a propósito, para probar que la detecta. Un detector de texto sin matriz de evasión puede quedar verde por no encontrar nada, y ese verde es indistinguible del verde legítimo.

El conjunto canónico SHALL constar de quince tipos: `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PurchaseAdjusted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, `ExpenseCreated`, `ExpenseAdjusted` y `ExpenseDeleted`. Esta enumeración SHALL prevalecer sobre cualquier enumeración anterior más corta que aparezca en otros requirements de este mismo capability o del capability `journal-entry`.

#### Scenario: Los dos filtros enumeran el mismo conjunto

- **WHEN** corre el gate del invariante sobre las definiciones vigentes
- **THEN** el conjunto del filtro del despachador y el del helper de posteo son iguales
- **AND** ambos contienen los quince tipos canónicos

#### Scenario: Una divergencia introducida rompe el gate

- **GIVEN** un tipo agregado a uno solo de los dos filtros
- **WHEN** corre el gate
- **THEN** falla, nombrando el tipo que sobra o falta y en cuál de los dos filtros

#### Scenario: El gate corre en integración continua

- **WHEN** se inspecciona el flujo de verificación del repositorio
- **THEN** el archivo de gate que contiene la comprobación del invariante figura como paso ejecutable del flujo

#### Scenario: El comparador detecta una divergencia plantada

- **WHEN** el gate corre su matriz de evasión sobre dos textos sintéticos que difieren en un tipo
- **THEN** el comparador reporta la divergencia, probando que la comprobación principal no es un detector vacío

#### Scenario: Un evento fuera del conjunto no postea asiento

- **WHEN** el relay procesa un evento de un tipo que no está en el conjunto canónico
- **THEN** el consumidor contable es un no-op para ese evento y el resto de los consumidores corre normalmente

## ADDED Requirements

### Requirement: La edición de una compra emite PurchaseAdjusted sólo si existe el evento de alta

El sistema SHALL emitir `PurchaseAdjusted` en la misma transacción que la edición de una compra **únicamente cuando existe un evento `PurchaseCreated`** para esa operación en el outbox, procesado o no. La emisión SHALL ser un `INSERT` plano, sin manejador de excepciones.

El payload SHALL llevar:

- la cuenta, el `old_operation_id` (el asiento a revertir) y el `new_operation_id` (el asiento nuevo), iguales una vez que la edición conserva el identificador;
- el total editado;
- la clase de forma de pago final derivada en el servidor, sin valor por defecto;
- el centro de costo;
- la fecha de negocio de la compra;
- el desglose de IVA cuando exista.

Es el mismo predicado que ya rige para el gasto: evaluar sobre el asiento suprimiría el ajuste de una compra editada dentro de la misma ventana del relay, y emitir sin evento de alta dejaría un evento irresoluble que reintentaría para siempre.

Este productor cierra un defecto latente: hasta este cambio, editar una compra con asiento dejaba vivo el asiento del importe viejo, y un borrado posterior emitía un `PurchaseDeleted` que no encontraba asiento.

#### Scenario: Editar una compra asentada emite el ajuste
- **GIVEN** una compra con evento `PurchaseCreated` ya procesado
- **WHEN** se edita su importe
- **THEN** se inserta un `PurchaseAdjusted` en la misma transacción, con el total editado

#### Scenario: Una compra histórica sin evento de alta no emite ajuste
- **GIVEN** una compra sin evento `PurchaseCreated`
- **WHEN** se la edita
- **THEN** la edición procede y no se emite ningún evento de compra

#### Scenario: Editar y borrar una compra deja el libro diario en cero
- **GIVEN** una compra asentada que se edita y después se borra
- **WHEN** el relay procesa los tres eventos en orden
- **THEN** el asiento original y el de la edición quedan revertidos, y no queda ningún evento pendiente con `P0451`
