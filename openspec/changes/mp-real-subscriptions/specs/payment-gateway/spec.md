> **Nota de secuencia**: los bloques MODIFIED de este archivo se escriben contra el estado
> de `payment-gateway` **posterior al archivado de `v31-mp-upgrade-webhook-fix`**, que es su
> prerequisito declarado.

## ADDED Requirements

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

## MODIFIED Requirements

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

## REMOVED Requirements

### Requirement: Crear preferencia de pago MercadoPago

**Reason**: contratar un plan con una preferencia de Checkout Pro es un **pago único**: cobra una vez y no genera recurrencia. Ese es el defecto de raíz que este change corrige — el plan quedaba activo para siempre tras un solo cobro. La contratación pasa a hacerse con una suscripción (`preapproval`), cubierta por el requirement *"El upgrade a un tier pago crea una suscripción recurrente"* de esta misma capability y por la capability `subscription-lifecycle`.

**Migration**: el endpoint `/api/billing/preferences` se retira; el alta de plan pasa por el endpoint de suscripciones del backend. Las preferencias ya emitidas y aún impagas caducan solas por la expiración propia de MercadoPago; los pagos únicos ya acreditados no se revierten — las cuentas afectadas se migran al esquema de suscripción según el plan de migración del change (para la única cuenta pagadora, con la cortesía firmada por el PO). El webhook sigue aceptando notificaciones de tipo `payment` durante la transición, así que un pago único en vuelo se acredita igual.
