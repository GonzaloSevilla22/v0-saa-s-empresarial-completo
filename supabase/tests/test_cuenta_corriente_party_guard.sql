-- =============================================================================
-- GATE: test_cuenta_corriente_party_guard.sql
-- CHANGE: cuenta-corriente-party-guard (tasks 2.1-2.7, 3.5-3.8, 4.1-4.3,
--         4.5-4.7, 5.1-5.2, 5.5-5.6, 9 — RED + GREEN + TRIANGULATE)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_delete_guard_ledgers.sql y test_pagos_cableados_restantes.sql) el
-- guard de tenencia de la parte (cliente/proveedor) y el cierre de la
-- primitiva de escritura cross-tenant:
--
--   FAMILIA 1 — incoherencia (cuenta, parte). Las RPCs de cuenta corriente
--   resolvían el tenant de la sesión pero NUNCA validaban que el
--   cliente/proveedor recibido por parámetro perteneciera a ese tenant. El
--   FK `client_id REFERENCES clients(id)` no está scopeado por tenant, así
--   que la fila entraba: el tenant A terminaba con saldo, cobros y partida
--   doble contra una entidad que jamás iba a ver en sus listas.
--     (2.2) rpc_register_payment_received  + cliente ajeno  → P0404
--     (2.3) rpc_register_payment_made      + proveedor ajeno → P0404
--     (2.4) rpc_register_supplier_charge   + proveedor ajeno → P0404
--     En las tres NO alcanza con el SQLSTATE: se compara el conteo de
--     movimientos, cobros/pagos y eventos antes y después, porque los specs
--     piden "sin efectos parciales", no sólo "falla".
--     (2.5) rpc_create_sale_operation_v2 (FORMULARIO) a crédito + cliente
--           ajeno → P0404 y CERO filas nuevas en sales / sale_items /
--           customer_accounts / customer_account_movements / stock_movements
--           / events. Cubierto por el choke point, SIN tocar la RPC de venta.
--     (2.6) rpc_quick_sale (POS) a crédito + cliente ajeno → P0404 y ninguna
--           sales_order confirmada. Mismo choke point.
--     (2.5/2.6-B) los libros del TENANT VÍCTIMA quedan sin cambios: cuentas
--           corrientes, movimientos y eventos de B contados antes y después.
--
--   FAMILIA 2 — primitiva de escritura cross-tenant (lo más grave). Dos
--   helpers SECURITY DEFINER que reciben el account_id COMO PARÁMETRO —sin
--   resolverlo de la sesión ni validar is_account_writer— tenían
--   GRANT EXECUTE TO authenticated, o sea que eran invocables por PostgREST
--   con el account_id de OTRO tenant:
--     (5.1) _pay_register_party_charge  bajo SET LOCAL ROLE authenticated → 42501
--     (5.2) _journal_post_from_event    bajo SET LOCAL ROLE authenticated → 42501
--   `_journal_post_from_event` nació con REVOKE (20260803000001 L517) y lo
--   PERDIÓ en 20261001000001 L1914, donde el "patrón uniforme" REVOKE+GRANT
--   se lo aplicó en piloto automático a un helper que nunca lo tuvo.
--
--   TRIANGULACIÓN (el guard no sobre-bloquea ni se cuela por otro lado):
--     (3.5) control positivo — cliente/proveedor PROPIOS sin cuenta corriente
--           previa: la cuenta se crea en el mismo commit y balance_after es
--           el esperado, por los cinco caminos (venta a crédito, cobro, cargo
--           a proveedor virgen, cargo a proveedor con cuenta, pago a
--           proveedor). Sin este assert el guard podría estar rechazando
--           todo. No alcanza con el saldo: los specs dicen que la operación
--           "se registra con su movimiento, su fila de cobro y su evento", así
--           que 3.5a cuenta el evento CustomerAccountCharged y 3.5b cuenta la
--           fila de payments_received Y el evento PaymentReceived.
--           Ojo con el proveedor: 3.5c usa v_supplier_a2, que llega VIRGEN,
--           porque v_supplier_a ya tiene cuenta corriente desde 2.3 y con él
--           "se crea en el mismo commit" no se ejercita nunca.
--     (3.6) identificador INEXISTENTE → mismo P0404 y MISMO texto de mensaje
--           que el caso "ajeno" — el error no distingue uno de otro (no
--           filtrar información entre tenants). 3.6 cubre el lado cliente;
--           3.6b y 3.6c el lado proveedor (pago y cargo manual), que tienen
--           su propio escenario en el spec de supplier-account.
--     (3.7) rpc_create_customer_account / rpc_create_supplier_account —que ya
--           validaban desde C-30— siguen comportándose igual con el guard
--           ahora duplicado en el choke point. Redundancia deliberada.
--     (4.6) ORDEN de los guards: cliente ajeno + amount = 0 → P0400, no
--           P0404. Congela la ubicación documentada en D2. 4.6b y 4.6c son el
--           espejo del lado PROVEEDOR (pago y cargo manual): el escenario
--           "Las validaciones de payload preceden al guard de parte" del spec
--           de supplier-account habla de "un pago o un cargo manual", así que
--           el orden tiene que estar congelado también ahí.
--     (4.7) cobro por transferencia + cliente ajeno → P0404 y CERO filas en
--           bank_movements; y con bank_account inexistente → P0412 (el
--           bloque bancario corre ANTES del guard de parte, D2). 4.7c es el
--           espejo en rpc_register_payment_made. Sólo el PAGO tiene espejo
--           bancario: rpc_register_supplier_charge no recibe cuenta bancaria.
--     (4.5) la clave de idempotencia NO se quema en el rechazo: reintentar
--           la misma clave con un cliente válido registra de verdad
--           (replayed = false).
--     (4.1-4.3) CANDADO DE CUERPO. Todos los asserts de comportamiento de
--           arriba pasan IGUAL con las 3 RPCs revertidas a su cuerpo
--           pre-guard, porque el choke point levanta el mismo P0404
--           (verificado empíricamente: baseline aplicado en una transacción
--           → el proveedor ajeno sigue dando P0404). O sea que la capa 2 de
--           D1 —el guard explícito— podía borrarse sin que nada fallara. Se
--           cierra con pg_get_functiondef: el literal del guard existe, y su
--           posición cae DESPUÉS del último guard de payload y ANTES del
--           INSERT de idempotencia (que es exactamente D2).
--     (5.5) control positivo del revoke — venta a crédito por FORMULARIO y
--           por POS sigue posteando su cargo. Prueba que el PERFORM interno
--           corre como definer y el revoke es transparente.
--     (5.6) rpc_process_outbox_dispatch sigue posteando un asiento que
--           BALANCEA tras el revoke de _journal_post_from_event.
--     (9)   BARRIDO GLOBAL del invariante que los specs declaran a nivel
--           TABLA: cero customer_accounts / supplier_accounts cuya parte
--           pertenezca a otro tenant, en toda la base — no sólo en los
--           caminos que este gate ejercita.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
--
-- Cleanup: el archivo termina con un DO block que borra los dos tenants
-- sintéticos y todo lo que colgaba de ellos, INCLUIDOS los dos residuos que
-- no cuelgan por account_id ni por user_id del anchor y que por eso se
-- escapaban: las claves `event_consumer` que escribe el dispatcher del outbox
-- en 5.6 (user_id sentinela, event_id sin FK → 21 huérfanas por corrida) y
-- las filas de `email_logs` de los emails sintéticos (FK ON DELETE SET NULL →
-- 4 filas por corrida con user_id NULL). Sin eso la SEGUNDA corrida
-- sobre la misma base aborta con `users_email_partial_key` (los anchors usan
-- un email fijo y un id nuevo, así que el ON CONFLICT (id) no los cubre) —
-- reproducido en local. Verificado: el gate corre VERDE dos veces seguidas.
-- =============================================================================

