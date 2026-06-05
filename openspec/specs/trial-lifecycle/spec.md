# trial-lifecycle Specification

## Purpose
TBD - created by archiving change grace-period-logic. Update Purpose after archive.
## Requirements
### Requirement: Vencimiento automático del trial

El sistema SHALL transicionar un perfil de `billing_status = 'trialing'` a `'expired'` cuando su `trial_expires_at` es anterior al momento actual, mediante un barrido programado diario.

#### Scenario: Trial vencido pasa a expired
- **GIVEN** un perfil con `billing_status='trialing'`, `trial_expires_at = now() - 1 day`
- **WHEN** corre `expire_trials()`
- **THEN** el perfil queda con `billing_status='expired'`

#### Scenario: Trial vigente no se toca
- **GIVEN** un perfil con `billing_status='trialing'`, `trial_expires_at = now() + 10 days`
- **WHEN** corre `expire_trials()`
- **THEN** el perfil sigue en `billing_status='trialing'`

#### Scenario: Usuarios beta sin fecha de trial nunca vencen
- **GIVEN** un perfil con `trial_expires_at IS NULL` (beta grandfathered)
- **WHEN** corre `expire_trials()`
- **THEN** el perfil no es modificado

#### Scenario: El barrido es idempotente
- **WHEN** `expire_trials()` corre dos veces seguidas
- **THEN** la segunda corrida transiciona 0 perfiles (los ya `expired` no re-matchean)

### Requirement: El plan efectivo cae al plan base tras el vencimiento

El sistema SHALL hacer que un usuario con trial vencido acceda solo a los límites de su `billing_plan` base, sin importar el `trial_plan` previo.

#### Scenario: Usuario gratis con trial avanzado vencido
- **GIVEN** un usuario con `billing_plan='gratis'`, `trial_plan='avanzado'`, trial vencido y `billing_status='expired'`
- **WHEN** se evalúa su plan efectivo
- **THEN** el plan efectivo es 'gratis' (el trial ya no aplica)

### Requirement: Auditoría del downgrade

El sistema SHALL registrar un `billing_events` por cada trial vencido, con el plan de origen y destino.

#### Scenario: Se audita el vencimiento
- **WHEN** `expire_trials()` transiciona un perfil
- **THEN** se inserta un `billing_events` con `event_type='trial_expired'`, `from_plan` = trial_plan, `to_plan` = billing_plan

### Requirement: Notificaciones de pre-vencimiento y vencimiento

El sistema SHALL encolar notificaciones por email cuando el trial está por vencer (7 días y 1 día antes) y cuando vence, sin duplicados.

#### Scenario: Aviso de 7 días
- **GIVEN** un perfil `trialing` cuyo `trial_expires_at` cae dentro de 7 días
- **WHEN** corre `queue_trial_notifications()`
- **THEN** se inserta un `email_logs` con `event_type='trial_expiring_soon'` y `metadata` indicando el umbral '7d'

#### Scenario: Sin duplicados
- **GIVEN** que ya se encoló el aviso '7d' para un perfil
- **WHEN** `queue_trial_notifications()` corre de nuevo el mismo día
- **THEN** no se inserta un segundo `email_logs` idéntico (lo impide el UNIQUE de email_logs)

#### Scenario: Aviso de vencimiento
- **WHEN** un trial vence
- **THEN** se encola un `email_logs` con `event_type='trial_expired'` para ese usuario

