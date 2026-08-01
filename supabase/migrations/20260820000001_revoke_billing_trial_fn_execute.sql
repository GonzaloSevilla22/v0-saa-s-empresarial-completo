-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-billing-trial-fn-execute — cierra advisors 0028/0029 para las 3
-- funciones de billing cron/trigger-only del ciclo de trials
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ⚠ GOVERNANCE: dominio billing = CRÍTICO. Este archivo se PROPONE gateado por
--   sign-off explícito del PO — NO mergear sin esa aprobación (el pipeline
--   aplica las migraciones a prod automáticamente al mergear a main).
--
-- Los advisors de seguridad (0028_anon_security_definer_function_executable /
-- 0029_authenticated_security_definer_function_executable, corrida 2026-07-31
-- post billing-pro-trial) marcan WARN tres funciones SECURITY DEFINER de
-- billing ejecutables vía PostgREST (/rest/v1/rpc/<fn>) sin necesidad:
--
--   · expire_trials()              cron-only   (cron.job 'expire-trials', 0 3 * * *, username postgres)
--   · queue_trial_notifications()  cron-only   (cron.job 'trial-notifications', 0 9 * * *, username postgres)
--   · set_new_user_trial()         trigger-only (RETURNS trigger; trg_new_user_trial en profiles, enabled)
--
-- Hallazgos PREEXISTENTES a billing-pro-trial: 20260817000001 las redefinió
-- con CREATE OR REPLACE, que CONSERVA ACLs — no las expuso. Verificado en prod
-- (2026-07-31, read-only, MCP) antes de proponer este REVOKE:
--   · proacl actual de las 3: {=X/postgres, postgres=X, anon=X,
--     authenticated=X, service_role=X} — anon/authenticated pueden EXECUTE.
--   · cron corre como postgres → conserva EXECUTE (este archivo no lo toca).
--   · El disparo de triggers NO chequea EXECUTE del usuario DML → el alta de
--     usuarios (trg_new_user_trial) no se ve afectada (mismo argumento que
--     20260517000002, 20260808000003 y 20260818000001, ya en prod).
--   · set_new_user_trial RETURNS trigger: PostgREST no puede invocarla con
--     éxito de todos modos (el WARN es por el privilegio); para las dos
--     cron-only el REVOKE sí cierra una invocación real — un anon podía
--     forzar el sweep de vencimientos / la cola de mails fuera de horario
--     (ambas idempotentes, pero sin razón para estar expuestas).
--   · 0 callers vía REST en el código: grep de las 3 en frontend/, backend/ y
--     supabase/functions/ → solo un comentario en TrialBanner.tsx y los tipos
--     generados en database.types.ts (que existen precisamente por la
--     exposición que este archivo elimina; se limpian solos en la próxima
--     regeneración de tipos).
--
-- service_role CONSERVA EXECUTE (igual que 20260818000001): no llega al
-- browser y puede necesitarse desde Edge Functions administrativas.
--
-- Inventario del backlog restante (0028 ~56 / 0029 ~94) y candidatas
-- siguientes (process_cancellations, lote trigger-only, regresión de ACLs por
-- DROP+CREATE): openspec/explore/2026-07-31-advisor-0028-0029-inventory.md
--
-- Idempotente: REVOKE repetido es no-op; el guard to_regprocedure la hace
-- drift-tolerante (no-op si la función no existe en el entorno).
--
-- Rollback (no recomendado — reabre los WARN sin ganar nada):
--   GRANT EXECUTE ON FUNCTION public.expire_trials()             TO anon, authenticated;
--   GRANT EXECUTE ON FUNCTION public.queue_trial_notifications() TO anon, authenticated;
--   GRANT EXECUTE ON FUNCTION public.set_new_user_trial()        TO anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.expire_trials()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.expire_trials() FROM PUBLIC, anon, authenticated;
  END IF;

  IF to_regprocedure('public.queue_trial_notifications()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.queue_trial_notifications() FROM PUBLIC, anon, authenticated;
  END IF;

  IF to_regprocedure('public.set_new_user_trial()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.set_new_user_trial() FROM PUBLIC, anon, authenticated;
  END IF;
END $$;

-- ── GATE 1: ninguna de las tres queda ejecutable por anon/authenticated ─────
-- (anon/authenticated heredan de PUBLIC, así que chequearlas cubre también
-- el caso de un EXECUTE residual vía PUBLIC)
DO $$
DECLARE
  v_fn   text;
  v_role text;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['public.expire_trials()',
                              'public.queue_trial_notifications()',
                              'public.set_new_user_trial()']
  LOOP
    CONTINUE WHEN to_regprocedure(v_fn) IS NULL;  -- drift-tolerante
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF has_function_privilege(v_role, to_regprocedure(v_fn), 'EXECUTE') THEN
        RAISE EXCEPTION 'GATE FAILED: % sigue con EXECUTE para %', v_fn, v_role;
      END IF;
    END LOOP;
  END LOOP;
END $$;

-- ── GATE 2 (positivo): la operación NO se rompe con el REVOKE ───────────────
-- postgres (quien ejecuta los cron.job) conserva EXECUTE sobre las dos
-- cron-only, y el trigger de alta de usuarios sigue colgado y habilitado.
DO $$
BEGIN
  IF to_regprocedure('public.expire_trials()') IS NOT NULL
     AND NOT has_function_privilege('postgres', to_regprocedure('public.expire_trials()'), 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED: postgres perdió EXECUTE sobre expire_trials() — el cron expire-trials dejaría de correr';
  END IF;

  IF to_regprocedure('public.queue_trial_notifications()') IS NOT NULL
     AND NOT has_function_privilege('postgres', to_regprocedure('public.queue_trial_notifications()'), 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED: postgres perdió EXECUTE sobre queue_trial_notifications() — el cron trial-notifications dejaría de correr';
  END IF;

  IF to_regprocedure('public.set_new_user_trial()') IS NOT NULL
     AND NOT EXISTS (
       SELECT 1 FROM pg_trigger t
       WHERE t.tgfoid = to_regprocedure('public.set_new_user_trial()')
         AND NOT t.tgisinternal
         AND t.tgenabled <> 'D'
     ) THEN
    RAISE EXCEPTION 'GATE FAILED: trg_new_user_trial ausente o deshabilitado — el alta de usuarios perdería el trial';
  END IF;
END $$;
