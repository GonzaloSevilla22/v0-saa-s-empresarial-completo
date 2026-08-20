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
--   3. get_admin_community_interactions is present; the 4 orphaned admin
--      RPCs (activation_rate/umv_rate/paid_conversion_rate/insights_
--      breakdown) stay dropped (limpiezas-pagos-admin G2, zero callers
--      verified in prod and in the code tree).
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

  -- ── 3. get_dashboard_critical_stock: branch-aware signature must exist ──────
  -- kpi-critical-stock-dashboard (D1/D7): la firma pasa de 0-args a
  -- (p_branch_id uuid DEFAULT NULL) — cuenta sobre branch_stock, consciente
  -- de sucursal. pg_get_function_identity_arguments no imprime el DEFAULT.
  SELECT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid'
  ) INTO v_ok;

  IF v_ok THEN
    RAISE NOTICE 'PASS: get_dashboard_critical_stock branch-aware signature exists';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: get_dashboard_critical_stock(p_branch_id uuid) not found');
  END IF;

  -- ── 4. get_dashboard_critical_stock: allowlist de firmas ─────────────────────
  -- Cualquier firma fuera de la allowlist {p_branch_id uuid} es un overload
  -- inesperado. El (p_user_id uuid) histórico es SECURITY DEFINER, filtra por
  -- el user_id que pasa el caller sin check de auth.uid() (IDOR). Dropped por
  -- 20260430000007, reintroducido por 20260623000001, dropeado de nuevo por
  -- 20260823000001 — debe seguir prohibido explícitamente por nombre/firma.
  SELECT string_agg(pg_get_function_identity_arguments(p.oid), ' | ')
  INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_critical_stock'
    AND pg_get_function_identity_arguments(p.oid) NOT IN ('p_branch_id uuid');

  IF v_bad IS NULL THEN
    RAISE NOTICE 'PASS: get_dashboard_critical_stock has no unexpected overloads';
  ELSE
    v_failures := array_append(v_failures,
      format('FAIL: unexpected get_dashboard_critical_stock overload(s): [%s] '
             '— vulnerable p_user_id overload was dropped by 20260430000007 '
             'and must never come back', v_bad));
  END IF;

  -- ── 5. get_admin_community_interactions exists; the 4 orphaned admin RPCs
  --      were dropped by limpiezas-pagos-admin (G2) — verified zero callers
  --      in prod (pg_proc/prosrc of the whole DB) and in the whole code tree.
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_admin_community_interactions'
  ) THEN
    v_failures := array_append(v_failures,
      'FAIL: get_admin_community_interactions not found (must stay — invoked by rpc_admin_business_kpis and rpc_admin_kpi_overview)');
  ELSE
    RAISE NOTICE 'PASS: get_admin_community_interactions exists';
  END IF;

  SELECT string_agg(fn, ', ')
  INTO v_missing
  FROM (VALUES
    ('get_admin_activation_rate'),
    ('get_admin_umv_rate'),
    ('get_admin_paid_conversion_rate'),
    ('get_admin_insights_breakdown')
  ) AS dropped(fn)
  WHERE EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = dropped.fn
  );

  IF v_missing IS NULL THEN
    RAISE NOTICE 'PASS: the 4 orphaned admin RPCs (activation_rate/umv_rate/paid_conversion_rate/insights_breakdown) are gone (limpiezas-pagos-admin G2)';
  ELSE
    v_failures := array_append(v_failures,
      format('FAIL: orphaned admin RPCs still exist (should have been dropped by limpiezas-pagos-admin G2): %s', v_missing));
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

  -- ── 7. get_admin_community_interactions is SECURITY DEFINER ─────────────────
  -- limpiezas-pagos-admin (G2): las otras 4 fueron dropeadas, no quedan para
  -- este check.
  SELECT bool_and(p.prosecdef)
  INTO v_ok
  FROM pg_proc p
  JOIN pg_namespace n ON p.pronamespace = n.oid
  WHERE n.nspname = 'public'
    AND p.proname = 'get_admin_community_interactions';

  IF COALESCE(v_ok, false) THEN
    RAISE NOTICE 'PASS: get_admin_community_interactions is SECURITY DEFINER';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: get_admin_community_interactions is not SECURITY DEFINER');
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
      AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid'
      AND p.prosrc LIKE '%min_stock > 0%'
  ) INTO v_ok;

  IF v_ok THEN
    RAISE NOTICE 'PASS: get_dashboard_critical_stock contains min_stock > 0 guard';
  ELSE
    v_failures := array_append(v_failures,
      'FAIL: get_dashboard_critical_stock() is missing the min_stock > 0 guard '
      '(lost when 20260623000001 recreated the function without it)');
  END IF;

  -- (§9 — get_admin_paid_conversion_rate signature check — removed by
  -- limpiezas-pagos-admin G2: the RPC itself was dropped, verified above in
  -- §5.)

  -- ── Verdict ─────────────────────────────────────────────────────────────────
  IF COALESCE(array_length(v_failures, 1), 0) > 0 THEN
    RAISE EXCEPTION E'% KPI signature test(s) failed:\n%',
      array_length(v_failures, 1), array_to_string(v_failures, E'\n');
  END IF;

  RAISE NOTICE '=== All deterministic KPI tests passed ===';
END;
$$;
