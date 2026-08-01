## MODIFIED Requirements

### Requirement: Crear preferencia de pago MercadoPago

El sistema SHALL crear una preferencia de pago en MercadoPago via API route server-side cuando el usuario inicia el flujo de upgrade, retornando una URL de Checkout Pro, y SHALL declarar como `notification_url` el webhook del backend FastAPI.

La `notification_url` queda horneada dentro de la preferencia en el momento de crearla y no puede modificarse después: por eso el destino debe ser el endpoint que efectivamente acredita el pago. El valor se deriva de `NEXT_PUBLIC_BACKEND_URL` y la resolución es fail-closed — sin esa variable no se emite ninguna preferencia.

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

## ADDED Requirements

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
