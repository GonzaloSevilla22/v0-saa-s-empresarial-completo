-- ============================================================
-- Retención de logs internos — cron.job_run_details escalonado,
-- reclamo de espacio de net._http_response y techo de email_logs
-- ============================================================
-- Diagnóstico medido en prod (gxdhpxvdjjkmxhdkkwyb, SELECTs de sólo lectura,
-- 2026-08-17): 48 de 86 MB de la DB son logs internos de mantenimiento.
--
--   - net._http_response (31 MB, 360 filas vivas / 0 muertas): pg_net.ttl =
--     6 horas YA funciona (360 filas ≡ 6h × 60 min de relay-process-outbox).
--     Los 31 MB son BLOAT de heap (30 MB de heap, TOAST de sólo 40 kB), no
--     filas retenidas — VACUUM normal nunca lo devuelve al SO. Por eso este
--     archivo NO agrega ninguna purga por antigüedad sobre esta tabla: sería
--     código muerto compitiendo con el worker de pg_net. Se agrega, en
--     cambio, un job diario de VACUUM (FULL, ANALYZE) para reclamar el
--     espacio. Verificado: el rol `postgres` (bajo el que corren los cron
--     jobs del proyecto) tiene privilegio MAINTAIN sobre la tabla (nuevo en
--     PG 17), aunque el owner sea supabase_admin — sin ese privilegio este
--     change no tendría cómo ejecutar VACUUM FULL sin ser el owner.
--   - cron.job_run_details (17 MB, 22.738 filas): ya tenía purga plana de 7
--     días (20260630000001, job `purge-cron-job-run-details`) y funciona.
--     El 98% del volumen (22.316 filas) lo generan los dos jobs `* * * * *`
--     (relay-process-outbox, relay-process-pending-cae). Esta migración
--     SUPERA esa purga plana con una ventana ESCALONADA por frecuencia del
--     schedule del job que generó la fila: 1 día para jobs de alta
--     frecuencia (campo de minutos `*` o `*/N`), 14 días para el resto y
--     para filas huérfanas (job ya desprogramado). Efecto esperado:
--     17 MB → ~2 MB, GANANDO historia útil (7→14 días) en los jobs de
--     negocio (expire-trials, process-cancellations, sweeps de billing).
--     La clasificación se hace por `schedule`, nunca por `jobid` — los
--     jobid rotan con cada unschedule/schedule (incluida esta migración).
--   - public.email_logs (3,7 MB, 5.210 filas desde 2026-03-01): único caso
--     de retención cero real. Techo de 90 días (OQ-1 no bloqueante: el PO
--     puede mover el literal sin reabrir el change).
--
-- Centraliza la lógica en UNA función `public.purge_internal_logs()`
-- (SECURITY DEFINER, search_path fijo, ACLs explícitas en este mismo
-- archivo) en vez de DELETEs embebidos en el comando del cron job:
-- testeable directamente por el gate de CI, auditable vía el
-- return_message del propio job, y sigue el patrón ya establecido en el
-- repo (`_notifications_cleanup()`, `_sweep_plan_limit_exceeded()`).
--
-- Idempotente de punta a punta: CREATE OR REPLACE + REVOKE/GRANT explícitos
-- (DROP+CREATE resetea ACLs a PUBLIC — regla dura del repo) + unschedule-
-- si-existe por NOMBRE (vía `FROM cron.job WHERE jobname = ...`, nunca
-- unschedule a ciegas) seguido de cron.schedule.
--
-- Retira el job `purge-cron-job-run-details` (superado por purge-internal-
-- logs) y ejecuta una purga inicial one-shot para no esperar al primer tick.
--
-- VACUUM no puede correr dentro del bloque transaccional en el que
-- `supabase db push` aplica cada migración (`VACUUM cannot run inside a
-- transaction block`) — por eso el VACUUM FULL va como comando de un cron
-- job, nunca ejecutado directamente en este archivo.
--
-- ROLLBACK PLAN (si hiciera falta):
--   SELECT cron.unschedule('purge-internal-logs');
--   SELECT cron.unschedule('vacuum-full-net-http-response');
--   DROP FUNCTION IF EXISTS public.purge_internal_logs();
--   -- restituir la purga previa si hiciera falta:
--   SELECT cron.schedule('purge-cron-job-run-details','0 4 * * *',
--     $$DELETE FROM cron.job_run_details WHERE start_time < now() - interval '7 days'$$);
--   -- Las filas ya purgadas no se recuperan (son logs) — el rollback
--   -- restituye la política, no los datos.
-- ============================================================

-- ─── 1. Función canónica de purga ──────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.purge_internal_logs()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $fn$
DECLARE
  -- Ventanas nombradas — único punto para ajustarlas (OQ-1: el PO puede
  -- mover v_email_logs_window sin reescribir ningún comando de cron).
  v_high_freq_window   CONSTANT interval := interval '1 day';
  v_low_freq_window    CONSTANT interval := interval '14 days';
  v_email_logs_window  CONSTANT interval := interval '90 days';

  v_cron_deleted       bigint := 0;
  v_email_deleted      bigint := 0;
