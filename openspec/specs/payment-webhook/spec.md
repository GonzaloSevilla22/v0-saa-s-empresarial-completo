# payment-webhook — Spec

## Purpose

Endpoint FastAPI `POST /payments/webhook` que recibe notificaciones de pago de MercadoPago, verifica la firma HMAC-SHA256, consulta la API de MP para obtener detalles del pago y actualiza el plan de la cuenta en la base de datos.

## Requirements

### Requirement: Verify MercadoPago webhook signature

The endpoint `POST /payments/webhook` SHALL verify the HMAC-SHA256 signature sent by MercadoPago before processing any payment notification.

Signed template: `id:<notification_data_id>;request-id:<x-request-id>;ts:<ts>;`
Secret: `MERCADOPAGO_WEBHOOK_SECRET` environment variable.
Comparison: constant-time (`hmac.compare_digest`).

#### Scenario: Valid signature is accepted

- **WHEN** MercadoPago sends a notification with a valid `x-signature` and `x-request-id` header
- **THEN** the endpoint returns HTTP 200 and proceeds to process the payment

#### Scenario: Invalid signature is rejected

- **WHEN** MercadoPago sends a notification with an invalid or missing `x-signature`
- **THEN** the endpoint returns HTTP 400 with `{"ok": false, "error": "Firma inválida"}`
- **AND** no database write occurs

#### Scenario: Missing webhook secret

- **WHEN** `MERCADOPAGO_WEBHOOK_SECRET` is not set in the environment
- **THEN** the endpoint returns HTTP 400 and logs a configuration error

### Requirement: Process payment notification with idempotency

The endpoint SHALL fetch payment details from MercadoPago API and update the organization plan only when the payment is approved and has not been processed before.

#### Scenario: Approved payment processed for the first time

- **WHEN** a payment notification arrives with `type: "payment"` and the payment has `status: "approved"`
- **AND** no `billing_events` row exists with the same `mercadopago_payment_id`
- **THEN** the endpoint updates `accounts.billing_plan`, `billing_status`, and `plan_expires_at`
- **AND** inserts a row into `billing_events` with `event_type: "plan_upgraded"`
- **AND** inserts a row into `email_logs` with `event_type: "plan_upgraded"`
- **AND** returns HTTP 200 with `{"ok": true}`

#### Scenario: Duplicate payment notification (idempotent)

- **WHEN** a payment notification arrives for a `mercadopago_payment_id` that already exists in `billing_events`
- **THEN** the endpoint returns HTTP 200 with `{"ok": true, "idempotent": true}`
- **AND** no database write occurs

#### Scenario: Payment not approved

- **WHEN** the MercadoPago payment has a status other than `"approved"` (e.g., `"pending"`, `"rejected"`)
- **THEN** the endpoint returns HTTP 200 with `{"ok": true, "status": "<status>"}`
- **AND** no database write occurs

#### Scenario: Non-payment notification type

- **WHEN** the notification type is not `"payment"` (e.g., `"merchant_order"`)
- **THEN** the endpoint returns HTTP 200 with `{"ok": true, "skipped": true}`

#### Scenario: Payment not found in MP API (test ID or deleted)

- **WHEN** the MercadoPago API returns 404 for the given payment ID
- **THEN** the endpoint returns HTTP 200 with `{"ok": true, "skipped": true}`
- **AND** no database write occurs

### Requirement: Shadow mode for safe migration

The endpoint SHALL support a `?shadow=true` query parameter that runs all validation and lookup logic without writing to the database.

#### Scenario: Shadow mode active — no database writes

- **WHEN** the request includes `?shadow=true`
- **AND** the signature is valid
- **AND** the payment would normally trigger a plan upgrade
- **THEN** the endpoint executes validation and DB lookup but performs no UPDATE or INSERT
- **AND** logs the expected result as `{"shadow": true, "would_upgrade": {"user_id": ..., "to_plan": ...}}`
- **AND** returns HTTP 200 with `{"ok": true, "shadow": true}`

#### Scenario: Shadow mode — signature still enforced

- **WHEN** the request includes `?shadow=true` but has an invalid signature
- **THEN** the endpoint returns HTTP 400 regardless of shadow mode

### Requirement: Service-role DB access for webhook

The payment webhook endpoint SHALL use the Supabase service_role key to access the database, as MercadoPago notifications are server-to-server and carry no user JWT.

#### Scenario: Webhook accesses DB without user context

- **WHEN** MercadoPago sends a webhook notification
- **THEN** the endpoint connects to Supabase using the pool regular (usuario postgres con BYPASSRLS)
- **AND** NOT using any user JWT or asyncpg JWT-passthrough pool

### Requirement: external_reference decoding

The endpoint SHALL parse `external_reference` from the MercadoPago payment in the format `"<userId>::<plan>"` to identify the user and target plan.

#### Scenario: Valid external_reference

- **WHEN** the payment has `external_reference: "abc123::avanzado"`
- **THEN** the endpoint resolves `userId = "abc123"` and `plan = "avanzado"`
- **AND** applies the plan upgrade to the account associated with that user

