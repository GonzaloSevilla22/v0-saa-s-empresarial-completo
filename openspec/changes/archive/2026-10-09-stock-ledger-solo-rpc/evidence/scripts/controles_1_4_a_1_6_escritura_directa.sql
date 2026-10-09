-- =============================================================================
-- controles_1_4_a_1_6_escritura_directa.sql — Controles por construcción de la
-- TANDA A de `stock-ledger-solo-rpc` (tasks 1.4, 1.5 y 1.6).
--
-- Se corre en el stack local ANTES de escribir la migración 20261073000001 (para
-- ver que la escritura directa HOY funciona) y DESPUÉS (para ver que quedó
-- cerrada). Cada control imprime una línea `CONTROL <n>: ...` con el resultado
-- observado, sea cual sea: el script no afirma nada, REPORTA. El veredicto lo
-- dan los logs de evidence/logs/ (antes y después) y el gate
-- supabase/tests/test_stock_ledger_solo_rpc.sql.
--
--   (i)   Forja + reversa pública, como `viewer` (rol de sólo lectura): inserta
--         una fila `reference_type='sale'` en stock_movements y llama a
--         rpc_reverse_stock_movement sobre ella. Hoy el stock SUBE (stock
--         fabricado a partir de una fila inventada). Es el control positivo
--         ejecutado en el red team de remitos-venta (redteam.log L79).
--   (ii)  Que DISCRIMINE: como `seller` (escritor), UPDATE de branch_stock a un
--         valor DISTINTO del actual. Hoy pasa (1 fila, el saldo cambia, ningún
--         movimiento en el ledger). Gemelo negativo: el mismo UPDATE como
--         `viewer` (no escritor) afecta 0 filas — prueba que el control mide la
--         policy `branch_stock_writer_update` y no un artefacto.
--   (iii) Ocupación cross-tenant: un escritor de la cuenta A inserta
--         branch_stock (A, producto de B, sucursal de B, 0) ANTES de que B tenga
--         fila; después B compra ese producto en esa sucursal por la RPC real.
--         c21_apply_branch_stock_delta actualiza por (producto, sucursal) sin
--         filtrar cuenta: se verifica si el saldo de B se acumula en la fila de
--         A (invisible para B bajo RLS).
--
-- Fixture sintética (usuarios @test.local vía handle_new_user), sesión simulada
-- con set_config LOCAL; limpieza total y residuo cero ASERTADO. NUNCA contra prod.
-- =============================================================================

CREATE OR REPLACE FUNCTION pg_temp.ctl_as(p_uid uuid) RETURNS void
LANGUAGE plpgsql AS $f$
BEGIN
  IF p_uid IS NULL THEN
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
  ELSE
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
  END IF;
END;
$f$;

CREATE OR REPLACE FUNCTION pg_temp.ctl_stock(p_product uuid, p_branch uuid) RETURNS numeric
LANGUAGE sql AS $f$
  SELECT COALESCE(sum(quantity), 0) FROM public.branch_stock
  WHERE product_id = p_product AND branch_id = p_branch;
$f$;

DO $$
DECLARE
  v_owner_a  uuid := gen_random_uuid();
  v_viewer   uuid := gen_random_uuid();
  v_seller   uuid := gen_random_uuid();
  v_owner_b  uuid := gen_random_uuid();
  v_users    uuid[];
  v_accounts uuid[];
  v_account_a uuid;
  v_account_b uuid;
  v_xa       uuid;
  v_xb       uuid;
  v_pa       uuid;
  v_pb       uuid;
  v_member   uuid;
  v_fake     uuid := gen_random_uuid();   -- "venta" inventada para la forja
  v_state    text;
  v_msg      text;
  v_table    text;
  v_before   numeric;
  v_after    numeric;
  v_n        bigint;
  v_n2       bigint;
  v_rows     integer;
  v_mov_before bigint;
  v_mov_after  bigint;
  v_res      text;
  v_acc      uuid;
  v_qty      numeric;
  v_op       jsonb;
