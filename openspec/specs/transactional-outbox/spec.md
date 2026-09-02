# Transactional Outbox Specification

## Purpose

Provides a canonical transactional outbox pattern for EIE domain events. Events are durably stored in `public.events` during mutations, processed asynchronously by a relay (pg_cron), and dispatched to consumers (AuditLog, EmailNotification) with idempotency, retry logic, and multi-tenant authorization via SECURITY DEFINER RPC.

---
## Requirements
### Requirement: Canonical events outbox schema

The `public.events` table SHALL be the single transactional outbox with a canonical V2 schema formalized in migration history: `id`, `account_id`, `event_type text`, `aggregate_type text`, `aggregate_id uuid`, `payload jsonb`, `occurred_at timestamptz DEFAULT now()`, and `processed_at timestamptz` where `NULL` means unprocessed. The reconciliation migration SHALL be idempotent and drift-tolerant so it converges CI and PROD without destructive DDL. Legacy columns (`company_id`, `entity_type`, `title`) SHALL be kept as nullable legacy columns, not dropped.

#### Scenario: Migration applies on a CI-shaped events table

- **WHEN** the reconciliation migration runs against a database whose `events` table is the CI stub (`id, company_id NULLABLE, title, created_at`, no `entity_type`)
- **THEN** it completes without error, the canonical V2 columns are present (added if missing), and no `entity_type`-not-found error occurs because all alterations are guarded by `IF EXISTS` / `ADD COLUMN IF NOT EXISTS`

#### Scenario: Migration applies on a drifted PROD-shaped events table

- **WHEN** the reconciliation migration runs against a database whose `events` table carries legacy `company_id`/`entity_type` as `NOT NULL`
- **THEN** those legacy columns are altered to nullable, the V2 columns remain intact, no column is dropped, and re-running the migration is a no-op

#### Scenario: Relay query has a supporting partial index

- **WHEN** the migration completes
- **THEN** a partial index on `events (occurred_at)` (or `events (processed_at)`) `WHERE processed_at IS NULL` exists so the relay's pending-row scan does not table-scan

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

### Requirement: AuditLog consumer

The relay SHALL include an AuditLog consumer (mandatory, first) that writes exactly one append-only row into `public.audit_logs` per processed event, stamped with the event's `account_id`. An event SHALL NOT be marked `processed_at` unless its audit row is committed. The relay SHALL only INSERT audit rows and SHALL NOT update or delete existing audit rows.

#### Scenario: Audit row written per processed event

- **WHEN** the relay processes an event through the AuditLog consumer
- **THEN** exactly one `audit_logs` row is inserted for that event, carrying the event's `account_id` and an action derived from `event_type`

#### Scenario: Audit failure blocks marking processed

- **WHEN** the AuditLog consumer fails to write its row
- **THEN** the event's `processed_at` remains `NULL` and no later consumer marks the event processed, so the audit entry is never skipped

### Requirement: EmailNotification consumer

The relay SHALL include an EmailNotification consumer that, for events of type `sale_created`, `stock_adjusted`, or `plan_changed`, emits the notification by inserting into `public.email_logs` (the DEC-09 path: DB webhook → Edge Function → Resend). The consumer SHALL NOT call Resend directly and SHALL NOT run for event types outside that set.

#### Scenario: Email emitted via email_logs for an in-scope event type

- **WHEN** the relay processes an event of type `sale_created`, `stock_adjusted`, or `plan_changed`
- **THEN** the EmailNotification consumer inserts a row into `email_logs` (not a direct Resend call) so the existing webhook pipeline delivers it

#### Scenario: No email for out-of-scope event types

- **WHEN** the relay processes an event whose type is not in `{sale_created, stock_adjusted, plan_changed}`
- **THEN** the EmailNotification consumer does nothing for that event

### Requirement: Consumer idempotency

Each consumer SHALL be idempotent, keyed by `(event_id, consumer_type)` reusing the `operation_idempotency` ledger via `INSERT ... ON CONFLICT DO NOTHING` (with `operation_kind = 'event_consumer'`). Processing the same event twice for the same consumer SHALL produce exactly one side-effect (e.g. one `audit_logs` row, one `journal_entries` row, or one `notifications` row).

#### Scenario: Re-processed event does not duplicate the audit row

- **WHEN** the same event is dispatched to the AuditLog consumer twice (e.g. after a retry)
- **THEN** the `(event_id, consumer_type)` idempotency key collides on the second attempt, the consumer skips its side-effect, and `audit_logs` contains exactly one row for that event

#### Scenario: Independent idempotency per consumer