#### Scenario: Invalid external_reference format

- **WHEN** `external_reference` is missing, null, or does not contain `::`
- **THEN** the endpoint returns HTTP 400 with `{"ok": false, "error": "external_reference inválido"}`
- **AND** no database write occurs

### Requirement: The signed manifest derives its id from the notification query string, lowercased

The endpoint SHALL build the HMAC manifest using the `data.id` value supplied as a **query parameter** on the notification URL, lowercasing it when it is alphanumeric, and SHALL fall back to the body's `data.id` only when the query parameter is absent.

This is not a cosmetic alignment with the provider's documentation. Payment identifiers are numeric, so reading them from the body and skipping normalisation happens to produce the same manifest. **Subscription identifiers are alphanumeric**: for `subscription_preapproval` and `subscription_authorized_payment` notifications the current derivation yields a different manifest than MercadoPago signed, and every such notification is rejected as forged.

#### Scenario: Alphanumeric identifier is lowercased before signing

- **WHEN** a notification arrives whose `data.id` query parameter contains uppercase alphanumeric characters
- **THEN** the manifest is built from the lowercased value
- **AND** a signature generated by MercadoPago for that notification verifies successfully

#### Scenario: Subscription notification passes signature verification

- **WHEN** a `subscription_preapproval` or `subscription_authorized_payment` notification arrives with a valid signature
- **THEN** the endpoint accepts it and proceeds to process it

#### Scenario: Numeric payment identifiers keep verifying as before

- **WHEN** a `payment` notification arrives with a valid signature
- **THEN** verification succeeds exactly as it did before this change

#### Scenario: Body is used only as a fallback

- **GIVEN** a notification delivered without a `data.id` query parameter
- **WHEN** the endpoint verifies the signature
- **THEN** it derives the manifest identifier from the body, applying the same lowercasing rule

#### Scenario: A forged subscription notification is still rejected

- **WHEN** a subscription notification arrives with a signature that does not match the manifest
- **THEN** the endpoint rejects it and no subscription or account state changes

### Requirement: Subscription state notifications are processed

The endpoint SHALL process `subscription_preapproval` notifications by fetching the subscription from MercadoPago and reconciling the locally stored state, plan and next charge date against it.

MercadoPago is the authority on subscription state. The endpoint SHALL apply what the provider reports rather than deriving state from the notification's action name alone.

#### Scenario: Authorisation activates the subscription

- **WHEN** a `subscription_preapproval` notification arrives for a subscription MercadoPago reports as authorised
- **THEN** the stored subscription becomes authorised and its next charge date is recorded

#### Scenario: Cancellation is reflected locally

- **WHEN** a `subscription_preapproval` notification arrives for a subscription MercadoPago reports as cancelled
- **THEN** the stored subscription becomes cancelled and the account is scheduled to downgrade at the end of its paid period

#### Scenario: Notification for an unknown subscription is not fatal

- **WHEN** a subscription notification arrives whose identifier matches no stored subscription
- **THEN** the endpoint returns a success status without creating account state, and logs the orphan for reconciliation

### Requirement: Authorized payment notifications are processed with idempotency

The endpoint SHALL process `subscription_authorized_payment` notifications by fetching the authorized payment from MercadoPago and applying its outcome — approved, rejected or being retried — to the subscription and to the account's paid period.

Each notification SHALL be claimed exactly once through the platform's existing idempotency mechanism, so that a redelivery of the same charge attempt neither extends the paid period twice nor sends a duplicate dunning notice.

#### Scenario: Approved charge extends the paid period once

- **WHEN** an authorized payment notification reports an approved charge
- **THEN** the account's paid period is extended and the charge is audited

#### Scenario: Redelivered notification is a no-op

- **GIVEN** an authorized payment notification already processed
- **WHEN** the same notification is delivered again
- **THEN** no further state change occurs and the endpoint returns a success status

#### Scenario: Rejected charge triggers dunning without downgrading

- **WHEN** an authorized payment notification reports a rejected charge that will be retried
- **THEN** the dunning notice is emitted and the account's plan and paid period are left unchanged

#### Scenario: Distinct retry attempts are processed independently

- **GIVEN** a charge that was rejected and is retried
- **WHEN** the notification for the later attempt arrives
- **THEN** it is processed on its own merits rather than skipped as a duplicate of the earlier attempt

### Requirement: Unknown notification topics are acknowledged and ignored

The endpoint SHALL return a success status without side effects for notification topics it does not handle.

MercadoPago retries notifications that are not acknowledged. Responding with an error to a topic the system deliberately ignores would produce indefinite retries of traffic that will never be processed.

#### Scenario: Unhandled topic is acknowledged

- **WHEN** a notification arrives with a topic the system does not handle
- **THEN** the endpoint returns a success status and performs no writes

#### Scenario: Handled topics are unaffected

- **WHEN** a notification arrives with a handled topic
- **THEN** it is processed normally
