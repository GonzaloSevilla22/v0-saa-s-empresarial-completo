## ADDED Requirements

### Requirement: Crear preferencia de pago MercadoPago

El sistema SHALL crear una preferencia de pago en MercadoPago via API route server-side cuando el usuario inicia el flujo de upgrade, retornando una URL de Checkout Pro.

#### Scenario: Preferencia creada exitosamente
- **WHEN** un usuario autenticado hace POST a `/api/billing/preferences` con `{ plan: 'avanzado' }`
- **THEN** el servidor crea una preferencia en la API de MP con el precio del plan en ARS, URLs de back_urls (success/failure/pending), y retorna `{ preferenceId, initPoint }` con status 200

#### Scenario: Plan inválido rechazado
- **WHEN** se envía un plan que no existe en `plan_limits` (ej: `{ plan: 'enterprise' }`)
- **THEN** la API route retorna status 400 con mensaje de error

#### Scenario: Usuario no autenticado bloqueado
- **WHEN** un request sin JWT válido llega a `/api/billing/preferences`
- **THEN** la API route retorna status 401

#### Scenario: Downgrade a plan gratis no requiere pago
- **WHEN** el usuario quiere bajar a `gratis`
- **THEN** no se crea preferencia; se gestiona via `/api/billing/cancel` sin pago

### Requirement: Verificar y procesar webhook de pago

El sistema SHALL recibir notificaciones de MercadoPago en `/api/billing/webhook`, verificar la firma HMAC-SHA256, y actualizar el plan del usuario solo si el pago fue aprobado.

#### Scenario: Pago aprobado actualiza el plan
- **GIVEN** un webhook de MP con `status: 'approved'` y firma válida
- **WHEN** llega a `/api/billing/webhook`
- **THEN** se actualiza `organizations.plan` al plan comprado, se inserta en `billing_events` con `event_type='payment_received'` y `mercadopago_payment_id`, y se retorna HTTP 200

#### Scenario: Firma inválida rechazada
- **GIVEN** un webhook con header `x-signature` que no coincide con `MERCADOPAGO_WEBHOOK_SECRET`
- **WHEN** llega a `/api/billing/webhook`
- **THEN** el servidor retorna HTTP 401 y NO modifica ningún dato

#### Scenario: Pago duplicado ignorado (idempotencia)
- **GIVEN** un `mercadopago_payment_id` que ya existe en `billing_events`
- **WHEN** llega el mismo webhook por segunda vez
- **THEN** el servidor retorna HTTP 200 sin modificar datos (idempotente)

#### Scenario: Pago rechazado o pendiente no cambia el plan
- **GIVEN** un webhook de MP con `status: 'rejected'` o `status: 'pending'`
- **WHEN** llega a `/api/billing/webhook`
- **THEN** se inserta en `billing_events` con `event_type='payment_failed'` pero `organizations.plan` no cambia

### Requirement: Cancelación de suscripción con degradación diferida

El sistema SHALL procesar una solicitud de cancelación degradando el plan al `gratis` al vencimiento del período pagado (no inmediatamente).

#### Scenario: Cancelación programada
- **WHEN** el usuario confirma la cancelación en `/facturacion`
- **THEN** `organizations.plan_expires_at` se setea a la fecha de vencimiento del período actual, se inserta en `billing_events` con `event_type='cancellation_requested'`, y el plan actual sigue activo hasta esa fecha

#### Scenario: Downgrade al vencer el período
- **GIVEN** un perfil con `plan_expires_at < NOW()` y `billing_status` indicando cancelación programada
- **WHEN** corre el barrido diario de downgrade
- **THEN** `organizations.plan` pasa a `'gratis'`, `billing_status = 'cancelled'`, INSERT en `billing_events` con `event_type='plan_downgraded'`

### Requirement: Email transaccional post-pago

El sistema SHALL encolar emails de confirmación de upgrade y downgrade via el patrón `email_logs` sin envío sincrónico.

#### Scenario: Email de upgrade encolado
- **WHEN** el webhook procesa un pago aprobado y actualiza el plan
- **THEN** se inserta en `email_logs` con `event_type='plan_upgraded'`, `recipient=email_del_usuario`, `metadata={from_plan, to_plan, amount}`

#### Scenario: Email de downgrade encolado
- **WHEN** se ejecuta el downgrade (ya sea por vencimiento o cancelación)
- **THEN** se inserta en `email_logs` con `event_type='plan_downgraded'`, `recipient=email_del_usuario`
