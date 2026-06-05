# billing — Delta Spec (grace-period-logic)

> Modifica la capability `billing` (C-01): agrega la transición automática de estado `trialing → expired` al ciclo de vida de la suscripción.

## ADDED Requirements

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
