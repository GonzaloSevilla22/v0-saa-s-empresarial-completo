# In-App Notifications Specification

## Purpose

Provides an ephemeral, real-time read model for in-app notifications delivered via Supabase Realtime. Notifications are created by the transactional outbox relay (Consumer 4) from domain events, scoped by `account_id` and `audience` (user list), stored in `public.notifications`, and consumed by the frontend bell via RLS-guarded Realtime subscriptions and mark-as-read mutations.

---
## Requirements
### Requirement: Notifications read-model schema

The system SHALL provide a `public.notifications` table as an ephemeral read model for the in-app notification bell, distinct from `sale_notifications` (customer-facing WhatsApp/email log). It SHALL carry `id uuid PK`, `account_id uuid NOT NULL` (FK `accounts`), `branch_id uuid NULL` (FK `branches`), `type text NOT NULL`, `severity text NOT NULL CHECK (severity IN ('info','warning','urgent'))`, `payload jsonb NOT NULL DEFAULT '{}'`, `audience uuid[] NOT NULL` (the user ids that should receive the notification), `read boolean NOT NULL DEFAULT false`, `created_at timestamptz NOT NULL DEFAULT now()`, and `read_at timestamptz NULL`. It SHALL be written only by the outbox relay (Consumer 4); no `INSERT` policy is granted to `authenticated`.

#### Scenario: Notification row carries audience and account scope

- **WHEN** the relay creates a notification for an in-scope event
- **THEN** a `notifications` row exists with the event's `account_id`, a non-empty `audience uuid[]`, a `type`, a `severity` in `{info, warning, urgent}`, `read = false`, and `created_at` stamped

#### Scenario: Notifications table is not sale_notifications

- **WHEN** a domain event is processed
- **THEN** the row is written to `public.notifications` and `public.sale_notifications` is never touched by this capability

### Requirement: Row Level Security by audience membership

The `notifications` table SHALL have RLS enabled. A `SELECT` policy `TO authenticated` SHALL return a row only when the current user belongs to the row's account (`account_id IN (SELECT current_account_ids())`) AND is a member of its audience (`(select auth.uid()) = ANY(audience)`), so a user never sees another user's or another account's notifications. There SHALL be no `INSERT` policy for `authenticated` (writes come only from the `SECURITY DEFINER` relay). A user SHALL be able to mark their own visible notifications as read, and only that.

#### Scenario: User sees only notifications addressed to them

- **WHEN** an authenticated user queries `notifications`
- **THEN** RLS returns only rows whose `account_id` is one of the user's accounts AND whose `audience` array contains the user's id, never rows addressed to other users or accounts

#### Scenario: User cannot insert a notification directly

- **WHEN** an authenticated user attempts `INSERT INTO notifications`
- **THEN** the statement is rejected because no `INSERT` policy grants it — only the relay's `SECURITY DEFINER` path writes rows

#### Scenario: Marking read is constrained by USING and WITH CHECK

- **WHEN** an authenticated user updates a notification they can see to set `read = true`
- **THEN** the `UPDATE` policy's `USING` restricts it to rows in their audience/account and its `WITH CHECK` prevents changing `account_id`, `audience`, `type`, `severity`, or `payload` (only `read`/`read_at` may change), so a user can neither reassign a row nor mutate another user's notification

### Requirement: Mark-as-read semantics

A notification SHALL be marked read via an `UPDATE` (RLS-guarded) that sets `read = true` and `read_at = now()`. Marking read SHALL be idempotent: marking an already-read notification SHALL leave `read = true` and SHALL NOT change the original `read_at`. The unread count for the bell badge SHALL be derived from `read = false` rows visible to the user.

#### Scenario: Marking an unread notification sets read and read_at

- **WHEN** the user marks an unread notification as read
- **THEN** `read` becomes `true` and `read_at` is set to the current time

#### Scenario: Re-marking a read notification is a no-op on read_at

- **WHEN** the user marks a notification that is already `read = true`
- **THEN** `read` stays `true` and `read_at` retains its original value

### Requirement: Audience resolution by role