DO $$
DECLARE
  -- ── Tenant A (el que opera) ───────────────────────────────────────────────
  v_anchor_a_email    text := 'cuenta-corriente-party-guard-a@test.local';
  v_user_a            uuid := gen_random_uuid();
  v_account_a         uuid;
  v_branch_a          uuid;
  v_product_a         uuid;
  v_bank_a            uuid;
  v_pm_credit         uuid;
  v_pm_cash           uuid;
  v_pm_transfer       uuid;
  v_client_a          uuid;   -- cliente propio "de trabajo"
  v_client_a2         uuid;   -- cliente propio FRESCO (control positivo 3.5a)
  v_supplier_a        uuid;   -- proveedor propio DE TRABAJO: 2.3 le crea la
                              -- cuenta corriente con 5000, así que en 3.5d ya
                              -- NO es fresco (por eso espera 5700, no 700).
  v_supplier_a2       uuid;   -- proveedor propio FRESCO de verdad (3.5c)

  -- ── Tenant B (la víctima: sus ids se usan desde la sesión de A) ───────────
  v_anchor_b_email    text := 'cuenta-corriente-party-guard-b@test.local';
  v_user_b            uuid := gen_random_uuid();
  v_account_b         uuid;
  v_client_b          uuid;
  v_supplier_b        uuid;

  -- ── Scratch ───────────────────────────────────────────────────────────────
  v_ghost             uuid := gen_random_uuid();   -- id que no existe en ningún tenant
  v_rejected          boolean;
  v_sqlstate          text;
  v_msg_foreign       text;   -- SQLERRM de "cliente ajeno"      (2.2)
  v_msg_ghost         text;   -- SQLERRM de "cliente inexistente" (3.6)
  v_msg_foreign_sup   text;   -- SQLERRM de "proveedor ajeno" en payment_made      (2.3)
  v_msg_ghost_sup     text;   -- SQLERRM de "proveedor inexistente" en payment_made (3.6b)
  v_msg_foreign_chg   text;   -- SQLERRM de "proveedor ajeno" en supplier_charge      (2.4)
  v_msg_ghost_chg     text;   -- SQLERRM de "proveedor inexistente" en supplier_charge (3.6c)
  v_def               text;   -- pg_get_functiondef, candados de cuerpo (4.1-4.3)
  v_pos_guard         integer;
  v_pos_prev          integer;
  v_pos_idem          integer;
  v_result            jsonb;
  v_count             integer;
  v_balance           numeric;
  v_ca_id             uuid;
  v_sa_id             uuid;
  v_op_id             uuid;
  v_so_id             uuid;
  v_event_id          uuid;
  v_event_row         public.events;
  v_entry_id          uuid;
  v_debit             numeric;
  v_credit            numeric;
  v_processed         integer;

  -- Conteos previos para el assert de "cero filas nuevas" (2.5)
  v_n_sales           integer;
  v_n_sale_items      integer;
  v_n_cust_accounts   integer;
  v_n_cust_movs       integer;
  v_n_stock_movs      integer;
  v_n_events          integer;
  v_n_bank_movs       integer;
  v_n_sup_accounts    integer;
  v_n_sup_movs        integer;
  v_n_pay_recv        integer;
  v_n_pay_made        integer;
  v_n_ev_charged      integer;
  v_n_ev_payrecv      integer;

  -- Libros del tenant B (la víctima): los specs dicen "los libros de B
  -- quedan sin cambios" y eso hay que medirlo, no suponerlo.
  v_nb_cust_accounts  integer;
  v_nb_cust_movs      integer;
  v_nb_events         integer;
  v_nb_journal        integer;