- **WHEN** an event is processed by multiple consumers (e.g. AuditLog and Notification)
- **THEN** each consumer records its own `(event_id, consumer_type)` key, so a retry that re-runs only the failed consumer does not re-fire the ones that already succeeded

### Requirement: Outbox producers

Backend mutations SHALL emit domain events into `public.events` inside the SAME transaction as the mutation (DEC-20). C-25 SHALL add `PurchaseCreated` and `StockAdjusted` producers; the `SaleConfirmed` producer already exists (C-29) and SHALL NOT be re-created. Each emitted event SHALL stamp `account_id`, `event_type`, `aggregate_type`, `aggregate_id`, `payload`, and `occurred_at`.

#### Scenario: PurchaseCreated emitted in the purchase transaction

- **WHEN** a purchase-create mutation commits
- **THEN** a `PurchaseCreated` event row exists in `events` with the purchase's `account_id` and aggregate identifiers, written in the same transaction

#### Scenario: Event rolls back with a failed mutation

- **WHEN** a `StockAdjusted`-producing mutation rolls back (e.g. invariant violation)
- **THEN** no `StockAdjusted` event row remains, because the event INSERT shares the mutation's transaction

### Requirement: Relay authorization model

El relay SHALL leer los eventos pendientes de todas las cuentas y actualizar su marca de procesado a través de una función con privilegio de definidor cuyo permiso de ejecución esté revocado de **los tres roles de aplicación** —el pseudo-rol público, el rol anónimo y el rol autenticado—, sin debilitar el aislamiento por cuenta de los usuarios normales.

La formulación anterior nombraba únicamente al rol anónimo y al pseudo-rol público. Ese silencio sobre el rol autenticado no fue una omisión inofensiva: las dos funciones del relay nacieron con permiso de ejecución concedido explícitamente a ese rol, y por lo tanto quedaron invocables desde la API de datos por cualquier usuario con sesión iniciada. Como ninguna de las dos filtra por cuenta —no filtrar es su razón de ser—, la combinación convierte al outbox en una lectura completa de los eventos de todos los inquilinos, con su contenido legible, y en la posibilidad de marcarlos procesados sin haberlos procesado. Lo segundo es más grave que lo primero: un evento marcado sin haber sido despachado **nunca** produce su asiento contable, porque el despachador real sólo mira los pendientes.

Una función del relay SHALL NOT resolverse agregándole un filtro por cuenta. Recorrer todas las cuentas es el contrato que este requisito le exige; filtrarla la volvería inútil como relay y no impediría que un consumidor incompleto cierre eventos ajenos. La forma correcta SHALL ser dejarla fuera del alcance de los roles de aplicación y alcanzarla únicamente desde un contexto de máquina.

El aislamiento por cuenta sobre la tabla de eventos para los usuarios normales SHALL seguir siendo de sólo lectura y limitado a su propia cuenta, y el código de aplicación SHALL NOT usar la clave de servicio para eludirlo.

#### Scenario: Un usuario autenticado no puede recorrer el outbox

- **WHEN** un usuario con sesión iniciada intenta invocar directamente, desde la API de datos, la función que devuelve el lote de eventos pendientes
- **THEN** la invocación es rechazada por falta de permiso de ejecución, y no obtiene ningún evento de ninguna cuenta

#### Scenario: Un usuario autenticado no puede cerrar un evento ajeno

- **WHEN** un usuario con sesión iniciada intenta invocar directamente la función que marca un evento como procesado, informando el identificador de un evento de otra cuenta
- **THEN** la invocación es rechazada, la marca de procesado del evento no cambia, y el despachador lo sigue viendo pendiente

#### Scenario: Normal user cannot read another account's events

- **WHEN** an authenticated user queries `events` directly
- **THEN** RLS returns only rows for that user's `account_id`, never other accounts' events

#### Scenario: Relay processes across accounts via the definer RPC

- **WHEN** the pg_cron relay invokes the outbox-processing RPC
- **THEN** the `SECURITY DEFINER` owner bypasses RLS for the relay's pending scan and `processed_at` update only, with EXECUTE not granted to `anon`/`PUBLIC`/`authenticated`, and no `service_role` key used in app code

### Requirement: Hay un único despachador del outbox

El sistema SHALL despachar los eventos del outbox por un único componente, el despachador en base de datos que ejecuta los cuatro consumidores en orden, y SHALL NOT mantener un segundo componente que seleccione eventos pendientes y los marque procesados con un subconjunto de los consumidores.

