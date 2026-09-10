## MODIFIED Requirements

### Requirement: El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate

El conjunto de tipos de evento que producen asiento contable SHALL estar declarado en **dos** lugares —el filtro del despachador del relay y el filtro del propio helper de posteo— y los dos SHALL enumerar **exactamente el mismo conjunto**.

Este invariante SHALL verificarse con un **gate automático** que extraiga los dos conjuntos de las definiciones vigentes en la base de datos y los compare, y SHALL NOT quedar sostenido únicamente por un comentario en el código. Una divergencia entre los dos filtros produce un evento que nunca postea su asiento —o que el despachador enruta hacia un helper que lo ignora— **sin levantar ningún error**: el modo de falla no es detectable por observación casual y ya se materializó otras veces en el sistema.

El gate SHALL ejecutarse en integración continua en cada cambio. Un gate escrito pero no cableado al flujo de verificación no verifica nada: la garantía que este requirement declara es la de una comprobación que **corre**, no la de un archivo que existe.

El gate SHALL incluir una **matriz de evasión ejecutada**: el mismo comparador SHALL correrse además contra textos sintéticos con una divergencia plantada a propósito, para probar que la detecta. Un detector de texto sin matriz de evasión puede quedar verde por no encontrar nada, y ese verde es indistinguible del verde legítimo.

El conjunto canónico SHALL constar de catorce tipos: `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, `ExpenseCreated`, `ExpenseAdjusted` y `ExpenseDeleted`. Esta enumeración SHALL prevalecer sobre cualquier enumeración anterior más corta que aparezca en otros requirements de este mismo capability o del capability `journal-entry`, que quedaron desactualizadas al incorporarse las ramas de borrado y las de gasto.

#### Scenario: Los dos filtros enumeran el mismo conjunto

- **WHEN** corre el gate del invariante sobre las definiciones vigentes
- **THEN** el conjunto del filtro del despachador y el del helper de posteo son iguales
- **AND** ambos contienen los catorce tipos canónicos

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

### Requirement: JournalEntry consumer (Consumer 3)

The relay `rpc_process_outbox_dispatch` SHALL include a third consumer, JournalEntry, that posts a double-entry accounting record for in-scope events. It SHALL run inside the same per-event `BEGIN/EXCEPTION/END` isolation block as the AuditLog and EmailNotification consumers, after them, so a posting failure for one event does not abort the batch. It SHALL run only for events of type `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, `ExpenseCreated`, `ExpenseAdjusted`, or `ExpenseDeleted` — the fourteen canonical types (see "El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate" below) — and SHALL be a no-op for all other event types. It SHALL be idempotent, keyed by `(event_id, 'JournalEntry')` in `operation_idempotency` (`INSERT ... ON CONFLICT DO NOTHING`) reinforced by a partial unique index on `journal_entries.source_event_id`. The mapping logic SHALL live in a helper function `_journal_post_from_event(event_row)` (`SECURITY DEFINER`, `SET search_path = public`). The consumer SHALL NOT use `service_role` and SHALL NOT make HTTP/`pg_net` calls.

#### Scenario: In-scope event posts an entry through Consumer 3

- **WHEN** the relay processes a `SaleConfirmed` event that has no existing journal entry
- **THEN** Consumer 3 calls `_journal_post_from_event`, which inserts a balanced `journal_entries` row plus its `journal_lines`, after Consumers 1 and 2 have run for that event

#### Scenario: Out-of-scope event is skipped by Consumer 3

- **WHEN** the relay processes an event whose type is not in the fourteen canonical types
- **THEN** Consumer 3 does nothing for that event while Consumers 1 and 2 still run normally

#### Scenario: The form-sale event reaches the consumer through both filters

- **WHEN** the relay processes a `SaleOperationCreated` event
- **THEN** the dispatch filter routes it to `_journal_post_from_event` and the helper's own filter accepts it, and an entry is posted

#### Scenario: The form-sale adjustment event reaches the consumer through both filters

- **WHEN** the relay processes a `SaleOperationAdjusted` event
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

## ADDED Requirements

### Requirement: El alta, la edición y el borrado de un gasto emiten su evento en la misma transacción que la mutación

