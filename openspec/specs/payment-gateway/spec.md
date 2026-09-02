# payment-gateway Specification

## Purpose
Integración con MercadoPago Checkout Pro para el flujo de upgrade de plan — creación de preferencias, verificación de webhooks HMAC-SHA256 con idempotencia, y cancelación con degradación diferida. Implementado en C-10.

## Requirements

### Requirement: Crear preferencia de pago MercadoPago (fallback en retirada)

El sistema SHALL crear una preferencia de pago en MercadoPago via API route server-side cuando el usuario inicia el flujo de upgrade por este camino de fallback, retornando una URL de Checkout Pro.

> **Nota (archivado `mp-real-subscriptions`, 2026-09-02)**: la contratación de un plan pago dejó de crear preferencias de pago único — el camino primario es ahora la suscripción recurrente descrita en el requirement *"El upgrade a un tier pago crea una suscripción recurrente"*, más abajo. Este endpoint se mantiene deliberadamente **sin retirar** como fallback mientras la migración completa a suscripciones termina de verificarse en producción (tarea 9.6 del change archivado — MANUAL PO, pendiente al momento de este archive); retirarlo antes rompería el único camino de pago que existiera si la palanca de suscripciones se apagara. Los escenarios de este requirement documentan ese fallback, no el flujo por defecto.

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

### Requirement: El upgrade a un tier pago crea una suscripción recurrente

El sistema SHALL iniciar el upgrade creando una suscripción recurrente en MercadoPago, y NOT SHALL crear preferencias de pago único para contratar un plan.

La creación SHALL ocurrir en el backend, porque requiere persistir el identificador de la suscripción para poder atribuir los cobros mensuales posteriores. El usuario SHALL ser redirigido a la URL de autorización devuelta por MercadoPago.

#### Scenario: Upgrade devuelve una URL de autorización de suscripción
- **WHEN** un usuario autenticado inicia el upgrade a un tier pago
- **THEN** el backend crea la suscripción, la persiste y devuelve la URL donde el usuario autoriza el débito recurrente

#### Scenario: No se crean pagos únicos para contratar un plan
- **WHEN** se inicia cualquier upgrade a un tier pago
- **THEN** no se crea ninguna preferencia de Checkout Pro de pago único

#### Scenario: Usuario no autenticado bloqueado
- **WHEN** llega una solicitud de alta de suscripción sin credenciales válidas
- **THEN** se rechaza con 401 y no se crea nada en MercadoPago

#### Scenario: Tier inválido rechazado
- **WHEN** se solicita el upgrade a un tier que no existe en `plan_limits` o que no tiene plan de suscripción registrado
- **THEN** se rechaza con un error explícito y no se crea ninguna suscripción

#### Scenario: Bajar a gratis no crea suscripción
- **WHEN** el usuario quiere pasar a `gratis`
- **THEN** no se crea ninguna suscripción; se gestiona por el camino de baja

### Requirement: Verificar y procesar webhook de pago

El sistema SHALL recibir notificaciones de MercadoPago en `/api/billing/webhook`, verificar la firma HMAC-SHA256, y actualizar el plan del usuario solo si el pago fue aprobado.

#### Scenario: Pago aprobado actualiza el plan
- **GIVEN** un webhook de MP con `status: 'approved'` y firma válida
- **WHEN** llega a `/api/billing/webhook`
- **THEN** se actualiza `accounts.billing_plan` al plan comprado, se inserta en `billing_events` con `event_type='plan_upgraded'` y `mercadopago_payment_id`, y se retorna HTTP 200

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
- **THEN** se inserta en `billing_events` con `event_type='payment_failed'` pero `accounts.billing_plan` no cambia

### Requirement: Cancelación de suscripción con degradación diferida

El sistema SHALL cancelar la suscripción en MercadoPago al recibir una solicitud de baja, y SHALL degradar el plan a `gratis` recién al vencimiento del período efectivamente pagado, no inmediatamente.

La fecha de degradación SHALL derivarse del período que la suscripción tiene realmente pagado, y NOT SHALL ser un plazo fijo estimado por el sistema.

#### Scenario: Cancelación programada
- **WHEN** el usuario confirma la cancelación en `/facturacion`
- **THEN** la suscripción queda cancelada en MercadoPago, `accounts.plan_expires_at` refleja el fin del período pagado, se inserta en `billing_events` con `event_type='cancellation_requested'`, y el plan actual sigue activo hasta esa fecha

#### Scenario: La fecha de degradación no es un plazo inventado
- **WHEN** se programa una cancelación
- **THEN** la fecha proviene del ciclo de la suscripción y no de un intervalo fijo aplicado desde el momento de cancelar

#### Scenario: Downgrade al vencer el período
- **GIVEN** una cuenta con `plan_expires_at < NOW()` y `billing_status = 'cancelling'`
- **WHEN** corre el barrido diario `process_cancellations()`
- **THEN** `accounts.billing_plan` pasa a `'gratis'`, `billing_status = 'cancelled'`, INSERT en `billing_events` con `event_type='plan_cancelled'`

#### Scenario: Fallo al cancelar en MercadoPago no deja estado inconsistente
- **GIVEN** que la cancelación en MercadoPago no puede completarse
- **WHEN** el usuario solicita la baja
- **THEN** la operación falla con un error explícito y la cuenta no queda marcada como cancelada localmente

### Requirement: Email transaccional post-pago

El sistema SHALL encolar via el patrón `email_logs`, sin envío sincrónico, los correos correspondientes a los hitos del ciclo de facturación: alta de plan, renovación mensual, cobro fallido, vencimiento próximo y baja.

Cada correo encolado SHALL incluir en su metadata un dato que lo haga único frente al hito que lo originó. La restricción de unicidad de `email_logs` sobre `(user_id, event_type, metadata)` descarta silenciosamente un segundo correo con metadata idéntica: sin ese discriminador, el aviso del segundo cobro fallido de una cuenta nunca se enviaría.

#### Scenario: Email de upgrade encolado
- **WHEN** se acredita el alta de un plan pago
- **THEN** se inserta en `email_logs` con `event_type='plan_upgraded'`, `recipient=email_del_usuario`, `metadata={plan, amount, activated_at}`

#### Scenario: Email de downgrade encolado
- **WHEN** se ejecuta el downgrade (ya sea por vencimiento o cancelación)
- **THEN** se inserta en `email_logs` con `event_type='plan_downgraded'`, `recipient=email_del_usuario`

#### Scenario: Email de cobro fallido encolado
- **WHEN** un cobro mensual de la suscripción resulta rechazado
- **THEN** se inserta en `email_logs` con un `event_type` propio de cobro fallido y metadata que identifica el cobro concreto

#### Scenario: Dos cobros fallidos distintos generan dos correos
- **GIVEN** una cuenta que ya recibió un aviso de cobro fallido
- **WHEN** falla un cobro posterior distinto del anterior
- **THEN** se encola un segundo correo y no queda descartado por la restricción de unicidad

#### Scenario: Los tipos nuevos tienen plantilla propia
- **WHEN** se envía un correo de cualquiera de los tipos nuevos del ciclo de suscripción
- **THEN** el contenido corresponde a ese hito y no al texto genérico de respaldo
