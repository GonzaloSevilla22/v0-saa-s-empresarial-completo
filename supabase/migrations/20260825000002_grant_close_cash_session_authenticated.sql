-- =============================================================================
-- grant_close_cash_session_authenticated.sql
--
-- Mismo patrón que 20260823000002: rpc_close_cash_session nunca tuvo un GRANT
-- explícito a `authenticated`, solo dependía del fallback de PUBLIC. Detectado
-- por el gate de 20260826000001_revoke_anon_analyze_bucket.sql, cuya intención
-- explícita (ver su propio header) es CONSERVAR authenticated en esta función
-- (solo retirarle el acceso a anon/PUBLIC). Las otras 7 funciones de esa misma
-- lista ya tenían grant propio — verificado vía pg_proc.proacl, sesión QA
-- 2026-08-05 (docs/QAimplementation-plan.md §"Drift de migraciones locales").
--
-- Debe aplicarse antes de 20260826000001 en la secuencia.
-- =============================================================================

GRANT EXECUTE ON FUNCTION public.rpc_close_cash_session(uuid, numeric, text) TO authenticated;

DO $$
BEGIN
  IF NOT has_function_privilege('authenticated', 'public.rpc_close_cash_session(uuid, numeric, text)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE FAILED: rpc_close_cash_session sigue sin EXECUTE para authenticated';
  END IF;
END $$;
