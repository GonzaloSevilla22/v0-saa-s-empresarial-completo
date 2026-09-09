-- =============================================================================
-- GATE: test_c30_party_movement_helpers_acl.sql
-- CHANGE: c30-party-movement-helpers-definer (candidato S2, h3 de
--         cuenta-corriente-party-guard)
-- =============================================================================
--
-- `c30_register_customer_account_movement` y
-- `c30_register_supplier_account_movement` reciben la cuenta corriente
-- (`p_account_id`) COMO PARÁMETRO y, antes de esta migración, eran SECURITY
-- INVOKER sin ningún guard de tenencia — la única barrera era la ausencia de
-- policies de escritura sobre customer_account_movements/
-- supplier_account_movements, una defensa de segundo orden. Este gate
-- ejercita las dos capas nuevas por separado:
--
--   (1) INTROSPECCIÓN — ambas funciones quedan SECURITY DEFINER, con
--       `SET search_path = public`, el literal `current_account_ids` (guard
--       de MEMBRESÍA) en el cuerpo y SIN el literal `is_account_writer`
--       (F3 — el guard NO estrecha por rol), y SIN EXECUTE para
--       anon/authenticated (postgres conserva EXECUTE — la cadena DEFINER de
--       sus callers sigue viva).
--   (2) NEGATIVO — bajo SET LOCAL ROLE authenticated (mismo patrón que
--       test_cuenta_corriente_party_guard.sql 5.1/5.2), invocar cualquiera
--       de los dos helpers DIRECTO se rechaza con 42501 (insufficient_
--       privilege) — el REVOKE por sí solo ya cierra el camino, antes de que
--       el guard interno tenga oportunidad de evaluar nada.
--   (3) POSITIVO DE NO-REGRESIÓN — los callers reales
--       (`rpc_register_payment_received`, `rpc_register_supplier_charge`,
--       con sus firmas VIVAS) siguen posteando el movimiento normalmente
--       para su propio tenant: el guard interno no sobre-bloquea al camino
--       legítimo, porque la cuenta que valida es la misma que la RPC ya
--       resolvió de la sesión.
--   (4) GUARD INTERNO — dos caras de la misma moneda, porque F3 dejó
--       establecido que el guard es de TENENCIA (membresía), no de rol:
--       (4a) NEGATIVO cross-tenant — como `postgres` (owner: el REVOKE de
--       (2) no aplica, así que si esto pasara SIN el guard interno,
--       escribiría en los libros de otro tenant) con `request.jwt.claims`
--       del tenant A, invocar el helper sobre una
--       `CustomerAccount`/`SupplierAccount` que pertenece al tenant B →
--       P0401, y los libros de B quedan intactos. Esto es lo que distingue
--       este candidato de un REVOKE a secas: si un CREATE OR REPLACE futuro
--       pierde el REVOKE (el mismo mecanismo que produjo el hotfix #454), el
--       guard interno sigue cerrando la cuenta ajena.
--       (4b) POSITIVO same-tenant con rol 'member' — un usuario SIN rol de
--       escritura (`account_members.role = 'member'`, molde de
--       `test_charge_due_date.sql` L126-132) que pertenece al MISMO tenant A
--       SÍ puede postear el movimiento sobre `v_ca_a`: si el guard hubiera
--       quedado en `is_account_writer` (owner/admin) en vez de
--       `current_account_ids()` (membresía), este caso fallaría con P0401 —
--       es la prueba directa de que la venta a crédito de un 'member' (hoy
--       0 en prod, futuro de v3-rbac-multirole) sigue funcionando.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta (mismo patrón
-- que test_cuenta_corriente_party_guard.sql).
--
-- Cleanup: el gate termina con un DO block que borra los dos tenants
-- sintéticos y todo lo que cuelga de ellos, para que la corrida sea
-- reproducible dos veces seguidas sobre la misma base.
-- =============================================================================

DO $$
DECLARE
  v_email_a       text := 'c30-party-movement-helpers-a@test.local';
  v_email_b       text := 'c30-party-movement-helpers-b@test.local';
  v_email_member  text := 'c30-party-movement-helpers-member@test.local';
  v_user_a        uuid := gen_random_uuid();
  v_user_b        uuid := gen_random_uuid();
  v_user_member   uuid := gen_random_uuid();
  v_account_a     uuid;
  v_account_b     uuid;
  v_client_a      uuid;
  v_client_b      uuid;
  v_supplier_a    uuid;
  v_supplier_b    uuid;
  v_ca_a          uuid;
  v_ca_b          uuid;
  v_sa_a          uuid;
  v_sa_b          uuid;

  v_oid_customer  regprocedure := 'public.c30_register_customer_account_movement(uuid, numeric, text, uuid, date)'::regprocedure;
  v_oid_supplier  regprocedure := 'public.c30_register_supplier_account_movement(uuid, numeric, text, uuid, date)'::regprocedure;

  v_prosecdef     bool;
  v_proconfig     text[];
  v_prosrc        text;

  v_rejected      boolean;
  v_sqlstate      text;
  v_balance_a     numeric;
  v_result        jsonb;

  v_nb_cust_movs  integer;
  v_nb_sup_movs   integer;
  v_nb_before     integer;
BEGIN
  -- ── Anchor sintético del tenant A ─────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate C30 Movement Helpers A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: no se pudo resolver cuenta para el anchor sintético A — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Anchor sintético del tenant B ──────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate C30 Movement Helpers B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_b IS NULL OR v_account_b = v_account_a THEN
    RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: no se pudo provisionar un SEGUNDO tenant independiente para el anchor B — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Anchor sintético 'member' de A (F3, check 4b) ───────────────────────────
  -- Molde de test_charge_due_date.sql L106-132: se le retira su propia cuenta
  -- auto-provisionada (donde nace 'owner') y se lo suma como MEMBER de A —
  -- sin eso, current_account_ids() lo seguiría resolviendo contra su cuenta
  -- propia y el assert (4b) mediría otra cosa.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_member, 'authenticated', 'authenticated', v_email_member, now(), now(),
          jsonb_build_object('name', 'Gate C30 Movement Helpers Member'))
  ON CONFLICT (id) DO NOTHING;

  DELETE FROM public.account_members WHERE user_id = v_user_member;
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_user_member, 'member');

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_account_a, '__gate_c30mh_client_a__', 'active')
  RETURNING id INTO v_client_a;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_b, v_account_b, '__gate_c30mh_client_b__', 'active')
  RETURNING id INTO v_client_b;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_a, '__gate_c30mh_supplier_a__')
  RETURNING id INTO v_supplier_a;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_b, '__gate_c30mh_supplier_b__')
  RETURNING id INTO v_supplier_b;

  -- Cuentas corrientes propias, una por tenant y por lado — creadas directo
  -- (como postgres, fuera de la sesión sintética) para no depender del
  -- guard bajo prueba en el propio setup.
  INSERT INTO public.customer_accounts (account_id, client_id, balance)
  VALUES (v_account_a, v_client_a, 0) RETURNING id INTO v_ca_a;

  INSERT INTO public.customer_accounts (account_id, client_id, balance)
  VALUES (v_account_b, v_client_b, 0) RETURNING id INTO v_ca_b;

  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance)
  VALUES (v_account_a, v_supplier_a, 0) RETURNING id INTO v_sa_a;

  INSERT INTO public.supplier_accounts (account_id, supplier_id, balance)
  VALUES (v_account_b, v_supplier_b, 0) RETURNING id INTO v_sa_b;

  -- ── Sesión sintética del tenant A ──────────────────────────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: auth.uid() no resuelve al anchor A con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ═══════════════════════ (1) INTROSPECCIÓN ════════════════════════════════
  SELECT p.prosecdef, p.proconfig, p.prosrc INTO v_prosecdef, v_proconfig, v_prosrc
  FROM pg_proc p WHERE p.oid = v_oid_customer;

  IF NOT v_prosecdef THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-customer-definer): c30_register_customer_account_movement no es SECURITY DEFINER.';
  END IF;
  IF v_proconfig IS NULL OR NOT ('search_path=public' = ANY (v_proconfig)) THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-customer-searchpath): falta SET search_path = public.';
  END IF;
  IF position('current_account_ids' IN v_prosrc) = 0 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-customer-guard): el cuerpo no contiene el guard de membresía current_account_ids().';
  END IF;
  IF position('is_account_writer' IN v_prosrc) > 0 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-customer-guard-rol, F3): el cuerpo usa is_account_writer — eso estrecha la autorización a owner/admin y rompería la venta a crédito de un member.';
  END IF;
  IF has_function_privilege('anon', v_oid_customer, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid_customer, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-customer-acl): sigue ejecutable por anon/authenticated.';
  END IF;
  IF NOT has_function_privilege('postgres', v_oid_customer, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-customer-owner): postgres quedó sin EXECUTE.';
  END IF;

  SELECT p.prosecdef, p.proconfig, p.prosrc INTO v_prosecdef, v_proconfig, v_prosrc
  FROM pg_proc p WHERE p.oid = v_oid_supplier;

  IF NOT v_prosecdef THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-supplier-definer): c30_register_supplier_account_movement no es SECURITY DEFINER.';
  END IF;
  IF v_proconfig IS NULL OR NOT ('search_path=public' = ANY (v_proconfig)) THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-supplier-searchpath): falta SET search_path = public.';
  END IF;
  IF position('current_account_ids' IN v_prosrc) = 0 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-supplier-guard): el cuerpo no contiene el guard de membresía current_account_ids().';
  END IF;
  IF position('is_account_writer' IN v_prosrc) > 0 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-supplier-guard-rol, F3): el cuerpo usa is_account_writer — eso estrecha la autorización a owner/admin y rompería la venta a crédito de un member.';
  END IF;
  IF has_function_privilege('anon', v_oid_supplier, 'EXECUTE')
     OR has_function_privilege('authenticated', v_oid_supplier, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-supplier-acl): sigue ejecutable por anon/authenticated.';
  END IF;
  IF NOT has_function_privilege('postgres', v_oid_supplier, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (1-supplier-owner): postgres quedó sin EXECUTE.';
  END IF;

  RAISE NOTICE 'PASS (1): ambos helpers son SECURITY DEFINER con search_path fijo, el guard de membresía current_account_ids() en el cuerpo (SIN is_account_writer), y sin EXECUTE para anon/authenticated.';

  -- ═══════════════════════ (2) NEGATIVO — REVOKE ════════════════════════════
  -- Bajo el rol de aplicación, invocar CUALQUIERA de los dos helpers directo
  -- se rechaza por falta de permiso, ANTES de que el guard interno corra.
  EXECUTE 'SET LOCAL ROLE authenticated';
  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.c30_register_customer_account_movement(v_ca_b, 100, 'sale', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  EXECUTE 'RESET ROLE';

  IF NOT v_rejected OR v_sqlstate <> '42501' THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (2-customer, SEVERIDAD ALTA): c30_register_customer_account_movement debe ser inalcanzable para authenticated (42501), obtuve %. Antes del REVOKE, un usuario logueado podía escribir en la cuenta corriente de CUALQUIER cliente de CUALQUIER tenant.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.c30_register_supplier_account_movement(v_sa_b, 100, 'purchase', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  EXECUTE 'RESET ROLE';

  IF NOT v_rejected OR v_sqlstate <> '42501' THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (2-supplier, SEVERIDAD ALTA): c30_register_supplier_account_movement debe ser inalcanzable para authenticated (42501), obtuve %.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  RAISE NOTICE 'PASS (2): ninguno de los dos helpers es invocable directo por authenticated — 42501 en ambos casos, sin escribir movimiento.';

  -- ═════════════════ (3) POSITIVO DE NO-REGRESIÓN ═══════════════════════════
  -- rpc_register_supplier_charge (cargo manual, sube deuda, no necesita
  -- forma de pago ni saldo previo) para el proveedor PROPIO de A.
  SELECT COUNT(*) INTO v_nb_sup_movs FROM public.supplier_account_movements m
    JOIN public.supplier_accounts a ON a.id = m.supplier_account_id WHERE a.id = v_sa_a;

  v_result := public.rpc_register_supplier_charge(
    'gate-c30mh-charge-' || v_user_a::text, v_supplier_a, 750, gen_random_uuid());

  SELECT COUNT(*) INTO v_nb_sup_movs FROM public.supplier_account_movements m
    JOIN public.supplier_accounts a ON a.id = m.supplier_account_id WHERE a.id = v_sa_a;
  IF v_nb_sup_movs <> 1 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (3-supplier): rpc_register_supplier_charge no posteó el movimiento para el propio tenant tras el guard interno (% movimientos, esperaba 1).', v_nb_sup_movs;
  END IF;
  SELECT balance INTO v_balance_a FROM public.supplier_accounts WHERE id = v_sa_a;
  IF v_balance_a <> 750 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (3-supplier-saldo): balance esperado 750, es %.', v_balance_a;
  END IF;

  -- rpc_register_payment_received necesita deuda previa (si no, P0409): se
  -- postea con el helper directo, como A, ANTES de invocar la RPC.
  PERFORM public.c30_register_customer_account_movement(v_ca_a, 1000, 'sale', gen_random_uuid());

  v_result := public.rpc_register_payment_received(
    'gate-c30mh-payment-' || v_user_a::text, v_client_a, 400);

  IF (v_result->>'payment_id') IS NULL THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (3-customer): rpc_register_payment_received no devolvió payment_id para el propio tenant.';
  END IF;
  SELECT balance INTO v_balance_a FROM public.customer_accounts WHERE id = v_ca_a;
  IF v_balance_a <> 600 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (3-customer-saldo): balance esperado 600 (1000 - 400), es %.', v_balance_a;
  END IF;

  RAISE NOTICE 'PASS (3): rpc_register_supplier_charge y rpc_register_payment_received siguen posteando normalmente para el propio tenant — el guard interno no sobre-bloquea al camino legítimo.';

  -- ═══════════════════ (4a) GUARD INTERNO — NEGATIVO CROSS-TENANT ═══════════
  -- Como postgres (el REVOKE de (2) no interviene: el owner tiene EXECUTE
  -- implícito), con la sesión sintética de A todavía activa, invocar el
  -- helper directo sobre una cuenta del tenant B.
  SELECT COUNT(*) INTO v_nb_cust_movs FROM public.customer_account_movements m
    JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.id = v_ca_b;

  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.c30_register_customer_account_movement(v_ca_b, 100, 'sale', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;

  IF NOT v_rejected OR v_sqlstate <> 'P0401' THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (4a-customer, SEVERIDAD ALTA): c30_register_customer_account_movement debe rechazar con P0401 una CustomerAccount de otro tenant incluso corriendo como el owner de la base (sin REVOKE de por medio), obtuve %. Sin este guard, el REVOKE de (2) es la ÚNICA defensa y un CREATE OR REPLACE futuro que lo pierda reabre la escritura cross-tenant.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  SELECT COUNT(*) INTO v_nb_cust_movs FROM public.customer_account_movements m
    JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.id = v_ca_b;
  IF v_nb_cust_movs <> 0 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (4a-customer-B): el intento dejó % movimientos en la cuenta del tenant víctima, esperaba 0.', v_nb_cust_movs;
  END IF;

  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.c30_register_supplier_account_movement(v_sa_b, 100, 'purchase', NULL);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE; v_rejected := true;
  END;

  IF NOT v_rejected OR v_sqlstate <> 'P0401' THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (4a-supplier, SEVERIDAD ALTA): c30_register_supplier_account_movement debe rechazar con P0401 una SupplierAccount de otro tenant incluso corriendo como el owner de la base, obtuve %.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  SELECT COUNT(*) INTO v_nb_sup_movs FROM public.supplier_account_movements m
    JOIN public.supplier_accounts a ON a.id = m.supplier_account_id WHERE a.id = v_sa_b;
  IF v_nb_sup_movs <> 0 THEN
    RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (4a-supplier-B): el intento dejó % movimientos en la cuenta del tenant víctima, esperaba 0.', v_nb_sup_movs;
  END IF;

  RAISE NOTICE 'PASS (4a): el guard interno rechaza con P0401 una cuenta corriente de otro tenant incluso corriendo como el owner de la base, sin dejar ningún movimiento en los libros de la víctima — defensa en profundidad independiente del REVOKE.';

  -- ═══════════════ (4b) GUARD INTERNO — POSITIVO SAME-TENANT 'member' ═══════
  -- F3: el guard es de MEMBRESÍA, no de rol. Un 'member' de A (sin
  -- is_account_writer) tiene que poder postear sobre la cuenta corriente
  -- PROPIA de su tenant (v_ca_a) — si el guard hubiera quedado en
  -- is_account_writer, este mismo caso fallaría con P0401 (probado en el
  -- propio F3 con la venta a crédito real: sqlstate=P0401 con el guard
  -- viejo, éxito con el guard de membresía).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_member::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_member THEN
    RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: auth.uid() no resolvió para el anchor member — se omite (4b).';
  ELSE
    -- Baseline ANTES del intento: v_ca_a ya tiene movimientos de la sección
    -- (3) (el cargo manual de 1000 + el pago de 400 vía rpc_register_
    -- payment_received) — se compara por DELTA, no por conteo absoluto.
    SELECT COUNT(*) INTO v_nb_before FROM public.customer_account_movements m
      JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.id = v_ca_a;

    v_rejected := false; v_sqlstate := NULL;
    BEGIN
      PERFORM public.c30_register_customer_account_movement(v_ca_a, 250, 'sale', NULL);
    EXCEPTION WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
    END;

    IF v_rejected THEN
      RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (4b-customer, F3): un member de A no pudo postear en la cuenta corriente PROPIA de A (sqlstate=%) — el guard volvió a ser de ROL (is_account_writer) en vez de MEMBRESÍA (current_account_ids()); esto rompería la venta a crédito de cualquier usuario sin rol owner/admin.', v_sqlstate;
    END IF;

    SELECT COUNT(*) INTO v_nb_cust_movs FROM public.customer_account_movements m
      JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.id = v_ca_a;
    IF v_nb_cust_movs <> v_nb_before + 1 THEN
      RAISE EXCEPTION 'GATE C30-MOVEMENT-HELPERS FAILED (4b-customer-count): el member posteó % movimientos nuevos en su propio tenant (antes %, después %), esperaba exactamente 1 nuevo.', v_nb_cust_movs - v_nb_before, v_nb_before, v_nb_cust_movs;
    END IF;

    RAISE NOTICE 'PASS (4b): un member de A (sin is_account_writer) posteó normalmente en la cuenta corriente propia de A — el guard es de membresía, no de rol.';
  END IF;

  RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: TODOS LOS CHEQUEOS PASARON.';
END $$;

-- =============================================================================
-- CLEANUP — reproducible dos veces seguidas sobre la misma base.
-- =============================================================================
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users
  WHERE email IN ('c30-party-movement-helpers-a@test.local',
                  'c30-party-movement-helpers-b@test.local',
                  'c30-party-movement-helpers-member@test.local');

  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  -- F3 (4b): v_user_member fue retirado de su propia cuenta auto-provisionada
  -- — esa cuenta ya no tiene ningún account_members apuntando a v_users, así
  -- que resolver v_accounts SOLO por account_members la deja afuera de la
  -- limpieza. Se suma por owner_user_id (molde test_charge_due_date.sql).
  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM (
    SELECT account_id FROM public.account_members WHERE user_id = ANY(v_users)
    UNION
    SELECT id AS account_id FROM public.accounts WHERE owner_user_id = ANY(v_users)
  ) x;

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.payments_received        WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_made             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements m USING public.customer_accounts a
      WHERE m.customer_account_id = a.id AND a.account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements m USING public.supplier_accounts a
      WHERE m.supplier_account_id = a.id AND a.account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts         WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts         WHERE account_id = ANY(v_accounts);
    DELETE FROM public.events                    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients                   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers                 WHERE account_id = ANY(v_accounts);
    -- Orfandad de la cuenta auto-provisionada del member (sin clients/
    -- suppliers propios, pero con lo que la provisión de cuenta nueva siembra).
    DELETE FROM public.payment_methods           WHERE account_id = ANY(v_accounts);
    DELETE FROM public.product_categories        WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches                  WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches
  -- (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe
  -- TODO borrado físico de una sucursal (P0428) — bypass explícito para el
  -- cleanup del fixture sintético, sólo alcanzable por un rol con privilegio
  -- de superusuario (postgres en CI).
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  DELETE FROM public.email_logs
   WHERE user_id = ANY(v_users)
      OR recipient IN ('c30-party-movement-helpers-a@test.local',
                       'c30-party-movement-helpers-b@test.local',
                       'c30-party-movement-helpers-member@test.local');
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE C30-MOVEMENT-HELPERS: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
