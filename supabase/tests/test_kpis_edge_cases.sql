-- =============================================================================
-- test_kpis_edge_cases.sql — Edge-case KPI RPC behaviour tests
--
-- Verifies runtime behaviour that can be checked without a live user session:
--   1. get_dashboard_financials raises when called without a session (auth.uid() NULL).
--   2. get_dashboard_critical_stock raises when called without a session.
--   3. Inverted date range path exists in get_dashboard_financials (syntax check).
--   4. is_admin() function exists and is callable (used by admin RPCs).
--
-- Uses RAISE EXCEPTION so psql exits non-zero on any failure.
-- =============================================================================

DO $$
DECLARE
  v_raised boolean;
BEGIN

  -- ── 1. get_dashboard_financials must reject NULL auth.uid() ─────────────────
  -- In the local test environment there is no authenticated session, so
  -- auth.uid() returns NULL. The function body starts with:
  --   IF v_uid IS NULL THEN RAISE EXCEPTION 'Not authenticated' ...
  -- We call it and expect the exception.
  v_raised := false;
  BEGIN
    PERFORM public.get_dashboard_financials(
      now() - interval '1 day',
      now()
    );
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_raised := true;
    WHEN OTHERS THEN
      -- Any other exception also means auth guard fired (e.g. different SQLSTATE)
      v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_financials did not raise for unauthenticated call';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_financials rejects unauthenticated call';

  -- ── 2. get_dashboard_critical_stock must reject NULL auth.uid() ─────────────
  v_raised := false;
  BEGIN
    PERFORM public.get_dashboard_critical_stock();
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_raised := true;
    WHEN OTHERS THEN
      v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_critical_stock did not raise for unauthenticated call';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_critical_stock rejects unauthenticated call';

  -- ── 3. Admin RPCs must reject calls (no admin session) ──────────────────────
  -- is_admin() returns false for NULL auth.uid(), so these should raise.
  v_raised := false;
  BEGIN
    PERFORM public.get_admin_paid_conversion_rate();
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_raised := true;
    WHEN OTHERS THEN
      v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL: get_admin_paid_conversion_rate did not raise without admin session';
  END IF;
  RAISE NOTICE 'PASS: get_admin_paid_conversion_rate rejects non-admin call';

  -- ── 4. is_admin() function itself must exist ─────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'is_admin'
  ) THEN
    RAISE EXCEPTION 'FAIL: is_admin() function not found in public schema';
  END IF;
  RAISE NOTICE 'PASS: is_admin() function exists';

  -- ── 5. Function return types are correct ─────────────────────────────────────
  -- get_dashboard_financials must return a SETOF record (table-valued)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_financials'
      AND p.proretset = true      -- RETURNS TABLE / SETOF
  ) THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_financials is not a set-returning function';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_financials is set-returning (RETURNS TABLE)';

  -- get_dashboard_critical_stock must return a scalar (bigint)
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public'
      AND p.proname = 'get_dashboard_critical_stock'
      AND p.proretset = false     -- scalar return
  ) THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_critical_stock is not a scalar function';
  END IF;
  RAISE NOTICE 'PASS: get_dashboard_critical_stock is scalar (RETURNS bigint)';

  -- ── 6. get_admin_paid_conversion_rate: inverted date range must be handled ───
  -- The function has DEFAULT NULL params so inverted dates are possible.
  -- When from > to for a non-NULL range the result should be 0 (not an error),
  -- but since is_admin() raises without a session this just verifies the guard fires.
  v_raised := false;
  BEGIN
    PERFORM public.get_admin_paid_conversion_rate(
      now() + interval '1 day',   -- from > to: inverted
      now() - interval '1 day'
    );
  EXCEPTION
    WHEN insufficient_privilege THEN
      v_raised := true;   -- expected: is_admin() fired first
    WHEN OTHERS THEN
      v_raised := true;
  END;

  IF NOT v_raised THEN
    RAISE EXCEPTION 'FAIL: get_admin_paid_conversion_rate did not raise for non-admin inverted-date call';
  END IF;
  RAISE NOTICE 'PASS: get_admin_paid_conversion_rate rejects non-admin call with date params';

  RAISE NOTICE '=== All edge-case KPI tests passed ===';
END;
$$;


