-- =============================================================================
-- MIGRATION: 20260808000003_v3_notifications_advisor_revoke.sql
-- CHANGE:    v3-notifications-realtime (cierre — hallazgo de advisors post-merge)
--
-- get_advisors (security) tras el merge de #262 marcó:
--   anon/authenticated_security_definer_function_executable sobre
--   public.trg_fiscal_document_rejected() — la función trigger nueva quedó
--   con el EXECUTE default de PUBLIC (via /rest/v1/rpc sería invocable,
--   aunque Postgres rechaza funciones RETURNS trigger fuera de contexto de
--   trigger: riesgo real nulo, pero el advisor y el patrón del proyecto
--   piden el REVOKE explícito — mismo tratamiento que recibió
--   trg_quote_record_creation en 20260807000001:413).
--
-- Se incluye también check_branch_low_stock(): misma clase de hallazgo;
-- función preexistente (20260608000000) pero recreada por este change
-- (producer StockBelowMinimum, 20260808000002) — se normaliza su ACL aquí.
--
-- El firing de triggers NO requiere EXECUTE del rol que dispara la mutación
-- (el privilegio evaluado es sobre la tabla), así que el REVOKE es inocuo
-- para el funcionamiento de ambos triggers.
--
-- IDEMPOTENCIA: REVOKE es idempotente por naturaleza.
-- APPLY: CI al mergear (NUNCA db push manual ni MCP apply_migration).
-- =============================================================================

REVOKE ALL ON FUNCTION public.trg_fiscal_document_rejected() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.check_branch_low_stock() FROM PUBLIC, anon, authenticated;

-- ── Gate: ninguna de las dos funciones queda ejecutable por roles de app ─────
DO $gate$
BEGIN
    IF has_function_privilege('anon', 'public.trg_fiscal_document_rejected()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.trg_fiscal_document_rejected()', 'EXECUTE')
    THEN
        RAISE EXCEPTION 'GATE FAILED: trg_fiscal_document_rejected sigue ejecutable por roles de app';
    END IF;

    IF has_function_privilege('anon', 'public.check_branch_low_stock()', 'EXECUTE')
       OR has_function_privilege('authenticated', 'public.check_branch_low_stock()', 'EXECUTE')
    THEN
        RAISE EXCEPTION 'GATE FAILED: check_branch_low_stock sigue ejecutable por roles de app';
    END IF;

    RAISE NOTICE '=== v3-notifications advisor revoke === OK';
END
$gate$;