Each in-scope event type SHALL resolve its `audience uuid[]` inside the relay consumer (server-side), never in the client, by mapping the V3 functional target to the current `account_members` role model. Because today's catalog is binary (`owner`, `member`), the mapping SHALL be: admin / purchases-permission / urgent-fiscal targets → account `owner`s; branch-scoped targets (e.g. `TransferDispatched` to the destination branch) → members associated with that branch, falling back to account `owner`s when no per-branch membership exists. The mapping SHALL live in a single, isolated function so it can be widened to functional roles when `v3-rbac-multirole` extends the catalog, without changing the consumer's dispatch logic.

#### Scenario: Admin-targeted event resolves to account owners

- **WHEN** the relay processes a `CashSessionClosed` event with a non-zero difference
- **THEN** the resolved `audience` contains the account's `owner` user id(s) and the row's `severity` is at least `warning`

#### Scenario: Empty audience does not create a dangling notification

- **WHEN** audience resolution yields an empty set for an event (e.g. no eligible members)
- **THEN** the consumer does not insert a `notifications` row (nothing addressed to nobody), and the event is still marked processed by the relay

### Requirement: Retention and cleanup

The read model SHALL be bounded so it does not grow without limit. Read notifications older than a fixed TTL (30 days) SHALL be eligible for deletion, and a scheduled cleanup (pg_cron) SHALL remove them. Unread notifications SHALL NOT be auto-deleted by TTL. The bell dropdown query SHALL be paginated / limited (most recent first) so the client never loads the full history.

#### Scenario: Read notifications past TTL are purged

- **WHEN** the cleanup job runs and finds `read = true` notifications with `read_at` older than the TTL
- **THEN** those rows are deleted, while unread rows and read rows within the TTL remain

#### Scenario: Bell query is bounded

- **WHEN** the client loads the notification bell
- **THEN** it fetches at most the most-recent N notifications (ordered by `created_at DESC`) plus the unread count, never the entire table

### Requirement: Realtime delivery via Supabase postgres_changes

New notifications SHALL be delivered to the client in real time via a Supabase Realtime `postgres_changes` subscription on `public.notifications`, with the audience/account filter enforced by RLS on the Realtime path (the client SHALL NOT be trusted to filter). The `notifications` table SHALL be added to the `supabase_realtime` publication. The frontend subscription SHALL be the app's Supabase Realtime integration for the notification bell and SHALL update the unread badge without polling. The legacy `realtime-websocket` (custom WSManager) approach SHALL NOT be used.

#### Scenario: Inserted notification pushes to the addressed user only

- **WHEN** the relay inserts a notification whose audience includes user U, and U is subscribed
- **THEN** U's client receives the Realtime `INSERT` payload for that row and the unread badge increments, while a user not in the audience receives nothing (RLS filters the Realtime stream)

#### Scenario: No polling for the badge

- **WHEN** the bell is mounted and connected
- **THEN** the unread count updates from the Realtime stream (and on mount via one query), with no interval polling loop

### Requirement: Resynchronization on reconnect

On reconnection of the Realtime channel (or on tab refocus / mount), the client SHALL resynchronize by re-querying the current notifications and unread count, so notifications that arrived while disconnected are not missed (FS §9.6 resilience pattern). Delivery SHALL be at-least-once at the UI: a notification already present SHALL NOT be duplicated in the list after a resync.

#### Scenario: Missed notifications appear after reconnect

- **WHEN** the client loses the Realtime connection, notifications are created, and the client reconnects
- **THEN** the resync query returns the notifications created during the gap and the list reflects the correct unread count

#### Scenario: Resync does not duplicate existing rows

- **WHEN** a resync query returns notifications already shown from the Realtime stream
- **THEN** the client dedupes by notification `id` so each notification appears once

### Requirement: PlanLimitExceeded notification type

The relay's Consumer 4 SHALL dispatch a `PlanLimitExceeded` notification type. Its audience SHALL be the account's owners (`ADMIN` semantic target), its severity SHALL be `warning`, and its `payload` SHALL carry the exceeded `resource`, the account's `current` count, the effective `limit`, and the effective `plan`.

The type SHALL be added to the relay's in-scope event list without changing the signature of the dispatch helper, and SHALL be rendered by the notification bell with a human-readable label.

