-- ═══════════════════════════════════════════════════════════════════════════
-- revoke-billing-cancellations-fn-execute — cierra advisors 0028/0029 para
-- process_cancellations() (cron-only, billing)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ⚠ GOVERNANCE: dominio billing = CRÍTICO. Este archivo se PROPONE gateado por
--   sign-off explícito del PO — NO mergear sin esa aprobación (el pipeline
--   aplica las migraciones a prod automáticamente al mergear a main).
--
-- Continuación del plan de openspec/explore/2026-07-31-advisor-0028-0029-
-- inventory.md (paso 1) tras 20260820000001 (#325, mergeado con sign-off PO):
-- misma evidencia, misma familia (billing), mismo patrón.
--
--   · process_cancellations()  cron-only  (cron.job 'process-cancellations',
--     30 3 * * *, username postgres, active) — sweep diario que baja a
--     gratis/cancelled las cuentas en billing_status='cancelling' con
--     plan_expires_at vencido + registra billing_events 'plan_cancelled'.
--
-- Verificado en prod (2026-08-01, read-only, MCP) antes de proponer:
--   · proacl: {=X/postgres, postgres=X, anon=X, authenticated=X,
--     service_role=X} — anon/authenticated pueden EXECUTE hoy vía
--     /rest/v1/rpc/process_cancellations.
--   · A diferencia de expire_trials (descriptivo), esta función MUTA estado
--     de billing (plan y status): un anon hoy puede forzar el timing del
--     sweep. El resultado sería el "correcto" (solo toca cuentas ya
--     'cancelling' y vencidas), pero no hay ninguna razón para permitirlo.
--   · cron corre como postgres → conserva EXECUTE (este archivo no lo toca).
--   · 0 callers vía REST en el código: grep en frontend/, backend/ y
--     supabase/functions/ → solo comentarios (app/api/billing/cancel/route.ts
--     documenta que el sweep corre por cron), lógica espejo en tests puros
--     (billing.test.ts) y los tipos generados de database.types.ts.
--
-- service_role CONSERVA EXECUTE (igual que 20260818000001 y 20260820000001).
--
-- Idempotente: REVOKE repetido es no-op; guard to_regprocedure =
-- drift-tolerante (no-op si la función no existe en el entorno).
--
-- Rollback (no recomendado — reabre los WARN sin ganar nada):
--   GRANT EXECUTE ON FUNCTION public.process_cancellations() TO anon, authenticated;

DO $$
BEGIN
  IF to_regprocedure('public.process_cancellations()') IS NOT NULL THEN
    REVOKE ALL ON FUNCTION public.process_cancellations() FROM PUBLIC, anon, authenticated;
  END IF;
END $$;

-- ── GATE 1: no queda ejecutable por anon/authenticated ──────────────────────
DO $$
DECLARE
  v_role text;
BEGIN
  IF to_regprocedure('public.process_cancellations()') IS NOT NULL THEN
    FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated'] LOOP
      IF has_function_privilege(v_role, to_regprocedure('public.process_cancellations()'), 'EXECUTE') THEN
        RAISE EXCEPTION 'GATE FAILED: process_cancellations() sigue con EXECUTE para %', v_role;
      END IF;
    END LOOP;
  END IF;
END $$;

-- ── GATE 2 (positivo): el cron no se rompe ──────────────────────────────────
DO $$
BEGIN
  IF to_regprocedure('public.process_cancellations()') IS NOT NULL
     AND NOT has_function_privilege('postgres', to_regprocedure('public.process_cancellations()'), 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED: postgres perdió EXECUTE sobre process_cancellations() — el cron process-cancellations dejaría de correr';
  END IF;
END $$;
