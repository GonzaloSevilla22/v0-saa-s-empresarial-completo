-- =============================================================================
-- grant_admin_kpi_fns_authenticated.sql
--
-- Otorga GRANT EXECUTE explícito a `authenticated` en 5 funciones admin que
-- dependían únicamente del fallback de PUBLIC (nunca tuvieron un grant propio).
-- Detectado por el gate de 20260824000001_revoke_anon_rest_legit_fns.sql al
-- aplicar esa migración contra una base con 67 migraciones de atraso: el gate
-- frenó correctamente antes de dejar estas 5 funciones sin EXECUTE para
-- authenticated.
--
-- Causa raíz (sesión QA 2026-08-05, detalle en docs/QAimplementation-plan.md
-- §"Drift de migraciones locales"):
--   1. 20260228000400_admin_kpi_metrics.sql crea estas 5 funciones sin ningún
--      GRANT/REVOKE → quedan 100% dependientes del default de Postgres
--      (PUBLIC con EXECUTE).
--   2. 20260517000002_fix_function_search_path.sql intenta restringir el
--      acceso revocándoselo a `anon` específicamente — pero el grant real
--      vivía en PUBLIC, no en anon, así que ese revoke no tuvo efecto real.
--   3. 20260824000001 revoca PUBLIC+anon correctamente (ahí sí se cae el
--      fallback real) y su propio gate detecta que `authenticated` se queda
--      sin acceso — porque nunca lo tuvo de forma independiente.
--
-- Alcance: SOLO estas 5 funciones, todas admin-only (validan is_admin()
-- internamente). Las otras 21 funciones de la lista de 26 de 20260824000001
-- (incluida get_dashboard_financials, la fuente canónica de KPIs del
-- dashboard de cualquier usuario) ya tenían grant propio — no las toca esta
-- migración, y quedan fuera de riesgo (verificado vía pg_proc.proacl).
--
-- Debe aplicarse ANTES de 20260824000001 en la secuencia — por eso el
-- timestamp queda justo después de la última migración aplicada limpia
-- (20260823000001) y antes de la bloqueada.
--
-- GOVERNANCE: antes de un db push a producción, confirmar si 20260824000001
-- ya se aplicó ahí y si tuvo el mismo fallo, o si producción ya tiene estos
-- grants por otra vía no capturada en migraciones.
-- =============================================================================

GRANT EXECUTE ON FUNCTION public.rpc_admin_business_kpis(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_kpi_overview(timestamptz, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_module_stats(text, timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_retention_30d(text, timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_admin_weekly_usage_distribution(timestamptz, timestamptz) TO authenticated;

-- ── GATE — verifica que authenticated efectivamente tenga EXECUTE ───────────
DO $$
DECLARE
  v_sig text;
  v_fns CONSTANT text[] := ARRAY[
    'public.rpc_admin_business_kpis(timestamptz, timestamptz)',
    'public.rpc_admin_kpi_overview(timestamptz, timestamptz, text)',
    'public.rpc_admin_module_stats(text, timestamptz, timestamptz)',
    'public.rpc_admin_retention_30d(text, timestamptz, timestamptz)',
    'public.rpc_admin_weekly_usage_distribution(timestamptz, timestamptz)'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: % sigue sin EXECUTE para authenticated', v_sig;
    END IF;
  END LOOP;
END $$;