El requisito de despacho ya exige que la marca de procesado se escriba **sólo después** de que todos los consumidores en alcance del evento tengan éxito. Dos componentes que comparten la misma tabla, el mismo predicado de selección y la misma marca, pero que corren distinta cantidad de consumidores, **violan ese requisito por construcción**: el que corre menos consumidores gana la carrera para algunos eventos y los cierra, y el otro nunca los vuelve a ver. El resultado no es un reintento perdido, es una omisión permanente y silenciosa — el evento queda contabilizado como procesado sin haber generado ni su asiento contable ni su notificación.

El disparador manual del relay, que existe para depuración y operación puntual, SHALL invocar al mismo despachador único en lugar de implementar su propio recorrido de consumidores.

#### Scenario: El disparador manual produce el mismo resultado que el despachador programado

- **GIVEN** un evento pendiente cuyo tipo produce asiento contable
- **WHEN** el relay se dispara manualmente en lugar de esperar a la corrida programada
- **THEN** el evento queda procesado con sus cuatro consumidores aplicados, incluido su asiento contable, igual que si lo hubiera tomado la corrida programada

#### Scenario: No existe un segundo camino que marque procesado con menos consumidores

- **WHEN** se inspeccionan los componentes capaces de escribir la marca de procesado sobre un evento
- **THEN** el único que la escribe es el despachador de cuatro consumidores

#### Scenario: Ningún evento queda procesado sin su asiento

- **GIVEN** un conjunto de eventos de tipos que producen asiento contable
- **WHEN** se los procesa por cualquiera de los dos disparadores
- **THEN** no queda ningún evento con marca de procesado que carezca de su asiento correspondiente

### Requirement: El disparador manual del relay es un camino de servicio con acceso restringido a administración de plataforma

El sistema SHALL exigir rol de administrador de plataforma para disparar el relay del outbox manualmente, y SHALL ejecutar ese disparo sobre el contexto de conexión de servicio, separado del contexto de conexión del pedido de usuario.

El disparador recorre el outbox de **todos** los inquilinos por diseño: es una operación de máquina, no una operación de un inquilino sobre sus propios datos. Hasta ahora sólo exigía tener sesión iniciada, de modo que cualquier usuario podía provocar el recorrido completo. La verificación de rol SHALL resolverse con el mecanismo de administración de plataforma que ya existe y se usa en otros comandos administrativos, y no con uno nuevo.

Ejecutarlo sobre el contexto de conexión de servicio SHALL ser parte del contrato y no un detalle de implementación: es lo que hace que la restricción de permisos sobre las funciones del relay siga siendo válida cuando el contexto de pedido de usuario adopte el rol de aplicación. El contexto de servicio SHALL NOT adoptar ese rol bajo ninguna configuración, y esa propiedad SHALL estar verificada por una prueba automatizada y no solamente documentada.

#### Scenario: Un usuario común no puede disparar el relay

- **GIVEN** un usuario con sesión iniciada que no es administrador de plataforma
- **WHEN** invoca el disparador manual del relay
- **THEN** recibe un rechazo por permisos y ningún evento cambia de estado

#### Scenario: El administrador de plataforma sí puede

- **GIVEN** un usuario que es administrador de plataforma
- **WHEN** invoca el disparador manual del relay
- **THEN** el despacho se ejecuta y la respuesta informa cuántos eventos se procesaron

#### Scenario: El contexto de servicio no adopta el rol de aplicación

- **WHEN** ambas palancas de alcance de transacción y de adopción de rol están activas
- **THEN** una conexión obtenida por el contexto de servicio sigue operando con el rol propietario, de modo que el disparador funciona aunque las funciones del relay estén revocadas del rol de aplicación

### ADDED Requirement: Editing a form sale adjusts its accounting trail instead of being blocked

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

### MODIFIED Requirement: JournalEntry consumer (Consumer 3)

