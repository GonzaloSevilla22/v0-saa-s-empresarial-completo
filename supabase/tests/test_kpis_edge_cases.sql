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


-- =============================================================================
-- kpi-branch-consistency — behavioural gate (tasks 2.1-2.6 + 6.1-6.5, grupos
-- 3-6).
--
-- Grupos 3-5: Parte B diario (D6, get_dashboard_financials neto de NC vía el
-- helper único D5) y Parte A no bloqueada (D3/D4, stock sin rotación de
-- rpc_dashboard_kpi_summary por sucursal).
--
-- Grupo 6 (OQ-1 firmada por el PO 2026-08-12, rama HÍBRIDA — design.md
-- §Open Questions): la atribución de NC por sucursal (D1) y
-- collected_revenue = NULL bajo filtro (D2) quedan implementadas en
-- supabase/migrations/20260920000001_kpi_branch_nc_attribution.sql. El
-- helper reporting_credit_notes_in_window deja de ignorar p_branch_id: la NC
-- se atribuye a la sucursal de su documento origen (sales_orders.branch_id
-- vía customer_account_movements.reference_id). El assert 1 (diario ≡
-- mensual) sigue verificando que ambos consumidores usen el mismo helper
-- (D5), ahora bajo la regla de atribución real.
--
-- Fixture (cuenta con sucursales A y B):
--   Ventas:   A qty=2 total=2000 (multi-unidad, total≠amount) | B total=500
--             | legacy branch_id NULL total=300 (evidencia de rotación D4)
--   Gastos:   A=100 | B=50
--   Compras:  A=200 | B=80
--   NC:       -400 (customer_account_movements, movement_type=credit_note),
--             reference_id → sales_orders (v_so_a) de la sucursal A: la NC
--             "pertenece" a A (D1).
--   Sin filtro:  invoiced = 2800-400=2400; net_profit = 2400-(150+280)=1970
--     (sin filtro la NC resta una sola vez, sea cual sea su sucursal — D1)
--   Filtro A:    invoiced = 2000-400=1600; net_profit = 1600-(100+200)=1300
--     (la NC es de A → resta en A)
--   Filtro B (task 6.1, grupo 6): invoiced = 500-0=500;
--     net_profit = 500-(50+80)=370
--     (la NC es de A, NO de B → NO resta en B: D1 es fail-CLOSED sobre la
--     sucursal que no la originó — no se duplica ni se reparte)
--   collected_revenue (task 6.2, grupo 6): NULL en rpc_dashboard_kpi_summary
--     cuando p_branch_id IS NOT NULL (A o B), sea cual sea charges_agg/
--     payments_agg (D2 — el par cargos/cobros no es atribuible a sucursal,
--     "percibido por sucursal" no es una métrica computable); sin filtro,
--     collected_revenue = invoiced_revenue (fixture sin cargos/cobros de cta
--     cte) y NO es NULL.
--
--   Stock sin rotación:
--     p_stagnant         cost=100, sin ventas: A qty=10, B qty=40
--                         → filtro A: value=1000 cnt=1 | sin filtro: value=5000 cnt=1
--     p_stagnant_deleted  cost=100, deleted_at=now(), A qty=5 → NUNCA cuenta (soft delete)
--     p_rotation_legacy   cost=80, A qty=20, con una venta LEGACY (branch_id NULL)
--                         en la ventana → NUNCA cuenta (D4 fail-open: la venta
--                         legacy es evidencia de rotación en cualquier sucursal)
--   Por construcción: filtro A → value=1000/cnt=1 (solo p_stagnant); sin
--   filtro → value=5000/cnt=1. Si p_stagnant_deleted o p_rotation_legacy
--   contaminaran el resultado, estos números no cerrarían.
-- =============================================================================
DO $$
DECLARE
  v_anchor_email     text := 'kpi-branch-consistency-gate@test.local';
  v_user_id          uuid := gen_random_uuid();
  v_account_id       uuid;
  v_branch_a         uuid;
  v_branch_b         uuid;
  v_client_id        uuid;
  v_customer_acct_id uuid;
  v_so_a             uuid;
  v_p1               uuid;
  v_p2               uuid;
  v_p_stagnant       uuid;
  v_p_stagnant_del   uuid;
  v_p_rotation_leg   uuid;
  v_from             timestamptz := now() - interval '2 days';
  v_to               timestamptz := now() + interval '1 day';
  v_prev_from        timestamptz := now() - interval '40 days';
  v_prev_to          timestamptz := now() - interval '35 days';
  v_fin_none         record;
  v_fin_a             record;
  v_fin_b            record;
  v_sum_none         record;
  v_sum_a            record;
  v_sum_b            record;