El sistema SHALL emitir los eventos `ExpenseCreated`, `ExpenseAdjusted` y `ExpenseDeleted` hacia el outbox **dentro de la misma transacción** que registra, modifica o borra el gasto y sus efectos en los libros de caja y banco. La emisión SHALL ser un `INSERT` plano, sin manejador de excepciones, por la misma razón que rige para los productores de venta, compra y anulación de cobros.

Los tres eventos SHALL llevar `aggregate_type = 'Expense'` y el identificador del gasto como `aggregate_id`.

La carga de `ExpenseCreated` y de `ExpenseAdjusted` SHALL llevar la cuenta, el identificador del gasto, el importe, la fecha de negocio del gasto **como fecha pura sin componente horario**, el centro de costo cuando se imputó, y la clase (`kind`) de la forma de pago derivada en el servidor desde el catálogo de la cuenta. La clase SHALL emitirse cruda, sin sustituirla por un valor por defecto cuando no hay forma de pago imputada: la carga SHALL reportar lo que ocurrió, y la presunción para el caso sin imputar SHALL vivir en la rama del consumidor.

La carga de `ExpenseDeleted` SHALL llevar la cuenta y el identificador del gasto, que es todo lo que el consumidor necesita para localizar el asiento vigente y revertirlo — el documento ya no existe cuando el relay corre.

El productor de alta SHALL vivir en la operación atómica de alta de gasto, de modo que el importador de gastos, que la invoca fila por fila, herede la emisión sin una segunda definición y sin código propio.

#### Scenario: El evento acompaña al alta

- **WHEN** un alta de gasto commitea
- **THEN** existe un evento `ExpenseCreated` escrito en la misma transacción que la fila del gasto y sus movimientos de caja o banco

#### Scenario: El evento se revierte con el alta fallida

- **WHEN** un alta de gasto revierte
- **THEN** no queda ningún evento `ExpenseCreated`

#### Scenario: El gasto importado emite su evento sin código del importador

- **WHEN** un lote de importación de gastos commitea
- **THEN** existe un evento `ExpenseCreated` por fila importada, emitido por la operación de alta que el importador invoca

#### Scenario: La carga reporta la clase real, incluida su ausencia

- **WHEN** se registra un gasto sin forma de pago imputada
- **THEN** la carga del evento lleva la clase nula, y no un literal por defecto

#### Scenario: La fecha viaja como fecha pura

- **WHEN** se emite el evento de un gasto
- **THEN** la fecha de negocio viaja como fecha sin componente horario, de modo que el consumidor la convierta en la zona del negocio y no en la de la sesión que corre el relay

### Requirement: Los eventos de edición y borrado de gasto se emiten sólo si existe el evento de alta

El sistema SHALL emitir `ExpenseAdjusted` y `ExpenseDeleted` **únicamente cuando existe un evento `ExpenseCreated` para ese mismo gasto** en el outbox.

El predicado SHALL evaluarse sobre la existencia del **evento de alta** y SHALL NOT evaluarse sobre la existencia del asiento. Un gasto creado y borrado dentro de la misma ventana de relay tiene su evento de alta sin procesar y todavía no tiene asiento: evaluar sobre el asiento suprimiría su evento de borrado y dejaría un asiento sin revertir. El relay procesa los eventos en orden de ocurrencia, de modo que el alta precede al borrado, y el fallo recuperable del consumidor resuelve el caso en que queden en corridas distintas.

Sin este predicado, borrar o editar un gasto anterior a la puesta en marcha del asiento contable emitiría un evento cuyo asiento original no existe ni existirá, que fallaría de forma recuperable en cada corrida del relay de forma indefinida, sin más señal que el ruido en los registros internos.

#### Scenario: Un gasto histórico no emite evento al borrarse

- **GIVEN** un gasto sin evento `ExpenseCreated`
- **WHEN** se lo borra
- **THEN** el borrado procede y no se emite ningún evento de gasto, de modo que el outbox no acumula un evento irresoluble

#### Scenario: Un gasto histórico no emite evento al editarse

- **GIVEN** un gasto sin evento `ExpenseCreated`
- **WHEN** se lo edita
- **THEN** la edición procede y no se emite ningún evento de gasto

#### Scenario: Un gasto con alta sin procesar sí emite su borrado

- **GIVEN** un gasto cuyo evento `ExpenseCreated` todavía no fue procesado por el relay
- **WHEN** se lo borra
- **THEN** se emite `ExpenseDeleted`, porque el predicado mira el evento y no el asiento
