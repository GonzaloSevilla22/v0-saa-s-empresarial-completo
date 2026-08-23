-- =============================================================================
-- RED PROBE — cuenta-corriente-party-guard (task 2.7)
-- =============================================================================
--
-- Diagnóstico independiente que prueba CADA comportamiento por separado y
-- reporta el SQLSTATE observado SIN abortar. Existe porque el gate real
-- (supabase/tests/test_cuenta_corriente_party_guard.sql) es fail-fast —molde de
-- la casa— y por lo tanto sólo muestra el PRIMER assert en rojo: aborta en 2.2
-- y no dice nada de los otros ocho. Esta sonda es el inventario completo del
-- RED del change.
--
-- Ejecutado el 2026-08-23 contra el stack LOCAL a 20261007000001 (esquema
-- ANTERIOR a la migración de este change). Salida resumida en tasks.md 2.7.
--
-- READ-ONLY POR CONSTRUCCIÓN: todo va dentro de BEGIN … ROLLBACK. La sonda
-- inserta tenants sintéticos, catálogo y operaciones —tiene que hacerlo para
-- ejercitar las RPCs de verdad— pero nada se persiste. Nunca se corrió contra
-- producción y no debe correrse contra producción.
--
-- Para reproducir el RED hoy: aplicar el esquema hasta 20261009000001
-- (`npx supabase db reset` con la migración 20261010000001 removida) y correr
-- este archivo; o, más barato, correr el gate y verlo abortar en 2.2.
--
-- Uso:
--   docker exec -i supabase_db_v0-saa-s-empresarial-completo --     psql -U postgres -d postgres -v ON_ERROR_STOP=1 --     < openspec/changes/cuenta-corriente-party-guard/baseline/red_probe_2026-08-23.sql
-- =============================================================================

BEGIN;

-- Diagnóstico RED: prueba CADA comportamiento por separado y reporta el
-- SQLSTATE observado, sin abortar. Sirve para el reporte "qué asserts están
-- en rojo antes de la migración" (el gate real es fail-fast, mold de la casa).
DO $$
DECLARE
  ua uuid := gen_random_uuid(); ub uuid := gen_random_uuid();
  aa uuid; ab uuid; br uuid; prod uuid; bank uuid;
  pmc uuid; pmt uuid;
  ca uuid; ca2 uuid; sa uuid; cb uuid; sb uuid;
  ghost uuid := gen_random_uuid();
  st text; n int; ev uuid; evrow public.events; caid uuid;
