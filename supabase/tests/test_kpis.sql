-- =============================================================================
-- test_kpis.sql — Deterministic KPI RPC signature tests
--
-- Verifies that:
--   1. Secure signatures (auth.uid()-based, no p_user_id) exist. Matched by
--      exact identity arguments, NOT by pronargs: the secure branch-aware
--      get_dashboard_financials(timestamptz, timestamptz, uuid) and the old
--      vulnerable (uuid, timestamptz, timestamptz) overload BOTH have 3 args,
--      so counting arguments cannot tell them apart.
--   2. No other overloads exist (vulnerable p_user_id variants stay dropped).
--   3. All admin RPCs are present.
--   4. Functions are SECURITY DEFINER.
--
-- All checks run; failures accumulate and a single RAISE EXCEPTION at the end
-- reports every one, so psql (run with -v ON_ERROR_STOP=1) exits non-zero.
-- =============================================================================

DO $$
DECLARE
  v_ok       boolean;
  v_bad      text;
  v_missing  text;
  v_failures text[] := '{}';
  -- Secure signature since 20260607000002_branch_filter_dashboard:
  --   (p_date_from timestamptz, p_date_to timestamptz, p_branch_id uuid DEFAULT NULL)
  c_financials_args constant text :=
    'p_date_from timestamp with time zone, p_date_to timestamp with time zone, p_branch_id uuid';
BEGIN

  -- ── 1. get_dashboard_financials: secure branch-aware signature must exist ───
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_financials'
      AND pg_get_function_identity_arguments(p.oid) = c_financials_args
  ) INTO v_ok;

  IF v_ok THEN
    RAISE NOTICE 'PASS: get_dashboard_financials secure signature exists';
  ELSE
    v_failures := array_append(v_failures,
      format('FAIL: get_dashboard_financials(%s) not found', c_financials_args));
  END IF;

  -- ── 2. get_dashboard_financials: no other overload may exist ────────────────
  -- Catches the vulnerable (p_user_id uuid, ...) overload dropped by
  -- 20260610000002 — and any future accidental overload.
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_financials'
    AND pg_get_function_identity_arguments(p.oid) <> c_financials_args;

  IF v_bad IS NULL THEN
    RAISE NOTICE 'PASS: get_dashboard_financials has no unexpected overloads';
  ELSE
    v_failures := array_append(v_failures,
      format('FAIL: unexpected get_dashboard_financials overload(s): [%s]', v_bad));
  END IF;

  -- ── 3. get_dashboard_critical_stock: secure 0-param version must exist ──────
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND pg_get_function_identity_arguments(p.oid) = ''   -- no params
  ) INTO v_ok;

  IF v_ok THEN
    RAISE NOTICE 'PASS: get_dashboard_critical_stock secure signature exists';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: get_dashboard_critical_stock() not found');
  END IF;

  -- ── 4. get_dashboard_critical_stock: no other overload may exist ────────────
  -- The (p_user_id uuid) overload is SECURITY DEFINER, filters by the
  -- caller-supplied user_id and performs no auth.uid() check (IDOR). Dropped
  -- by 20260430000007; must never come back.
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_critical_stock'
    AND pg_get_function_identity_arguments(p.oid) <> '';

  IF v_bad IS NULL THEN
    RAISE NOTICE 'PASS: get_dashboard_critical_stock has no unexpected overloads';
  ELSE
    v_failures := array_append(v_failures,
      format('FAIL: unexpected get_dashboard_critical_stock overload(s): [%s] '
             '— vulnerable p_user_id overload was dropped by 20260430000007 '
             'and reintroduced by 20260623000001 — it must be dropped again', v_bad));
  END IF;

  -- ── 5. All five admin RPCs must exist ────────────────────────────────────────
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

  IF v_missing IS NULL THEN
    RAISE NOTICE 'PASS: all 5 admin RPCs exist';
  ELSE
    v_failures := array_append(v_failures,
      format('FAIL: admin RPCs not found: %s', v_missing));
  END IF;

  -- ── 6. Tenant RPCs are SECURITY DEFINER ─────────────────────────────────────
  SELECT bool_and(p.prosecdef)
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname IN ('get_dashboard_financials', 'get_dashboard_critical_stock');

  IF COALESCE(v_ok, false) THEN
    RAISE NOTICE 'PASS: tenant KPI functions are SECURITY DEFINER';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: tenant KPI functions are not SECURITY DEFINER');
  END IF;

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

  IF COALESCE(v_ok, false) THEN
    RAISE NOTICE 'PASS: admin KPI functions are SECURITY DEFINER';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: admin KPI functions are not SECURITY DEFINER');
  END IF;

  -- ── 8. get_dashboard_critical_stock excludes min_stock = 0 products ─────────
  -- Canonical predicate (RN-23, frontend/lib/product-stock.ts): min_stock = 0
  -- means "no threshold configured" and must NOT count as critical. The
  -- function body must contain the min_stock > 0 guard. Static code check;
  -- behavioural validation requires a live session.
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND pg_get_function_identity_arguments(p.oid) = ''
      AND p.prosrc LIKE '%min_stock > 0%'
  ) INTO v_ok;

  IF v_ok THEN
    RAISE NOTICE 'PASS: get_dashboard_critical_stock contains min_stock > 0 guard';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: get_dashboard_critical_stock() is missing the min_stock > 0 guard '
      '(lost when 20260623000001 recreated the function without it)');
  END IF;

  -- ── 9. get_admin_paid_conversion_rate accepts optional date params ──────────
  -- Signature: (timestamptz DEFAULT NULL, timestamptz DEFAULT NULL).
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_admin_paid_conversion_rate'
      AND p.pronargs = 2
      AND p.pronargdefaults = 2   -- both params must default to NULL
  ) INTO v_ok;

  IF v_ok THEN
    RAISE NOTICE 'PASS: get_admin_paid_conversion_rate has optional date-range signature';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: get_admin_paid_conversion_rate does not have the 2-param (date-optional) signature');
  END IF;

  -- ── Verdict ─────────────────────────────────────────────────────────────────
  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'% KPI signature test(s) failed:\n%',
      array_length(v_failures, 1), array_to_string(v_failures, E'\n');
  END IF;

  RAISE NOTICE '=== All deterministic KPI tests passed ===';
END;
$$;
