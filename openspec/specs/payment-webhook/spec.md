# Spec: payment-webhook

## Overview

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

---

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

---

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

---

### Requirement: Service-role DB access for webhook

The payment webhook endpoint SHALL use the Supabase service_role key to access the database, as MercadoPago notifications are server-to-server and carry no user JWT.

#### Scenario: Webhook accesses DB without user context

- **WHEN** MercadoPago sends a webhook notification
- **THEN** the endpoint connects to Supabase using the pool regular (usuario postgres con BYPASSRLS)
- **AND** NOT using any user JWT or asyncpg JWT-passthrough pool

---

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
