# payment-gateway Specification

## Purpose
Integración con MercadoPago Checkout Pro para el flujo de upgrade de plan — creación de preferencias, verificación de webhooks HMAC-SHA256 con idempotencia, y cancelación con degradación diferida. Implementado en C-10.

## Requirements

### Requirement: Crear preferencia de pago MercadoPago (fallback en retirada)

El sistema SHALL crear una preferencia de pago en MercadoPago via API route server-side cuando el usuario inicia el flujo de upgrade por este camino de fallback, retornando una URL de Checkout Pro, y SHALL declarar como `notification_url` el webhook del backend FastAPI.

La `notification_url` queda horneada dentro de la preferencia en el momento de crearla y no puede modificarse después: por eso el destino debe ser el endpoint que efectivamente acredita el pago. El valor se deriva de `NEXT_PUBLIC_BACKEND_URL` y la resolución es fail-closed — sin esa variable no se emite ninguna preferencia.

> **Nota (archivado `mp-real-subscriptions`, 2026-09-02)**: la contratación de un plan pago dejó de crear preferencias de pago único — el camino primario es ahora la suscripción recurrente descrita en el requirement *"El upgrade a un tier pago crea una suscripción recurrente"*, más abajo. Este endpoint se mantiene deliberadamente **sin retirar** como fallback mientras la migración completa a suscripciones termina de verificarse en producción (tarea 9.6 del change archivado — MANUAL PO); retirarlo antes rompería el único camino de pago que existiera si la palanca de suscripciones se apagara. Los escenarios de este requirement documentan ese fallback, no el flujo por defecto.

#### Scenario: Preferencia creada exitosamente
- **WHEN** un usuario autenticado hace POST a `/api/billing/preferences` con `{ plan: 'avanzado' }`
- **THEN** el servidor crea una preferencia en la API de MP con el precio del plan en ARS, URLs de back_urls (success/failure/pending), y retorna `{ preferenceId, initPoint }` con status 200

#### Scenario: La preferencia notifica al webhook del backend
- **WHEN** se crea una preferencia para cualquier plan pago
- **THEN** el cuerpo enviado a MercadoPago lleva `notification_url` apuntando a `${NEXT_PUBLIC_BACKEND_URL}/payments/webhook`
- **AND** NO apunta a ninguna ruta bajo `/api/billing/` del frontend

#### Scenario: Sin URL de backend configurada no se emite preferencia
- **GIVEN** que `NEXT_PUBLIC_BACKEND_URL` no está definida en el entorno
- **WHEN** llega un POST a `/api/billing/preferences`
- **THEN** la API route retorna status 500 y NO crea ninguna preferencia en MercadoPago

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

El sistema SHALL procesar toda notificación de pago de MercadoPago en el webhook del backend FastAPI, que es el único componente autorizado a modificar el plan de una cuenta.

La ruta `/api/billing/webhook` del frontend SHALL persistir únicamente como reenviador sin estado, porque las preferencias emitidas antes de este change llevan esa URL horneada de forma permanente. El reenviador NO accede a la base de datos: reenvía los bytes crudos del cuerpo junto con los headers `x-signature` y `x-request-id`, sin re-serializar ni normalizar el payload, y propaga la respuesta del backend. La verificación de firma y la idempotencia ocurren una sola vez, en el backend.

#### Scenario: Pago aprobado actualiza el plan
- **GIVEN** un webhook de MP con `status: 'approved'` y firma válida
- **WHEN** llega al webhook del backend
- **THEN** se actualiza `accounts.billing_plan` al plan comprado, se inserta en `billing_events` con `event_type='plan_upgraded'` y `mercadopago_payment_id`, y se retorna HTTP 200

#### Scenario: Notificación reenviada por el legacy acredita igual
- **GIVEN** una preferencia creada antes de este change, cuya `notification_url` apunta a `/api/billing/webhook`
- **WHEN** MercadoPago notifica un pago aprobado a esa URL
- **THEN** la ruta de Next.js reenvía el cuerpo crudo y los headers de firma al webhook del backend
- **AND** el resultado en base de datos es idéntico al de una notificación recibida directamente
- **AND** la ruta de Next.js retorna el mismo código de estado que devolvió el backend

#### Scenario: El reenviador no escribe en la base de datos
- **WHEN** llega cualquier notificación a `/api/billing/webhook`
- **THEN** la ruta no ejecuta ninguna lectura ni escritura contra Supabase
- **AND** la acreditación del plan ocurre exclusivamente en el backend

#### Scenario: Firma inválida rechazada
- **GIVEN** un webhook con header `x-signature` que no coincide con `MERCADOPAGO_WEBHOOK_SECRET`
- **WHEN** llega al webhook del backend
- **THEN** el servidor rechaza la notificación y NO modifica ningún dato

#### Scenario: Pago duplicado ignorado (idempotencia)
- **GIVEN** un `mercadopago_payment_id` que ya existe en `billing_events`
- **WHEN** llega el mismo webhook por segunda vez, sin importar si vino directo o reenviado
- **THEN** el servidor retorna HTTP 200 sin modificar datos (idempotente)

#### Scenario: Pago rechazado o pendiente no cambia el plan
- **GIVEN** un webhook de MP con `status: 'rejected'` o `status: 'pending'`
- **WHEN** llega al webhook del backend
- **THEN** `accounts.billing_plan` no cambia

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

### Requirement: Convivencia observable entre la ruta legacy y la directa

El sistema SHALL permitir observar, durante la ventana de convivencia, qué proporción de las notificaciones de MercadoPago llega por la ruta reenviada y cuál directamente, para que el retiro del reenviador se decida con evidencia y no por calendario.

Cada reenvío SHALL quedar registrado con el identificador de la notificación y el código de estado devuelto por el backend. El backend SHALL poder distinguir el origen de cada notificación procesada.

#### Scenario: Cada reenvío queda trazado
- **WHEN** la ruta legacy reenvía una notificación al backend
- **THEN** registra el identificador del pago y el código de estado que devolvió el backend

#### Scenario: El origen de la notificación es distinguible en el backend
- **WHEN** el backend procesa una notificación
- **THEN** la traza permite determinar si llegó directa de MercadoPago o reenviada por la ruta legacy

#### Scenario: Retiro del reenviador condicionado a evidencia
- **GIVEN** que el reenviador registró cero reenvíos durante la ventana de convivencia acordada
- **AND** que un pago real de verificación acreditó el plan sin intervención manual
- **THEN** la ruta legacy puede eliminarse
- **AND** mientras cualquiera de las dos condiciones no se cumpla, el reenviador permanece activo