BEGIN
  -- cron.job_run_details: clasificar por el schedule del job (LEFT JOIN —
  -- las filas huérfanas, jobid ya ausente de cron.job, caen en la ventana
  -- larga). Patrón reconocido de "alta frecuencia": el campo de minutos del
  -- schedule (primer token) es literalmente `*` o empieza con `*/`
  -- (ej. `* * * * *`, `*/5 * * * *`, `*/30 * * * *`). Limitación conocida y
  -- documentada: una forma no canónica como `0-59/1 * * * *` también corre
  -- cada minuto pero NO matchea el patrón — cae en la ventana de 14 días
  -- (más filas retenidas, nunca pérdida de datos). Ningún job del proyecto
  -- usa esa forma hoy.
  WITH classified AS (
    SELECT
      d.runid,
      d.start_time,
      (
        j.schedule IS NOT NULL
        AND (
          split_part(j.schedule, ' ', 1) = '*'
          OR split_part(j.schedule, ' ', 1) LIKE '*/%'
        )
      ) AS is_high_freq
    FROM cron.job_run_details d
    LEFT JOIN cron.job j ON j.jobid = d.jobid
  ),
  to_delete AS (
    SELECT runid
    FROM classified
    WHERE (is_high_freq     AND start_time < now() - v_high_freq_window)
       OR (NOT is_high_freq AND start_time < now() - v_low_freq_window)
  )
  DELETE FROM cron.job_run_details d
  USING to_delete t
  WHERE d.runid = t.runid;
  GET DIAGNOSTICS v_cron_deleted = ROW_COUNT;

  -- public.email_logs: techo único de 90 días (literal, ajustable acá sin
  -- tocar ningún comando de cron).
  DELETE FROM public.email_logs
  WHERE created_at < now() - v_email_logs_window;
  GET DIAGNOSTICS v_email_deleted = ROW_COUNT;

  RETURN jsonb_build_object(
    'cron_job_run_details_deleted', v_cron_deleted,
    'email_logs_deleted',           v_email_deleted
  );
END;
$fn$;

COMMENT ON FUNCTION public.purge_internal_logs() IS
    'internal-logs-retention: función canónica de purga de logs internos de '
    'mantenimiento — cron.job_run_details (escalonada por frecuencia del '
    'schedule: 1 día alta frecuencia, 14 días resto/huérfanas) y '
    'public.email_logs (90 días, OQ-1). Devuelve jsonb con los conteos '
    'purgados para que el gate de CI la invoque directamente. NO toca '
    'net._http_response (pg_net.ttl nativo ya la retiene — ver job '
    'vacuum-full-net-http-response). SECURITY DEFINER, revocada de '
    'PUBLIC/anon/authenticated, EXECUTE sólo para postgres (rol de los cron '
    'jobs del proyecto).';

-- Regla dura del repo: DROP+CREATE resetea ACLs a EXECUTE-para-PUBLIC —
-- las ACLs se declaran en el MISMO archivo, inmediatamente después.
REVOKE ALL ON FUNCTION public.purge_internal_logs() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.purge_internal_logs() TO postgres;

-- ─── 2. Registro idempotente de los jobs ───────────────────────────────────
-- unschedule-si-existe por NOMBRE (nunca a ciegas) para los tres nombres,
-- incluido el job retirado, seguido de cron.schedule de los dos nuevos.

SELECT cron.unschedule(jobname)
FROM cron.job
WHERE jobname IN ('purge-cron-job-run-details', 'purge-internal-logs', 'vacuum-full-net-http-response');

-- Diario 04:00 UTC — mismo slot horario que la purga que reemplaza.
SELECT cron.schedule(
  'purge-internal-logs',
  '0 4 * * *',
  $$SELECT public.purge_internal_logs();$$
);

-- Diario 04:20 UTC (01:20 ART, tráfico mínimo) — 20 minutos después de la
-- purga para no competir con ella por I/O. VACUUM FULL toma ACCESS
-- EXCLUSIVE sobre net._http_response; post-reclamo la tabla pesa ~1-2 MB y
-- el lock es sub-segundo. `pg_net` es fire-and-forget en este proyecto:
-- ningún código de supabase/, backend/ ni frontend/ lee net._http_response
-- ni llama a net.http_collect_response (verificado por grep en el propose).
SELECT cron.schedule(
  'vacuum-full-net-http-response',
  '20 4 * * *',
  $$VACUUM (FULL, ANALYZE) net._http_response;$$
);

-- ─── 3. Purga inicial one-shot ──────────────────────────────────────────────
-- No espera al primer tick programado: el backlog histórico se purga al
-- aplicar la migración.
SELECT public.purge_internal_logs();
