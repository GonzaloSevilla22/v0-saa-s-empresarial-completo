-- Plantilla de la reproducción 6.5 (ajuste fantasma) y 6.6 (viewer cambia stock por PUT /products).
-- run_repro_6_5_6_6.sh la completa: reinstala DENTRO de la transacción los CINCO cuerpos vivos de
-- partida (evidence/live_functiondefs/*.sql) y elimina el CHECK de motivo, es decir deja la base con el
-- comportamiento de HEAD (tanda A) sobre el stack ya migrado, ejecuta el escenario exactamente como lo
-- ejecutaba backend/repositories/product_repository.py::update (versión de HEAD) y hace ROLLBACK.
-- Con la marca @@NEW_BODIES@@ no reinstala nada: corre el MISMO escenario sobre los cuerpos nuevos.
--
-- Secuencia del PUT /products/{id} del backend de HEAD (ProductRepository.update):
--   1. UPDATE products SET <campos> WHERE id = $1 AND account_id = $2          (sólo si hay campos)
--   2. SELECT stock FROM v_products_with_stock WHERE id = $1 AND account_id = $2
--   3. delta = stock_target - stock_actual
--   4. SELECT public.rpc_apply_product_stock_delta($1, delta, NULL, 'Ajuste manual de stock', TRUE, FALSE)
-- ejecutada por asyncpg con los claims del JWT del usuario y SET LOCAL ROLE authenticated.

BEGIN;

@@REINSTATE_HEAD@@

CREATE OR REPLACE FUNCTION pg_temp.as_user(p_uid uuid) RETURNS void LANGUAGE plpgsql AS $f$
BEGIN
  PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid::text, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
END; $f$;

DO $$
DECLARE
  v_owner  uuid := gen_random_uuid();
  v_viewer uuid := gen_random_uuid();
  v_acc    uuid;
  v_member uuid;
  v_branch uuid;
  v_client uuid;
  v_prod   uuid;
  v_form_stock numeric;
  v_now_stock  numeric;
  v_delta      numeric;
  v_r      jsonb;
  v_n      bigint;
  v_txt    text;
  v_state  text;
BEGIN
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_owner,  'authenticated', 'authenticated', 'repro-owner@test.local',  now(), now(), '{"name":"Repro owner","phone":"","locality":"","province":""}'::jsonb),
         (v_viewer, 'authenticated', 'authenticated', 'repro-viewer@test.local', now(), now(), '{"name":"Repro viewer","phone":"","locality":"","province":""}'::jsonb);
  SELECT account_id INTO v_acc FROM public.account_members WHERE user_id = v_owner LIMIT 1;
  SET session_replication_role = replica;
  DELETE FROM public.account_member_roles WHERE member_id IN (SELECT id FROM public.account_members WHERE user_id = v_viewer);
  DELETE FROM public.account_members WHERE user_id = v_viewer;
  SET session_replication_role = DEFAULT;
  INSERT INTO public.account_members (account_id, user_id, role) VALUES (v_acc, v_viewer, 'member') RETURNING id INTO v_member;
  INSERT INTO public.account_member_roles (account_id, member_id, role) VALUES (v_acc, v_member, 'viewer');
  v_branch := public.c26_default_branch(v_acc);
  INSERT INTO public.clients (user_id, account_id, name) VALUES (v_owner, v_acc, 'Cliente repro') RETURNING id INTO v_client;
  INSERT INTO public.products (user_id, account_id, name, sku, cost, price)
  VALUES (v_owner, v_acc, 'Producto repro', 'REPRO-1', 10, 20) RETURNING id INTO v_prod;
  PERFORM public.c21_apply_branch_stock_delta(v_acc, v_prod, v_branch, 10);

  -- ════════ 6.5: ajuste fantasma al guardar un cambio de PRECIO con el stock viejo ════════
  PERFORM pg_temp.as_user(v_owner);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT stock INTO v_form_stock FROM public.v_products_with_stock WHERE id = v_prod AND account_id = v_acc;
  RAISE NOTICE '6.5 [1] el usuario abre el formulario de edición: stock del formulario = %', v_form_stock;

  SELECT public.rpc_create_sale_operation('repro-sale-' || gen_random_uuid()::text, v_client, CURRENT_DATE, 'ARS',
         jsonb_build_array(jsonb_build_object('product_id', v_prod, 'amount', 100.00, 'quantity', 2, 'unit_id', NULL)), v_branch, NULL)
    INTO v_r;
  SELECT stock INTO v_now_stock FROM public.v_products_with_stock WHERE id = v_prod AND account_id = v_acc;
  RAISE NOTICE '6.5 [2] una venta de 2 unidades mientras el formulario seguía abierto: saldo real = %', v_now_stock;

  -- 6.5 [3]: el usuario cambia el PRECIO y guarda; el formulario manda price=175 y el stock viejo (10).
  UPDATE public.products SET price = 175 WHERE id = v_prod AND account_id = v_acc;
  SELECT stock INTO v_now_stock FROM public.v_products_with_stock WHERE id = v_prod AND account_id = v_acc;
  v_delta := v_form_stock - v_now_stock;
  RAISE NOTICE '6.5 [3] el backend de HEAD calcula delta = objetivo(%) - saldo actual(%) = %', v_form_stock, v_now_stock, v_delta;
  BEGIN
    IF v_delta <> 0 THEN
      PERFORM public.rpc_apply_product_stock_delta(v_prod, v_delta, NULL, 'Ajuste manual de stock', TRUE, FALSE);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_txt = MESSAGE_TEXT;
    RAISE NOTICE '6.5 [3] la RPC fue rechazada: % %', v_state, v_txt;
  END;
  EXECUTE 'RESET ROLE';
  SELECT stock INTO v_now_stock FROM public.v_products_with_stock WHERE id = v_prod AND account_id = v_acc;
  SELECT count(*) INTO v_n FROM public.stock_movements WHERE product_id = v_prod AND reason = 'Ajuste manual de stock';
  RAISE NOTICE '6.5 [4] RESULTADO: saldo = % ; movimientos "Ajuste manual de stock" = % (las 2 unidades vendidas fueron re-sumadas)', v_now_stock, v_n;

  -- ════════ 6.6: un VIEWER cambia el stock por PUT /products/{id} ════════
  PERFORM pg_temp.as_user(v_viewer);
  EXECUTE 'SET LOCAL ROLE authenticated';
  SELECT stock INTO v_now_stock FROM public.v_products_with_stock WHERE id = v_prod AND account_id = v_acc;
  v_delta := 500 - v_now_stock;
  RAISE NOTICE '6.6 [1] viewer: stock actual = %, PUT con stock = 500 => delta = %', v_now_stock, v_delta;
  BEGIN
    PERFORM public.rpc_apply_product_stock_delta(v_prod, v_delta, NULL, 'Ajuste manual de stock', TRUE, FALSE);
    RAISE NOTICE '6.6 [2] la RPC ACEPTÓ el ajuste del viewer';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_txt = MESSAGE_TEXT;
    RAISE NOTICE '6.6 [2] la RPC rechazó al viewer: % %', v_state, v_txt;
  END;
  EXECUTE 'RESET ROLE';
  SELECT stock INTO v_now_stock FROM public.v_products_with_stock WHERE id = v_prod AND account_id = v_acc;
  RAISE NOTICE '6.6 [3] RESULTADO: saldo tras el intento del viewer = %', v_now_stock;
END $$;

ROLLBACK;
