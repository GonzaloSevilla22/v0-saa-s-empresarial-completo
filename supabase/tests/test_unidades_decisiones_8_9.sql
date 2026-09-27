-- =============================================================================
-- test_unidades_decisiones_8_9.sql — Gate de la migración de DATOS
-- 20261065000001_unidades_decisiones_8_9.sql (decisiones 8 y 9 del sign-off de
-- ventas-unidades-conversion, OK del PO 2026-09-27).
--
-- La migración no define funciones: su lógica son dos bloques DO. Por eso este
-- gate la EJECUTA de verdad con `\i` (dos veces) sobre fixtures propias
-- sembradas antes — `supabase start`/`db reset` ya la aplicó sobre una base
-- vacía de candidatos, donde es un no-op. Corre desde la raíz del repo (así la
-- invoca KPI_Validation.yml: `psql -f supabase/tests/...`).
--
--   (a) producto sin unidad base con ventas en kg → queda con base Kilogramo
--       (también con una venta SIN unidad al lado: las líneas sin unidad no
--       declaran ninguna, misma regla que el guard) y en otra cuenta (a3);
--   (b) producto con ventas en kg Y en mL (el caso de ac5ae409…) → omitido,
--       sigue sin base; también con una compra en 'u' (b2) y con sólo compras
--       en kg, sin ventas (b3);
--   (c) producto con base PROPIA (Gramo) y ventas en kg → intacto;
--   (d) variante de OTRA cuenta que hereda kg del padre, con ventas en kg →
--       intacta (base propia NULL); un padre sin base con una variante viva que
--       hereda → omitido, él y la variante (d2); un producto borrado → intacto
--       (d3);
--   (p) un P0409 del guard sobre UNA fila se captura: ese producto se omite y
--       los demás se asignan igual (se fuerza con un trigger del gate, porque
--       el predicado espeja la regla del guard y el rechazo real sólo llega
--       por una carrera);
--   (e) decisión 8: el movimiento cf4550c0-… (−0,0004, type 'sale', sin
--       sucursal) sembrado → aparece UN ajuste de −0,3806 con la marca, en la
--       sucursal default, del dueño de la cuenta, quantity_before/after
--       coherentes, y branch_stock baja exactamente eso (6999,4276 → 6999,0470);
--   (f) reaplicar la migración → 0 cambios (mismos movimientos, mismas bases,
--       mismo stock);
--   (h) residuo cero asertado tras el cleanup.
--
-- RED (2026-09-27, stack local): contra un stub vacío de la migración, fallan
-- a.1, a.2, a.3, p.2, e.1, e.2 y e.8 (7 fallos) y el cleanup deja residuo cero.
--
-- Sesión simulada con set_config LOCAL a la transacción de cada bloque —
-- NUNCA usar este patrón contra prod.
-- =============================================================================

\set ON_ERROR_STOP 1