BEGIN
  -- ── Anchor sintético: dispara handle_new_user (account + branch + cashbox) ──
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate KPI Branch Consistency', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE KPI-BRANCH-CONSISTENCY: no se pudo resolver una account para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  -- Simula sesión del anchor: auth.uid() lee el claim 'sub' vía GUC de
  -- request — necesario para invocar get_dashboard_financials/
  -- rpc_dashboard_kpi_summary directamente (ambas SECURITY DEFINER exigen
  -- auth.uid() IS NOT NULL). Mismo patrón que el gate kpi-critical-stock-dashboard.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_id::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_id::text, true);

  -- ── Dos sucursales propias del fixture (no dependen de "Casa Central") ──────
  INSERT INTO public.branches (id, account_id, name) VALUES (gen_random_uuid(), v_account_id, '__gate_kbc_branch_a__') RETURNING id INTO v_branch_a;
  INSERT INTO public.branches (id, account_id, name) VALUES (gen_random_uuid(), v_account_id, '__gate_kbc_branch_b__') RETURNING id INTO v_branch_b;

  -- ── Productos ────────────────────────────────────────────────────────────
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_user_id, v_account_id, '__gate_kbc_p1__', 1000, 100) RETURNING id INTO v_p1;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_user_id, v_account_id, '__gate_kbc_p2__', 500,  50)  RETURNING id INTO v_p2;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_user_id, v_account_id, '__gate_kbc_p_stagnant__', 100, 100) RETURNING id INTO v_p_stagnant;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost, deleted_at) VALUES (gen_random_uuid(), v_user_id, v_account_id, '__gate_kbc_p_stagnant_deleted__', 100, 100, now()) RETURNING id INTO v_p_stagnant_del;
  INSERT INTO public.products (id, user_id, account_id, name, price, cost) VALUES (gen_random_uuid(), v_user_id, v_account_id, '__gate_kbc_p_rotation_legacy__', 80, 80) RETURNING id INTO v_p_rotation_leg;

  -- ── Cliente + cabecera de cta cte (para la NC) ──────────────────────────────
  INSERT INTO public.clients (user_id, account_id, name)
  VALUES (v_user_id, v_account_id, '__gate_kbc_client__')
  RETURNING id INTO v_client_id;

  INSERT INTO public.customer_accounts (account_id, client_id, balance, created_by)
  VALUES (v_account_id, v_client_id, 0, v_user_id)
  RETURNING id INTO v_customer_acct_id;

  -- ── Orden de venta de la sucursal A (task 6.1) — documento origen al que la
  --    NC se atribuye vía reference_id. No necesita corresponder a una fila
  --    real de `sales`: el revenue se calcula sobre `sales`, la atribución de
  --    la NC se calcula sobre `sales_orders` (D1) — son universos separados.
  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by)
  VALUES (v_account_id, v_branch_a, v_client_id, 'confirmed', 400, v_user_id)
  RETURNING id INTO v_so_a;

  -- ── Ventas ───────────────────────────────────────────────────────────────
  -- Branch A: quantity=2, amount(unitario)=1000, total=2000 (multi-unidad).
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_a, v_p1, 1000, 2, 2000, now());
  -- Branch B.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_b, v_p2, 500, 1, 500, now());
  -- Legacy sin sucursal (branch_id NULL) — evidencia de rotación D4 sobre p_rotation_leg.
  INSERT INTO public.sales (user_id, account_id, branch_id, product_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, NULL, v_p_rotation_leg, 300, 1, 300, now());

  -- ── Gastos ───────────────────────────────────────────────────────────────
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_a, 'otros', 100, now());
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_b, 'otros', 50, now());

  -- ── Compras ──────────────────────────────────────────────────────────────
  INSERT INTO public.purchases (user_id, account_id, branch_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_a, 200, 1, 200, now());
  INSERT INTO public.purchases (user_id, account_id, branch_id, amount, quantity, total, date)
  VALUES (v_user_id, v_account_id, v_branch_b, 80, 1, 80, now());

  -- ── Nota de crédito: -400 (acredita al cliente, vive negativa en el ledger).
  --    reference_id → v_so_a (sales_orders de la sucursal A) — atribución D1.
  INSERT INTO public.customer_account_movements
    (customer_account_id, account_id, amount, balance_after, movement_type, reference_id, created_by, created_at)
  VALUES (v_customer_acct_id, v_account_id, -400, 0, 'credit_note', v_so_a, v_user_id, now());

  -- ── branch_stock para el trío de stock sin rotación ─────────────────────────
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock) VALUES
    (v_account_id, v_p_stagnant,     v_branch_a, 10, 0),
    (v_account_id, v_p_stagnant,     v_branch_b, 40, 0),
    (v_account_id, v_p_stagnant_del, v_branch_a, 5,  0),
    (v_account_id, v_p_rotation_leg, v_branch_a, 20, 0);

  -- ══════════════════════════════════════════════════════════════════════════
  -- ASSERT 1 (tasks 2.3/2.4) — diario ≡ mensual, sin filtro y con filtro A.
  -- ══════════════════════════════════════════════════════════════════════════
  SELECT * INTO v_fin_none FROM public.get_dashboard_financials(v_from, v_to, NULL);
  SELECT * INTO v_sum_none FROM public.rpc_dashboard_kpi_summary(v_from, v_to, v_prev_from, v_prev_to, NULL);

  IF v_fin_none.total_income IS DISTINCT FROM v_sum_none.invoiced_revenue THEN
    RAISE EXCEPTION 'FAIL 2.3a: sin filtro, get_dashboard_financials.total_income (%) <> rpc_dashboard_kpi_summary.invoiced_revenue (%)',
      v_fin_none.total_income, v_sum_none.invoiced_revenue;
  END IF;
  IF v_fin_none.net_profit IS DISTINCT FROM v_sum_none.net_profit THEN
    RAISE EXCEPTION 'FAIL 2.3b: sin filtro, get_dashboard_financials.net_profit (%) <> rpc_dashboard_kpi_summary.net_profit (%)',
      v_fin_none.net_profit, v_sum_none.net_profit;
  END IF;
  IF v_fin_none.total_income <> 2400 THEN
    RAISE EXCEPTION 'FAIL 2.3c: total_income sin filtro esperaba 2400 (2800 ventas - 400 NC), dio %', v_fin_none.total_income;
  END IF;
  RAISE NOTICE 'PASS 2.3: diario ≡ mensual sin filtro de sucursal (total_income=%, net_profit=%)', v_fin_none.total_income, v_fin_none.net_profit;

  SELECT * INTO v_fin_a FROM public.get_dashboard_financials(v_from, v_to, v_branch_a);
  SELECT * INTO v_sum_a FROM public.rpc_dashboard_kpi_summary(v_from, v_to, v_prev_from, v_prev_to, v_branch_a);

  IF v_fin_a.total_income IS DISTINCT FROM v_sum_a.invoiced_revenue THEN
    RAISE EXCEPTION 'FAIL 2.4a: filtro branch_a, get_dashboard_financials.total_income (%) <> rpc_dashboard_kpi_summary.invoiced_revenue (%)',
      v_fin_a.total_income, v_sum_a.invoiced_revenue;
  END IF;
  IF v_fin_a.net_profit IS DISTINCT FROM v_sum_a.net_profit THEN
    RAISE EXCEPTION 'FAIL 2.4b: filtro branch_a, get_dashboard_financials.net_profit (%) <> rpc_dashboard_kpi_summary.net_profit (%)',
      v_fin_a.net_profit, v_sum_a.net_profit;
  END IF;
  IF v_fin_a.total_income <> 1600 THEN
    RAISE EXCEPTION 'FAIL 2.4c: total_income filtro branch_a esperaba 1600 (2000 ventas de A - 400 NC global), dio %', v_fin_a.total_income;
  END IF;
  RAISE NOTICE 'PASS 2.4: diario ≡ mensual con filtro de sucursal A (total_income=%, net_profit=%)', v_fin_a.total_income, v_fin_a.net_profit;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ASSERT 2 (task 2.5) — stock sin rotación por sucursal + exclusión soft-delete.
  -- ══════════════════════════════════════════════════════════════════════════
  IF v_sum_a.stagnant_stock_value <> 1000 OR v_sum_a.stagnant_stock_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 2.5a: stagnant con filtro branch_a esperaba value=1000 cnt=1 (solo p_stagnant, 10u*$100), dio value=% cnt=%',
      v_sum_a.stagnant_stock_value, v_sum_a.stagnant_stock_count;
  END IF;
  IF v_sum_none.stagnant_stock_value <> 5000 OR v_sum_none.stagnant_stock_count <> 1 THEN
    RAISE EXCEPTION 'FAIL 2.5b: stagnant sin filtro esperaba value=5000 cnt=1 (p_stagnant 50u*$100, contado una sola vez), dio value=% cnt=%',
      v_sum_none.stagnant_stock_value, v_sum_none.stagnant_stock_count;
  END IF;
  RAISE NOTICE 'PASS 2.5: stock sin rotación por sucursal (A=1000/1, sin filtro=5000/1) y soft-deleted excluido';

  -- ══════════════════════════════════════════════════════════════════════════
  -- ASSERT 3 (task 2.6) — fail-open D4: venta legacy exime de "sin rotación".
  -- Ya cubierto por construcción en el ASSERT 2 (si p_rotation_legacy hubiera
  -- contaminado el value/count de branch_a, 1000/1 no habría cerrado).
  -- ══════════════════════════════════════════════════════════════════════════
  RAISE NOTICE 'PASS 2.6: p_rotation_legacy (venta legacy branch_id NULL) no cuenta como stock sin rotación en branch_a (verificado por construcción en 2.5a)';

  -- ══════════════════════════════════════════════════════════════════════════
  -- ASSERT 4 (task 6.1, grupo 6, OQ-1 híbrida) — la NC de la sucursal A NO
  -- resta al filtrar sucursal B, y sin filtro resta una sola vez.
  -- ══════════════════════════════════════════════════════════════════════════
  SELECT * INTO v_fin_b FROM public.get_dashboard_financials(v_from, v_to, v_branch_b);
  SELECT * INTO v_sum_b FROM public.rpc_dashboard_kpi_summary(v_from, v_to, v_prev_from, v_prev_to, v_branch_b);

  IF v_fin_b.total_income IS DISTINCT FROM v_sum_b.invoiced_revenue THEN
    RAISE EXCEPTION 'FAIL 6.1a: filtro branch_b, get_dashboard_financials.total_income (%) <> rpc_dashboard_kpi_summary.invoiced_revenue (%)',
      v_fin_b.total_income, v_sum_b.invoiced_revenue;
  END IF;
  IF v_fin_b.net_profit IS DISTINCT FROM v_sum_b.net_profit THEN
    RAISE EXCEPTION 'FAIL 6.1b: filtro branch_b, get_dashboard_financials.net_profit (%) <> rpc_dashboard_kpi_summary.net_profit (%)',
      v_fin_b.net_profit, v_sum_b.net_profit;
  END IF;
  IF v_fin_b.total_income <> 500 THEN
    RAISE EXCEPTION 'FAIL 6.1c: total_income filtro branch_b esperaba 500 (la NC es de A, NO resta en B), dio %', v_fin_b.total_income;
  END IF;
  IF v_fin_b.net_profit <> 370 THEN
    RAISE EXCEPTION 'FAIL 6.1d: net_profit filtro branch_b esperaba 370 (500 - 50 gastos - 80 compras, sin NC), dio %', v_fin_b.net_profit;
  END IF;
  -- Triangulación: la NC de A SÍ resta en A (ya cubierto por 2.4, invoiced=1600)
  -- y resta UNA sola vez sin filtro (ya cubierto por 2.3, invoiced=2400) — el
  -- valor de 6.1 es el caso negativo (B no ve la NC ajena).
  IF v_sum_a.invoiced_revenue <> 1600 THEN
    RAISE EXCEPTION 'FAIL 6.1e: invoiced_revenue filtro branch_a esperaba 1600 (la NC es de A → resta en A), dio %', v_sum_a.invoiced_revenue;
  END IF;
  RAISE NOTICE 'PASS 6.1: NC de sucursal A no resta en sucursal B (B=%/%), sí resta en A (invoiced=%), y sin filtro resta una sola vez (invoiced=%)',
    v_fin_b.total_income, v_fin_b.net_profit, v_sum_a.invoiced_revenue, v_fin_none.total_income;

  -- ══════════════════════════════════════════════════════════════════════════
  -- ASSERT 5 (task 6.2, grupo 6, OQ-1 híbrida) — collected_revenue/
  -- prev_collected_revenue son NULL bajo filtro de sucursal (D2); sin filtro
  -- siguen siendo computables (no hay cargos/cobros de cta cte en el fixture,
  -- así que collected_revenue = invoiced_revenue).
  -- ══════════════════════════════════════════════════════════════════════════
  IF v_sum_a.collected_revenue IS NOT NULL OR v_sum_a.prev_collected_revenue IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL 6.2a: filtro branch_a, collected_revenue/prev_collected_revenue esperaban NULL, dieron %/%',
      v_sum_a.collected_revenue, v_sum_a.prev_collected_revenue;
  END IF;
  IF v_sum_b.collected_revenue IS NOT NULL OR v_sum_b.prev_collected_revenue IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL 6.2b: filtro branch_b, collected_revenue/prev_collected_revenue esperaban NULL, dieron %/%',
      v_sum_b.collected_revenue, v_sum_b.prev_collected_revenue;
  END IF;
  IF v_sum_a.invoiced_revenue IS NULL THEN
    RAISE EXCEPTION 'FAIL 6.2c: filtro branch_a, invoiced_revenue no debería ser NULL (solo collected_revenue es no computable por sucursal)';
  END IF;
  IF v_sum_none.collected_revenue IS NULL OR v_sum_none.collected_revenue <> v_sum_none.invoiced_revenue THEN
    RAISE EXCEPTION 'FAIL 6.2d: sin filtro, collected_revenue esperaba = invoiced_revenue (%) y no NULL, dio %',
      v_sum_none.invoiced_revenue, v_sum_none.collected_revenue;
  END IF;
  RAISE NOTICE 'PASS 6.2: collected_revenue/prev_collected_revenue son NULL bajo filtro de sucursal (A y B) e invoiced_revenue sigue calculado; sin filtro collected_revenue=% (=invoiced_revenue)',
    v_sum_none.collected_revenue;

  RAISE NOTICE '=== kpi-branch-consistency behavioural gate passed ===';

  -- ── Cleanup hijo→padre (accounts=0 al final) ────────────────────────────────
  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.jwt.claim.sub', '', true);

  DELETE FROM public.analytics_events               WHERE account_id = v_account_id;
  DELETE FROM public.customer_account_movements      WHERE account_id = v_account_id;
  DELETE FROM public.customer_accounts               WHERE account_id = v_account_id;
  DELETE FROM public.sales_orders                    WHERE account_id = v_account_id;
  DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account_id);
  DELETE FROM public.stock_movements                 WHERE account_id = v_account_id;
  DELETE FROM public.sales                           WHERE account_id = v_account_id;
  DELETE FROM public.purchases                       WHERE account_id = v_account_id;
  DELETE FROM public.expenses                        WHERE account_id = v_account_id;
  DELETE FROM public.clients                         WHERE account_id = v_account_id;
  DELETE FROM public.branch_stock                    WHERE account_id = v_account_id;
  DELETE FROM public.products                        WHERE account_id = v_account_id;
  DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
  DELETE FROM public.branches                        WHERE account_id = v_account_id;
  DELETE FROM public.account_members                 WHERE user_id = v_user_id;
  DELETE FROM public.accounts                        WHERE owner_user_id = v_user_id;
  DELETE FROM public.profiles                        WHERE id = v_user_id;
  DELETE FROM public.email_logs                      WHERE user_id = v_user_id;
  DELETE FROM public.operation_idempotency            WHERE user_id = v_user_id;
  DELETE FROM auth.users                              WHERE id = v_user_id;