The relay `rpc_process_outbox_dispatch` SHALL include a third consumer, JournalEntry, that posts a double-entry accounting record for in-scope events. It SHALL run inside the same per-event `BEGIN/EXCEPTION/END` isolation block as the AuditLog and EmailNotification consumers, after them, so a posting failure for one event does not abort the batch. It SHALL run only for events of type `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, or `CreditNoteIssued`, and SHALL be a no-op for all other event types. It SHALL be idempotent, keyed by `(event_id, 'JournalEntry')` in `operation_idempotency` (`INSERT ... ON CONFLICT DO NOTHING`) reinforced by a partial unique index on `journal_entries.source_event_id`. The mapping logic SHALL live in a helper function `_journal_post_from_event(event_row)` (`SECURITY DEFINER`, `SET search_path = public`). The consumer SHALL NOT use `service_role` and SHALL NOT make HTTP/`pg_net` calls.

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

### MODIFIED Requirement: JournalEntry-producing outbox events

The change SHALL ensure the journal-posting events are emitted into `public.events` in the same transaction as their mutation. `SaleConfirmed` (C-29), `PurchaseCreated`, `PaymentReceived` (C-30), and `PaymentMade` (C-30) producers already exist and SHALL NOT be re-created. The change SHALL add a `SaleOperationCreated` producer to `rpc_create_sale_operation_v2`, the live path of the sale form, which until now emitted no event at all and therefore produced no accounting entry for the majority of the application's sales. The producer SHALL emit the event after the cash, current-account and bank effects of the same transaction, SHALL stamp `aggregate_type = 'SaleOperation'` and `aggregate_id = operation_id`, and SHALL carry `account_id`, `operation_id`, the canonical `total`, the sale date used as the accounting date, the client reference, and the payment-method `kind` derived server-side from the imputed payment method. The emitted `payment_method` SHALL be the raw derived `kind`, with no `COALESCE` to a default: the payload SHALL report what happened, and any presumption for an unimputed method SHALL live in the consumer branch, because emitting a fixed literal misstates every operation that was in fact settled otherwise. The producer SHALL be a plain `INSERT` with no exception handler: swallowing a failed event insert while the sale commits would reproduce, silently and irrecoverably, the very defect this producer exists to fix.

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

### Requirement: El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate

El conjunto de tipos de evento que producen asiento contable SHALL estar declarado en **dos** lugares —el filtro del despachador del relay y el filtro del propio helper de posteo— y los dos SHALL enumerar **exactamente el mismo conjunto**.

Este invariante SHALL verificarse con un **gate automático** que extraiga los dos conjuntos de las definiciones vigentes en la base de datos y los compare, y SHALL NOT quedar sostenido únicamente por un comentario en el código. Una divergencia entre los dos filtros produce un evento que nunca postea su asiento —o que el despachador enruta hacia un helper que lo ignora— **sin levantar ningún error**: el modo de falla no es detectable por observación casual y ya se materializó otras veces en el sistema.

El conjunto canónico SHALL constar de once tipos: `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PaymentReceivedReversed` y `PaymentMadeReversed`. Esta enumeración SHALL prevalecer sobre cualquier enumeración anterior más corta que aparezca en otros requirements de este mismo capability, que quedaron desactualizadas al incorporarse las ramas de borrado.

#### Scenario: Los dos filtros enumeran el mismo conjunto

- **WHEN** corre el gate del invariante sobre las definiciones vigentes
- **THEN** el conjunto del filtro del despachador y el del helper de posteo son iguales
- **AND** ambos contienen los once tipos canónicos

#### Scenario: Una divergencia introducida rompe el gate

- **GIVEN** un tipo agregado a uno solo de los dos filtros
- **WHEN** corre el gate
- **THEN** falla, nombrando el tipo que sobra o falta y en cuál de los dos filtros

#### Scenario: Un evento fuera del conjunto no postea asiento

- **WHEN** el relay procesa un evento de un tipo que no está en el conjunto canónico
- **THEN** el consumidor contable es un no-op para ese evento y el resto de los consumidores corre normalmente

### Requirement: La anulación de un cobro y la de un pago emiten su evento en la misma transacción que las compensaciones

El sistema SHALL emitir los eventos `PaymentReceivedReversed` y `PaymentMadeReversed` hacia el outbox **dentro de la misma transacción** que registra los contra-movimientos de cuenta corriente, caja y banco y que borra el documento del pago. La emisión SHALL ser un `INSERT` plano, sin manejador de excepciones: tragarse un evento fallido mientras la anulación commitea dejaría los libros de dinero compensados y el libro diario no, en silencio y de forma irrecuperable.

El payload SHALL llevar la cuenta, el identificador del pago anulado, el identificador de la cuenta corriente de la parte, el importe, el motivo cuando se informó, y el momento de la anulación — todo lo que el consumidor contable necesita para localizar el asiento vigente y revertirlo sin volver a consultar el documento, que ya no existe.

#### Scenario: El evento de anulación acompaña a las compensaciones

- **WHEN** se anula un cobro y la operación commitea
- **THEN** existe un evento `PaymentReceivedReversed` en el outbox, escrito en la misma transacción que los contra-movimientos

#### Scenario: El evento se revierte con una anulación fallida

- **WHEN** una anulación falla y revierte
- **THEN** no queda ningún evento de anulación en el outbox

#### Scenario: El payload basta para revertir el asiento

- **WHEN** el consumidor contable procesa un evento de anulación
- **THEN** encuentra en el payload el identificador del pago y la cuenta, y con ellos localiza el asiento vigente
- **AND** no necesita consultar el documento del pago, que ya fue borrado