#### Scenario: Relay dispatches the plan overage notification

- **WHEN** a `PlanLimitExceeded` event is processed by the outbox relay
- **THEN** a `notifications` row is created with `type = 'PlanLimitExceeded'`, `severity = 'warning'`, the account's owners in `audience`, and a payload containing `resource`, `current`, `limit` and `plan`

#### Scenario: Events outside the in-scope list remain no-ops

- **WHEN** the relay processes an event type that is not in the in-scope list
- **THEN** no notification row is created and the previously supported types keep dispatching unchanged

#### Scenario: The bell renders a label for the new type

- **WHEN** a `PlanLimitExceeded` notification is displayed in the bell
- **THEN** it shows a human-readable label rather than the raw type identifier

### Requirement: Temporal deduplication of plan overage notices

The system SHALL emit at most one `PlanLimitExceeded` notification per `(account_id, resource)` within a 7-day window, so that a recurring detection sweep does not produce a daily notification for an account that stays over its limit.

#### Scenario: A repeated sweep does not duplicate the notice

- **GIVEN** an account that received a `PlanLimitExceeded` notification for `products` two days ago and is still over the limit
- **WHEN** the detection sweep runs again
- **THEN** no second notification for `products` is created for that account

#### Scenario: A different resource is notified independently

- **GIVEN** an account that received a `PlanLimitExceeded` notification for `products` two days ago and has just exceeded the client limit
- **WHEN** the detection sweep runs
- **THEN** a notification for `clients` is created

#### Scenario: The notice is emitted again after the window elapses

- **GIVEN** an account still over its product limit whose last `PlanLimitExceeded` notification for `products` is older than 7 days
- **WHEN** the detection sweep runs
- **THEN** a new notification for `products` is created

### Requirement: SubscriptionPaymentFailed notification type

The relay's Consumer 4 SHALL dispatch a `SubscriptionPaymentFailed` notification type. Its audience SHALL be the account's owners (`ADMIN` semantic target), its severity SHALL be `warning`, and its `payload` SHALL carry the affected `plan`, the charge `amount`, the retry attempt reported by the payment provider and, when known, the date of the next retry.

The type SHALL be added to the relay's in-scope event list without changing the signature of the dispatch helper, following the precedent set by `PlanLimitExceeded`, and SHALL be rendered by the notification bell with a human-readable label.

The notification SHALL NOT be branch-scoped: a failed subscription charge concerns the account as a whole.

#### Scenario: Relay dispatches the failed charge notification

- **WHEN** a `SubscriptionPaymentFailed` event is processed by the outbox relay
- **THEN** a `notifications` row is created with `type = 'SubscriptionPaymentFailed'`, `severity = 'warning'`, the account's owners in `audience`, a null branch, and a payload containing the plan, the amount and the retry attempt

#### Scenario: Existing types keep dispatching unchanged

- **WHEN** the relay processes any previously supported event type
- **THEN** it dispatches exactly as before the addition of the new type

#### Scenario: The bell renders a label for the new type

- **WHEN** a `SubscriptionPaymentFailed` notification is displayed in the bell
- **THEN** it shows a human-readable label rather than the raw type identifier

#### Scenario: Empty audience does not create a dangling notification

- **WHEN** audience resolution yields an empty set for a failed charge event
- **THEN** no `notifications` row is inserted and the event is still marked processed by the relay

### Requirement: Deduplication of failed charge notices per charge attempt

The system SHALL emit at most one `SubscriptionPaymentFailed` notification per charge attempt, so that a redelivered provider notification does not produce a duplicate notice, while a genuinely new retry attempt does produce its own.

Deduplication SHALL key on the charge attempt rather than on the account, because the retries of a single failed charge are distinct events that the account owner needs to see.

#### Scenario: A redelivered notification does not duplicate the notice

- **GIVEN** an account that already received a failed charge notice for a given charge attempt
- **WHEN** the provider redelivers the notification for that same attempt
- **THEN** no second notification is created

#### Scenario: A new retry attempt produces its own notice

- **GIVEN** an account that received a failed charge notice for the first attempt
- **WHEN** a later retry of that charge also fails
- **THEN** a notification for the new attempt is created

