-- =============================================================================
-- GATE: test_dashboard_critical_stock_items.sql
-- CHANGE: kpi-canonicalization (candidato S5)
--
-- Verifica get_dashboard_critical_stock_items(p_branch_id uuid, p_limit int):
--   (1) Introspección: existe con firma única, SECURITY DEFINER, search_path
--       fijado, guards min_stock>0/variant_only en el cuerpo, ACLs exactas
--       (anon sin EXECUTE, authenticated con EXECUTE).
--   (2) Paridad de predicado con la hermana get_dashboard_critical_stock:
--       COUNT(DISTINCT product_id) sobre las filas del detalle == el conteo
--       de la hermana, total y por sucursal.
--   (3) Orden: la fila más crítica (menor quantity/min_stock) va primera.
--   (4) p_limit acota el resultado; p_limit <= 0 → P0400.
--   (5) Tenencia: bajo los claims de otra cuenta, ninguna fila de la cuenta
--       ajena es visible (control positivo: la cuenta propia sí ve la suya).
--
-- Mismo patrón de anchor sintético + set_config('request.jwt.claims', ...)
-- que supabase/tests/test_receivables_report.sql / test_estadisticas_ventas.sql
-- — SIN "SET LOCAL ROLE authenticated": la función es SECURITY DEFINER y su
-- propio guard de tenencia (current_account_ids(), derivado de auth.uid())
-- es lo que se está probando, no RLS de tabla.
-- =============================================================================

-- ── 1. Introspección: existencia, firma, SECURITY DEFINER, search_path, ACLs ─
DO $$
DECLARE
  v_oid    oid;
  v_secdef boolean;
  v_config text[];
  v_prosrc text;
BEGIN
  SELECT p.oid, p.prosecdef, p.proconfig, p.prosrc
    INTO v_oid, v_secdef, v_config, v_prosrc
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'get_dashboard_critical_stock_items'
    AND pg_get_function_identity_arguments(p.oid) = 'p_branch_id uuid, p_limit integer';

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (existencia): get_dashboard_critical_stock_items(p_branch_id uuid, p_limit integer) no existe.';
  END IF;

  IF NOT v_secdef THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (secdef): debe ser SECURITY DEFINER.';
  END IF;

  IF v_config IS NULL OR NOT EXISTS (
    SELECT 1 FROM unnest(v_config) AS cfg WHERE cfg LIKE 'search_path=%'
  ) THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (search_path): no fija search_path.';
  END IF;

  IF position('min_stock > 0' in v_prosrc) = 0 THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (predicado): falta el guard min_stock > 0 (RN-23).';
  END IF;

  IF position('variant_only' in v_prosrc) = 0 THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (predicado): falta la exclusión de variant_only.';
  END IF;

  -- Ningún overload inesperado (mismo criterio que test_kpis.sql §4).
  IF EXISTS (
    SELECT 1 FROM pg_proc p2
    JOIN pg_namespace n2 ON n2.oid = p2.pronamespace
    WHERE n2.nspname = 'public'
      AND p2.proname = 'get_dashboard_critical_stock_items'
      AND pg_get_function_identity_arguments(p2.oid) <> 'p_branch_id uuid, p_limit integer'
  ) THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (overload): existe una firma inesperada de get_dashboard_critical_stock_items.';
  END IF;

  IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (acl): anon NO debe poder ejecutar get_dashboard_critical_stock_items.';
  END IF;

  IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (acl): authenticated debe poder ejecutar get_dashboard_critical_stock_items.';
  END IF;

  RAISE NOTICE 'PASS (1): get_dashboard_critical_stock_items con firma única, SECURITY DEFINER, guards y ACLs exactas.';
END $$;

