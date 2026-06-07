## ADDED Requirements

### Requirement: Columnas de precio en plan_limits

El sistema SHALL almacenar precios ARS en `plan_limits` para que sean actualizables sin deploy.

#### Scenario: Precios leídos desde DB en /planes
- **WHEN** la page `/planes` renderiza los planes
- **THEN** los precios mostrados provienen de `plan_limits.price_ars_monthly`, no de constantes hardcodeadas en el código

#### Scenario: Precios actualizados sin deploy
- **WHEN** un admin actualiza `price_ars_monthly` en `plan_limits` para el plan `avanzado`
- **THEN** `/planes` muestra el nuevo precio en el próximo render sin necesidad de redeploy

### Requirement: Columnas de auditoría en billing_events para MercadoPago

El sistema SHALL tener campos específicos de MP en `billing_events` para trazabilidad completa de pagos.

#### Scenario: Pago aprobado registrado con ID de MP
- **WHEN** se procesa un webhook de pago aprobado
- **THEN** el `billing_events` insertado contiene `mercadopago_payment_id`, `mercadopago_preference_id`, `amount` y el payload completo del webhook en `metadata`

#### Scenario: Idempotencia por payment_id
- **GIVEN** que ya existe un `billing_events` con `mercadopago_payment_id = 'X'`
- **WHEN** llega un segundo webhook con el mismo `payment_id`
- **THEN** no se inserta un segundo evento (UNIQUE constraint en `mercadopago_payment_id`)

### Requirement: Campo plan_expires_at en organizations

El sistema SHALL tener un campo `plan_expires_at TIMESTAMPTZ` en `organizations` para manejar el fin del período pagado en cancelaciones.

#### Scenario: plan_expires_at seteado al cancelar
- **WHEN** un usuario cancela su suscripción mensual
- **THEN** `organizations.plan_expires_at` queda en la fecha de vencimiento del período actual (ej: si pagó el 1 de junio, `plan_expires_at = 1 de julio`)

#### Scenario: plan_expires_at NULL en plan gratis
- **GIVEN** un usuario en plan `gratis` sin historial de pago
- **WHEN** se consulta `organizations.plan_expires_at`
- **THEN** el valor es NULL (sin período de pago activo)
