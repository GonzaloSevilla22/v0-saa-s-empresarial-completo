## MODIFIED Requirements

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

## ADDED Requirements

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
