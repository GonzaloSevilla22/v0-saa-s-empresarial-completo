## ADDED Requirements

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
