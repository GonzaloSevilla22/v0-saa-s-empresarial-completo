## MODIFIED Requirements

### Requirement: A subscription charge's payment notification is acknowledged, not rejected

MercadoPago sends two notifications for every subscription charge: `subscription_authorized_payment` (which credits the money — see the `subscription-lifecycle` capability) and a `payment` notification for the same charge. The latter never carries an `external_reference` in the `"<userId>::<plan>"` format the one-shot checkout uses, so the endpoint SHALL NOT reject it with the generic invalid-`external_reference` error — MercadoPago retries a rejected notification indefinitely, and a case that will never resolve produces indefinite retries.

The endpoint SHALL recognise a subscription charge from fields the MercadoPago payment API exposes for that purpose — `operation_type: "recurring_payment"`, `point_of_interaction.type: "SUBSCRIPTIONS"`, or a non-empty `metadata.preapproval_id` — and respond with a success status distinguishable from ordinary processing.

Because MercadoPago does not guarantee the `subscription_authorized_payment` notification for a processed charge (production case: November 2026 charge, payment `187789722328`, never notified as `processed`), when the payment carries a non-empty `metadata.preapproval_id` that identifies a known subscription assigned to an account, the endpoint SHALL reconcile that subscription's charges through the same shared reconciliation used by the admin replay and the scheduled sweep (see `subscription-lifecycle`), and respond with `{"ok": true, "reconciled": "subscription_charge"}`. In every other subscription-charge case (another marker, unknown preapproval, or a subscription without an account) the endpoint SHALL respond with `{"ok": true, "ignored": "subscription_charge"}` without writing to the database, leaving the charge to the scheduled sweep or the manual queue.

The decision SHALL be logged at a level that the production log pipeline retains, naming the marker that matched, the preapproval resolved (or none) and the outcome, and carrying no payer data.

A non-empty, malformed `external_reference` that carries none of those markers SHALL still be rejected exactly as before: the exemption from the `external_reference` check is scoped to subscription charges the endpoint can positively identify, plus the single case of an absent/empty `external_reference`, which is acknowledged rather than retried forever; never a blanket exemption for a malformed non-empty reference.

#### Scenario: A subscription charge's payment notification without a known preapproval is ignored, not rejected

- **WHEN** a `payment` notification arrives for an approved payment whose `external_reference` is missing or does not match the one-shot format
- **AND** the payment reports `operation_type: "recurring_payment"`, or `point_of_interaction.type: "SUBSCRIPTIONS"`, or a non-empty `metadata.preapproval_id`
- **AND** no subscription assigned to an account matches its `metadata.preapproval_id` (absent, unknown, or without account)
- **THEN** the endpoint returns HTTP 200 with `{"ok": true, "ignored": "subscription_charge"}`
- **AND** no database write occurs

#### Scenario: A subscription charge's payment notification with a known preapproval reconciles the subscription

- **GIVEN** an authorized subscription assigned to an account, whose current monthly charge MercadoPago already processed and approved but never notified as `processed`
- **WHEN** a `payment` notification arrives for that approved charge carrying `metadata.preapproval_id` of that subscription
- **THEN** the subscription's approved charges are reconciled through the shared reconciliation, crediting the new charge exactly once
- **AND** the endpoint returns HTTP 200 with `{"ok": true, "reconciled": "subscription_charge"}`

#### Scenario: A late cuota notification after reconciliation is a no-op on money

- **GIVEN** a charge already credited by reconciliation
- **WHEN** the `subscription_authorized_payment` notification for that charge arrives later as `processed`/`approved`
- **THEN** no second billing event is recorded, no second renewal email is queued, and the paid period is not extended again

#### Scenario: MercadoPago failure during reconciliation is retried by MercadoPago

- **WHEN** the reconciliation triggered by a `payment` notification cannot reach the MercadoPago API
- **THEN** the endpoint returns HTTP 502 and writes nothing, so MercadoPago redelivers the notification

#### Scenario: An invalid external_reference without a subscription marker is still rejected

- **WHEN** a `payment` notification arrives for an approved payment whose `external_reference` is non-empty and malformed
- **AND** none of the subscription-charge markers are present
- **THEN** the endpoint returns HTTP 400 with `{"ok": false, "error": "external_reference inválido"}`, exactly as it did before this capability

#### Scenario: An empty external_reference without a subscription marker is acknowledged

- **WHEN** a `payment` notification arrives for an approved payment whose `external_reference` is missing, null, or empty
- **AND** none of the subscription-charge markers are present
- **THEN** the endpoint returns HTTP 200 with `{"ok": true, "ignored": "no_external_reference"}`
- **AND** a single diagnostic warning is logged, carrying no payer data
- **AND** no database write occurs

#### Scenario: A valid external_reference is processed normally even if a marker is present

- **WHEN** a `payment` notification carries a valid `"<userId>::<plan>"` external_reference
- **THEN** the endpoint applies the plan upgrade as usual, regardless of any subscription-charge marker present in the payload

## ADDED Requirements

### Requirement: The subscription reconciliation sweep is a machine endpoint authenticated by shared secret

The backend SHALL expose `POST /payments/subscriptions/reconcile-cron` for the scheduled reconciliation sweep. It SHALL authenticate only with `Authorization: Bearer <secret>` compared in constant time against the configured relay secret, and SHALL fail closed: if the secret is not configured, or the header is missing or wrong, it SHALL respond HTTP 401 without touching MercadoPago or the database. It SHALL use the service database context, as the webhook does. The shared-secret check SHALL be a single reusable dependency, also used by the existing fiscal relay cron endpoint.

When the subscription billing switch is off, the endpoint SHALL respond HTTP 200 with `{"ok": true, "skipped": true}` without querying anything.

#### Scenario: Missing or wrong secret is rejected

- **WHEN** the endpoint is called without the `Authorization` header, with a wrong secret, or while no secret is configured
- **THEN** it returns HTTP 401 and performs no MercadoPago call and no database write

#### Scenario: Valid secret runs the sweep

- **WHEN** the endpoint is called with the configured secret and subscription billing enabled
- **THEN** it runs the reconciliation sweep and returns HTTP 200 summarising how many subscriptions were checked, which charges were credited and how many subscriptions failed

#### Scenario: Billing switch off

- **WHEN** the endpoint is called with the configured secret while subscription billing is disabled
- **THEN** it returns HTTP 200 with `{"ok": true, "skipped": true}` and performs no MercadoPago call

#### Scenario: The fiscal relay endpoint keeps its contract

- **WHEN** the fiscal relay cron endpoint is called with a missing, wrong or unconfigured secret
- **THEN** it still returns HTTP 401 exactly as before, now through the shared dependency