-- ─── 0. Pre-limpieza (una corrida abortada a mitad deja fixtures) ────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  DROP TRIGGER IF EXISTS zz_gate_d89_force_p0409 ON public.products;
  DROP FUNCTION IF EXISTS public._gate_d89_force_p0409();
  SELECT array_agg(id) INTO v_users FROM auth.users
   WHERE email IN ('unidades-decisiones-8-9-a@test.local', 'unidades-decisiones-8-9-b@test.local');
  IF v_users IS NULL THEN RETURN; END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY(v_users);
  DELETE FROM public.events                WHERE account_id = ANY(v_accounts);
  DELETE FROM public.email_logs            WHERE user_id = ANY(v_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.analytics_events      WHERE account_id = ANY(v_accounts) OR user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.document_status_history WHERE account_id = ANY(v_accounts);
  DELETE FROM public.sales_order_items     WHERE account_id = ANY(v_accounts);
  DELETE FROM public.sales_orders          WHERE account_id = ANY(v_accounts);
  DELETE FROM public.stock_movements       WHERE account_id = ANY(v_accounts) OR user_id = ANY(v_users);
  DELETE FROM public.branch_stock          WHERE account_id = ANY(v_accounts);
  DELETE FROM public.sale_items            WHERE account_id = ANY(v_accounts);
  DELETE FROM public.purchase_items        WHERE account_id = ANY(v_accounts);
  DELETE FROM public.sales                 WHERE account_id = ANY(v_accounts) OR user_id = ANY(v_users);
  DELETE FROM public.purchases             WHERE account_id = ANY(v_accounts) OR user_id = ANY(v_users);
  DELETE FROM public.products              WHERE account_id = ANY(v_accounts) OR user_id = ANY(v_users);
  DELETE FROM public.branches              WHERE account_id = ANY(v_accounts);
  DELETE FROM public.units_of_measure      WHERE account_id = ANY(v_accounts);
  DELETE FROM public.journal_entries       WHERE account_id = ANY(v_accounts);
  DELETE FROM public.notifications         WHERE account_id = ANY(v_accounts);
  DELETE FROM public.payment_methods       WHERE account_id = ANY(v_accounts);
  DELETE FROM public.product_categories    WHERE account_id = ANY(v_accounts);
  DELETE FROM public.audit_logs            WHERE account_id = ANY(v_accounts);
  DELETE FROM public.accounts              WHERE id = ANY(v_accounts);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id = ANY(v_accounts);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  DELETE FROM auth.users                   WHERE id = ANY(v_users);
  DELETE FROM public.audit_logs            WHERE account_id = ANY(v_accounts);
END $$;

-- Estado del gate entre sentencias (la migración corre con \i en el medio).
DROP TABLE IF EXISTS pg_temp.gate_d89;
CREATE TEMP TABLE gate_d89 (k text PRIMARY KEY, id uuid, num numeric);
DROP TABLE IF EXISTS pg_temp.gate_d89_fail;
CREATE TEMP TABLE gate_d89_fail (msg text);

-- ─── 1. Fixtures ────────────────────────────────────────────────────────────
DO $setup$
DECLARE
  v_sys_u     constant uuid := '00000000-0000-0000-0001-000000000001';
  v_sys_kg    constant uuid := '00000000-0000-0000-0001-000000000002';
  v_sys_l     constant uuid := '00000000-0000-0000-0001-000000000003';
  v_sys_g     constant uuid := '00000000-0000-0000-0001-000000000010';
  v_sys_ml    constant uuid := '00000000-0000-0000-0001-000000000012';
  v_user_a    uuid := gen_random_uuid();
  v_user_b    uuid := gen_random_uuid();
  v_account_a uuid;
  v_account_b uuid;
  v_branch_a  uuid;
  v_branch_b  uuid;
  v_p         uuid;
  v_p2        uuid;
  v_op        uuid;
  v_k         text;
BEGIN
  -- Unidades de SISTEMA con los mismos ids que prod, sólo si faltan (db reset
  -- no las siembra); el cleanup retira únicamente las que sembró este gate.
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_u) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_u, NULL, 'Unidad', 'u', 'unit', 1.0, NULL, true);
    INSERT INTO gate_d89 VALUES ('seeded_u', v_sys_u, NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_kg) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_kg, NULL, 'Kilogramo', 'kg', 'weight', 1.0, NULL, true);
    INSERT INTO gate_d89 VALUES ('seeded_kg', v_sys_kg, NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_l) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_l, NULL, 'Litro', 'L', 'volume', 1.0, NULL, true);
    INSERT INTO gate_d89 VALUES ('seeded_l', v_sys_l, NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_g) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_g, NULL, 'Gramo', 'g', 'weight', 0.001, v_sys_kg, true);
    INSERT INTO gate_d89 VALUES ('seeded_g', v_sys_g, NULL);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.units_of_measure WHERE id = v_sys_ml) THEN
    INSERT INTO public.units_of_measure (id, account_id, name, symbol, type, factor, base_unit_id, is_system)
    VALUES (v_sys_ml, NULL, 'Mililitro', 'mL', 'volume', 0.001, v_sys_l, true);
    INSERT INTO gate_d89 VALUES ('seeded_ml', v_sys_ml, NULL);
  END IF;

  -- Dos cuentas reales vía handle_new_user.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', 'unidades-decisiones-8-9-a@test.local', now(), now(),
          jsonb_build_object('name', 'Gate D89 A', 'phone', '', 'locality', '', 'province', ''));
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', 'unidades-decisiones-8-9-b@test.local', now(), now(),
          jsonb_build_object('name', 'Gate D89 B', 'phone', '', 'locality', '', 'province', ''));
  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_a = v_account_b THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó dos cuentas distintas (% / %)', v_account_a, v_account_b;
  END IF;
  v_branch_a := public.c26_default_branch(v_account_a);
  v_branch_b := public.c26_default_branch(v_account_b);
  IF v_branch_a IS NULL OR v_branch_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: las cuentas no tienen sucursal default';
  END IF;
  INSERT INTO gate_d89 VALUES ('user_a', v_user_a, NULL), ('user_b', v_user_b, NULL),
                              ('account_a', v_account_a, NULL), ('account_b', v_account_b, NULL),
                              ('branch_a', v_branch_a, NULL), ('branch_b', v_branch_b, NULL);

  -- ── Cuenta A ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_a::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_a::text, true);

  -- (a) sin base, ventas en kg → kg.  (a2) + una venta SIN unidad → kg.
  -- (b) kg + mL → sin base.  (b2) kg + compra en u → sin base.  (b3) sólo compra en kg → sin base.
  -- (p) kg, pero el guard (forzado) rechaza → sin base, y los demás siguen.
  FOREACH v_k IN ARRAY ARRAY['a', 'a2', 'b', 'b2', 'b3', 'p', 'd3'] LOOP
    INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
    VALUES (v_user_a, v_account_a, 'Alimento D89 ' || v_k, 'D89-' || upper(v_k), 100.00, 200.00)
    RETURNING id INTO v_p;
    INSERT INTO gate_d89 VALUES ('p_' || v_k, v_p, NULL);
    PERFORM public.rpc_adjust_branch_stock(v_p, v_branch_a, 10, 'seed gate D89');
    IF v_k <> 'b3' THEN
      PERFORM public.rpc_create_sale_operation('d89-' || v_k || '-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
        jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 200.00, 'quantity', 2, 'unit_id', v_sys_kg)), v_branch_a, NULL);
    END IF;
  END LOOP;

  SELECT id INTO v_p FROM gate_d89 WHERE k = 'p_a2';
  PERFORM public.rpc_create_sale_operation('d89-a2b-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 200.00, 'quantity', 1)), v_branch_a, NULL);

  -- (b) la línea en mL que la regla de hoy rechaza (P0400 unit_requires_base_unit)
  -- es HISTORIA: se siembra como en prod, venta en kg re-etiquetada a mL.
  SELECT id INTO v_p FROM gate_d89 WHERE k = 'p_b';
  PERFORM public.rpc_create_sale_operation('d89-bml-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 200.00, 'quantity', 0.381, 'unit_id', v_sys_kg)), v_branch_a, NULL);
  UPDATE public.sales SET unit_id = v_sys_ml
   WHERE id = (SELECT s.id FROM public.sales s WHERE s.product_id = v_p AND s.quantity = 0.381 LIMIT 1);
  UPDATE public.sale_items SET unit_id = v_sys_ml WHERE product_id = v_p AND quantity = 0.381;

  SELECT id INTO v_p FROM gate_d89 WHERE k = 'p_b2';
  PERFORM public.rpc_create_purchase_operation('d89-b2-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate D89',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 50.00, 'quantity', 3, 'unit_id', v_sys_u)), v_branch_a);

  SELECT id INTO v_p FROM gate_d89 WHERE k = 'p_b3';
  PERFORM public.rpc_create_purchase_operation('d89-b3-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra gate D89',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 50.00, 'quantity', 3, 'unit_id', v_sys_kg)), v_branch_a);

  -- (c) base PROPIA Gramo, ventas en kg → intacto.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_a, v_account_a, 'Especia D89 (g)', 'D89-C', 1.00, 2.00, v_sys_g) RETURNING id INTO v_p;
  INSERT INTO gate_d89 VALUES ('p_c', v_p, NULL);
  PERFORM public.rpc_adjust_branch_stock(v_p, v_branch_a, 5000, 'seed gate D89');
  PERFORM public.rpc_create_sale_operation('d89-c-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 2000.00, 'quantity', 1, 'unit_id', v_sys_kg)), v_branch_a, NULL);

  -- (d2) padre sin base, vendido en kg, con una variante VIVA que hereda → omitidos los dos.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  -- (La venta del padre va ANTES de crear la variante: con variantes, la venta
  -- exige elegir una.)
  VALUES (v_user_a, v_account_a, 'Alimento D89 padre', 'D89-D2P', 100.00, 200.00) RETURNING id INTO v_p;
  PERFORM public.rpc_adjust_branch_stock(v_p, v_branch_a, 10, 'seed gate D89');
  PERFORM public.rpc_create_sale_operation('d89-d2-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 200.00, 'quantity', 2, 'unit_id', v_sys_kg)), v_branch_a, NULL);
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_a, v_account_a, 'Alimento D89 padre — variante', 'D89-D2V', 100.00, 200.00, v_p, true) RETURNING id INTO v_p2;
  INSERT INTO gate_d89 VALUES ('p_d2p', v_p, NULL), ('p_d2v', v_p2, NULL);

  -- (d3) vendido en kg y después borrado (soft delete; el guard RN-B4 exige
  -- stock 0, así que se lo lleva a 0 antes, como haría el usuario).
  SELECT id INTO v_p FROM gate_d89 WHERE k = 'p_d3';
  PERFORM public.rpc_adjust_branch_stock(v_p, v_branch_a, 0, 'seed gate D89 (a 0 para borrar)');
  UPDATE public.products SET deleted_at = now(), deleted_by = v_user_a WHERE id = v_p;

  -- (e) decisión 8: producto sin base con stock 6999,4280 y el movimiento
  -- cf4550c0-… sembrado tal como está en prod (−0,0004, 'sale', sin sucursal:
  -- la venta no tenía sucursal y descontó de la default).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_a, v_account_a, 'Alimento D89 ABIERTO (decisión 8)', 'D89-E', 7900.00, 10500.00) RETURNING id INTO v_p;
  INSERT INTO gate_d89 VALUES ('p_e', v_p, NULL);
  PERFORM public.rpc_adjust_branch_stock(v_p, v_branch_a, 6999.4280, 'seed gate D89');
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_p, NULL, -0.0004);
  INSERT INTO public.stock_movements (id, user_id, account_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after, reference_type, performed_by, branch_id)
  VALUES ('cf4550c0-cf36-4f88-aeba-bdf2cd8bb423', v_user_a, v_account_a, v_p, 'Alimento D89 ABIERTO (decisión 8)', 'sale',
    -0.0004, 6999.4280, 6999.4276, 'sale', v_user_a, NULL);

  -- ── Cuenta B ──
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_user_b::text)::text, true);
  PERFORM set_config('request.jwt.claim.sub', v_user_b::text, true);

  -- (a3) sin base, ventas en kg, otra cuenta → kg (la migración no es por cuenta).
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_user_b, v_account_b, 'Alimento D89 B', 'D89-A3', 100.00, 200.00) RETURNING id INTO v_p;
  INSERT INTO gate_d89 VALUES ('p_a3', v_p, NULL);
  PERFORM public.rpc_adjust_branch_stock(v_p, v_branch_b, 10, 'seed gate D89');
  PERFORM public.rpc_create_sale_operation('d89-a3-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p, 'amount', 200.00, 'quantity', 2, 'unit_id', v_sys_kg)), v_branch_b, NULL);

  -- (d) padre en kg + variante que HEREDA, vendida en kg → la variante queda con base propia NULL.
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, base_unit_id)
  VALUES (v_user_b, v_account_b, 'Queso D89 (padre kg)', 'D89-DP', 800.00, 1500.00, v_sys_kg) RETURNING id INTO v_p;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price, parent_id, is_variant)
  VALUES (v_user_b, v_account_b, 'Queso D89 — horma', 'D89-DV', 800.00, 1500.00, v_p, true) RETURNING id INTO v_p2;
  INSERT INTO gate_d89 VALUES ('p_dp', v_p, NULL), ('p_dv', v_p2, NULL);
  PERFORM public.rpc_adjust_branch_stock(v_p2, v_branch_b, 5, 'seed gate D89');
  PERFORM public.rpc_create_sale_operation('d89-d-' || gen_random_uuid()::text, NULL, CURRENT_DATE, 'ARS',
    jsonb_build_array(jsonb_build_object('product_id', v_p2, 'amount', 1500.00, 'quantity', 1, 'unit_id', v_sys_kg)), v_branch_b, NULL);

  -- (p) un P0409 del guard sobre UNA fila: trigger del gate (se retira después de la migración).
  SELECT id INTO v_p FROM gate_d89 WHERE k = 'p_p';
  EXECUTE format($f$
    CREATE FUNCTION public._gate_d89_force_p0409() RETURNS trigger LANGUAGE plpgsql AS $b$
    BEGIN
      IF NEW.id = %L::uuid THEN
        RAISE EXCEPTION 'base_unit_locked: forzado por el gate D89' USING ERRCODE = 'P0409';
      END IF;
      RETURN NEW;
    END $b$
    $f$, v_p);
  REVOKE ALL ON FUNCTION public._gate_d89_force_p0409() FROM PUBLIC, anon, authenticated;
  CREATE TRIGGER zz_gate_d89_force_p0409 BEFORE UPDATE OF base_unit_id ON public.products
    FOR EACH ROW EXECUTE FUNCTION public._gate_d89_force_p0409();

  -- Foto previa del stock de (e).
  INSERT INTO gate_d89 VALUES ('e_stock_before', NULL,
    (SELECT quantity FROM public.branch_stock WHERE product_id = (SELECT id FROM gate_d89 WHERE k = 'p_e') AND branch_id = v_branch_a));
  RAISE NOTICE 'gate D89: fixtures sembradas';
