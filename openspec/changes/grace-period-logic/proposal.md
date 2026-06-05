## Why

C-01 creó el trial de 30 días (`trial_plan`, `trial_expires_at`) y C-02 hace que el gating respete el plan efectivo (que ya cae a `billing_plan` cuando el trial vence, vía `getEffectivePlan`). Pero falta cerrar el ciclo: **nada marca formalmente el trial como vencido en la DB, ni avisa al usuario que se le acaba**. Hoy un trial vencido solo se refleja en el cálculo client-side; el `billing_status` queda en `'trialing'` para siempre y el usuario nunca recibe un aviso. C-03 formaliza el vencimiento (estado autoritativo en DB + auditoría) y agrega las notificaciones de pre-vencimiento y vencimiento.

## What Changes

- **Job programado de vencimiento (diario)**: una función SQL `expire_trials()` que busca perfiles con `billing_status = 'trialing'` y `trial_expires_at < now()`, los pasa a `billing_status = 'expired'` y registra un `billing_events` de downgrade. El plan efectivo cae automáticamente a `billing_plan` (gratis para usuarios nuevos) — la cascada de gating de C-02 ya lo respeta.
- **Habilitar `pg_cron`** (hoy solo está `pg_net`): para agendar `expire_trials()` y el barrido de notificaciones una vez por día.
- **Notificaciones de trial** (vía el patrón existente `email_logs` → webhook → `send-email`): nuevos `event_type` `trial_expiring_soon` (7 días antes y 1 día antes) y `trial_expired` (al vencer). Deduplicadas para no spamear.
- **Downgrade auditado**: cada vencimiento inserta un `billing_events` (`event_type = 'trial_expired'`, `from_plan = trial_plan`, `to_plan = billing_plan`).
- **Sin impacto en los 26 usuarios beta**: tienen `trial_expires_at = NULL` → nunca entran al barrido. Solo afecta a usuarios nuevos (post-trigger de C-01).

## Capabilities

### New Capabilities
- `trial-lifecycle`: Vencimiento programado del trial, transición de estado `trialing → expired`, auditoría del downgrade, y notificaciones de pre-vencimiento/vencimiento al usuario.

### Modified Capabilities
- `billing`: Se agrega la transición de estado `trialing → expired` como comportamiento observable del ciclo de vida de la suscripción (la capability `billing` de C-01 definió los estados pero no la transición automática).

## Impact

- **DB / Migraciones**: habilitar `pg_cron`; función `expire_trials()` (`SECURITY DEFINER`, `search_path` fijo); función `queue_trial_notifications()`; 2 jobs `cron.schedule`. Migración idempotente.
- **Email**: nuevos `event_type` en `email_logs` y sus plantillas en la Edge Function `send-email` (`trial_expiring_soon`, `trial_expired`). Reusa el webhook existente.
- **Frontend**: opcional — un banner "Te quedan N días de prueba" leyendo `trial_expires_at`. Mínimo; el grueso es backend.
- **Riesgo**: bajo. El barrido es aditivo sobre `billing_status`; un error solo afectaría a usuarios con trial activo (ninguno de los 26 actuales). `getEffectivePlan` ya protege el gating aunque el job no corra.
