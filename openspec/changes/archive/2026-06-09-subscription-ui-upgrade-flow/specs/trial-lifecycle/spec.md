## ADDED Requirements

### Requirement: Downgrade por cancelación programada

El sistema SHALL degradar el plan de un usuario a `gratis` cuando su `plan_expires_at` vence tras una cancelación voluntaria, como extensión del ciclo de vida de billing.

#### Scenario: Downgrade ejecutado por barrido diario
- **GIVEN** un perfil con `plan_expires_at < NOW()` y `billing_status = 'cancelling'`
- **WHEN** corre el barrido diario (`expire_trials` o un nuevo job `process_cancellations`)
- **THEN** `organizations.plan` pasa a `'gratis'`, `billing_status = 'cancelled'`, se inserta `billing_events` con `event_type='plan_downgraded'`

#### Scenario: Plan activo hasta el último día
- **GIVEN** un perfil con `plan_expires_at = today + 1 day` y `billing_status = 'cancelling'`
- **WHEN** corre el barrido diario
- **THEN** el plan no cambia (solo degrada cuando `plan_expires_at < NOW()`)

#### Scenario: Email de downgrade por cancelación encolado
- **WHEN** se ejecuta el downgrade por cancelación
- **THEN** se inserta en `email_logs` con `event_type='plan_downgraded'`, diferenciado del downgrade por trial vencido via `metadata.reason = 'cancellation'`