-- ── 2-5. Comportamiento con anchors sintéticos ───────────────────────────────
DO $$
DECLARE
  v_anchor_email   text := 'critical-stock-items-gate@test.local';
  v_intruder_email text := 'critical-stock-items-gate-intruder@test.local';
  v_user_id      uuid := gen_random_uuid();
  v_intruder_id  uuid := gen_random_uuid();
  v_account_id           uuid;
  v_intruder_account_id  uuid;
  v_branch_a     uuid;  -- auto-provisionada por handle_new_user()
  v_branch_b     uuid;  -- creada a mano en este gate
  v_intruder_branch uuid;
  v_p_a uuid; v_p_b uuid; v_p_c uuid; v_p_d uuid;
  v_p_untracked uuid; v_p_variant uuid; v_p_deleted uuid; v_p_no_threshold uuid;
  v_p_intruder uuid;
  v_count      int;
  v_count_sib  bigint;
  v_row        record;
  v_resolved   boolean := false;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Critical Stock Items'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_intruder_id, 'authenticated', 'authenticated', v_intruder_email, now(), now(),
          jsonb_build_object('name', 'Gate Critical Stock Items Intruder'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id          FROM public.account_members WHERE user_id = v_user_id     ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_intruder_account_id FROM public.account_members WHERE user_id = v_intruder_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL OR v_intruder_account_id IS NULL THEN
    RAISE NOTICE 'GATE CRITICAL-STOCK-ITEMS: no se pudo resolver cuenta para los anchors sintéticos — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a       FROM public.branches WHERE account_id = v_account_id          ORDER BY created_at LIMIT 1;
  SELECT id INTO v_intruder_branch FROM public.branches WHERE account_id = v_intruder_account_id ORDER BY created_at LIMIT 1;

  IF v_branch_a IS NULL OR v_intruder_branch IS NULL THEN
    RAISE NOTICE 'GATE CRITICAL-STOCK-ITEMS: sucursal auto-provisionada no disponible para los anchors — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.branches (account_id, name) VALUES (v_account_id, '__gate_csi_branch_b__') RETURNING id INTO v_branch_b;

  -- ── Fixture: productos ────────────────────────────────────────────────────
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_a__', 1000, 400, 'GATE-CSI-A', 'tracked') RETURNING id INTO v_p_a;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_b__', 1000, 400, 'GATE-CSI-B', 'tracked') RETURNING id INTO v_p_b;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_c__', 1000, 400, 'GATE-CSI-C', 'tracked') RETURNING id INTO v_p_c;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_d__', 1000, 400, 'GATE-CSI-D', 'tracked') RETURNING id INTO v_p_d;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_untracked__', 1000, 400, 'GATE-CSI-U', 'untracked') RETURNING id INTO v_p_untracked;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_variant__', 1000, 400, 'GATE-CSI-V', 'variant_only') RETURNING id INTO v_p_variant;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type, deleted_at, deleted_by)
  VALUES (v_user_id, v_account_id, '__gate_csi_deleted__', 1000, 400, 'GATE-CSI-DEL', 'tracked', now(), v_user_id) RETURNING id INTO v_p_deleted;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_user_id, v_account_id, '__gate_csi_no_threshold__', 1000, 400, 'GATE-CSI-NT', 'tracked') RETURNING id INTO v_p_no_threshold;
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku, stock_control_type)
  VALUES (v_intruder_id, v_intruder_account_id, '__gate_csi_intruder__', 1000, 400, 'GATE-CSI-X', 'tracked') RETURNING id INTO v_p_intruder;

  -- ── Fixture: branch_stock ─────────────────────────────────────────────────
  -- A: sólo crítico en sucursal A, ratio 1/10 = 0.1
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_a, v_branch_a, 1, 10);
  -- B: sólo crítico en sucursal A, ratio 8/10 = 0.8
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_b, v_branch_a, 8, 10);
  -- C: sólo crítico en sucursal B, límite exacto (quantity = min_stock), ratio 1.0
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_c, v_branch_b, 5, 5);
  -- D: crítico en AMBAS sucursales — en B con ratio 0 (el más crítico de todos)
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_d, v_branch_a, 5, 5);
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_d, v_branch_b, 0, 5);
  -- Excluidos: untracked, variant_only, soft-deleted, sin umbral (min_stock=0)
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_untracked, v_branch_a, 0, 10);
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_variant, v_branch_a, 0, 10);
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_deleted, v_branch_a, 0, 10);
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_account_id, v_p_no_threshold, v_branch_a, 0, 0);
  -- Intruso: crítico en su propia sucursal (control positivo de (5)).
  INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
  VALUES (v_intruder_account_id, v_p_intruder, v_intruder_branch, 0, 5);

  -- ── Sesión del anchor real ────────────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE CRITICAL-STOCK-ITEMS: auth.uid() no resuelve con request.jwt.claims local — se omiten los asserts que invocan la RPC.';
  ELSE
    v_resolved := true;

    -- (2) Paridad de predicado — total y por sucursal.
    SELECT COUNT(DISTINCT product_id) INTO v_count
      FROM public.get_dashboard_critical_stock_items(NULL, NULL);
    SELECT public.get_dashboard_critical_stock(NULL) INTO v_count_sib;
    IF v_count <> v_count_sib THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (2 total): COUNT(DISTINCT product_id) del detalle = %, hermana = % — no coinciden.', v_count, v_count_sib;
    END IF;
    IF v_count <> 4 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (2 fixture): esperaba 4 productos críticos distintos (A,B,C,D), dio %.', v_count;
    END IF;

    SELECT COUNT(DISTINCT product_id) INTO v_count
      FROM public.get_dashboard_critical_stock_items(v_branch_a, NULL);
    SELECT public.get_dashboard_critical_stock(v_branch_a) INTO v_count_sib;
    IF v_count <> v_count_sib OR v_count <> 3 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (2 sucursal A): detalle=%, hermana=%, esperaba 3 (A,B,D).', v_count, v_count_sib;
    END IF;

    SELECT COUNT(DISTINCT product_id) INTO v_count
      FROM public.get_dashboard_critical_stock_items(v_branch_b, NULL);
    SELECT public.get_dashboard_critical_stock(v_branch_b) INTO v_count_sib;
    IF v_count <> v_count_sib OR v_count <> 2 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (2 sucursal B): detalle=%, hermana=%, esperaba 2 (C,D).', v_count, v_count_sib;
    END IF;

    RAISE NOTICE 'PASS (2): paridad de predicado con la hermana, total y por sucursal.';

    -- Detalle NO deduplica por producto: D aparece 2 veces (una por sucursal).
    SELECT COUNT(*) INTO v_count FROM public.get_dashboard_critical_stock_items(NULL, NULL) r WHERE r.product_id = v_p_d;
    IF v_count <> 2 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (2b): el producto D crítico en 2 sucursales debe aparecer en 2 filas del detalle (sin deduplicar), dio %.', v_count;
    END IF;

    -- Excluidos explícitos: untracked/variant_only/soft-deleted/sin umbral.
    IF EXISTS (
      SELECT 1 FROM public.get_dashboard_critical_stock_items(NULL, NULL) r
      WHERE r.product_id IN (v_p_untracked, v_p_variant, v_p_deleted, v_p_no_threshold)
    ) THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (2c): untracked/variant_only/soft-deleted/sin-umbral no deben aparecer en el detalle.';
    END IF;
    RAISE NOTICE 'PASS (2b/2c): sin deduplicar por producto, y excluidos respetados.';

    -- (3) Orden: la fila más crítica (menor ratio) va primera — D en sucursal B, ratio 0.
    SELECT * INTO v_row FROM public.get_dashboard_critical_stock_items(NULL, NULL) LIMIT 1;
    IF v_row.product_id <> v_p_d OR v_row.branch_id <> v_branch_b OR v_row.quantity <> 0 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (3): la primera fila debía ser D en sucursal B (ratio 0, el más crítico), dio product_id=%, branch_id=%, quantity=%.', v_row.product_id, v_row.branch_id, v_row.quantity;
    END IF;
    RAISE NOTICE 'PASS (3): la fila más crítica (menor quantity/min_stock) va primera.';

    -- (4) p_limit acota el resultado.
    SELECT COUNT(*) INTO v_count FROM public.get_dashboard_critical_stock_items(NULL, 1);
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (4a): p_limit=1 debía devolver exactamente 1 fila, dio %.', v_count;
    END IF;
    SELECT * INTO v_row FROM public.get_dashboard_critical_stock_items(NULL, 1) LIMIT 1;
    IF v_row.product_id <> v_p_d OR v_row.branch_id <> v_branch_b THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (4b): con p_limit=1 la única fila debía ser la más crítica (D, sucursal B).';
    END IF;

    -- p_limit <= 0 → P0400 (cero y negativo).
    BEGIN
      PERFORM * FROM public.get_dashboard_critical_stock_items(NULL, 0);
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (4c): p_limit=0 debía rechazarse con P0400.';
    EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
    END;
    BEGIN
      PERFORM * FROM public.get_dashboard_critical_stock_items(NULL, -1);
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (4d): p_limit=-1 debía rechazarse con P0400.';
    EXCEPTION WHEN SQLSTATE 'P0400' THEN NULL;
    END;
    RAISE NOTICE 'PASS (4): p_limit acota el resultado y p_limit <= 0 se rechaza con P0400.';

    -- ── Sesión del intruso ────────────────────────────────────────────────
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_intruder_id::text, 'role', 'authenticated')::text, true);

    -- Control positivo: el intruso ve su PROPIA fila crítica.
    SELECT COUNT(*) INTO v_count FROM public.get_dashboard_critical_stock_items(NULL, NULL) r WHERE r.product_id = v_p_intruder;
    IF v_count <> 1 THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (5 control positivo): el intruso no ve su propia fila crítica bajo su propia sesión (%).', v_count;
    END IF;

    -- (5) Tenencia: ninguna fila de la cuenta del anchor es visible para el intruso.
    IF EXISTS (
      SELECT 1 FROM public.get_dashboard_critical_stock_items(NULL, NULL) r
      WHERE r.product_id IN (v_p_a, v_p_b, v_p_c, v_p_d)
    ) THEN
      RAISE EXCEPTION 'GATE CRITICAL-STOCK-ITEMS FAILED (5): bajo los claims del intruso se filtró una fila crítica de la cuenta ajena.';
    END IF;
    RAISE NOTICE 'PASS (5): ninguna fila de otra cuenta es visible (control positivo: el intruso sí ve la suya).';
  END IF;

  PERFORM set_config('request.jwt.claims', '', true);

  -- ── Cleanup hijo→padre ─────────────────────────────────────────────────────
  DELETE FROM public.branch_stock WHERE branch_id IN (v_branch_a, v_branch_b, v_intruder_branch);
  DELETE FROM public.products     WHERE account_id IN (v_account_id, v_intruder_account_id);
  DELETE FROM public.cashboxes    WHERE branch_id IN (v_branch_a, v_branch_b, v_intruder_branch);
  -- sucursal-guard-vaciado-auditoria: branches prohibe el borrado fisico SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explicito para el cleanup del fixture sintetico -- session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.branches WHERE account_id IN (v_account_id, v_intruder_account_id);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_intruder_id);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id IN (v_user_id, v_intruder_id);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles   WHERE id IN (v_user_id, v_intruder_id);
  DELETE FROM public.email_logs WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_intruder_id);
  DELETE FROM auth.users        WHERE id IN (v_user_id, v_intruder_id);

  IF v_resolved THEN
    RAISE NOTICE 'GATE CRITICAL-STOCK-ITEMS PASSED.';
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    BEGIN
      PERFORM set_config('request.jwt.claims', '', true);
      IF v_account_id IS NOT NULL THEN
        DELETE FROM public.branch_stock WHERE branch_id IN (v_branch_a, v_branch_b, v_intruder_branch);
        DELETE FROM public.products     WHERE account_id IN (v_account_id, v_intruder_account_id);
        DELETE FROM public.cashboxes    WHERE branch_id IN (v_branch_a, v_branch_b, v_intruder_branch);
        SET session_replication_role = replica;
        DELETE FROM public.branches WHERE account_id IN (v_account_id, v_intruder_account_id);
        SET session_replication_role = DEFAULT;
        DELETE FROM public.account_members WHERE user_id IN (v_user_id, v_intruder_id);
        SET session_replication_role = replica;
        DELETE FROM public.accounts WHERE owner_user_id IN (v_user_id, v_intruder_id);
        SET session_replication_role = DEFAULT;
      END IF;
      DELETE FROM public.profiles   WHERE id IN (v_user_id, v_intruder_id);
      DELETE FROM public.email_logs WHERE user_id IN (v_user_id, v_intruder_id);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_intruder_id);
      DELETE FROM auth.users        WHERE id IN (v_user_id, v_intruder_id);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
