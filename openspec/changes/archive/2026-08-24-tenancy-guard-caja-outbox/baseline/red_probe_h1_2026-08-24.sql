-- =============================================================================
-- RED PROBE — tenancy-guard-caja-outbox, tramo h1 (task 2.10)
--
-- Por qué existe: `supabase/tests/test_tenancy_guard_caja_outbox.sql` es
-- fail-fast (el primer assert que falla aborta el DO block), así que corriéndolo
-- contra el esquema PRE-migración sólo se ve el rojo de 2.2 y no el de 2.3,
-- 2.4 ni 2.5. Este archivo prueba CADA comportamiento por separado, captura el
-- SQLSTATE (o la ausencia de error) en una tabla temporal y la vuelca al final.
--
-- Read-only por construcción: todo corre dentro de un BEGIN … ROLLBACK, así que
-- no deja ni los tenants sintéticos ni los movimientos de caja que el hueco
-- produce. NO es un gate de CI: es el registro del RED. Se corre a mano:
--
--   docker exec -i supabase_db_v0-saa-s-empresarial-completo \
--     psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
--     < openspec/changes/tenancy-guard-caja-outbox/baseline/red_probe_h1_2026-08-24.sql
--
-- Lectura de la salida: en el esquema PRE-migración las cuatro filas de guard
-- dicen `sin error` y la fila del barrido global cuenta las filas corruptas que
-- el propio probe acaba de fabricar (y que el ROLLBACK deshace). En el esquema
-- POST-migración las cuatro dicen P0422/P0401, el control positivo sigue en
-- `sin error` y el barrido vuelve a 0.
-- =============================================================================

BEGIN;

CREATE TEMP TABLE red_probe_h1 (
  orden    int,
  caso     text,
  esperado text,
  obtenido text,
  detalle  text
) ON COMMIT DROP;