BEGIN
  -- ── Anchor sintético del tenant A ─────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_anchor_a_email, now(), now(),
          jsonb_build_object('name', 'Gate Party Guard A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE PARTY-GUARD: no se pudo resolver cuenta para el anchor sintético A — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Anchor sintético del tenant B (SEGUNDO tenant, la clave de este gate) ─
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_anchor_b_email, now(), now(),
          jsonb_build_object('name', 'Gate Party Guard B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_b IS NULL OR v_account_b = v_account_a THEN
    RAISE NOTICE 'GATE PARTY-GUARD: no se pudo provisionar un SEGUNDO tenant independiente para el anchor B — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a    FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_credit   FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'credit'   LIMIT 1;
  SELECT id INTO v_pm_cash     FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash'     LIMIT 1;
  SELECT id INTO v_pm_transfer FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' LIMIT 1;

  IF v_branch_a IS NULL OR v_pm_credit IS NULL OR v_pm_cash IS NULL OR v_pm_transfer IS NULL THEN
    RAISE NOTICE 'GATE PARTY-GUARD: branch/catálogo de formas de pago no disponible para el anchor A — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_ccpg_product__', 1000, 400, 'GATE-CCPG-1')
  RETURNING id INTO v_product_a;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a, v_product_a, 1000)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 1000;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_ccpg_bank__', 'ARS', 0)
  RETURNING id INTO v_bank_a;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_account_a, '__gate_ccpg_client_a__', 'active')
  RETURNING id INTO v_client_a;

  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_a, v_account_a, '__gate_ccpg_client_a2__', 'active')
  RETURNING id INTO v_client_a2;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_a, '__gate_ccpg_supplier_a__')
  RETURNING id INTO v_supplier_a;

  -- Proveedor propio que NO va a tener cuenta corriente hasta 3.5c: es el
  -- único control positivo honesto de "la cuenta se crea en el mismo commit"
  -- del lado proveedor (v_supplier_a ya la tiene desde 2.3).
  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_a, '__gate_ccpg_supplier_a2__')
  RETURNING id INTO v_supplier_a2;

  -- Parte del tenant B: existe, es válida, pero NO pertenece a la cuenta A.
  INSERT INTO public.clients (user_id, account_id, name, status)
  VALUES (v_user_b, v_account_b, '__gate_ccpg_client_b__', 'active')
  RETURNING id INTO v_client_b;

  INSERT INTO public.suppliers (account_id, name)
  VALUES (v_account_b, '__gate_ccpg_supplier_b__')
  RETURNING id INTO v_supplier_b;

  -- ── Sesión sintética del tenant A (request.jwt.claims) ────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE PARTY-GUARD: auth.uid() no resuelve al anchor A con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ═══════════ (2.2) rpc_register_payment_received + cliente ajeno ══════════
  -- Precondición imprescindible: el cargo tiene que existir primero, si no el
  -- cobro fallaría por saldo negativo (P0409) y el rojo no probaría nada.
  -- Se postea en la cuenta corriente de A contra un cliente PROPIO, para que
  -- el único factor bajo prueba sea el client_id ajeno del cobro.
  v_ca_id := public.c30_get_or_create_customer_account(v_account_a, v_client_a);
  PERFORM public.c30_register_customer_account_movement(v_ca_id, 5000, 'sale', gen_random_uuid());

  -- El spec no pide sólo el P0404: pide que NO quede movimiento, ni cobro,
  -- ni evento en el outbox. Se mide antes y después (mismo patrón que 2.5).
  SELECT COUNT(*) INTO v_n_cust_movs FROM public.customer_account_movements WHERE customer_account_id = v_ca_id;
  SELECT COUNT(*) INTO v_n_pay_recv  FROM public.payments_received          WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_events    FROM public.events                     WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-2-2',
      p_client_id       => v_client_b,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_foreign := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2): rpc_register_payment_received con un client_id de OTRO tenant debería fallar con P0404. Hoy tiene éxito y crea una fila en customer_accounts con account_id=A y client_id de B.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.customer_accounts
  WHERE account_id = v_account_a AND client_id = v_client_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2-fila): el rechazo no debe dejar una customer_account con la parte ajena, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE customer_account_id = v_ca_id;
  IF v_count <> v_n_cust_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2-movimiento): el rechazo dejó % movimientos en la cuenta corriente propia, esperaba %.', v_count, v_n_cust_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.payments_received WHERE account_id = v_account_a;
  IF v_count <> v_n_pay_recv THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2-cobro): el rechazo dejó % filas en payments_received, esperaba %.', v_count, v_n_pay_recv;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_n_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.2-evento): el rechazo dejó % eventos, esperaba % — no debe emitirse ningún evento de cobro.', v_count, v_n_events;
  END IF;
  RAISE NOTICE 'PASS (2.2): rpc_register_payment_received rechaza el cliente de otro tenant con P0404, sin cuenta corriente, sin movimiento, sin cobro y sin evento.';

  -- ═══════════ (2.3) rpc_register_payment_made + proveedor ajeno ════════════
  v_sa_id := public.c30_get_or_create_supplier_account(v_account_a, v_supplier_a);
  PERFORM public.c30_register_supplier_account_movement(v_sa_id, 5000, 'purchase', gen_random_uuid());

  SELECT COUNT(*) INTO v_n_sup_movs FROM public.supplier_account_movements WHERE supplier_account_id = v_sa_id;
  SELECT COUNT(*) INTO v_n_pay_made FROM public.payments_made              WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_events   FROM public.events                     WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccpg-2-3',
      p_supplier_id     => v_supplier_b,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      -- El SQLERRM se guarda para 3.6b: "ajeno" e "inexistente" tienen que
      -- ser indistinguibles también del lado proveedor.
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_foreign_sup := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3): rpc_register_payment_made con un supplier_id de OTRO tenant debería fallar con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.supplier_accounts
  WHERE account_id = v_account_a AND supplier_id = v_supplier_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3-fila): el rechazo no debe dejar una supplier_account con la parte ajena, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.supplier_account_movements WHERE supplier_account_id = v_sa_id;
  IF v_count <> v_n_sup_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3-movimiento): el rechazo dejó % movimientos, esperaba %.', v_count, v_n_sup_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.payments_made WHERE account_id = v_account_a;
  IF v_count <> v_n_pay_made THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3-pago): el rechazo dejó % filas en payments_made, esperaba %.', v_count, v_n_pay_made;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_n_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.3-evento): el rechazo dejó % eventos, esperaba %.', v_count, v_n_events;
  END IF;
  RAISE NOTICE 'PASS (2.3): rpc_register_payment_made rechaza el proveedor de otro tenant con P0404, sin cuenta, sin movimiento, sin pago y sin evento.';

  -- ═══════════ (2.4) rpc_register_supplier_charge + proveedor ajeno ═════════
  SELECT COUNT(*) INTO v_n_sup_accounts FROM public.supplier_accounts           WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_sup_movs     FROM public.supplier_account_movements  WHERE supplier_account_id = v_sa_id;
  SELECT COUNT(*) INTO v_n_events       FROM public.events                      WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_supplier_charge(
      p_idempotency_key => 'gate-ccpg-2-4',
      p_supplier_id     => v_supplier_b,
      p_amount          => 250
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_foreign_chg := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.4): rpc_register_supplier_charge con un supplier_id de OTRO tenant debería fallar con P0404.';
  END IF;

  -- El spec de supplier-account dice "no se crea ni la cuenta corriente ni el
  -- movimiento ni el evento de cargo": las tres cosas se miden.
  SELECT COUNT(*) INTO v_count FROM public.supplier_accounts WHERE account_id = v_account_a AND supplier_id = v_supplier_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.4-fila): el rechazo dejó % supplier_accounts con la parte ajena, esperaba 0.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.supplier_accounts WHERE account_id = v_account_a;
  IF v_count <> v_n_sup_accounts THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.4-cuentas): el rechazo dejó % supplier_accounts en total, esperaba %.', v_count, v_n_sup_accounts;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.supplier_account_movements WHERE supplier_account_id = v_sa_id;
  IF v_count <> v_n_sup_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.4-movimiento): el rechazo dejó % movimientos, esperaba %.', v_count, v_n_sup_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_n_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.4-evento): el rechazo dejó % eventos, esperaba % — no debe emitirse SupplierAccountCharged.', v_count, v_n_events;
  END IF;
  RAISE NOTICE 'PASS (2.4): rpc_register_supplier_charge rechaza el proveedor de otro tenant con P0404, sin cuenta, sin movimiento y sin evento.';

  -- ════ (2.5) FORMULARIO — venta a crédito con cliente ajeno (choke point) ══
  -- El camino de más volumen: rpc_create_sale_operation_v2 NO valida la parte
  -- (no hay una sola ocurrencia de `FROM public.clients` en su migración).
  -- Lo cubre el guard del choke point c30_get_or_create_customer_account, sin
  -- tocar una línea de la RPC de venta (ver 3.8).
  -- Libros del TENANT B: el spec dice "los libros de B quedan sin cambios" y
  -- eso no se mide en ningún lado. Se mide acá y se compara tras 2.6.
  SELECT COUNT(*) INTO v_nb_cust_accounts FROM public.customer_accounts WHERE account_id = v_account_b;
  SELECT COUNT(*) INTO v_nb_cust_movs     FROM public.customer_account_movements m
    JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.account_id = v_account_b;
  SELECT COUNT(*) INTO v_nb_events        FROM public.events WHERE account_id = v_account_b;

  SELECT COUNT(*) INTO v_n_sales         FROM public.sales                       WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_sale_items    FROM public.sale_items                  WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_cust_accounts FROM public.customer_accounts           WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_cust_movs     FROM public.customer_account_movements  WHERE customer_account_id = v_ca_id;
  SELECT COUNT(*) INTO v_n_stock_movs    FROM public.stock_movements             WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_events        FROM public.events                      WHERE account_id = v_account_a;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_sale_operation_v2(
      p_idempotency_key   => 'gate-ccpg-2-5',
      p_client_id         => v_client_b,
      p_date              => public.reporting_local_today(),
      p_currency          => 'ARS',
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
      p_branch_id         => v_branch_a,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5, ESTRELLA): una venta a crédito del FORMULARIO con un cliente de OTRO tenant debería fallar con P0404 — es el camino de más volumen y hoy postea el cargo sin preguntar nada.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales WHERE account_id = v_account_a;
  IF v_count <> v_n_sales THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-sales): el rechazo dejó % filas en sales, esperaba % (sin cambios).', v_count, v_n_sales;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.sale_items WHERE account_id = v_account_a;
  IF v_count <> v_n_sale_items THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-sale_items): el rechazo dejó % filas en sale_items, esperaba %.', v_count, v_n_sale_items;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_accounts WHERE account_id = v_account_a;
  IF v_count <> v_n_cust_accounts THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-customer_accounts): el rechazo dejó % cuentas corrientes, esperaba %.', v_count, v_n_cust_accounts;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements WHERE customer_account_id = v_ca_id;
  IF v_count <> v_n_cust_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-movimientos): el rechazo dejó % movimientos, esperaba %.', v_count, v_n_cust_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.stock_movements WHERE account_id = v_account_a;
  IF v_count <> v_n_stock_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-stock): el rechazo dejó % movimientos de stock, esperaba % — el descuento de kardex no debe sobrevivir al rechazo.', v_count, v_n_stock_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_n_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5-events): el rechazo dejó % eventos, esperaba % — ningún evento debe llegar al outbox.', v_count, v_n_events;
  END IF;
  RAISE NOTICE 'PASS (2.5, ESTRELLA): venta a crédito del formulario con cliente ajeno → P0404 y cero filas nuevas en los 6 libros.';

  -- ════════ (2.6) POS — quick sale a crédito con cliente ajeno ══════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key   => 'gate-ccpg-2-6',
      p_client_id         => v_client_b,
      p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'credit',
      p_branch_id         => v_branch_a,
      p_payment_method_id => v_pm_credit
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.6, ESTRELLA): una venta a crédito del POS con un cliente de OTRO tenant debería fallar con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.sales_orders WHERE client_id = v_client_b;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.6-orden): el rechazo dejó % sales_orders contra el cliente ajeno, esperaba 0.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2.6, ESTRELLA): venta a crédito del POS con cliente ajeno → P0404 y ninguna orden confirmada.';

  -- ══ (2.5/2.6-B) los libros del TENANT B quedan intactos ═══════════════════
  SELECT COUNT(*) INTO v_count FROM public.customer_accounts WHERE account_id = v_account_b;
  IF v_count <> v_nb_cust_accounts THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5/2.6-B-cuentas): los intentos cross-tenant dejaron % customer_accounts en el tenant víctima, esperaba %.', v_count, v_nb_cust_accounts;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements m
    JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.account_id = v_account_b;
  IF v_count <> v_nb_cust_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5/2.6-B-movimientos): los libros de B tienen % movimientos, esperaba %.', v_count, v_nb_cust_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_b;
  IF v_count <> v_nb_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (2.5/2.6-B-eventos): el tenant víctima tiene % eventos, esperaba % — no debe recibir ningún evento originado por A.', v_count, v_nb_events;
  END IF;
  RAISE NOTICE 'PASS (2.5/2.6-B): los libros del tenant víctima quedan sin cambios — ni cuenta, ni movimiento, ni evento.';

  -- ═══════════════════ (3.8) el choke point es lo que cubre ═════════════════
  -- Esto era un NOTICE incondicional: decía "PASS" aunque alguien agregara un
  -- guard propio dentro de la RPC de venta y el choke point dejara de ser
  -- quien cubre. Ahora es un assert de verdad sobre el cuerpo VIVO: si
  -- aparece una lectura de `clients` en el camino de venta, 2.5/2.6 podrían
  -- seguir verdes por el motivo equivocado y nadie se enteraría.
  v_def := pg_get_functiondef('public.rpc_create_sale_operation_v2(text, uuid, date, text, jsonb, uuid, text, uuid, uuid, uuid)'::regprocedure);
  IF position('FROM public.clients' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.8-v2): el choke point dejó de ser quien cubre — alguien agregó un guard propio (lectura de public.clients) dentro de rpc_create_sale_operation_v2. Revisar 3.8 y la decisión D1: 2.5 puede estar verde por el motivo equivocado.';
  END IF;
  v_def := pg_get_functiondef('public._c29_confirm_order_core(text, uuid, text, uuid, text, uuid, text, uuid, uuid)'::regprocedure);
  IF position('FROM public.clients' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.8-core): el choke point dejó de ser quien cubre — alguien agregó un guard propio (lectura de public.clients) dentro de _c29_confirm_order_core. Revisar 3.8 y la decisión D1: 2.6 puede estar verde por el motivo equivocado.';
  END IF;
  RAISE NOTICE 'PASS (3.8): 2.5 y 2.6 pasan SIN una sola lectura de public.clients en rpc_create_sale_operation_v2 ni en _c29_confirm_order_core — el guard del choke point c30_get_or_create_customer_account cubre todo caller, presente y futuro.';

  -- ════════════ (3.5) CONTROL POSITIVO — la parte PROPIA sigue andando ══════
  -- (3.5a) venta a crédito con cliente propio FRESCO (sin cuenta corriente
  --        previa): la cuenta se crea en el mismo commit.
  SELECT COUNT(*) INTO v_n_ev_charged FROM public.events
   WHERE account_id = v_account_a AND event_type = 'CustomerAccountCharged';

  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-ccpg-3-5a',
    p_client_id         => v_client_a2,
    p_date              => public.reporting_local_today(),
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 1000, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;

  SELECT id, balance INTO v_ca_id, v_balance
  FROM public.customer_accounts WHERE account_id = v_account_a AND client_id = v_client_a2;
  IF v_ca_id IS NULL OR v_balance <> 1000 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5a): con cliente PROPIO sin cuenta previa esperaba cuenta creada con balance 1000, obtuve id=% balance=% — el guard estaría rechazando de más.', v_ca_id, v_balance;
  END IF;

  -- El spec pide "y su evento": el camino feliz tiene que EMITIR, no sólo no fallar.
  SELECT COUNT(*) INTO v_count FROM public.events
   WHERE account_id = v_account_a AND event_type = 'CustomerAccountCharged';
  IF v_count <> v_n_ev_charged + 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5a-evento): la venta a crédito con cliente propio debe emitir exactamente 1 CustomerAccountCharged; hay % y esperaba %.', v_count, v_n_ev_charged + 1;
  END IF;

  -- (3.5b) cobro parcial sobre esa cuenta recién creada → balance_after 600.
  --        El spec de customer-account no promete sólo el saldo: dice que el
  --        cobro "se registra con su movimiento, su fila de cobro y su
  --        evento". El balance_after prueba el movimiento; la fila de
  --        payments_received y el evento PaymentReceived hay que contarlos
  --        (mismo patrón que 3.5a con CustomerAccountCharged).
  SELECT COUNT(*) INTO v_n_pay_recv FROM public.payments_received
   WHERE account_id = v_account_a;
  SELECT COUNT(*) INTO v_n_ev_payrecv FROM public.events
   WHERE account_id = v_account_a AND event_type = 'PaymentReceived';

  SELECT public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccpg-3-5b',
    p_client_id       => v_client_a2,
    p_amount          => 400
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 600 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5b): balance_after esperado 600 tras cobrar 400 sobre 1000, es %.', v_result->>'balance_after';
  END IF;
  IF (v_result->>'replayed')::boolean THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5b-replay): el cobro con clave nueva no debería devolver replayed = true.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.payments_received
   WHERE account_id = v_account_a;
  IF v_count <> v_n_pay_recv + 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5b-cobro): el cobro con cliente propio debe dejar exactamente 1 fila nueva en payments_received; hay % y esperaba %.', v_count, v_n_pay_recv + 1;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.events
   WHERE account_id = v_account_a AND event_type = 'PaymentReceived';
  IF v_count <> v_n_ev_payrecv + 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5b-evento): el cobro con cliente propio debe emitir exactamente 1 PaymentReceived; hay % y esperaba %.', v_count, v_n_ev_payrecv + 1;
  END IF;

  -- (3.5c) cargo de proveedor PROPIO FRESCO — el espejo real de 3.5a del lado
  --        proveedor. v_supplier_a NO sirve para esto: 2.3 ya le creó la
  --        cuenta corriente con 5000, así que con él "la cuenta se crea en el
  --        mismo commit" nunca se ejercita. Se usa v_supplier_a2, virgen.
  SELECT COUNT(*) INTO v_count FROM public.supplier_accounts
   WHERE account_id = v_account_a AND supplier_id = v_supplier_a2;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5c-precondición): v_supplier_a2 debía llegar SIN cuenta corriente para que el control positivo pruebe la creación; hay % filas.', v_count;
  END IF;

  SELECT public.rpc_register_supplier_charge(
    p_idempotency_key => 'gate-ccpg-3-5c',
    p_supplier_id     => v_supplier_a2,
    p_amount          => 700
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 700 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5c): con proveedor PROPIO sin cuenta previa, balance_after esperado 700, es %.', v_result->>'balance_after';
  END IF;
  SELECT COUNT(*), MAX(balance) INTO v_count, v_balance FROM public.supplier_accounts
   WHERE account_id = v_account_a AND supplier_id = v_supplier_a2;
  IF v_count <> 1 OR v_balance <> 700 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5c-fila): esperaba 1 supplier_account creada en el mismo commit con balance 700, hay % filas con balance %.', v_count, v_balance;
  END IF;

  -- (3.5d) cargo sobre el proveedor que YA tenía cuenta (5000 desde 2.3) → 5700
  SELECT public.rpc_register_supplier_charge(
    p_idempotency_key => 'gate-ccpg-3-5d',
    p_supplier_id     => v_supplier_a,
    p_amount          => 700
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 5700 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5d): balance_after esperado 5700 (5000 previos + 700), es %.', v_result->>'balance_after';
  END IF;

  -- (3.5e) pago a ese proveedor → balance_after 5400
  SELECT public.rpc_register_payment_made(
    p_idempotency_key => 'gate-ccpg-3-5e',
    p_supplier_id     => v_supplier_a,
    p_amount          => 300
  ) INTO v_result;
  IF (v_result->>'balance_after')::numeric <> 5400 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.5e): balance_after esperado 5400 tras pagar 300 sobre 5700, es %.', v_result->>'balance_after';
  END IF;
  RAISE NOTICE 'PASS (3.5): control positivo — cliente y proveedor PROPIOS funcionan por los 5 caminos; la cuenta corriente se crea en el mismo commit tanto del lado cliente (3.5a) como del lado proveedor (3.5c, con un proveedor virgen), y los balance_after son los esperados.';

  -- ═══ (3.6) id INEXISTENTE → mismo P0404 y MISMO texto que el caso ajeno ═══
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-3-6',
      p_client_id       => v_ghost,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_ghost := SQLERRM; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6): un client_id inexistente debería fallar con P0404.';
  END IF;

  -- El mensaje sólo puede diferir en el UUID interpolado: si el texto que
  -- rodea al id no fuese idéntico, el error distinguiría "ajeno" de
  -- "inexistente" y filtraría la existencia de entidades de otros tenants.
  IF replace(v_msg_ghost, v_ghost::text, '<id>') IS DISTINCT FROM replace(v_msg_foreign, v_client_b::text, '<id>') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6-mensaje): el error de "cliente ajeno" (%) y el de "cliente inexistente" (%) deben ser indistinguibles salvo por el UUID — si no, se filtra qué ids existen en otros tenants.', v_msg_foreign, v_msg_ghost;
  END IF;
  RAISE NOTICE 'PASS (3.6): id ajeno e id inexistente producen el MISMO P0404 con el MISMO texto — el error no filtra información entre tenants.';

  -- (3.6b) espejo del lado PROVEEDOR en rpc_register_payment_made. El spec de
  -- supplier-account tiene su propio escenario "un proveedor inexistente se
  -- rechaza igual que uno ajeno" y 3.6 sólo cubría el lado cliente.
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccpg-3-6b',
      p_supplier_id     => v_ghost,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_ghost_sup := SQLERRM; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6b): un supplier_id inexistente debería fallar con P0404 en rpc_register_payment_made.';
  END IF;
  IF replace(v_msg_ghost_sup, v_ghost::text, '<id>') IS DISTINCT FROM replace(v_msg_foreign_sup, v_supplier_b::text, '<id>') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6b-mensaje): el error de "proveedor ajeno" (%) y el de "proveedor inexistente" (%) deben ser indistinguibles salvo por el UUID.', v_msg_foreign_sup, v_msg_ghost_sup;
  END IF;

  -- (3.6c) espejo en rpc_register_supplier_charge — es la otra RPC que el
  -- spec de supplier-account nombra (cargo manual).
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_supplier_charge(
      p_idempotency_key => 'gate-ccpg-3-6c',
      p_supplier_id     => v_ghost,
      p_amount          => 250
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; v_msg_ghost_chg := SQLERRM; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6c): un supplier_id inexistente debería fallar con P0404 en rpc_register_supplier_charge.';
  END IF;
  IF replace(v_msg_ghost_chg, v_ghost::text, '<id>') IS DISTINCT FROM replace(v_msg_foreign_chg, v_supplier_b::text, '<id>') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.6c-mensaje): en rpc_register_supplier_charge, "proveedor ajeno" (%) e "inexistente" (%) deben ser indistinguibles salvo por el UUID.', v_msg_foreign_chg, v_msg_ghost_chg;
  END IF;
  RAISE NOTICE 'PASS (3.6b + 3.6c): del lado PROVEEDOR el id ajeno y el inexistente también producen el mismo P0404 con el mismo texto, por las dos RPCs (pago y cargo manual).';

  -- ═════ (3.7) rpc_create_*_account —que ya validaban— sin regresión ════════
  SELECT public.rpc_create_customer_account(p_client_id => v_client_a) INTO v_result;
  IF (v_result->>'customer_account_id') IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7a): rpc_create_customer_account con cliente propio debería devolver customer_account_id.';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_customer_account(p_client_id => v_client_b);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7b): rpc_create_customer_account con cliente ajeno debería seguir fallando con P0404 (ya validaba desde C-30).';
  END IF;

  SELECT public.rpc_create_supplier_account(p_supplier_id => v_supplier_a) INTO v_result;
  IF (v_result->>'supplier_account_id') IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7c): rpc_create_supplier_account con proveedor propio debería devolver supplier_account_id.';
  END IF;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_supplier_account(p_supplier_id => v_supplier_b);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (3.7d): rpc_create_supplier_account con proveedor ajeno debería seguir fallando con P0404.';
  END IF;
  RAISE NOTICE 'PASS (3.7): rpc_create_customer_account / rpc_create_supplier_account se comportan igual con el guard ahora duplicado en el choke point — redundancia deliberada, no regresión.';

  -- ═══ (4.6) ORDEN de los guards: payload primero (P0400), parte después ════
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-6',
      p_client_id       => v_client_b,
      p_amount          => 0
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0400' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.6): cliente ajeno + amount = 0 debe fallar con P0400 (validación de payload PRIMERO), falló con % — el guard de parte quedó mal ubicado respecto de D2.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  -- (4.6b/4.6c) ESPEJO DEL LADO PROVEEDOR. El escenario "Las validaciones de
  -- payload preceden al guard de parte" del spec de supplier-account habla de
  -- "un pago o un cargo manual" con proveedor ajeno: sin estos dos asserts el
  -- orden estaba congelado sólo del lado cliente y las dos RPCs de proveedor
  -- podían invertirlo (P0404 antes que P0400) sin que nada fallara.
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccpg-4-6b',
      p_supplier_id     => v_supplier_b,
      p_amount          => 0
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0400' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.6b): en rpc_register_payment_made, proveedor ajeno + amount = 0 debe fallar con P0400 (validación de payload PRIMERO), falló con % — el guard de parte quedó mal ubicado respecto de D2.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_supplier_charge(
      p_idempotency_key => 'gate-ccpg-4-6c',
      p_supplier_id     => v_supplier_b,
      p_amount          => 0
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0400' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.6c): en rpc_register_supplier_charge, proveedor ajeno + amount = 0 debe fallar con P0400 (validación de payload PRIMERO), falló con % — el guard de parte quedó mal ubicado respecto de D2.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  -- ═ (4.7) transferencia: bank_account primero (P0412), después la parte ════
  -- (4.7a) bank_account VÁLIDO + cliente ajeno → P0404 y cero bank_movements
  SELECT COUNT(*) INTO v_n_bank_movs FROM public.bank_movements WHERE bank_account_id = v_bank_a;

  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-7a',
      p_client_id       => v_client_b,
      p_amount          => 100,
      p_payment_method  => 'transfer',
      p_bank_account_id => v_bank_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0404' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7a): cobro por transferencia con cliente ajeno debe fallar con P0404, falló con %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE bank_account_id = v_bank_a;
  IF v_count <> v_n_bank_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7a-banco): el guard debe cortar ANTES del ruteo bancario — hay % movimientos, esperaba %.', v_count, v_n_bank_movs;
  END IF;

  -- (4.7b) bank_account INEXISTENTE + cliente ajeno → P0412, NO P0404.
  -- Congela que el bloque bancario corre antes del guard de parte (D2).
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-7b',
      p_client_id       => v_client_b,
      p_amount          => 100,
      p_payment_method  => 'transfer',
      p_bank_account_id => v_ghost
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0412' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7b): cliente ajeno + bank_account inexistente debe fallar con P0412 (el bloque bancario corre ANTES del guard de parte, D2), falló con %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;

  -- (4.7c) espejo del lado PROVEEDOR: pago por transferencia con proveedor
  -- ajeno + bank_account inexistente → P0412, no P0404. Sólo aplica al PAGO:
  -- rpc_register_supplier_charge no recibe cuenta bancaria (su firma es
  -- p_idempotency_key, p_supplier_id, p_amount, p_reference_id), así que del
  -- cargo manual sólo se puede congelar el orden contra el importe (4.6c).
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_register_payment_made(
      p_idempotency_key => 'gate-ccpg-4-7c',
      p_supplier_id     => v_supplier_b,
      p_amount          => 100,
      p_payment_method  => 'transfer',
      p_bank_account_id => v_ghost
    );
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  IF NOT v_rejected OR v_sqlstate <> 'P0412' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.7c): en rpc_register_payment_made, proveedor ajeno + bank_account inexistente debe fallar con P0412 (el bloque bancario corre ANTES del guard de parte, D2), falló con %.', COALESCE(v_sqlstate, '<sin error>');
  END IF;
  RAISE NOTICE 'PASS (4.6 + 4.7): el orden documentado en D2 queda congelado por los DOS lados — cliente (4.6/4.7a/4.7b) y proveedor (4.6b/4.6c/4.7c): amount (P0400) → payment_method → bank_account (P0412) → parte (P0404) → idempotencia; y el guard corta antes del ruteo bancario.';

  -- ═══ (4.1-4.3) CANDADO DE CUERPO del guard explícito en las 3 RPCs ════════
  -- Por qué hace falta: TODOS los asserts de comportamiento de arriba pasan
  -- igual con las 3 RPCs revertidas a su cuerpo pre-guard, porque el choke
  -- point (c30_get_or_create_*) levanta el MISMO P0404. Es decir: sin estos
  -- asserts, la capa 2 de D1 —el guard explícito, que existe para dar el
  -- mensaje del dominio del llamador y para no consumir la clave de
  -- idempotencia— podría desaparecer del código y el gate seguiría verde.
  -- Se verifica sobre el cuerpo VIVO (pg_get_functiondef), no sobre el .sql:
  --   (a) el literal del guard está presente, y
  --   (b) su posición cae DESPUÉS de la última validación de payload y
  --       ANTES del INSERT de idempotencia — que es exactamente D2.
  --
  -- caja-compras-cobranzas (2026-09-01): la firma ganó un 7º argumento
  -- (p_cash_session_id uuid DEFAULT NULL, trailing) — DROP+CREATE, no
  -- overload. El literal de acá se actualiza a la firma nueva; el orden
  -- relativo bank_account_not_found < client_not_found < idempotencia que
  -- este candado verifica sigue intacto (el bloque nuevo del opt-in de caja
  -- se insertó ANTES del guard de tenencia, sin mover ninguna de las tres
  -- anclas).
  v_def := pg_get_functiondef('public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid, uuid)'::regprocedure);
  v_pos_guard := position('client_not_found' in v_def);
  v_pos_prev  := position('bank_account_not_found' in v_def);
  v_pos_idem  := position('INSERT INTO public.operation_idempotency' in v_def);
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.1-cuerpo): rpc_register_payment_received perdió su guard explícito de cliente (no aparece client_not_found en el cuerpo vivo). El choke point sigue cubriendo el comportamiento, así que ningún otro assert lo detecta — la capa 2 de D1 se borró en silencio.';
  END IF;
  IF v_pos_prev = 0 OR v_pos_idem = 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.1-anclas): no se encontraron las anclas de orden en rpc_register_payment_received (bank_account_not_found=%, INSERT idempotencia=%) — el candado de posición quedaría vacuo.', v_pos_prev, v_pos_idem;
  END IF;
  IF NOT (v_pos_prev < v_pos_guard AND v_pos_guard < v_pos_idem) THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.1-orden): en rpc_register_payment_received el guard de cliente debe ir DESPUÉS de la validación de bank_account y ANTES del INSERT de idempotencia (D2). Posiciones: bank=%, guard=%, idempotencia=%.', v_pos_prev, v_pos_guard, v_pos_idem;
  END IF;

  v_def := pg_get_functiondef('public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid, uuid)'::regprocedure);
  v_pos_guard := position('supplier_not_found' in v_def);
  v_pos_prev  := position('bank_account_not_found' in v_def);
  v_pos_idem  := position('INSERT INTO public.operation_idempotency' in v_def);
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.2-cuerpo): rpc_register_payment_made perdió su guard explícito de proveedor (no aparece supplier_not_found en el cuerpo vivo).';
  END IF;
  IF v_pos_prev = 0 OR v_pos_idem = 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.2-anclas): no se encontraron las anclas de orden en rpc_register_payment_made (bank=%, idempotencia=%).', v_pos_prev, v_pos_idem;
  END IF;
  IF NOT (v_pos_prev < v_pos_guard AND v_pos_guard < v_pos_idem) THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.2-orden): en rpc_register_payment_made el guard de proveedor debe ir DESPUÉS de bank_account y ANTES del INSERT de idempotencia (D2). Posiciones: bank=%, guard=%, idempotencia=%.', v_pos_prev, v_pos_guard, v_pos_idem;
  END IF;

  -- rpc_register_supplier_charge no tiene bloque bancario: su última
  -- validación de payload previa al guard es la del importe (invalid_amount).
  v_def := pg_get_functiondef('public.rpc_register_supplier_charge(text, uuid, numeric, uuid)'::regprocedure);
  v_pos_guard := position('supplier_not_found' in v_def);
  v_pos_prev  := position('invalid_amount' in v_def);
  v_pos_idem  := position('INSERT INTO public.operation_idempotency' in v_def);
  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.3-cuerpo): rpc_register_supplier_charge perdió su guard explícito de proveedor (no aparece supplier_not_found en el cuerpo vivo).';
  END IF;
  IF v_pos_prev = 0 OR v_pos_idem = 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.3-anclas): no se encontraron las anclas de orden en rpc_register_supplier_charge (invalid_amount=%, idempotencia=%).', v_pos_prev, v_pos_idem;
  END IF;
  IF NOT (v_pos_prev < v_pos_guard AND v_pos_guard < v_pos_idem) THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.3-orden): en rpc_register_supplier_charge el guard de proveedor debe ir DESPUÉS de la validación de importe y ANTES del INSERT de idempotencia (D2). Posiciones: amount=%, guard=%, idempotencia=%.', v_pos_prev, v_pos_guard, v_pos_idem;
  END IF;
  RAISE NOTICE 'PASS (4.1-4.3): las 3 RPCs de pago conservan su guard EXPLÍCITO en el cuerpo vivo, ubicado donde manda D2 (después del último guard de payload, antes del INSERT de idempotencia) — la capa 2 de D1 no puede borrarse en silencio.';

  -- ═══ (4.5) la clave de idempotencia NO se quema en el rechazo ═════════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_register_payment_received(
      p_idempotency_key => 'gate-ccpg-4-5-shared',
      p_client_id       => v_client_b,
      p_amount          => 100
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-pre): el cobro con cliente ajeno debería haberse rechazado con P0404.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.operation_idempotency
  WHERE user_id = v_user_a AND operation_kind = 'payment_received' AND idempotency_key = 'gate-ccpg-4-5-shared';
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-slot): el rechazo dejó % filas en operation_idempotency para la clave compartida, esperaba 0 — la clave quedó quemada.', v_count;
  END IF;

  -- Mismo idempotency_key, ahora con un cliente VÁLIDO: tiene que registrar
  -- de verdad, no devolver el replay de un intento que nunca ocurrió.
  SELECT public.rpc_register_payment_received(
    p_idempotency_key => 'gate-ccpg-4-5-shared',
    p_client_id       => v_client_a2,
    p_amount          => 100
  ) INTO v_result;
  IF (v_result->>'replayed')::boolean THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5): el reintento con la MISMA clave y un cliente válido devolvió replayed = true — el rechazo quemó la clave de idempotencia.';
  END IF;
  IF (v_result->>'payment_id') IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-pago): el reintento con cliente válido debería registrar un cobro real.';
  END IF;
  IF (v_result->>'balance_after')::numeric <> 500 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (4.5-saldo): balance_after esperado 500 (600 - 100), es %.', v_result->>'balance_after';
  END IF;
  RAISE NOTICE 'PASS (4.5): un cobro rechazado por cliente ajeno NO quema la clave de idempotencia — el reintento con cliente válido registra de verdad.';

  -- ═════ (5.1) _pay_register_party_charge no es alcanzable por el rol app ═══
  -- Ojo: la primitiva recibe el account_id COMO PARÁMETRO. Sin el revoke, un
  -- authenticated cualquiera escribe en la cuenta corriente REAL del tenant B.
  -- Libros de la víctima ANTES del intento: el spec de party-account-charge
  -- dice "los libros del tenant B quedan sin cambios: sin movimiento, sin
  -- saldo alterado y sin evento de cargo". Se mide.
  SELECT COUNT(*) INTO v_nb_cust_accounts FROM public.customer_accounts WHERE account_id = v_account_b;
  SELECT COUNT(*) INTO v_nb_cust_movs     FROM public.customer_account_movements m
    JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.account_id = v_account_b;
  SELECT COUNT(*) INTO v_nb_events        FROM public.events WHERE account_id = v_account_b;

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public._pay_register_party_charge(v_account_b, 'customer', v_client_b, 1000, NULL, NULL);
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  EXECUTE 'RESET ROLE';

  IF NOT v_rejected OR v_sqlstate <> '42501' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1, SEVERIDAD ALTA): _pay_register_party_charge debe ser inalcanzable para el rol authenticated (42501 insufficient_privilege), obtuve %. Es una primitiva SECURITY DEFINER que recibe el account_id por parámetro: expuesta vía PostgREST permite escribir en los libros de CUALQUIER tenant.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  IF has_function_privilege('authenticated',
       'public._pay_register_party_charge(uuid,text,uuid,numeric,uuid,uuid)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1-acl): authenticated no debe tener EXECUTE sobre _pay_register_party_charge.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.customer_accounts WHERE account_id = v_account_b;
  IF v_count <> v_nb_cust_accounts THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1-B-cuentas): el intento dejó % customer_accounts en el tenant víctima, esperaba %.', v_count, v_nb_cust_accounts;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements m
    JOIN public.customer_accounts a ON a.id = m.customer_account_id WHERE a.account_id = v_account_b;
  IF v_count <> v_nb_cust_movs THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1-B-movimientos): el intento dejó % movimientos en los libros de B, esperaba %.', v_count, v_nb_cust_movs;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_b;
  IF v_count <> v_nb_events THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.1-B-eventos): el intento dejó % eventos en el tenant víctima, esperaba % — no debe emitirse CustomerAccountCharged en libros ajenos.', v_count, v_nb_events;
  END IF;
  RAISE NOTICE 'PASS (5.1): _pay_register_party_charge deja de ser invocable por authenticated y los libros del tenant víctima quedan sin cambios — la primitiva de escritura cross-tenant queda cerrada.';

  -- ═════ (5.2) _journal_post_from_event, mismo caso, misma proveniencia ═════
  -- El evento se forja como postgres (RLS de events no aplica al owner) y la
  -- fila se lee ANTES del cambio de rol: lo que se prueba es el EXECUTE, no
  -- el acceso a la tabla.
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_b, 'SaleConfirmed', 'SalesOrder', gen_random_uuid(),
    jsonb_build_object('account_id', v_account_b, 'sales_order_id', gen_random_uuid(),
                       'operation_id', gen_random_uuid(), 'total', 999, 'payment_method', 'cash'), now())
  RETURNING id INTO v_event_id;
  SELECT * INTO v_event_row FROM public.events WHERE id = v_event_id;

  SELECT COUNT(*) INTO v_nb_journal FROM public.journal_entries WHERE account_id = v_account_b;

  EXECUTE 'SET LOCAL ROLE authenticated';
  v_rejected := false;
  v_sqlstate := NULL;
  BEGIN
    PERFORM public._journal_post_from_event(v_event_row);
  EXCEPTION
    WHEN OTHERS THEN
      v_sqlstate := SQLSTATE; v_rejected := true;
  END;
  EXECUTE 'RESET ROLE';

  IF NOT v_rejected OR v_sqlstate <> '42501' THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.2, SEVERIDAD ALTA): _journal_post_from_event debe ser inalcanzable para authenticated (42501), obtuve %. Nació con REVOKE en 20260803000001 L517 y lo perdió en 20261001000001 L1914 cuando el patrón uniforme REVOKE+GRANT se lo aplicó en piloto automático.', COALESCE(v_sqlstate, '<sin error: la llamada tuvo ÉXITO>');
  END IF;

  IF has_function_privilege('authenticated',
       'public._journal_post_from_event(public.events)'::regprocedure, 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.2-acl): authenticated no debe tener EXECUTE sobre _journal_post_from_event.';
  END IF;

  -- El 42501 sin este assert probaría el permiso, no la consecuencia: lo que
  -- importa es que en los libros de B no aparezca el asiento forjado.
  SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE account_id = v_account_b;
  IF v_count <> v_nb_journal THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.2-B-asientos): el intento dejó % journal_entries en el tenant víctima, esperaba %.', v_count, v_nb_journal;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE source_event_id = v_event_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.2-B-forjado): el evento forjado dejó % asientos posteados, esperaba 0.', v_count;
  END IF;
  RAISE NOTICE 'PASS (5.2): _journal_post_from_event deja de ser invocable por authenticated y el evento forjado no postea asiento — no se puede forjar un evento y escribir en el libro diario de otro tenant.';

  -- ══ (5.5) el revoke es TRANSPARENTE para los callers internos (definer) ═══
  SELECT COUNT(*) INTO v_n_ev_charged FROM public.events
   WHERE account_id = v_account_a AND event_type = 'CustomerAccountCharged';

  SELECT public.rpc_create_sale_operation_v2(
    p_idempotency_key   => 'gate-ccpg-5-5-form',
    p_client_id         => v_client_a2,
    p_date              => public.reporting_local_today(),
    p_currency          => 'ARS',
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'amount', 250, 'quantity', 1)),
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;
  v_op_id := (v_result->>'operation_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE customer_account_id = v_ca_id AND reference_id = v_op_id AND amount = 250;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.5-formulario): tras el revoke, la venta a crédito del formulario debe seguir posteando su cargo vía _pay_register_party_charge (el PERFORM interno corre como definer). Esperaba 1 movimiento, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.events
   WHERE account_id = v_account_a AND event_type = 'CustomerAccountCharged';
  IF v_count <> v_n_ev_charged + 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.5-formulario-evento): el cargo del formulario debe emitir 1 CustomerAccountCharged tras el revoke; hay % y esperaba %.', v_count, v_n_ev_charged + 1;
  END IF;
  v_n_ev_charged := v_count;

  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-ccpg-5-5-pos',
    p_client_id         => v_client_a2,
    p_items             => jsonb_build_array(jsonb_build_object('product_id', v_product_a, 'quantity', 1, 'price', 300, 'subtotal', 300)),
    p_payment_method    => 'credit',
    p_branch_id         => v_branch_a,
    p_payment_method_id => v_pm_credit
  ) INTO v_result;
  v_so_id := (v_result->>'sales_order_id')::uuid;

  -- El cargo del POS referencia sales_orders.id (no operation_id) — misma
  -- premisa que verifica test_pagos_cableados_restantes.sql (9c).
  SELECT COUNT(*) INTO v_count FROM public.customer_account_movements
  WHERE customer_account_id = v_ca_id AND reference_id = v_so_id AND amount = 300;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.5-pos): tras el revoke, la venta a crédito del POS debe seguir posteando su cargo. Esperaba 1 movimiento con reference_id=sales_order_id, hay %.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.events
   WHERE account_id = v_account_a AND event_type = 'CustomerAccountCharged';
  IF v_count <> v_n_ev_charged + 1 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.5-pos-evento): el cargo del POS debe emitir 1 CustomerAccountCharged tras el revoke; hay % y esperaba %.', v_count, v_n_ev_charged + 1;
  END IF;
  RAISE NOTICE 'PASS (5.5): el revoke es transparente para los callers reales — formulario y POS siguen posteando el cargo a crédito y emitiendo su evento.';

  -- ══ (5.6) el dispatcher del outbox sigue posteando asientos balanceados ═══
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_account_a, 'SaleConfirmed', 'SalesOrder', gen_random_uuid(),
    jsonb_build_object('account_id', v_account_a, 'sales_order_id', gen_random_uuid(),
                       'operation_id', gen_random_uuid(), 'total', 1234, 'payment_method', 'cash'), now())
  RETURNING id INTO v_event_id;

  SELECT public.rpc_process_outbox_dispatch(1000) INTO v_processed;

  SELECT je.id INTO v_entry_id FROM public.journal_entries je WHERE je.source_event_id = v_event_id;
  IF v_entry_id IS NULL THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.6): tras el revoke de _journal_post_from_event, rpc_process_outbox_dispatch debe seguir posteando el asiento del evento % — no se encontró journal_entry.', v_event_id;
  END IF;

  SELECT COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
         COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
  INTO v_debit, v_credit
  FROM public.journal_lines WHERE entry_id = v_entry_id;

  IF v_debit <> v_credit OR v_debit <> 1234 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (5.6-balance): el asiento del outbox debe balancear en 1234 por lado, es debit=% credit=%.', v_debit, v_credit;
  END IF;
  RAISE NOTICE 'PASS (5.6): rpc_process_outbox_dispatch (SECURITY DEFINER) sigue posteando asientos balanceados tras el revoke — el dispatcher no pasa por el ACL de authenticated.';

  -- ══ (9) BARRIDO GLOBAL: el invariante que los specs declaran de la TABLA ══
  -- "no existe ninguna fila cuyo clients.account_id difiera del
  -- customer_accounts.account_id" (y su espejo proveedor). Todo lo anterior
  -- prueba caminos; esto prueba el estado, incluida cualquier fila que haya
  -- dejado otro gate de la corrida de CI.
  SELECT COUNT(*) INTO v_count
  FROM public.customer_accounts ca
  JOIN public.clients c ON c.id = ca.client_id
  WHERE c.account_id IS DISTINCT FROM ca.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (9-clientes): hay % customer_accounts cuyo cliente pertenece a otro tenant — el invariante de coherencia (account_id, client_id) está roto en la base entera, no sólo en los caminos que este gate ejercita.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.supplier_accounts sa
  JOIN public.suppliers s ON s.id = sa.supplier_id
  WHERE s.account_id IS DISTINCT FROM sa.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE PARTY-GUARD FAILED (9-proveedores): hay % supplier_accounts cuyo proveedor pertenece a otro tenant.', v_count;
  END IF;
  RAISE NOTICE 'PASS (9): barrido global — cero cuentas corrientes (cliente y proveedor) con la parte de otro tenant en toda la base.';

  RAISE NOTICE 'GATE CUENTA-CORRIENTE-PARTY-GUARD OK: guard de tenencia en el choke point + 3 RPCs de pago (con candado de cuerpo), orden de guards congelado, idempotencia intacta, libros del tenant víctima sin tocar, y las dos primitivas cross-tenant cerradas sin romper ningún caller real.';