BEGIN
  -- ── fixture ───────────────────────────────────────────────────────────────
  v_users := ARRAY[v_owner_a, v_viewer, v_seller, v_owner_b];
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  SELECT u.id, 'authenticated', 'authenticated', 'slr-control-' || u.tag || '@test.local', now(), now(),
         jsonb_build_object('name', 'Control SLR ' || u.tag, 'phone', '', 'locality', '', 'province', '')
  FROM (VALUES (v_owner_a, 'owner-a'), (v_viewer, 'viewer'), (v_seller, 'seller'), (v_owner_b, 'owner-b')) AS u(id, tag);

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_owner_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_owner_b ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN
    RAISE EXCEPTION 'SETUP FAILED: handle_new_user no creó las cuentas de los owners';
  END IF;
  SELECT array_agg(DISTINCT account_id) INTO v_accounts FROM public.account_members WHERE user_id = ANY (v_users);

  -- viewer y seller: se mudan a la cuenta A con su rol del pivot (la cuenta propia
  -- que les creó handle_new_user se borra para que current_account_ids() = {A}).
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles
   WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id IN (v_viewer, v_seller));
  DELETE FROM public.account_members WHERE user_id IN (v_viewer, v_seller);
  SET session_replication_role = DEFAULT;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_viewer, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'viewer');
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_account_a, v_seller, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_account_a, v_member, 'seller');

  SELECT id INTO v_xa FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_xb FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_a, v_account_a, 'Control SLR PA', 'SLR-PA', 10, 20) RETURNING id INTO v_pa;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner_b, v_account_b, 'Control SLR PB', 'SLR-PB', 10, 20) RETURNING id INTO v_pb;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CONTROL (i) — forja + reversa pública, como `viewer`
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM public.c21_apply_branch_stock_delta(v_account_a, v_pa, v_xa, 1);   -- saldo legítimo: 1
  v_before := pg_temp.ctl_stock(v_pa, v_xa);

  PERFORM pg_temp.ctl_as(v_viewer);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_res := 'forja=?';
  BEGIN
    INSERT INTO public.stock_movements (account_id, product_id, product_name, type, quantity_delta, reference_id, reference_type, branch_id)
    VALUES (v_account_a, v_pa, 'Control SLR PA', 'sale', -1, v_fake, 'sale', v_xa);
    v_res := 'forja=INSERTADA';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_res := format('forja=RECHAZADA %s %s', v_state, v_msg);
  END;
  BEGIN
    PERFORM public.rpc_reverse_stock_movement(v_fake, 'sale', 'control 1.4');
    v_res := v_res || ' | reversa=EJECUTADA';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_res := v_res || format(' | reversa=RECHAZADA %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.ctl_as(NULL);
  v_after := pg_temp.ctl_stock(v_pa, v_xa);
  RAISE NOTICE 'CONTROL (i) [viewer]: % | stock % -> % (%)', v_res, v_before, v_after,
    CASE WHEN v_after > v_before THEN 'EL STOCK SUBIÓ: fabricado a partir de una fila forjada' ELSE 'el stock no cambió' END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CONTROL (ii) — UPDATE directo de branch_stock a un valor DISTINTO
  -- ═══════════════════════════════════════════════════════════════════════
  SELECT count(*) INTO v_mov_before FROM public.stock_movements WHERE product_id = v_pa;
  v_before := pg_temp.ctl_stock(v_pa, v_xa);

  -- gemelo negativo: viewer (no escritor)
  PERFORM pg_temp.ctl_as(v_viewer);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_res := 'update=?';
  BEGIN
    UPDATE public.branch_stock SET quantity = 777 WHERE product_id = v_pa AND branch_id = v_xa;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_res := format('update=EJECUTADO filas=%s', v_rows);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_res := format('update=RECHAZADO %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.ctl_as(NULL);
  RAISE NOTICE 'CONTROL (ii) [viewer, no escritor]: % | saldo % -> %', v_res, v_before, pg_temp.ctl_stock(v_pa, v_xa);

  -- el control propiamente dicho: seller (escritor)
  PERFORM pg_temp.ctl_as(v_seller);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_res := 'update=?';
  BEGIN
    UPDATE public.branch_stock SET quantity = 555 WHERE product_id = v_pa AND branch_id = v_xa;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_res := format('update=EJECUTADO filas=%s', v_rows);
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_res := format('update=RECHAZADO %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.ctl_as(NULL);
  v_after := pg_temp.ctl_stock(v_pa, v_xa);
  SELECT count(*) INTO v_mov_after FROM public.stock_movements WHERE product_id = v_pa;
  RAISE NOTICE 'CONTROL (ii) [seller, escritor]: % | saldo % -> % | movimientos del producto % -> % (%)',
    v_res, v_before, v_after, v_mov_before, v_mov_after,
    CASE WHEN v_after <> v_before AND v_mov_after = v_mov_before THEN 'EL SALDO CAMBIÓ SIN RASTRO EN EL LEDGER' ELSE 'el saldo no cambió' END;

  -- ═══════════════════════════════════════════════════════════════════════
  -- CONTROL (iii) — ocupación cross-tenant de (producto de B, sucursal de B)
  -- ═══════════════════════════════════════════════════════════════════════
  PERFORM pg_temp.ctl_as(v_owner_a);
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_res := 'ocupacion=?';
  BEGIN
    INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
    VALUES (v_account_a, v_pb, v_xb, 0);
    v_res := 'ocupacion=INSERTADA (A, producto de B, sucursal de B, 0)';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_res := format('ocupacion=RECHAZADA %s %s', v_state, v_msg);
  END;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.ctl_as(NULL);
  RAISE NOTICE 'CONTROL (iii) paso 1 [owner de A]: %', v_res;

  -- B compra su producto en su sucursal por la RPC real (como lo hace la app).
  PERFORM pg_temp.ctl_as(v_owner_b);
  BEGIN
    v_op := public.rpc_create_purchase_operation(
      'slr-control-' || gen_random_uuid()::text, CURRENT_DATE, 'Compra control SLR',
      jsonb_build_array(jsonb_build_object('product_id', v_pb, 'amount', 10.00, 'quantity', 7, 'unit_id', NULL)),
      v_xb, NULL);
    v_res := 'compra de B=OK';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    v_res := format('compra de B=FALLÓ %s %s', v_state, v_msg);
  END;
  PERFORM pg_temp.ctl_as(NULL);

  SELECT count(*), max(account_id::text)::uuid, max(quantity)
    INTO v_n, v_acc, v_qty
    FROM public.branch_stock WHERE product_id = v_pb AND branch_id = v_xb;
  RAISE NOTICE 'CONTROL (iii) paso 2 [%]: filas de branch_stock para (producto de B, sucursal de B)=%; account_id de la fila=% (A=% / B=%); quantity=%',
    v_res, v_n, v_acc, v_account_a, v_account_b, v_qty;

  -- Qué ve B bajo RLS de ese saldo.
  PERFORM pg_temp.ctl_as(v_owner_b);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT count(*), COALESCE(sum(quantity), 0) INTO v_n2, v_after FROM public.branch_stock WHERE product_id = v_pb;
  EXECUTE 'RESET ROLE';
  PERFORM pg_temp.ctl_as(NULL);
  RAISE NOTICE 'CONTROL (iii) paso 3 [B bajo RLS]: ve % fila(s) de saldo de su producto, suma % (%)', v_n2, v_after,
    CASE WHEN v_n2 = 0 AND v_qty > 0 THEN 'EL SALDO DE B QUEDÓ ACUMULADO EN LA FILA DE A, INVISIBLE PARA B'
         WHEN v_n2 > 0 THEN 'B ve su saldo: no hubo ocupación efectiva'
         ELSE 'sin saldo' END;

  -- ── limpieza y residuo cero ───────────────────────────────────────────────
  SET session_replication_role = replica;
  DELETE FROM public.stock_movements
   WHERE user_id = ANY (v_users) OR account_id = ANY (v_accounts) OR product_id IN (v_pa, v_pb) OR reference_id = v_fake;
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
  FOR v_table IN
    SELECT c.table_name
    FROM   information_schema.columns c
    JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
    WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
      AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
  LOOP
    EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
  END LOOP;
  DELETE FROM public.branch_stock WHERE product_id IN (v_pa, v_pb);
  DELETE FROM public.accounts              WHERE id = ANY (v_accounts);
  DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
  DELETE FROM public.profiles              WHERE id = ANY (v_users);
  DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
  DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
  DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
  DELETE FROM auth.users                   WHERE id = ANY (v_users);
  SET session_replication_role = DEFAULT;

  IF EXISTS (SELECT 1 FROM public.stock_movements WHERE user_id = ANY (v_users) OR account_id = ANY (v_accounts) OR product_id IN (v_pa, v_pb))
     OR EXISTS (SELECT 1 FROM public.branch_stock WHERE account_id = ANY (v_accounts) OR product_id IN (v_pa, v_pb))
     OR EXISTS (SELECT 1 FROM public.products WHERE id IN (v_pa, v_pb))
     OR EXISTS (SELECT 1 FROM public.accounts WHERE id = ANY (v_accounts))
     OR EXISTS (SELECT 1 FROM auth.users WHERE id = ANY (v_users)) THEN
    RAISE EXCEPTION 'CONTROLES SLR: quedaron filas de la fixture (residuo no cero)';
  END IF;
  RAISE NOTICE 'CONTROLES SLR: fixture limpiada, residuo cero.';

EXCEPTION
  WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    PERFORM set_config('request.jwt.claims', '', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    BEGIN
      EXECUTE 'RESET ROLE';
      SET session_replication_role = replica;
      IF v_accounts IS NOT NULL THEN
        DELETE FROM public.stock_movements WHERE account_id = ANY (v_accounts) OR product_id IN (v_pa, v_pb);
        DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id = ANY (v_accounts));
        FOR v_table IN
          SELECT c.table_name
          FROM   information_schema.columns c
          JOIN   information_schema.tables  t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
          WHERE  c.table_schema = 'public' AND c.column_name = 'account_id'
            AND  t.table_type = 'BASE TABLE' AND c.table_name <> 'accounts'
        LOOP
          EXECUTE format('DELETE FROM public.%I WHERE account_id = ANY ($1)', v_table) USING v_accounts;
        END LOOP;
        DELETE FROM public.branch_stock WHERE product_id IN (v_pa, v_pb);
        DELETE FROM public.accounts WHERE id = ANY (v_accounts);
      END IF;
      DELETE FROM public.account_members       WHERE user_id = ANY (v_users);
      DELETE FROM public.profiles              WHERE id = ANY (v_users);
      DELETE FROM public.email_logs            WHERE user_id = ANY (v_users);
      DELETE FROM public.analytics_events      WHERE user_id = ANY (v_users);
      DELETE FROM public.operation_idempotency WHERE user_id = ANY (v_users);
      DELETE FROM auth.users                   WHERE id = ANY (v_users);
      SET session_replication_role = DEFAULT;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE EXCEPTION 'CONTROLES SLR abortaron: % / %', v_state, v_msg;
END $$;
