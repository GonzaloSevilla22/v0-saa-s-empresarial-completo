## ADDED Requirements

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