END $setup$;

-- ─── 2. La migración, de verdad ─────────────────────────────────────────────
\i supabase/migrations/20261065000001_unidades_decisiones_8_9.sql

-- Foto después de la primera aplicación (para (f)).
INSERT INTO gate_d89
SELECT 'snap_movs', NULL, count(*) FROM public.stock_movements
 WHERE account_id IN (SELECT id FROM gate_d89 WHERE k IN ('account_a', 'account_b'));
INSERT INTO gate_d89
SELECT 'snap_bases', NULL, count(*) FROM public.products
 WHERE account_id IN (SELECT id FROM gate_d89 WHERE k IN ('account_a', 'account_b')) AND base_unit_id IS NOT NULL;
INSERT INTO gate_d89
SELECT 'snap_stock', NULL, sum(quantity) FROM public.branch_stock
 WHERE account_id IN (SELECT id FROM gate_d89 WHERE k IN ('account_a', 'account_b'));
INSERT INTO gate_d89
SELECT 'snap_all_bases', NULL, count(*) FROM public.products WHERE base_unit_id IS NOT NULL;

-- ─── 3. (f) Reaplicación ─────────────────────────────────────────────────────
\i supabase/migrations/20261065000001_unidades_decisiones_8_9.sql

-- El trigger forzado sigue vivo durante la reaplicación (el producto de (p)
-- tiene que seguir omitido); se retira recién ahora.
DROP TRIGGER IF EXISTS zz_gate_d89_force_p0409 ON public.products;
DROP FUNCTION IF EXISTS public._gate_d89_force_p0409();