### Requirement: Tipos de notificación de resumen de deuda vencida

El Consumer 4 del relay SHALL despachar dos tipos de notificación nuevos —el resumen de deuda **por cobrar** vencida y el de deuda **por pagar** vencida—, cuya audiencia SHALL ser el target semántico de administración (los propietarios de la cuenta), cuya severidad SHALL ser `warning`, y cuyo `payload` SHALL llevar la cantidad de partes con deuda vencida, el importe total vencido y el día calendario argentino al que corresponde el resumen.

Ninguno de los dos tipos SHALL llevar sucursal: la cuenta corriente no referencia sucursal.

Los tipos SHALL incorporarse a la lista de eventos en alcance del helper de despacho **sin cambiar su firma**, y la campana de notificaciones SHALL renderizarlos con un rótulo legible en lugar del identificador crudo.

Ninguno de los dos tipos SHALL incorporarse al conjunto canónico de eventos que producen asiento contable: un vencimiento no mueve dinero y no tiene contrapartida contable. El conteo de ese conjunto canónico SHALL permanecer inalterado.

#### Scenario: El relay despacha el resumen de deuda por cobrar

- **WHEN** el relay procesa un evento de resumen de deuda por cobrar vencida
- **THEN** se crea una notificación con ese tipo, severidad `warning`, los propietarios de la cuenta como audiencia, sin sucursal, y un payload con la cantidad de deudores, el importe vencido y el día del resumen

#### Scenario: El relay despacha el resumen de deuda por pagar

- **WHEN** el relay procesa un evento de resumen de deuda por pagar vencida
- **THEN** se crea la notificación equivalente para el lado proveedor

#### Scenario: Los tipos previos siguen despachando igual

- **WHEN** el relay procesa cualquiera de los tipos de notificación que ya existían
- **THEN** su comportamiento no cambia, y los eventos fuera de la lista en alcance siguen siendo no-ops

#### Scenario: La campana muestra un rótulo legible

- **WHEN** una notificación de resumen de deuda vencida se muestra en la campana
- **THEN** se ve un rótulo legible en castellano y no el identificador del tipo

#### Scenario: El resumen no produce asiento contable

- **WHEN** el relay procesa un evento de resumen de deuda vencida
- **THEN** no se crea ningún asiento contable
- **AND** el conjunto canónico de tipos de evento que producen asiento sigue teniendo la misma cantidad de elementos que antes de este cambio

### Requirement: Deduplicación diaria del resumen de deuda vencida

El sistema SHALL emitir a lo sumo **un** resumen de deuda vencida por cuenta, por lado del circuito y por **día calendario argentino**, de modo que un barrido que vuelva a ejecutarse el mismo día no produzca un segundo aviso para la misma cuenta.

La deduplicación SHALL sostenerse **aunque los importes hayan cambiado** entre dos ejecuciones del mismo día: la unidad percibida por el usuario es el día, no la cifra.

La deduplicación SHALL cubrir con un mismo mecanismo los dos canales del aviso —la notificación y el correo—, de modo que no exista un estado en el que se envíe uno y no el otro.

#### Scenario: Una segunda corrida el mismo día no duplica

- **GIVEN** una cuenta que ya recibió hoy su resumen de deuda por cobrar vencida
- **WHEN** el barrido vuelve a ejecutarse el mismo día
- **THEN** no se crea ninguna notificación ni correo adicional para esa cuenta

#### Scenario: Un importe distinto el mismo día tampoco duplica

- **GIVEN** una cuenta que ya recibió hoy su resumen y desde entonces cobró parte de la deuda vencida
- **WHEN** el barrido vuelve a ejecutarse el mismo día
- **THEN** no se crea ningún aviso adicional

#### Scenario: Al día siguiente se emite de nuevo

- **GIVEN** una cuenta que recibió su resumen ayer y sigue con deuda vencida
- **WHEN** el barrido corre al día siguiente
- **THEN** se emite un resumen nuevo

#### Scenario: Los dos lados se deduplican por separado

- **GIVEN** una cuenta con deuda vencida por cobrar y por pagar
- **WHEN** corre el barrido
- **THEN** recibe un resumen de cada lado, y cada uno se deduplica de forma independiente

