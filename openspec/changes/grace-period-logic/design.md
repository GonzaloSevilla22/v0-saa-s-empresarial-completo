## Context

C-01 dejó el trial como timestamps (`trial_plan`, `trial_started_at`, `trial_expires_at`) y `billing_status` con estados `active|trialing|expired|cancelled`. C-02 (`getEffectivePlan`) ya devuelve `billing_plan` cuando `trial_expires_at < now()`, así que el gating client-side ya cae a gratis al vencer. Falta: (a) marcar formalmente `billing_status='expired'` en la DB, (b) auditar el downgrade, (c) avisar al usuario.

Estado actual en prod: 26 usuarios con `trial_expires_at = NULL` (beta, nunca vencen). `pg_net` instalado; `pg_cron` NO.

## Goals / Non-Goals

**Goals**
- Función `expire_trials()` que transiciona `trialing → expired` para trials vencidos + auditoría.
- Habilitar `pg_cron` y agendar el barrido diario.
- Notificaciones `trial_expiring_soon` (7d, 1d) y `trial_expired` vía `email_logs`.
- No tocar a los usuarios beta (`trial_expires_at IS NULL`).

**Non-Goals**
- Reactivación / re-trial → fuera de alcance.
- Pago real / upgrade desde el aviso → C-10 (subscription-ui-upgrade-flow).
- Reset mensual de contadores IA → C-04 (usa el mismo pg_cron pero es otro change).
- Banner de UI rico → mínimo opcional; el grueso es backend.

## Decisions

### D1 — Scheduler: `pg_cron` (habilitarlo) sobre alternativas
**Decisión**: `CREATE EXTENSION IF NOT EXISTS pg_cron;` y agendar con `cron.schedule()`.
**Por qué**: es la solución DB-native de Supabase, sin infra extra. La alternativa (Edge Function programada o GitHub Actions cron pegándole a un endpoint) agrega superficie y secrets. El barrido es 100% SQL sobre `profiles` → vive mejor en la DB.
**Trade-off**: `pg_cron` corre en la base `postgres`, no en la de la app; en Supabase se agenda sobre la DB del proyecto sin problema. Aceptado.

### D2 — `expire_trials()`: transición idempotente + auditoría
**Decisión**:
```sql
CREATE OR REPLACE FUNCTION expire_trials() RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE n integer;
BEGIN
  WITH expired AS (
    UPDATE profiles SET billing_status = 'expired'
    WHERE billing_status = 'trialing'
      AND trial_expires_at IS NOT NULL
      AND trial_expires_at < now()
    RETURNING id, trial_plan, billing_plan
  )
  INSERT INTO billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
  SELECT id, 'trial_expired', trial_plan, billing_plan, 'C-03 grace-period auto-downgrade',
         jsonb_build_object('expired_at', now())
  FROM expired;
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;
```
**Por qué**: una sola pasada atómica (UPDATE + auditoría vía CTE). Idempotente: una vez en `expired` ya no matchea `trialing`. No toca `trial_plan`/`trial_expires_at` (se conservan como registro histórico). El gating ya cae a `billing_plan` por `getEffectivePlan`.

### D3 — Notificaciones vía `email_logs` (patrón existente), deduplicadas
**Decisión**: función `queue_trial_notifications()` que inserta en `email_logs` con `event_type`:
- `trial_expiring_soon` para perfiles `trialing` con `trial_expires_at` entre `now()+6d..now()+7d` (aviso 7 días) y `now()..now()+1d` (aviso 1 día).
- `trial_expired` lo encola el propio `expire_trials()` (o un barrido posterior).
La dedup la da el `UNIQUE(user_id, event_type, metadata)` de `email_logs` (C-01) — el `metadata` incluye el umbral (`'7d'`/`'1d'`) para permitir ambos avisos sin colisión.
**Por qué**: reusa el webhook `email_logs INSERT → send-email` ya en producción. Cero infra nueva de email.

### D4 — Plantillas en `send-email`
**Decisión**: agregar 2 ramas en la Edge Function `send-email`: `trial_expiring_soon` ("Te quedan N días de prueba del plan Avanzado") y `trial_expired` ("Tu prueba terminó — seguís con el plan Gratis"). Ambas con CTA a `/planes` (C-10).
**Por qué**: el `send-email` ya enrutea por `event_type`; es additivo.

### D5 — Dos jobs cron diarios
**Decisión**:
- `cron.schedule('expire-trials', '0 3 * * *', 'SELECT expire_trials()')` — 3 AM.
- `cron.schedule('trial-notifications', '0 9 * * *', 'SELECT queue_trial_notifications()')` — 9 AM (horario razonable para que el email salga de día).
**Por qué**: separar vencimiento (madrugada) de notificación (mañana) evita avisar y vencer en el mismo tick.

## Estándares aplicados (skill-registry)

- **supabase-postgres-best-practices**: funciones `SECURITY DEFINER` con `search_path` fijo; índice parcial `idx_profiles_trial_expires_at` (ya existe de C-01) cubre el barrido; TIMESTAMPTZ.
- **supabase**: el barrido usa `service_role` implícito (pg_cron corre como superuser); `send-email` mantiene su patrón.
- **Reglas duras**: migración via `npx supabase db push` (NUNCA MCP apply_migration); deploy de `send-email` vía CI al merge.

## Risks / Trade-offs

- **R1 — `pg_cron` no disponible/permiso**: si el plan de Supabase no permite `pg_cron`, fallback a Edge Function programada. Mitigación: verificar `CREATE EXTENSION pg_cron` en el apply; si falla, documentar el fallback.
- **R2 — Doble notificación**: mitigado por el `UNIQUE` de `email_logs` + `metadata` con umbral.
- **R3 — Reloj/zona horaria**: `trial_expires_at` es TIMESTAMPTZ; el cron corre en UTC. Los avisos "7d/1d" tienen ventana de 1 día, tolerante a la hora exacta.
- **R4 — El job no corre**: el gating NO se rompe (getEffectivePlan ya cae a billing_plan). Solo se atrasan el estado DB y los emails. Riesgo bajo.

## Migration Plan

1. `CREATE EXTENSION IF NOT EXISTS pg_cron;`
2. Funciones `expire_trials()` y `queue_trial_notifications()`.
3. `cron.schedule` de los 2 jobs.
4. Ramas nuevas en `send-email` (deploy vía CI).
5. Verificar: crear un perfil de test con `trial_expires_at < now()`, correr `SELECT expire_trials()`, confirmar `billing_status='expired'` + `billing_events` insertado.

## Open Questions

- ¿El aviso de 7 días aplica para trials de 30 días recién creados, o solo cuando realmente quedan 7? (Asumido: se evalúa contra `trial_expires_at` real, no contra la fecha de alta.)
- ¿Se quiere un tercer aviso (3 días)? Asumido: solo 7d y 1d. Fácil de agregar.
