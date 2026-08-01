## ADDED Requirements

### Requirement: The backend webhook is the sole system of record for payment accreditation

The endpoint `POST /payments/webhook` SHALL be the only component authorised to change an account's billing plan in response to a MercadoPago notification.

No other process — in particular no Next.js route handler — may write `accounts.billing_plan`, `accounts.billing_status` or `billing_events` as a result of a payment notification. This makes signature verification and idempotency single-sited: they are enforced exactly once, at this endpoint.

#### Scenario: Accreditation happens only in the backend

- **WHEN** MercadoPago notifies an approved payment through any entry path
- **THEN** the plan change and the `billing_events` row are written by `POST /payments/webhook`
- **AND** no other component writes those rows for that payment

#### Scenario: Relayed notification is processed identically to a direct one

- **GIVEN** a notification relayed by the legacy Next.js route with the original raw body and the `x-signature` / `x-request-id` headers preserved byte-for-byte
- **WHEN** it reaches `POST /payments/webhook`
- **THEN** signature verification succeeds exactly as it would for a direct notification
- **AND** the resulting database state is identical

#### Scenario: Relayed and direct delivery of the same payment collapse to one accreditation

- **GIVEN** the same `mercadopago_payment_id` arrives once relayed and once directly
- **WHEN** both are processed
- **THEN** exactly one `billing_events` row exists for that payment
- **AND** the second delivery returns HTTP 200 with `{"ok": true, "idempotent": true}`

### Requirement: Notification origin is observable

The endpoint SHALL record enough information to distinguish, for every processed notification, whether it arrived directly from MercadoPago or was relayed by the legacy frontend route.

This observability is what allows the coexistence window to be closed on evidence rather than on a fixed date.

#### Scenario: Direct notification is traced as direct

- **WHEN** MercadoPago posts a notification straight to `POST /payments/webhook`
- **THEN** the log entry for that notification identifies the origin as direct

#### Scenario: Relayed notification is traced as relayed

- **WHEN** the legacy route relays a notification to `POST /payments/webhook`
- **THEN** the log entry for that notification identifies the origin as relayed

### Requirement: Misconfigured webhook secret fails closed and is diagnosable

The endpoint SHALL reject every notification when `MERCADOPAGO_WEBHOOK_SECRET` is absent or does not match the secret configured in the MercadoPago panel, and SHALL log the rejection distinctly enough to tell a configuration fault apart from a forged request.

A silent mismatch is indistinguishable from the H-02 bug itself — money captured, plan not credited — so it must be loud in the logs.

#### Scenario: Missing secret rejects and logs a configuration fault

- **GIVEN** `MERCADOPAGO_WEBHOOK_SECRET` is unset in the backend environment
- **WHEN** any notification arrives
- **THEN** the endpoint rejects it without touching the database
- **AND** logs the cause as missing configuration, not as an invalid signature

#### Scenario: Secret value is never emitted

- **WHEN** the endpoint logs a signature rejection for any reason
- **THEN** the log contains neither the configured secret nor the received signature value