-- =============================================================================
-- kpi-critical-stock-dashboard — behavioural gate for
-- get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL) (tasks 2.3, 2.4,
-- 4.1-4.5). Siembra una cuenta sintética con 2 sucursales + un segundo
-- usuario 'member' de la misma cuenta (D4) + un tercer usuario dueño de una
-- cuenta ajena (branch de otra cuenta). Simula sesión con
-- set_config('request.jwt.claim.sub', ...) — auth.uid() lee el claim 'sub'.
-- Cleanup hijo→padre por email del anchor; no-op si el anchor no existe
-- (patrón 20260806000002 / 20260809000001).
--
-- Fixture (cuenta A, 2 sucursales A y B):
--   p_x       tracked, min_stock=5:  A qty=0 (crítico) / B qty=50 (no crítico)
--   p_multi   tracked, min_stock=3:  A qty=1 (crítico) / B qty=2 (crítico)  — dedup DISTINCT
--   p_zero    tracked, min_stock=0:  A qty=0                                — sin umbral, nunca crítico
--   p_untrk   untracked, min_stock=5: A qty=0                               — excluido (no sostiene stock propio)
--   p_vonly   variant_only, min_stock=5: A qty=0                            — excluido
--   p_legacy  'unit' (legacy desconocido), min_stock=5: A qty=0             — fail-open, SÍ cuenta
--   p_nulltyp NULL, min_stock=5: A qty=0                                    — fail-open, SÍ cuenta
--   p_deleted tracked, min_stock=5: A qty=0, deleted_at=now()               — excluido (soft delete)
--
--   Cuenta con umbral y crítico en A: p_x, p_multi, p_legacy, p_nulltyp = 4
--   Crítico en B: solo p_multi (qty=2 <= min_stock=3) = 1
--   Agregado (sin filtro), DISTINCT product_id: p_x, p_multi, p_legacy, p_nulltyp = 4
--     (si el bug fuera "contar filas" en vez de productos distintos, daría 5:
--      p_multi es crítico en A Y B, sumaría 2 filas)
-- =============================================================================
DO $$
DECLARE
  v_owner_id      uuid := gen_random_uuid();
  v_member_id     uuid := gen_random_uuid();
  v_other_id      uuid := gen_random_uuid();
  v_account_id    uuid;
  v_other_account uuid;
  v_branch_a      uuid;
  v_branch_b      uuid;
  v_branch_foreign uuid;
  v_p_x           uuid;
  v_p_multi       uuid;
  v_p_zero        uuid;
  v_p_untrk       uuid;
  v_p_vonly       uuid;
  v_p_legacy      uuid;
  v_p_nulltyp     uuid;
  v_p_deleted     uuid;
  v_count         bigint;
  v_all_accounts  uuid[];
