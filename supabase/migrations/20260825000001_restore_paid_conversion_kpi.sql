-- ═══════════════════════════════════════════════════════════════════════════
-- restore-paid-conversion-kpi — repara drift prod↔migraciones en
-- get_admin_paid_conversion_rate (regresión del fix de seguridad 20260430000007)
-- ═══════════════════════════════════════════════════════════════════════════
--
-- HALLAZGO (2026-08-01, durante el lote 4 de advisors): prod tiene SOLO la
-- versión LEGACY `get_admin_paid_conversion_rate()` (cuerpo de 20260430000004):
--   · SIN guard is_admin()  → cualquier usuario autenticado podía leer el KPI
--     global de conversión paga de la plataforma (SECURITY DEFINER sin guard),
--   · SIN SET search_path   → flaggeada por el advisor 0011,
--   · SIN el overload 2-args → el filtro por fechas del panel admin
--     (adminAnalytics.ts fetchPaidConversionRate con p_date_from/p_date_to)
--     devolvía 404 de PostgREST en prod.
--
-- La migración 20260430000007_fix_kpi_rpc_security ya había dropeado la () y
-- creado la 2-args con guard — en prod alguien recreó la vieja después (drift
-- manual; la cadena de migraciones NO la recrea, CI no la tiene). Esta
-- migración restaura el estado definido por las migraciones:
--   1. DROP de la legacy () (no-op en CI, donde no existe).
--   2. Recrea la 2-args canónica (copia EXACTA de 20260430000007; en CI es un
--      CREATE OR REPLACE idéntico que conserva ACLs).
--   3. Re-aplica ACLs en el mismo archivo — regla DROP+CREATE-resetea-ACLs:
--      REVOKE PUBLIC+anon (en prod el CREATE fresco dispara los default
--      privileges que le regalan EXECUTE a anon) + GRANT explícito a
--      authenticated (paridad con 20260430000007).
--
-- Sin cambios de frontend: la llamada sin parámetros ({}) resuelve a la 2-args
-- por los DEFAULT NULL con la MISMA semántica all-time; la llamada con fechas
-- vuelve a funcionar. El guard is_admin() no afecta a los callers reales (el
-- panel admin solo lo usan admins).

DROP FUNCTION IF EXISTS public.get_admin_paid_conversion_rate();

CREATE OR REPLACE FUNCTION public.get_admin_paid_conversion_rate(
  p_date_from timestamptz DEFAULT NULL,
  p_date_to   timestamptz DEFAULT NULL
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_rate numeric;
BEGIN
  IF NOT public.is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- When dates are supplied: % of the registered cohort that is on 'pro' plan.
  -- When NULL: all-time snapshot across all profiles (original behavior).
  SELECT COALESCE(
    ROUND(
      (COUNT(*) FILTER (WHERE plan = 'pro')::numeric / NULLIF(COUNT(*), 0)) * 100,
      2
    ), 0
  ) INTO v_rate
  FROM public.profiles
  WHERE (p_date_from IS NULL OR created_at >= p_date_from)
    AND (p_date_to   IS NULL OR created_at <= p_date_to);

  RETURN v_rate;
END;
$$;

REVOKE EXECUTE ON FUNCTION public.get_admin_paid_conversion_rate(timestamptz, timestamptz) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.get_admin_paid_conversion_rate(timestamptz, timestamptz) TO authenticated;

-- ── GATES ────────────────────────────────────────────────────────────────────
DO $$
DECLARE
  v_count int;
  v_fn CONSTANT regprocedure :=
    'public.get_admin_paid_conversion_rate(timestamptz, timestamptz)'::regprocedure;
BEGIN
  -- (a) 42725: queda exactamente 1 definición (la legacy () fue eliminada)
  SELECT COUNT(*) INTO v_count
  FROM pg_proc
  WHERE pronamespace = 'public'::regnamespace
    AND proname = 'get_admin_paid_conversion_rate';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: esperaba 1 definición de get_admin_paid_conversion_rate, hay %', v_count;
  END IF;

  -- (b) el guard is_admin() y el search_path fijo están presentes
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid = v_fn
      AND prosrc LIKE '%is_admin%'
      AND proconfig::text LIKE '%search_path%'
  ) THEN
    RAISE EXCEPTION 'GATE (b) FAILED: la función restaurada no tiene guard is_admin() o search_path fijo';
  END IF;

  -- (c) ACLs: anon sin EXECUTE (cubre PUBLIC por herencia), authenticated con EXECUTE
  IF has_function_privilege('anon', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (c) FAILED: anon sigue con EXECUTE';
  END IF;
  IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (c) FAILED: authenticated quedó sin EXECUTE';
  END IF;
END $$;