-- ─── 4. Aserciones (los fallos se guardan; el cleanup va en su propio bloque
-- para que un fallo no lo revierta — las fixtures ya están commiteadas) ─────
DO $$
DECLARE
  v_kg        constant uuid := '00000000-0000-0000-0001-000000000002';
  v_g         constant uuid := '00000000-0000-0000-0001-000000000010';
  v_mov_id    constant uuid := 'cf4550c0-cf36-4f88-aeba-bdf2cd8bb423';
  v_failures  text[] := '{}';
  v_user_a    uuid := (SELECT id FROM gate_d89 WHERE k = 'user_a');
  v_user_b    uuid := (SELECT id FROM gate_d89 WHERE k = 'user_b');
  v_account_a uuid := (SELECT id FROM gate_d89 WHERE k = 'account_a');
  v_account_b uuid := (SELECT id FROM gate_d89 WHERE k = 'account_b');
  v_branch_a  uuid := (SELECT id FROM gate_d89 WHERE k = 'branch_a');
  v_p_e       uuid := (SELECT id FROM gate_d89 WHERE k = 'p_e');
  v_seeded    uuid[] := ARRAY(SELECT id FROM gate_d89 WHERE k LIKE 'seeded_%');
  v_before    numeric := (SELECT num FROM gate_d89 WHERE k = 'e_stock_before');
  v_base      uuid;
  v_cnt       integer;
  v_num       numeric;
  v_mov       record;
  v_txt       text;
  r           record;