DO $$
DECLARE
  v_email_a    text := 'red-probe-h1-a@test.local';
  v_email_b    text := 'red-probe-h1-b@test.local';
  v_user_a     uuid := gen_random_uuid();
  v_user_b     uuid := gen_random_uuid();
  v_account_a  uuid;
  v_account_b  uuid;
  v_branch_a1  uuid;
  v_branch_a2  uuid;
  v_cashbox_a1 uuid;
  v_cashbox_a2 uuid;
  v_cashbox_b  uuid;
  v_branch_b   uuid;
  v_session_a1 uuid;
  v_session_a2 uuid;
  v_session_b  uuid;
  v_pm_cash_a  uuid;
  v_product_a  uuid;
  v_so_id      uuid;
  v_state      text;
  v_before     integer;
  v_after      integer;
  v_count      integer;
  v_result     jsonb;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'RED probe A'));
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'RED probe B'));

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  SELECT id INTO v_branch_a1  FROM public.branches  WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_a1 FROM public.cashboxes WHERE branch_id  = v_branch_a1 ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b   FROM public.branches  WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_b  FROM public.cashboxes WHERE branch_id  = v_branch_b  ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash_a  FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' LIMIT 1;

  INSERT INTO public.branches (account_id, name) VALUES (v_account_a, '__probe_branch_a2__') RETURNING id INTO v_branch_a2;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a2, '__probe_cashbox_a2__') RETURNING id INTO v_cashbox_a2;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a1, 'open', 0, v_user_a) RETURNING id INTO v_session_a1;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a2, 'open', 0, v_user_a) RETURNING id INTO v_session_a2;
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 0, v_user_b) RETURNING id INTO v_session_b;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__probe_product__', 1000, 400, 'PROBE-H1-1')
  RETURNING id INTO v_product_a;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a1, v_product_a, 1000);

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  -- ── (2.2) POS + sesión de caja de OTRO TENANT ───────────────────────────────
  SELECT COUNT(*) INTO v_before FROM public.cash_movements WHERE session_id = v_session_b;
  v_state := 'sin error';
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key   => 'probe-2-2',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_b,
      p_branch_id         => v_branch_a1,
      p_payment_method_id => v_pm_cash_a);
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE || ' ' || left(SQLERRM, 60);
  END;
  SELECT COUNT(*) INTO v_after FROM public.cash_movements WHERE session_id = v_session_b;
  INSERT INTO red_probe_h1 VALUES (1, '2.2 rpc_quick_sale con la sesión de caja de OTRO TENANT', 'P0422', v_state,
    format('movimientos en la caja de la víctima: %s → %s', v_before, v_after));

  -- ── (2.3) confirm_sales_order + sesión de OTRO TENANT ───────────────────────
  INSERT INTO public.sales_orders (account_id, branch_id, status, total, created_by)
  VALUES (v_account_a, v_branch_a1, 'draft', 1000, v_user_a) RETURNING id INTO v_so_id;
  INSERT INTO public.sales_order_items (sales_order_id, account_id, product_id, quantity, price, subtotal)
  VALUES (v_so_id, v_account_a, v_product_a, 1, 1000, 1000);

  SELECT COUNT(*) INTO v_before FROM public.cash_movements WHERE session_id = v_session_b;
  v_state := 'sin error';
  BEGIN
    PERFORM public.rpc_confirm_sales_order(
      p_idempotency_key   => 'probe-2-3',
      p_sales_order_id    => v_so_id,
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_b,
      p_payment_method_id => v_pm_cash_a);
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE || ' ' || left(SQLERRM, 60);
  END;
  SELECT COUNT(*) INTO v_after FROM public.cash_movements WHERE session_id = v_session_b;
  INSERT INTO red_probe_h1
  SELECT 2, '2.3 rpc_confirm_sales_order con la sesión de caja de OTRO TENANT', 'P0422', v_state,
         format('movimientos en la caja de la víctima: %s → %s · estado de la orden: %s',
                v_before, v_after, (SELECT status FROM public.sales_orders WHERE id = v_so_id));

  -- ── (2.4) sesión de OTRA SUCURSAL DEL MISMO TENANT ──────────────────────────
  SELECT COUNT(*) INTO v_before FROM public.cash_movements WHERE session_id = v_session_a2;
  v_state := 'sin error';
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key   => 'probe-2-4',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_a2,
      p_branch_id         => v_branch_a1,
      p_payment_method_id => v_pm_cash_a);
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE || ' ' || left(SQLERRM, 60);
  END;
  SELECT COUNT(*) INTO v_after FROM public.cash_movements WHERE session_id = v_session_a2;
  INSERT INTO red_probe_h1 VALUES (3, '2.4 sesión de OTRA SUCURSAL del mismo tenant (sólo la capa 1 lo ve)', 'P0422', v_state,
    format('movimientos en la caja de la otra sucursal: %s → %s', v_before, v_after));

  -- ── (2.5) c28_register_cash_movement directo contra la caja de B ────────────
  SELECT COUNT(*) INTO v_before FROM public.cash_movements WHERE session_id = v_session_b;
  v_state := 'sin error';
  BEGIN
    PERFORM public.c28_register_cash_movement(v_session_b, 500, 'sale', NULL);
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE || ' ' || left(SQLERRM, 60);
  END;
  SELECT COUNT(*) INTO v_after FROM public.cash_movements WHERE session_id = v_session_b;
  INSERT INTO red_probe_h1 VALUES (4, '2.5 c28_register_cash_movement directo contra la caja de OTRO TENANT', 'P0401', v_state,
    format('movimientos en la caja de la víctima: %s → %s', v_before, v_after));

  -- ── (3.5) control positivo: la venta legítima tiene que seguir andando ──────
  v_state := 'sin error';
  BEGIN
    SELECT public.rpc_quick_sale(
      p_idempotency_key   => 'probe-3-5',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 2, 'price', 1000, 'subtotal', 2000)),
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_a1,
      p_branch_id         => v_branch_a1,
      p_payment_method_id => v_pm_cash_a) INTO v_result;
  EXCEPTION WHEN OTHERS THEN v_state := SQLSTATE || ' ' || left(SQLERRM, 60);
  END;
  SELECT COUNT(*) INTO v_after FROM public.cash_movements WHERE session_id = v_session_a1;
  INSERT INTO red_probe_h1 VALUES (5, '3.5 CONTROL POSITIVO: venta POS con su PROPIA sesión de caja', 'sin error', v_state,
    format('movimientos en la caja propia: %s (esperado 1, importe 2000)', v_after));

  -- ── (2.9) barrido global, sobre el estado que este probe acaba de fabricar ──
  SELECT COUNT(*) INTO v_count
  FROM public.cash_movements cm
  JOIN public.cash_sessions cs ON cs.id = cm.session_id
  JOIN public.cashboxes cb     ON cb.id = cs.cashbox_id
  JOIN public.branches b       ON b.id  = cb.branch_id
  JOIN public.sales_orders so  ON so.id = cm.reference_id
  WHERE so.account_id IS DISTINCT FROM b.account_id;
  INSERT INTO red_probe_h1 VALUES (6, '2.9 barrido global: movimientos imputados a la caja de otro tenant', '0', v_count::text,
    'cuenta las filas corruptas que los casos 2.2/2.3 acaban de fabricar; el ROLLBACK las deshace');
END $$;

SELECT orden, caso, esperado, obtenido, detalle FROM red_probe_h1 ORDER BY orden;

ROLLBACK;