END $$;

-- ── Fase de cleanup ──────────────────────────────────────────────────────────
-- Sin esto, la SEGUNDA corrida del gate sobre la misma base aborta con
-- `users_email_partial_key` (el anchor usa un email fijo y un id nuevo, así
-- que el ON CONFLICT (id) DO NOTHING no lo cubre) — verificado en local.
--
-- Va en un DO block SEPARADO, como en test_cuentas_billetera_tipo.sql (Fase
-- 9), y resuelve los ids por email en vez de heredar las variables: así
-- limpia también las corridas que se cortaron por alguno de los caminos
-- degrade-don't-fail (que hacen RETURN después de haber insertado los
-- anchors). Si el DO principal ABORTA, psql con ON_ERROR_STOP=1 corta antes
-- de llegar acá — pero en ese caso la transacción del DO ya revirtió todo,
-- incluidos los anchors, así que no queda nada que limpiar.
--
-- El orden es el inverso al de creación y está verificado empíricamente
-- contra el stack local (sonda en BEGIN…ROLLBACK): ninguna FK ni guard de
-- borrado se interpone.
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users
  WHERE email IN ('cuenta-corriente-party-guard-a@test.local',
                  'cuenta-corriente-party-guard-b@test.local');

  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE PARTY-GUARD: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements           WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_received        WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payments_made            WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements m USING public.customer_accounts a
      WHERE m.customer_account_id = a.id AND a.account_id = ANY(v_accounts);
    DELETE FROM public.supplier_account_movements m USING public.supplier_accounts a
      WHERE m.supplier_account_id = a.id AND a.account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts        WHERE account_id = ANY(v_accounts);
    DELETE FROM public.supplier_accounts        WHERE account_id = ANY(v_accounts);
    DELETE FROM public.stock_movements          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sale_items               WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales                    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales_order_items i USING public.sales_orders o
      WHERE i.sales_order_id = o.id AND o.account_id = ANY(v_accounts);
    DELETE FROM public.sales_orders             WHERE account_id = ANY(v_accounts);
    -- Antes de borrar los events: las claves de idempotencia que escribe el
    -- dispatcher del outbox en 5.6 (rpc_process_outbox_dispatch) llevan
    -- operation_kind='event_consumer' y un user_id SENTINELA
    -- (00000000-0000-0000-0000-000000000000), no el del anchor, así que el
    -- `DELETE … WHERE user_id = ANY(v_users)` de más abajo NO las alcanza.
    -- Como operation_idempotency.event_id no tiene FK, quedaban apuntando a
    -- events ya borrados: 21 filas huérfanas POR CORRIDA. Tiene que ir acá,
    -- mientras los events todavía existen y se las puede resolver por cuenta.
    DELETE FROM public.operation_idempotency
     WHERE operation_kind = 'event_consumer'
       AND event_id IN (SELECT id FROM public.events WHERE account_id = ANY(v_accounts));
    DELETE FROM public.events                   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products                 WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_accounts            WHERE account_id = ANY(v_accounts);
    DELETE FROM public.clients                  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.suppliers                WHERE account_id = ANY(v_accounts);
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  -- sucursal-guard-vaciado-auditoria: DELETE FROM accounts cascadea a branches (ON DELETE CASCADE) y el trigger trg_guard_branch_decommission prohibe TODO borrado fisico de una sucursal (P0428) -- bypass explicito para el cleanup del fixture sintetico. session_replication_role solo lo puede fijar un rol con privilegio de superusuario (postgres en CI); no abre ningun camino para authenticated/anon via PostgREST.
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  -- email_logs.user_id es FK ON DELETE SET NULL: borrar el anchor NO borra la
  -- fila, la deja con user_id NULL y el recipient sintético adentro. Mismo
  -- patrón que test_tenancy_rls_role.sql (L~207): se borra por user_id ANTES
  -- del DELETE de auth.users y por recipient para las corridas que ya
  -- perdieron el vínculo.
  DELETE FROM public.email_logs
   WHERE user_id = ANY(v_users)
      OR recipient IN ('cuenta-corriente-party-guard-a@test.local',
                       'cuenta-corriente-party-guard-b@test.local');
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE CUENTA-CORRIENTE-PARTY-GUARD: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