BEGIN
  -- Bases esperadas.
  FOR r IN
    SELECT * FROM (VALUES
      ('a.1', 'p_a',   v_kg, 'sin base con ventas en kg → Kilogramo'),
      ('a.2', 'p_a2',  v_kg, 'ventas en kg + una venta SIN unidad → Kilogramo'),
      ('a.3', 'p_a3',  v_kg, 'otra cuenta, ventas en kg → Kilogramo'),
      ('b.1', 'p_b',   NULL, 'ventas en kg Y en mL → omitido'),
      ('b.2', 'p_b2',  NULL, 'ventas en kg + compra en u → omitido'),
      ('b.3', 'p_b3',  NULL, 'sólo compras en kg, sin ventas → omitido'),
      ('c.1', 'p_c',   v_g,  'base propia Gramo → intacta'),
      ('d.1', 'p_dv',  NULL, 'variante de otra cuenta que hereda kg → base propia intacta (NULL)'),
      ('d.2', 'p_dp',  v_kg, 'padre en kg de otra cuenta → intacto'),
      ('d2.1','p_d2p', NULL, 'padre sin base con variante viva que hereda → omitido'),
      ('d2.2','p_d2v', NULL, 'la variante del padre omitido → intacta'),
      ('d3.1','p_d3',  NULL, 'producto borrado → intacto'),
      ('p.1', 'p_p',   NULL, 'P0409 del guard capturado → omitido'),
      ('e.0', 'p_e',   NULL, 'producto de la decisión 8 (sin ventas en kg) → sin base')
    ) AS t(tag, key, expected, label)
  LOOP
    SELECT base_unit_id INTO v_base FROM public.products WHERE id = (SELECT id FROM gate_d89 WHERE k = r.key);
    IF v_base IS DISTINCT FROM r.expected THEN
      v_failures := v_failures || format('%s %s: base_unit_id=%s, esperaba %s', r.tag, r.label,
                                         COALESCE(v_base::text, 'NULL'), COALESCE(r.expected::text, 'NULL'));
    END IF;
  END LOOP;

  -- p.2: el P0409 de una fila no abortó a las demás (a/a2/a3 asignados en la MISMA corrida).
  SELECT count(*) INTO v_cnt FROM public.products
   WHERE id IN (SELECT id FROM gate_d89 WHERE k IN ('p_a', 'p_a2', 'p_a3')) AND base_unit_id = v_kg;
  IF v_cnt <> 3 THEN
    v_failures := v_failures || format('p.2 con un P0409 en otra fila se asignaron %s/3', v_cnt);
  END IF;

  -- (e) decisión 8.
  SELECT count(*) INTO v_cnt FROM public.stock_movements
   WHERE product_id = v_p_e AND metadata->>'fix' = 'ventas-unidades-conversion-decision-8';
  IF v_cnt <> 1 THEN
    v_failures := v_failures || format('e.1 movimientos de ajuste con la marca: %s, esperaba 1', v_cnt);
  END IF;
  SELECT * INTO v_mov FROM public.stock_movements
   WHERE product_id = v_p_e AND metadata->>'fix' = 'ventas-unidades-conversion-decision-8'
   ORDER BY created_at LIMIT 1;
  IF FOUND THEN
    IF v_mov.quantity_delta IS DISTINCT FROM -0.3806::numeric THEN
      v_failures := v_failures || format('e.3 quantity_delta=%s, esperaba -0.3806', v_mov.quantity_delta);
    END IF;
    IF v_mov.quantity_before IS DISTINCT FROM 6999.4276::numeric OR v_mov.quantity_after IS DISTINCT FROM 6999.0470::numeric THEN
      v_failures := v_failures || format('e.4 before/after=%s/%s, esperaba 6999.4276/6999.0470', v_mov.quantity_before, v_mov.quantity_after);
    END IF;
    IF v_mov.type IS DISTINCT FROM 'adjustment' OR v_mov.reference_type IS NOT NULL OR v_mov.reference_id IS NOT NULL THEN
      v_failures := v_failures || format('e.5 type/reference=%s/%s/%s, esperaba adjustment/NULL/NULL (como rpc_apply_product_stock_delta)',
                                         v_mov.type, v_mov.reference_type, v_mov.reference_id);
    END IF;
    IF v_mov.user_id IS DISTINCT FROM v_user_a OR v_mov.performed_by IS DISTINCT FROM v_user_a
       OR v_mov.account_id IS DISTINCT FROM v_account_a OR v_mov.branch_id IS DISTINCT FROM v_branch_a THEN
      v_failures := v_failures || format('e.6 user/performed_by/account/branch=%s/%s/%s/%s, esperaba el dueño de A y la sucursal default',
                                         v_mov.user_id, v_mov.performed_by, v_mov.account_id, v_mov.branch_id);
    END IF;
    IF v_mov.metadata->>'corrects_movement' IS DISTINCT FROM v_mov_id::text OR v_mov.movement_number IS NULL
       OR v_mov.product_name IS DISTINCT FROM 'Alimento D89 ABIERTO (decisión 8)' OR v_mov.reason IS NULL THEN
      v_failures := v_failures || format('e.7 metadata/movement_number/product_name/reason incompletos: %s / %s / %s / %s',
                                         v_mov.metadata, v_mov.movement_number, v_mov.product_name, v_mov.reason);
    END IF;
  END IF;
  SELECT quantity INTO v_num FROM public.branch_stock WHERE product_id = v_p_e AND branch_id = v_branch_a;
  IF v_before IS DISTINCT FROM 6999.4276::numeric OR v_num IS DISTINCT FROM 6999.0470::numeric THEN
    v_failures := v_failures || format('e.2 branch_stock %s → %s, esperaba 6999.4276 → 6999.0470', v_before, v_num);
  END IF;
  -- Invariante del ledger: SUM(quantity_delta) = branch_stock.
  SELECT sum(quantity_delta) INTO v_num FROM public.stock_movements WHERE product_id = v_p_e;
  IF v_num IS DISTINCT FROM 6999.0470::numeric THEN
    v_failures := v_failures || format('e.8 SUM(quantity_delta)=%s, esperaba 6999.0470', v_num);
  END IF;

  -- (f) reaplicar = 0 cambios.
  SELECT count(*) INTO v_cnt FROM public.stock_movements WHERE account_id IN (v_account_a, v_account_b);
  IF v_cnt <> (SELECT num FROM gate_d89 WHERE k = 'snap_movs') THEN
    v_failures := v_failures || format('f.1 la reaplicación cambió los movimientos: %s → %s', (SELECT num FROM gate_d89 WHERE k = 'snap_movs'), v_cnt);
  END IF;
  SELECT count(*) INTO v_cnt FROM public.products WHERE account_id IN (v_account_a, v_account_b) AND base_unit_id IS NOT NULL;
  IF v_cnt <> (SELECT num FROM gate_d89 WHERE k = 'snap_bases') THEN
    v_failures := v_failures || format('f.2 la reaplicación cambió las bases: %s → %s', (SELECT num FROM gate_d89 WHERE k = 'snap_bases'), v_cnt);
  END IF;
  SELECT sum(quantity) INTO v_num FROM public.branch_stock WHERE account_id IN (v_account_a, v_account_b);
  IF v_num IS DISTINCT FROM (SELECT num FROM gate_d89 WHERE k = 'snap_stock') THEN
    v_failures := v_failures || format('f.3 la reaplicación cambió el stock: %s → %s', (SELECT num FROM gate_d89 WHERE k = 'snap_stock'), v_num);
  END IF;
  SELECT count(*) INTO v_cnt FROM public.products WHERE base_unit_id IS NOT NULL;
  IF v_cnt <> (SELECT num FROM gate_d89 WHERE k = 'snap_all_bases') THEN
    v_failures := v_failures || format('f.4 la reaplicación asignó bases fuera del fixture: %s → %s', (SELECT num FROM gate_d89 WHERE k = 'snap_all_bases'), v_cnt);
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'zz_gate_d89_force_p0409')
     OR to_regprocedure('public._gate_d89_force_p0409()') IS NOT NULL THEN
    v_failures := v_failures || 'f.5 el trigger forzado del gate sigue vivo'::text;
  END IF;

  INSERT INTO gate_d89_fail SELECT unnest(v_failures);
  IF COALESCE(array_length(v_failures, 1), 0) = 0 THEN
    RAISE NOTICE 'PASS (a) (b) (c) (d) (p): 14/14 bases + p.2; (e) ajuste -0.3806 con marca, 6999.4276 → 6999.0470, invariante del ledger; (f) reaplicación sin cambios';
  END IF;
