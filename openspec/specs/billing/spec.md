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

El sistema SHALL transicionar automáticamente el `billing_status` de una **cuenta** (`public.accounts`) de `trialing` a `expired` cuando su trial vence, mediante un barrido programado diario.

Este barrido es **descriptivo, no autoritativo**: existe para que la UI de facturación y los reportes reflejen el estado del ciclo comercial. El **acceso** de la cuenta NOT SHALL depender de que este barrido haya corrido — el plan efectivo se determina de forma perezosa según la capability `billing-trial-lifecycle`.

La transición SHALL registrarse en `billing_events`. La función que la ejecuta SHALL documentar en su `COMMENT` que no es el mecanismo de gating.

#### Scenario: La transición ocurre sin intervención manual
- **GIVEN** una cuenta cuyo trial venció
- **WHEN** corre el barrido programado diario
- **THEN** el `billing_status` de la cuenta pasa de `trialing` a `expired` sin acción del usuario ni del admin

#### Scenario: Los demás estados no se ven afectados
- **GIVEN** una cuenta con `billing_status='active'` (suscripción pagada) o `'cancelled'`
- **WHEN** corre el barrido de vencimiento
- **THEN** el estado no cambia (solo `trialing` con trial vencido transiciona)

#### Scenario: El barrido no decide acceso
- **GIVEN** una cuenta cuyo trial venció y sobre la que el barrido todavía no corrió (sigue en `billing_status='trialing'`)
- **WHEN** intenta crear un recurso por encima del límite de `gratis`
- **THEN** la operación es rechazada igual, porque el plan efectivo ya es `gratis` independientemente del `billing_status`

#### Scenario: El barrido opera sobre cuentas, no sobre perfiles
- **WHEN** corre el barrido de vencimiento
- **THEN** las filas actualizadas pertenecen a `public.accounts`, y `public.profiles` no es la fuente consultada

### Requirement: Los avisos de vencimiento próximo describen un vencimiento real

El barrido que encola los avisos de "tu prueba vence pronto" (ventanas de 7 y 1 día) SHALL leer `public.accounts`, de modo que el aviso corresponda al trial que efectivamente determina el plan efectivo de la cuenta.

#### Scenario: El aviso se encola desde la fecha de vencimiento de la cuenta
- **GIVEN** una cuenta cuyo `accounts.trial_expires_at` cae dentro de la ventana de 7 días
- **WHEN** corre el barrido de avisos
- **THEN** se encola el aviso para los usuarios de esa cuenta

#### Scenario: No se avisa por un vencimiento que no existe
- **GIVEN** una cuenta sin trial (`trial_expires_at IS NULL`) cuyo perfil legacy sí tiene una fecha de vencimiento cargada
- **WHEN** corre el barrido de avisos
- **THEN** no se encola ningún aviso para esa cuenta

### Requirement: Columnas de exención comercial en accounts

El sistema SHALL almacenar la exención comercial en `public.accounts` mediante `billing_exempt boolean NOT NULL DEFAULT false`, `billing_exempt_reason text`, `billing_exempt_granted_at timestamptz` y `billing_exempt_granted_by uuid` (FK `auth.users`), con un CHECK que exige motivo cuando la exención está activa.

#### Scenario: Las columnas existen con sus defaults
- **WHEN** se consulta el esquema de `accounts`
- **THEN** `billing_exempt` existe con default `false` y las tres columnas de auditoría existen como nullables

#### Scenario: El CHECK exige motivo
- **WHEN** se intenta activar `billing_exempt` sin `billing_exempt_reason`
- **THEN** la base rechaza la operación