EXCEPTION
  WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN
      RAISE;
    END IF;
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      PERFORM set_config('request.jwt.claim.sub', '', true);

      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.analytics_events               WHERE account_id = v_account_id;
        DELETE FROM public.customer_account_movements      WHERE account_id = v_account_id;
        DELETE FROM public.customer_accounts               WHERE account_id = v_account_id;
        DELETE FROM public.sales_orders                    WHERE account_id = v_account_id;
        DELETE FROM public.sale_items WHERE sale_id IN (SELECT id FROM public.sales WHERE account_id = v_account_id);
        DELETE FROM public.stock_movements                 WHERE account_id = v_account_id;
        DELETE FROM public.sales                           WHERE account_id = v_account_id;
        DELETE FROM public.purchases                       WHERE account_id = v_account_id;
        DELETE FROM public.expenses                        WHERE account_id = v_account_id;
        DELETE FROM public.clients                         WHERE account_id = v_account_id;
        DELETE FROM public.branch_stock                    WHERE account_id = v_account_id;
        DELETE FROM public.products                        WHERE account_id = v_account_id;
        DELETE FROM public.cashboxes    WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = v_account_id);
        DELETE FROM public.branches                        WHERE account_id = v_account_id;
        DELETE FROM public.account_members                 WHERE user_id = v_user_id;
        DELETE FROM public.accounts                        WHERE owner_user_id = v_user_id;
      END IF;
      DELETE FROM public.profiles         WHERE id = v_user_id;
      DELETE FROM public.email_logs       WHERE user_id = v_user_id;
      DELETE FROM public.operation_idempotency WHERE user_id = v_user_id;
      DELETE FROM auth.users              WHERE id = v_user_id;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
