# billing Specification

## Purpose
TBD - created by archiving change grace-period-logic. Update Purpose after archive.
## Requirements

### Requirement: Columnas de precio en plan_limits

El sistema SHALL almacenar precios ARS en `plan_limits` para que sean actualizables sin deploy.

#### Scenario: Precios leídos desde DB en /planes
- **WHEN** la page `/planes` renderiza los planes
- **THEN** los precios mostrados provienen de `plan_limits.price_monthly`, no de constantes hardcodeadas en el código

#### Scenario: Precios anuales disponibles
- **WHEN** se consulta `plan_limits`
- **THEN** la columna `price_ars_annual` devuelve el precio anual (mensual × 10) para cada plan de pago

### Requirement: Columnas de auditoría en billing_events para MercadoPago

El sistema SHALL tener campos específicos de MP en `billing_events` para trazabilidad completa de pagos.

#### Scenario: Pago aprobado registrado con ID de MP
- **WHEN** se procesa un webhook de pago aprobado
- **THEN** el `billing_events` insertado contiene `mercadopago_payment_id`, `mercadopago_preference_id`, `amount` y metadata del webhook

#### Scenario: Idempotencia por payment_id
- **GIVEN** que ya existe un `billing_events` con `mercadopago_payment_id = 'X'`
- **WHEN** llega un segundo webhook con el mismo `payment_id`
- **THEN** no se inserta un segundo evento (UNIQUE index en `mercadopago_payment_id`)

### Requirement: Campo plan_expires_at en accounts

El sistema SHALL tener un campo `plan_expires_at TIMESTAMPTZ` en `accounts` para manejar el fin del período pagado en cancelaciones.

#### Scenario: plan_expires_at seteado al cancelar
- **WHEN** un usuario cancela su suscripción mensual
- **THEN** `accounts.plan_expires_at` queda en la fecha de vencimiento del período actual

#### Scenario: plan_expires_at NULL en plan gratis
- **GIVEN** un usuario en plan `gratis` sin historial de pago
- **WHEN** se consulta `accounts.plan_expires_at`
- **THEN** el valor es NULL (sin período de pago activo)
### Requirement: Transición de estado del ciclo de suscripción

El sistema SHALL transicionar automáticamente el `billing_status` de un perfil de `trialing` a `expired` cuando su trial vence, como parte del ciclo de vida de la suscripción definido en C-01.

#### Scenario: La transición ocurre sin intervención manual
- **GIVEN** un perfil cuyo trial venció
- **WHEN** corre el barrido programado diario
- **THEN** el `billing_status` pasa de `trialing` a `expired` sin acción del usuario ni del admin

#### Scenario: Los demás estados no se ven afectados
- **GIVEN** un perfil con `billing_status='active'` (suscripción pagada futura) o `'cancelled'`
- **WHEN** corre el barrido de vencimiento
- **THEN** el estado no cambia (solo `trialing` con trial vencido transiciona)