BEGIN
  INSERT INTO auth.users (id,aud,role,email,created_at,updated_at,raw_user_meta_data)
  VALUES (ua,'authenticated','authenticated','red-probe-a@test.local',now(),now(),jsonb_build_object('name','A'));
  INSERT INTO auth.users (id,aud,role,email,created_at,updated_at,raw_user_meta_data)
  VALUES (ub,'authenticated','authenticated','red-probe-b@test.local',now(),now(),jsonb_build_object('name','B'));
  SELECT account_id INTO aa FROM public.account_members WHERE user_id=ua LIMIT 1;
  SELECT account_id INTO ab FROM public.account_members WHERE user_id=ub LIMIT 1;
  SELECT id INTO br FROM public.branches WHERE account_id=aa LIMIT 1;
  SELECT id INTO pmc FROM public.payment_methods WHERE account_id=aa AND kind='credit' LIMIT 1;
  SELECT id INTO pmt FROM public.payment_methods WHERE account_id=aa AND kind='transfer' LIMIT 1;
  INSERT INTO public.products (user_id,account_id,name,price,cost,sku) VALUES (ua,aa,'__rp__',1000,400,'RP-1') RETURNING id INTO prod;
  INSERT INTO public.branch_stock (account_id,branch_id,product_id,quantity) VALUES (aa,br,prod,1000) ON CONFLICT (branch_id,product_id) DO UPDATE SET quantity=1000;
  INSERT INTO public.bank_accounts (account_id,name,currency,opening_balance) VALUES (aa,'__rp_bank__','ARS',0) RETURNING id INTO bank;
  INSERT INTO public.clients (user_id,account_id,name,status) VALUES (ua,aa,'__rp_ca__','active') RETURNING id INTO ca;
  INSERT INTO public.clients (user_id,account_id,name,status) VALUES (ua,aa,'__rp_ca2__','active') RETURNING id INTO ca2;
  INSERT INTO public.suppliers (account_id,name) VALUES (aa,'__rp_sa__') RETURNING id INTO sa;
  INSERT INTO public.clients (user_id,account_id,name,status) VALUES (ub,ab,'__rp_cb__','active') RETURNING id INTO cb;
  INSERT INTO public.suppliers (account_id,name) VALUES (ab,'__rp_sb__') RETURNING id INTO sb;
  PERFORM set_config('request.jwt.claims', json_build_object('sub',ua::text,'role','authenticated')::text, true);

  caid := public.c30_get_or_create_customer_account(aa, ca);
  PERFORM public.c30_register_customer_account_movement(caid, 5000, 'sale', gen_random_uuid());

  -- 2.2
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN PERFORM public.rpc_register_payment_received('rp-2-2', cb, 100); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  RAISE NOTICE '[2.2] payment_received(cliente ajeno) -> % (esperado P0404)', st;
  SELECT count(*) INTO n FROM public.customer_accounts WHERE account_id=aa AND client_id=cb;
  RAISE NOTICE '[2.2] filas cross-tenant en customer_accounts tras el intento: % (rollback de subtx)', n;

  -- 2.2-bis: demostración directa del choke point sin la validación de saldo
  st := 'NINGUNO (la llamada tuvo EXITO -> FILA CROSS-TENANT CREADA)';
  BEGIN
    PERFORM public.c30_get_or_create_customer_account(aa, cb);
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  SELECT count(*) INTO n FROM public.customer_accounts WHERE account_id=aa AND client_id=cb;
  RAISE NOTICE '[choke] c30_get_or_create_customer_account(A, clienteB) -> % ; filas creadas=% (esperado P0404 / 0)', st, n;
  DELETE FROM public.customer_accounts WHERE account_id=aa AND client_id=cb;

  st := 'NINGUNO (la llamada tuvo EXITO -> FILA CROSS-TENANT CREADA)';
  BEGIN PERFORM public.c30_get_or_create_supplier_account(aa, sb); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  SELECT count(*) INTO n FROM public.supplier_accounts WHERE account_id=aa AND supplier_id=sb;
  RAISE NOTICE '[choke] c30_get_or_create_supplier_account(A, proveedorB) -> % ; filas creadas=% (esperado P0404 / 0)', st, n;
  DELETE FROM public.supplier_accounts WHERE account_id=aa AND supplier_id=sb;

  -- 2.3
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN PERFORM public.rpc_register_payment_made('rp-2-3', sb, 100); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  RAISE NOTICE '[2.3] payment_made(proveedor ajeno) -> % (esperado P0404)', st;

  -- 2.4
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN PERFORM public.rpc_register_supplier_charge('rp-2-4', sb, 250); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  SELECT count(*) INTO n FROM public.supplier_accounts WHERE account_id=aa AND supplier_id=sb;
  RAISE NOTICE '[2.4] supplier_charge(proveedor ajeno) -> % ; supplier_accounts cross-tenant=% (esperado P0404 / 0)', st, n;
  DELETE FROM public.supplier_account_movements WHERE supplier_account_id IN (SELECT id FROM public.supplier_accounts WHERE account_id=aa AND supplier_id=sb);
  DELETE FROM public.supplier_accounts WHERE account_id=aa AND supplier_id=sb;

  -- 2.5
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2('rp-2-5', cb, public.reporting_local_today(), 'ARS',
      jsonb_build_array(jsonb_build_object('product_id',prod,'amount',1000,'quantity',1)), br, NULL, pmc);
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  SELECT count(*) INTO n FROM public.customer_accounts WHERE account_id=aa AND client_id=cb;
  RAISE NOTICE '[2.5] venta FORMULARIO credito + cliente ajeno -> % ; cuentas cross-tenant=% (esperado P0404 / 0)', st, n;

  -- 2.6
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN
    PERFORM public.rpc_quick_sale('rp-2-6', cb,
      jsonb_build_array(jsonb_build_object('product_id',prod,'quantity',1,'price',1000,'subtotal',1000)),
      'credit', NULL, NULL, NULL, br, NULL, pmc);
  EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  SELECT count(*) INTO n FROM public.sales_orders WHERE client_id=cb;
  RAISE NOTICE '[2.6] venta POS credito + cliente ajeno -> % ; sales_orders cross-tenant=% (esperado P0404 / 0)', st, n;

  -- 3.6
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN PERFORM public.rpc_register_payment_received('rp-3-6', ghost, 100); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  RAISE NOTICE '[3.6] payment_received(cliente inexistente) -> % (esperado P0404)', st;

  -- 4.6
  st := 'NINGUNO';
  BEGIN PERFORM public.rpc_register_payment_received('rp-4-6', cb, 0); EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  RAISE NOTICE '[4.6] payment_received(cliente ajeno, amount=0) -> % (esperado P0400, ya verde hoy)', st;

  -- 4.7a / 4.7b
  st := 'NINGUNO (la llamada tuvo EXITO)';
  BEGIN PERFORM public.rpc_register_payment_received('rp-4-7a', cb, 100, NULL, 'transfer', bank); EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  RAISE NOTICE '[4.7a] payment_received transfer + cliente ajeno -> % (esperado P0404)', st;
  st := 'NINGUNO';
  BEGIN PERFORM public.rpc_register_payment_received('rp-4-7b', cb, 100, NULL, 'transfer', ghost); EXCEPTION WHEN OTHERS THEN st := SQLSTATE; END;
  RAISE NOTICE '[4.7b] payment_received transfer + bank inexistente -> % (esperado P0412, ya verde hoy)', st;

  -- 5.1
  EXECUTE 'SET LOCAL ROLE authenticated';
  st := 'NINGUNO (la llamada tuvo EXITO -> ESCRITURA CROSS-TENANT REAL)';
  BEGIN PERFORM public._pay_register_party_charge(ab,'customer',cb,1000,NULL,NULL); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM public.customer_accounts WHERE account_id=ab AND client_id=cb;
  RAISE NOTICE '[5.1] _pay_register_party_charge como authenticated -> % ; cuentas escritas en el tenant VICTIMA=% (esperado 42501 / 0)', st, n;

  -- 5.2
  INSERT INTO public.events (account_id,event_type,aggregate_type,aggregate_id,payload,occurred_at)
  VALUES (ab,'SaleConfirmed','SalesOrder',gen_random_uuid(),
    jsonb_build_object('account_id',ab,'sales_order_id',gen_random_uuid(),'operation_id',gen_random_uuid(),'total',999,'payment_method','cash'),now())
  RETURNING id INTO ev;
  SELECT * INTO evrow FROM public.events WHERE id=ev;
  EXECUTE 'SET LOCAL ROLE authenticated';
  st := 'NINGUNO (la llamada tuvo EXITO -> ASIENTO FORJADO EN OTRO TENANT)';
  BEGIN PERFORM public._journal_post_from_event(evrow); EXCEPTION WHEN OTHERS THEN st := SQLSTATE||' '||SQLERRM; END;
  EXECUTE 'RESET ROLE';
  SELECT count(*) INTO n FROM public.journal_entries WHERE source_event_id=ev;
  RAISE NOTICE '[5.2] _journal_post_from_event como authenticated -> % ; asientos posteados en el tenant VICTIMA=% (esperado 42501 / 0)', st, n;

  RAISE NOTICE '--- ACLs actuales ---';
  RAISE NOTICE '_pay_register_party_charge  authenticated=%', has_function_privilege('authenticated','public._pay_register_party_charge(uuid,text,uuid,numeric,uuid,uuid)'::regprocedure,'EXECUTE');
  RAISE NOTICE '_journal_post_from_event    authenticated=%', has_function_privilege('authenticated','public._journal_post_from_event(public.events)'::regprocedure,'EXECUTE');
END $$;

ROLLBACK;