END $$;

-- ─── 5. Cleanup + (h) residuo cero ──────────────────────────────────────────
DO $$
DECLARE
  v_mov_id    constant uuid := 'cf4550c0-cf36-4f88-aeba-bdf2cd8bb423';
  v_failures  text[] := '{}';
  v_user_a    uuid := (SELECT id FROM gate_d89 WHERE k = 'user_a');
  v_user_b    uuid := (SELECT id FROM gate_d89 WHERE k = 'user_b');
  v_account_a uuid := (SELECT id FROM gate_d89 WHERE k = 'account_a');
  v_account_b uuid := (SELECT id FROM gate_d89 WHERE k = 'account_b');
  v_seeded    uuid[] := ARRAY(SELECT id FROM gate_d89 WHERE k LIKE 'seeded_%');
  v_cnt       integer;
  v_txt       text;
BEGIN
  DROP TRIGGER IF EXISTS zz_gate_d89_force_p0409 ON public.products;
  DROP FUNCTION IF EXISTS public._gate_d89_force_p0409();
  DELETE FROM public.events                WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_a, v_user_b)
                                              OR metadata::text LIKE '%' || v_account_a::text || '%'
                                              OR metadata::text LIKE '%' || v_account_b::text || '%';
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.analytics_events      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b);
  SET session_replication_role = replica;
  DELETE FROM public.document_status_history WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sales_order_items     WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sales_orders          WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.stock_movements       WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b);
  DELETE FROM public.branch_stock          WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sale_items            WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.purchase_items        WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.sales                 WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b);
  DELETE FROM public.purchases             WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b);
  DELETE FROM public.products              WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b);
  DELETE FROM public.branches              WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.units_of_measure      WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.journal_entries       WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.notifications         WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.payment_methods       WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.product_categories    WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.audit_logs            WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.accounts              WHERE id IN (v_account_a, v_account_b);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.account_feature_flags WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_a, v_user_b);
  DELETE FROM public.profiles              WHERE id IN (v_user_a, v_user_b);
  DELETE FROM auth.users                   WHERE id IN (v_user_a, v_user_b);
  DELETE FROM public.audit_logs            WHERE account_id IN (v_account_a, v_account_b);
  DELETE FROM public.units_of_measure      WHERE id = ANY(v_seeded);

  -- ── (h) Residuo cero ──
  FOR v_txt, v_cnt IN
    SELECT 'products', count(*)::int FROM public.products
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'branch_stock', count(*)::int FROM public.branch_stock WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'stock_movements', count(*)::int FROM public.stock_movements
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b) OR id = v_mov_id
    UNION ALL SELECT 'sales', count(*)::int FROM public.sales
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'purchases', count(*)::int FROM public.purchases
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'sale_items', count(*)::int FROM public.sale_items WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'purchase_items', count(*)::int FROM public.purchase_items WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'sales_orders', count(*)::int FROM public.sales_orders WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'branches', count(*)::int FROM public.branches WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'accounts', count(*)::int FROM public.accounts WHERE id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'auth.users', count(*)::int FROM auth.users WHERE id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'units_of_measure', count(*)::int FROM public.units_of_measure
      WHERE account_id IN (v_account_a, v_account_b) OR id = ANY(v_seeded)
    UNION ALL SELECT 'events', count(*)::int FROM public.events WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'analytics_events', count(*)::int FROM public.analytics_events
      WHERE account_id IN (v_account_a, v_account_b) OR user_id IN (v_user_a, v_user_b)
    UNION ALL SELECT 'journal_entries', count(*)::int FROM public.journal_entries WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'notifications', count(*)::int FROM public.notifications WHERE account_id IN (v_account_a, v_account_b)
    UNION ALL SELECT 'audit_logs', count(*)::int FROM public.audit_logs WHERE account_id IN (v_account_a, v_account_b)
  LOOP
    IF v_cnt <> 0 THEN
      v_failures := v_failures || format('h residuo: %s filas del fixture en %s tras el cleanup', v_cnt, v_txt);
    END IF;
  END LOOP;

  INSERT INTO gate_d89_fail SELECT unnest(v_failures);
  IF COALESCE(array_length(v_failures, 1), 0) = 0 THEN
    RAISE NOTICE 'PASS (h) residuo cero: 17/17 tablas';
  END IF;
END $$;

-- ─── 6. Veredicto ───────────────────────────────────────────────────────────
DO $$
DECLARE
  v_n integer := (SELECT count(*) FROM gate_d89_fail);
BEGIN
  IF v_n > 0 THEN
    RAISE EXCEPTION E'GATE unidades-decisiones-8-9 FAILED (% fallos):\n  %',
      v_n, (SELECT string_agg(msg, E'\n  ') FROM gate_d89_fail);
  END IF;
  RAISE NOTICE 'GATE unidades-decisiones-8-9: PASS';
END $$;

DROP TABLE IF EXISTS pg_temp.gate_d89;
DROP TABLE IF EXISTS pg_temp.gate_d89_fail;