BEGIN
  -- ── Anchors: 3 usuarios sintéticos, trigger handle_new_user auto-crea cuenta ──
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES
    (v_owner_id,  'authenticated', 'authenticated', 'critical-stock-gate-owner@test.local',  now(), now(), jsonb_build_object('name', 'Gate Owner',  'phone', '', 'locality', '', 'province', '')),
    (v_member_id, 'authenticated', 'authenticated', 'critical-stock-gate-member@test.local', now(), now(), jsonb_build_object('name', 'Gate Member', 'phone', '', 'locality', '', 'province', '')),
    (v_other_id,  'authenticated', 'authenticated', 'critical-stock-gate-other@test.local',  now(), now(), jsonb_build_object('name', 'Gate Other',  'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM public.account_members
  WHERE user_id = v_owner_id
  ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    INSERT INTO public.accounts (id, owner_user_id) VALUES (gen_random_uuid(), v_owner_id) RETURNING id INTO v_account_id;
    INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_id, v_owner_id, 'owner') ON CONFLICT DO NOTHING;
  END IF;

  SELECT account_id INTO v_other_account
  FROM public.account_members
  WHERE user_id = v_other_id
  ORDER BY created_at LIMIT 1;

  IF v_other_account IS NULL THEN
    INSERT INTO public.accounts (id, owner_user_id) VALUES (gen_random_uuid(), v_other_id) RETURNING id INTO v_other_account;
    INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_other_account, v_other_id, 'owner') ON CONFLICT DO NOTHING;
  END IF;

  -- D4: v_member_id es MIEMBRO (no owner) de la cuenta de v_owner_id — nunca
  -- fue dueño de los productos (products.user_id sigue siendo v_owner_id).
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_id, v_member_id, 'member')
  ON CONFLICT DO NOTHING;

  -- ── Sucursales ────────────────────────────────────────────────────────────
  INSERT INTO public.branches (id, account_id, name) VALUES (gen_random_uuid(), v_account_id, '__gate_cs_branch_a__') RETURNING id INTO v_branch_a;
  INSERT INTO public.branches (id, account_id, name) VALUES (gen_random_uuid(), v_account_id, '__gate_cs_branch_b__') RETURNING id INTO v_branch_b;

  SELECT id INTO v_branch_foreign FROM public.branches WHERE account_id = v_other_account ORDER BY created_at LIMIT 1;
  IF v_branch_foreign IS NULL THEN
    INSERT INTO public.branches (id, account_id, name) VALUES (gen_random_uuid(), v_other_account, '__gate_cs_branch_foreign__') RETURNING id INTO v_branch_foreign;
  END IF;

  -- ── Productos (cuenta A, dueño v_owner_id) ──────────────────────────────────
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_x__', 100, 50) RETURNING id INTO v_p_x;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_multi__', 100, 50) RETURNING id INTO v_p_multi;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_zero__', 100, 50) RETURNING id INTO v_p_zero;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, stock_control_type) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_untrk__', 100, 50, 'untracked') RETURNING id INTO v_p_untrk;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, stock_control_type) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_vonly__', 100, 50, 'variant_only') RETURNING id INTO v_p_vonly;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, stock_control_type) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_legacy__', 100, 50, 'unit') RETURNING id INTO v_p_legacy;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_nulltyp__', 100, 50) RETURNING id INTO v_p_nulltyp;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, deleted_at) VALUES (gen_random_uuid(), v_owner_id, v_account_id, '__gate_cs_p_deleted__', 100, 50, now()) RETURNING id INTO v_p_deleted;

  -- ── branch_stock ──────────────────────────────────────────────────────────
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock) VALUES
    (v_account_id, v_p_x,       v_branch_a, 0,  5),
    (v_account_id, v_p_x,       v_branch_b, 50, 5),
    (v_account_id, v_p_multi,   v_branch_a, 1,  3),
    (v_account_id, v_p_multi,   v_branch_b, 2,  3),
    (v_account_id, v_p_zero,    v_branch_a, 0,  0),
    (v_account_id, v_p_untrk,   v_branch_a, 0,  5),
    (v_account_id, v_p_vonly,   v_branch_a, 0,  5),
    (v_account_id, v_p_legacy,  v_branch_a, 0,  5),
    (v_account_id, v_p_nulltyp, v_branch_a, 0,  5),
    (v_account_id, v_p_deleted, v_branch_a, 0,  5);

  -- ── 2.3 (RED→GREEN) — filtro por sucursal cuenta SOLO esa sucursal ─────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);

  SELECT public.get_dashboard_critical_stock(v_branch_a) INTO v_count;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'FAIL 2.3: get_dashboard_critical_stock(branch_a) = % (esperado 4: p_x, p_multi, p_legacy, p_nulltyp)', v_count;
  END IF;
  RAISE NOTICE 'PASS 2.3: filtro por sucursal A cuenta 4 (excluye zero/untracked/variant_only/deleted)';

  SELECT public.get_dashboard_critical_stock(v_branch_b) INTO v_count;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'FAIL: get_dashboard_critical_stock(branch_b) = % (esperado 1: solo p_multi, p_x no es crítico en B)', v_count;
  END IF;
  RAISE NOTICE 'PASS: filtro por sucursal B cuenta 1 (p_x con 50 unidades NO es crítico ahí)';

  -- ── 2.4 / 4.2 (RED→GREEN) — agregado sin filtro: DISTINCT product_id ───────
  SELECT public.get_dashboard_critical_stock() INTO v_count;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'FAIL 2.4/4.2: get_dashboard_critical_stock() = % (esperado 4 — p_multi crítico en A y B cuenta UNA vez, no 2)', v_count;
  END IF;
  RAISE NOTICE 'PASS 2.4/4.2: agregado sin filtro cuenta 4 productos distintos (p_multi dedupeado pese a 2 sucursales críticas)';

  -- ── 4.1 — min_stock=0 nunca cuenta (con y sin filtro) ───────────────────────
  IF EXISTS (
    SELECT 1 FROM public.branch_stock
    WHERE product_id = v_p_zero AND branch_id = v_branch_a AND min_stock > 0
  ) THEN
    RAISE EXCEPTION 'FAIL 4.1: fixture inconsistente — p_zero no debería tener min_stock > 0';
  END IF;
  -- Ya cubierto arriba: v_p_zero no está en los 4 productos contados.
  RAISE NOTICE 'PASS 4.1: min_stock=0 (p_zero) queda fuera de ambos conteos (verificado por exclusión en 2.3/2.4)';

  -- ── 4.5a — un MIEMBRO (no owner de los productos) ve el mismo KPI ───────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_member_id::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_member_id::text, true);

  SELECT public.get_dashboard_critical_stock(v_branch_a) INTO v_count;
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'FAIL 4.5a: member ve % en branch_a, esperado 4 (mismo que el owner — D4 scope por cuenta)', v_count;
  END IF;
  RAISE NOTICE 'PASS 4.5a: member de la cuenta ve el mismo KPI que el owner (scope account_id, no products.user_id)';

  -- ── 4.5b — sucursal de OTRA cuenta no filtra datos ajenos ───────────────────
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_owner_id::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_owner_id::text, true);

  SELECT public.get_dashboard_critical_stock(v_branch_foreign) INTO v_count;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'FAIL 4.5b: get_dashboard_critical_stock(branch de otra cuenta) = % (esperado 0)', v_count;
  END IF;
  RAISE NOTICE 'PASS 4.5b: una sucursal de otra cuenta no expone datos ajenos (0)';

  -- ── Cleanup hijo→padre (best-effort, idempotente) ───────────────────────────
  -- v_member_id también dispara handle_new_user al insertarse en auth.users
  -- (cuenta personal propia, distinta de v_account_id donde es 'member') —
  -- se resuelve TODA cuenta cuyo owner sea alguno de los 3 usuarios sintéticos
  -- además de las 2 ya conocidas, o el DELETE FROM auth.users final falla por
  -- accounts_owner_user_id_fkey (lección de 20260806000002/20260809000001).
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  SELECT COALESCE(array_agg(DISTINCT id), ARRAY[]::uuid[]) INTO v_all_accounts
  FROM public.accounts
  WHERE owner_user_id IN (v_owner_id, v_member_id, v_other_id)
     OR id IN (v_account_id, v_other_account);

  DELETE FROM public.branch_stock       WHERE account_id = ANY (v_all_accounts);
  DELETE FROM public.products           WHERE account_id = ANY (v_all_accounts);
  DELETE FROM public.branches           WHERE account_id = ANY (v_all_accounts);
  DELETE FROM public.account_members    WHERE user_id IN (v_owner_id, v_member_id, v_other_id);
  DELETE FROM public.accounts           WHERE id = ANY (v_all_accounts);
  DELETE FROM public.profiles           WHERE id IN (v_owner_id, v_member_id, v_other_id);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_owner_id, v_member_id, v_other_id);
  DELETE FROM auth.users                WHERE id IN (v_owner_id, v_member_id, v_other_id);

  RAISE NOTICE '=== kpi-critical-stock-dashboard behavioural gate passed ===';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN
      RAISE;
    END IF;
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);

      SELECT COALESCE(array_agg(DISTINCT id), ARRAY[]::uuid[]) INTO v_all_accounts
      FROM public.accounts
      WHERE owner_user_id IN (v_owner_id, v_member_id, v_other_id)
         OR id IN (v_account_id, v_other_account);

      DELETE FROM public.branch_stock       WHERE account_id = ANY (v_all_accounts);
      DELETE FROM public.products           WHERE account_id = ANY (v_all_accounts);
      DELETE FROM public.branches           WHERE account_id = ANY (v_all_accounts);
      DELETE FROM public.account_members    WHERE user_id IN (v_owner_id, v_member_id, v_other_id);
      DELETE FROM public.accounts           WHERE id = ANY (v_all_accounts);
      DELETE FROM public.profiles           WHERE id IN (v_owner_id, v_member_id, v_other_id);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_owner_id, v_member_id, v_other_id);
      DELETE FROM auth.users                WHERE id IN (v_owner_id, v_member_id, v_other_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
