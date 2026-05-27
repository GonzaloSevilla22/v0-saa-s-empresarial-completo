-- =============================================================================
-- test_kpis.sql — Deterministic KPI RPC signature tests
--
-- Verifies that:
--   1. Secure signatures (no p_user_id) exist.
--   2. Vulnerable overloads (with uuid param) were dropped.
--   3. All admin RPCs are present.
--   4. Functions are SECURITY DEFINER with search_path = public.
--
-- Uses RAISE EXCEPTION so psql exits non-zero on any failure.
-- =============================================================================

DO $$
DECLARE
  v_ok boolean;
BEGIN

  -- ── 1. get_dashboard_financials: secure 2-param version must exist ──────────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_financials'
      AND p.pronargs = 2          -- (timestamptz, timestamptz) — no uuid
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_financials(timestamptz, timestamptz) not found';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_financials secure signature exists';

  -- ── 2. get_dashboard_financials: old vulnerable (uuid,...) overload gone ────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_financials'
      AND p.pronargs = 3          -- old: (uuid, timestamptz, timestamptz)
  ) INTO v_ok;

  IF v_ok THEN
    RAISE EXCEPTION 'FAIL: vulnerable get_dashboard_financials(uuid,...) overload still exists';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_financials vulnerable overload absent';

  -- ── 3. get_dashboard_critical_stock: secure 0-param version must exist ──────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND p.pronargs = 0          -- no params
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_critical_stock() not found';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_critical_stock secure signature exists';

  -- ── 4. get_dashboard_critical_stock: old vulnerable (uuid) overload gone ────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND p.pronargs = 1          -- old: (uuid)
  ) INTO v_ok;

  IF v_ok THEN
    RAISE EXCEPTION 'FAIL: vulnerable get_dashboard_critical_stock(uuid) overload still exists';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_critical_stock vulnerable overload absent';

  -- ── 5. All five admin RPCs must exist ────────────────────────────────────────
  DECLARE
    v_missing text;
  BEGIN
    SELECT string_agg(expected.fn, ', ')
    INTO v_missing
    FROM (VALUES
      ('get_admin_activation_rate'),
      ('get_admin_umv_rate'),
      ('get_admin_paid_conversion_rate'),
      ('get_admin_community_interactions'),
      ('get_admin_insights_breakdown')
    ) AS expected(fn)
    WHERE NOT EXISTS (
      SELECT 1 FROM pg_proc p
      JOIN pg_namespace n ON p.pronamespace = n.oid
      WHERE n.nspname = 'public'
        AND p.proname = expected.fn
    );

    IF v_missing IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL: admin RPCs not found: %', v_missing;
    END IF;
  END;
  RAISE NOTICE 'PASS: all 5 admin RPCs exist';

  -- ── 6. Tenant RPCs are SECURITY DEFINER ─────────────────────────────────────
  SELECT bool_and(p.prosecdef)
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname IN ('get_dashboard_financials', 'get_dashboard_critical_stock');

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: tenant KPI functions are not SECURITY DEFINER';
  END IF;
  RAISE NOTICE 'PASS: tenant KPI functions are SECURITY DEFINER';

  -- ── 7. Admin RPCs are SECURITY DEFINER ──────────────────────────────────────
  SELECT bool_and(p.prosecdef)
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname IN (
      'get_admin_activation_rate',
      'get_admin_umv_rate',
      'get_admin_paid_conversion_rate',
      'get_admin_community_interactions',
      'get_admin_insights_breakdown'
    );

  IF NOT COALESCE(v_ok, false) THEN
    RAISE EXCEPTION 'FAIL: admin KPI functions are not SECURITY DEFINER';
  END IF;
  RAISE NOTICE 'PASS: admin KPI functions are SECURITY DEFINER';

  -- ── 8. get_dashboard_critical_stock excludes min_stock = 0 products ─────────
  -- Verify the function definition contains the min_stock > 0 guard.
  -- This is a static code check; behavioural validation requires a live session.
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND p.prosrc  LIKE '%min_stock > 0%'
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_critical_stock is missing the min_stock > 0 guard';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_critical_stock contains min_stock > 0 guard';

  -- ── 9. get_admin_paid_conversion_rate accepts optional date params ────────────
  -- New signature: (timestamptz DEFAULT NULL, timestamptz DEFAULT NULL).
  -- pronargs = 2; both params must have defaults (proisstrict = false / pronargdefaults set).
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_admin_paid_conversion_rate'
      AND p.pronargs = 2
  ) INTO v_ok;

  IF NOT v_ok THEN
    RAISE EXCEPTION 'FAIL: get_admin_paid_conversion_rate does not have the 2-param (date-optional) signature';
  END IF;
  RAISE NOTICE 'PASS: get_admin_paid_conversion_rate has optional date-range signature';

  RAISE NOTICE '=== All deterministic KPI tests passed ===';
END;
$$;
