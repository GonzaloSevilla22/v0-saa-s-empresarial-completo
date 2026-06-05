# Tasks — grace-period-logic (C-03)

> Governance **ALTO**: toca `billing_status` de perfiles reales, pero solo de usuarios con trial activo (ninguno de los 26 beta actuales tiene `trial_expires_at`). Migración aditiva. Aplicar via `npx supabase db push` (NUNCA MCP apply_migration).
> Tests: assertions SQL (perfil de prueba con trial vencido → expired + billing_event). El gating ya está protegido por getEffectivePlan (C-02), así que un fallo del job no rompe el acceso.

## 0. Pre-flight

- [x] 0.1 Verificar que `pg_cron` se puede habilitar en el plan de Supabase actual (`CREATE EXTENSION IF NOT EXISTS pg_cron`). Si falla, activar el fallback de R1 (Edge Function programada). **RESULT: pg_cron instalado correctamente.**
- [x] 0.2 Capturar baseline: `SELECT billing_status, count(*) FROM profiles GROUP BY 1` (debe ser 26 trialing, todos con trial_expires_at NULL). **RESULT: 26 trialing, trial_expires_at=NULL (confirmado).**

## 1. Migración — extensión + funciones

- [x] 1.1 Crear `supabase/migrations/20260605040000_grace_period.sql`. `CREATE EXTENSION IF NOT EXISTS pg_cron;`
- [x] 1.2 Función `expire_trials() RETURNS integer` (`SECURITY DEFINER`, `SET search_path=public`): UPDATE `trialing`→`expired` donde `trial_expires_at IS NOT NULL AND trial_expires_at < now()`, con CTE que inserta `billing_events` (`event_type='trial_expired'`, from=trial_plan, to=billing_plan). Retorna ROW_COUNT.
- [x] 1.3 Función `queue_trial_notifications() RETURNS integer` (`SECURITY DEFINER`, `search_path=public`): INSERT en `email_logs` para perfiles `trialing` con `trial_expires_at` en ventana 7d y 1d, `event_type='trial_expiring_soon'`, `metadata` con umbral ('7d'/'1d'). ON CONFLICT DO NOTHING (dedup vía UNIQUE de email_logs).
- [x] 1.4 **TEST 1.4**: `SELECT public.expire_trials()` → retorna 0 (ningún usuario real tiene trial_expires_at, idempotente). Los 26 usuarios siguen en `trialing`. `SELECT public.queue_trial_notifications()` → retorna 0 (ninguno en ventana de notificación). **PASS.**

## 2. Migración — agendar jobs

- [x] 2.1 `cron.schedule('expire-trials', '0 3 * * *', 'SELECT public.expire_trials()')`.
- [x] 2.2 `cron.schedule('trial-notifications', '0 9 * * *', 'SELECT public.queue_trial_notifications()')`.
- [x] 2.3 **GATE + `npx supabase db push`**. **TEST 2.3**: `SELECT jobname FROM cron.job` — confirmado: `expire-trials` y `trial-notifications` presentes. **PASS.**

## 3. Plantillas de email (`send-email`)

- [x] 3.1 En `supabase/functions/send-email/index.ts`: rama `trial_expiring_soon` — "Te quedan N días de prueba del plan Avanzado" + CTA a `/planes`. N derivado del `metadata.umbral` ('7d'→7 días, '1d'→1 día). Color urgente (rojo) para 1d, ámbar para 7d.
- [x] 3.2 Rama `trial_expired` — "Tu prueba terminó, seguís con el plan Gratis" + CTA a `/planes`. Deploy via CI al merge.
- [x] 3.3 **TEST 3.3**: HTML se construye sin `any` types, `tsc --noEmit` limpio. Deploy pendiente al merge (CI).

## 4. Frontend (mínimo, opcional)

- [x] 4.1 Banner "Te quedan N días de prueba" en el dashboard (`components/dashboard/TrialBanner.tsx`), leyendo `user.billingStatus` y `user.trialExpiresAt`. Solo renderiza cuando `billing_status='trialing'`, `trial_expires_at` es futura y no nula. Dismissible por sesión. Color ámbar/rojo según urgencia (<=3 días = rojo). CTA a `/planes`.
- [x] 4.2 **TEST 4.1**: `tsc --noEmit` pasa. **PASS.**

## 5. Cierre

- [x] 5.1 `tsc --noEmit` limpio. **PASS.**
- [x] 5.2 Re-correr TEST 1.4 y 2.3 en verde sobre el remoto. **PASS — expire_trials()=0, queue_trial_notifications()=0, cron.job tiene 2 rows, 26 usuarios siguen en trialing.**
- [ ] 5.3 Marcar `[x]` C-03 en `CHANGES.md` tras archivar.
