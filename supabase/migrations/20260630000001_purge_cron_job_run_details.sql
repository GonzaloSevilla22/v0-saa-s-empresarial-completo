-- ============================================================
-- Retención de logs de pg_cron — purga de cron.job_run_details
-- ============================================================
-- El job `relay-process-pending-cae` (C-27) corre CADA MINUTO, por lo que
-- cron.job_run_details acumula ~1.440 filas/día sin tope. Ni Postgres ni
-- Supabase la purgan solas; con el tiempo infla el tamaño de la DB (relevante
-- en el plan free, donde la cuota es a nivel organización).
--
-- Este migration agrega un job diario de retención (7 días) + una limpieza
-- inicial puntual para no esperar al primer tick.
--
-- Idempotente: unschedule previo por nombre + cron.schedule (mismo patrón que
-- `relay-process-pending-cae` en 20260627000001_c27_fiscal_profile.sql).
--
-- ROLLBACK PLAN (si hiciera falta):
--   SELECT cron.unschedule('purge-cron-job-run-details');
-- ============================================================

-- Limpieza inicial puntual (no espera al primer tick del job).
DELETE FROM cron.job_run_details WHERE start_time < now() - interval '7 days';

-- Job diario de retención — 04:00 UTC (slot libre entre los jobs existentes:
-- 03:00 expire-trials, 03:30 process-cancellations, 09:00 trial-notifications).
SELECT cron.unschedule('purge-cron-job-run-details')
FROM cron.job
WHERE jobname = 'purge-cron-job-run-details';

SELECT cron.schedule(
  'purge-cron-job-run-details',
  '0 4 * * *',
  $$DELETE FROM cron.job_run_details WHERE start_time < now() - interval '7 days'$$
);
