-- =============================================================================
-- GATE: test_tenancy_guard_caja_outbox.sql
-- CHANGE: tenancy-guard-caja-outbox — tramo h1 (tasks 2.1-2.5, 2.9, 2.10,
--         3.5-3.9)
--
-- Ejercita de verdad (dos tenants sintéticos, sesión vía request.jwt.claims,
-- mismo molde que test_cuenta_corriente_party_guard.sql) el guard de tenencia
-- de la SESIÓN DE CAJA en el camino del POS.
--
--   EL HUECO (h1). `_c29_confirm_order_core` —el core que confirman los dos
--   wrappers públicos del POS, rpc_quick_sale y rpc_confirm_sales_order—
--   valida is_account_writer sobre la orden, la forma de pago, la sucursal y
--   la cuenta bancaria, pero del p_cash_session_id SÓLO chequeaba IS NULL
--   (cash_requires_session, P0400) y lo pasaba crudo a
--   c28_register_cash_movement, que es SECURITY INVOKER y sólo exige
--   status='open' + sucursal activa: ni account_id, ni current_account_ids(),
--   ni que la caja sea la de la sucursal de la venta. Como todos los callers
--   son SECURITY DEFINER y corren como postgres, la RLS no interviene.
--   Resultado reproducido: una venta del tenant A con la sesión abierta del
--   tenant B se confirma y le deja a B un INGRESO FANTASMA en su arqueo.
--   El contraste que define el fix vive en el mismo dominio: el FORMULARIO de
--   venta (rpc_create_sale_operation_v2) sí lo cierra, con
--   cash_optin_requires_open_session (cs.status='open' AND
--   cb.branch_id = v_gate_branch → P0422). El guard existía y no se replicó.
--
--   DOS CAPAS, INVARIANTES DISTINTOS (design.md D1) — y por eso dos familias
--   de asserts:
--     CAPA 1, en _c29_confirm_order_core: invariante de SUCURSAL. Es la única
--     capa que puede expresarlo (v_gate_branch sólo existe dentro del core).
--       (2.2) rpc_quick_sale (POS) + sesión abierta de OTRO TENANT   → P0422
--       (2.3) rpc_confirm_sales_order + sesión de otro tenant        → P0422
--       (2.4) sesión de OTRA SUCURSAL DEL MISMO TENANT               → P0422
--             ← el assert que sólo la capa 1 puede cubrir: la capa 2 lo
--               dejaría pasar (mismo account_id). Sin él, D1 no está probado.
--     CAPA 2, en c28_register_cash_movement: invariante de TENANT. Es la única
--     que cubre callers futuros; membresía (current_account_ids()), NO
--     is_account_writer — es un backstop de tenencia, no de autorización
--     (D1 iii: exigir permiso de escritura acá endurecería en silencio el rol
--     del camino del formulario).
--       (2.5) c28_register_cash_movement invocada DIRECTO con los claims de A
--             contra la sesión de B                                   → P0401
--
--   En las cuatro NO alcanza con el SQLSTATE: el spec pide "sin efectos
--   parciales", así que los movimientos de la caja de la víctima se cuentan y
--   se suman ANTES y DESPUÉS, y tienen que quedar idénticos.
--
--   (2.9) BARRIDO GLOBAL sobre TODA la tabla cash_movements —no sólo los
--   tenants sintéticos—: cero movimientos cuya sesión pertenezca a un tenant
--   distinto del de la venta/orden que los originó. Convierte la auditoría de
--   daño histórico en candado permanente y cubre residuos de otros gates de la
--   misma corrida de CI. Mismo patrón que el assert (9) del gate anterior.
--
--   TRIANGULACIÓN (el guard no rompe el POS ni se relaja por otro lado):
--     (3.5) CONTROL POSITIVO — venta POS en efectivo con la sesión CORRECTA de
--           la propia sucursal sigue funcionando y escribe EXACTAMENTE 1
--           cash_movements de tipo 'sale', con reference_id = sales_order_id y
--           el importe total. Sin este assert el guard podría estar
--           rechazando todo.
--     (3.7) SALDO FIRMADO — recupera la cobertura que la capa 2 degrada. El
--           gate (b) embebido en 20260804000003_fix_c28_cash_movement_balance
--           invoca el helper sobre un anchor cuyo usuario NO está en
--           account_members de la cuenta del anchor, así que con la capa 2
--           puesta ese gate se auto-degrada a NOTICE (no aborta, porque el
--           ERRCODE elegido es P0401 y su handler `WHEN raise_exception`
--           matchea SÓLO P0001 — ver D8 y la task 3.6). La aserción se
--           replica acá sobre un tenant BIEN PROVISIONADO: opening = 1000,
--           luego +500 / −200 / +300 → balance_after 1500 / 1300 / 1600 (con
--           el bug viejo de MAX(balance_after) el tercero daría 1800).
--           NO se edita 20260804000003: es una migración ya aplicada en prod.
--     (3.8) Los wrappers HEREDAN el guard: ni rpc_quick_sale ni
--           rpc_confirm_sales_order contienen el literal del guard en su
--           cuerpo vivo — 2.2 y 2.3 pasan sin haberlos tocado.
--     (3.9) rpc_delete_sale_operation sigue compensando caja sobre una venta
--           propia (regresión de la capa 2 sobre el camino de borrado), y
--           rpc_register_cash_movement sigue exigiendo is_account_writer (el
--           guard duplicado no relaja nada).
--     (3.2/3.3-cuerpo) CANDADO DE POSICIÓN. Los asserts de comportamiento no
--           distinguen en qué capa se levantó el error, así que la ubicación
--           documentada en D2 se congela leyendo el cuerpo vivo: en el core el
--           guard cae DESPUÉS de cash_requires_session y ANTES del INSERT de
--           idempotencia (o sea, antes de la primera escritura); en el helper,
--           ANTES del INSERT en cash_movements.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
--
-- Cleanup: DO block separado al final que resuelve los ids por email (así
-- limpia también las corridas cortadas por un camino degrade-don't-fail) y
-- borra los dos tenants sintéticos y todo lo que colgaba de ellos, incluidos
-- los dos residuos que NO cuelgan del anchor: las claves `event_consumer` de
-- operation_idempotency (user_id sentinela, event_id sin FK) y las filas de
-- email_logs (FK ON DELETE SET NULL). Sin eso la SEGUNDA corrida sobre la
-- misma base aborta con users_email_partial_key. Verificado: el gate corre
-- VERDE dos veces seguidas.
-- =============================================================================

DO $$
DECLARE
  -- ── Tenant A (el que opera) ───────────────────────────────────────────────
  v_email_a        text := 'tenancy-guard-caja-a@test.local';
  v_user_a         uuid := gen_random_uuid();
  v_account_a      uuid;
  v_branch_a1      uuid;   -- sucursal por defecto (la de la venta)
  v_branch_a2      uuid;   -- SEGUNDA sucursal del MISMO tenant (assert 2.4)
  v_cashbox_a1     uuid;
  v_cashbox_a2     uuid;
  v_cashbox_a3     uuid;   -- caja limpia para el saldo firmado (3.7)
  v_session_a1     uuid;
  v_session_a2     uuid;
  v_session_a3     uuid;
  v_pm_cash_a      uuid;
  v_product_a      uuid;

  -- ── Tenant B (la víctima: su sesión de caja se usa desde la sesión de A) ──
  v_email_b        text := 'tenancy-guard-caja-b@test.local';
  v_user_b         uuid := gen_random_uuid();
  v_account_b      uuid;
  v_branch_b       uuid;
  v_cashbox_b      uuid;
  v_session_b      uuid;

  -- ── Scratch ───────────────────────────────────────────────────────────────
  v_rejected       boolean;
  v_result         jsonb;
  v_so_id          uuid;
  v_mov_id         uuid;
  v_op_id          uuid;
  v_count          integer;
  v_status         text;
  v_amount         numeric;
  v_balance        numeric;
  v_def            text;
  v_pos_guard      integer;
  v_pos_prev       integer;
  v_pos_write      integer;

  -- Libros de la VÍCTIMA, medidos antes y después de cada intento
  v_nb_movs        integer;
  v_nb_sum         numeric;
BEGIN
  -- ── Anchor sintético del tenant A ─────────────────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Tenancy Caja A'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL THEN
    RAISE NOTICE 'GATE TENANCY-CAJA: no se pudo resolver cuenta para el anchor sintético A — degradando sin abortar.';
    RETURN;
  END IF;

  -- ── Anchor sintético del tenant B (la víctima) ────────────────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Tenancy Caja B'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;

  IF v_account_b IS NULL OR v_account_b = v_account_a THEN
    RAISE NOTICE 'GATE TENANCY-CAJA: no se pudo provisionar un SEGUNDO tenant independiente para el anchor B — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_a1  FROM public.branches   WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_a1 FROM public.cashboxes  WHERE branch_id  = v_branch_a1 ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_cash_a  FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' LIMIT 1;
  SELECT id INTO v_branch_b   FROM public.branches   WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_b  FROM public.cashboxes  WHERE branch_id  = v_branch_b  ORDER BY created_at LIMIT 1;

  IF v_branch_a1 IS NULL OR v_cashbox_a1 IS NULL OR v_pm_cash_a IS NULL
     OR v_branch_b IS NULL OR v_cashbox_b IS NULL THEN
    RAISE NOTICE 'GATE TENANCY-CAJA: sucursal/caja/catálogo no sembrado para los anchors — degradando sin abortar.';
    RETURN;
  END IF;

  -- Segunda sucursal del MISMO tenant A, con su propia caja: es el escenario
  -- del assert 2.4, el único que la capa 2 no puede cubrir.
  INSERT INTO public.branches (account_id, name)
  VALUES (v_account_a, '__gate_tgc_branch_a2__')
  RETURNING id INTO v_branch_a2;

  INSERT INTO public.cashboxes (branch_id, name)
  VALUES (v_branch_a2, '__gate_tgc_cashbox_a2__')
  RETURNING id INTO v_cashbox_a2;

  -- Caja adicional en la sucursal principal, para el saldo firmado (3.7) sin
  -- mezclarse con los movimientos del control positivo.
  INSERT INTO public.cashboxes (branch_id, name)
  VALUES (v_branch_a1, '__gate_tgc_cashbox_a3__')
  RETURNING id INTO v_cashbox_a3;

  -- Sesiones abiertas. Se insertan directo (el gate corre como postgres) para
  -- no depender del orden de los guards de rpc_open_cash_session: lo que este
  -- gate prueba es el consumo de la sesión, no su apertura.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a1, 'open', 0, v_user_a) RETURNING id INTO v_session_a1;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a2, 'open', 0, v_user_a) RETURNING id INTO v_session_a2;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a3, 'open', 1000, v_user_a) RETURNING id INTO v_session_a3;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 0, v_user_b) RETURNING id INTO v_session_b;

  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_tgc_product__', 1000, 400, 'GATE-TGC-1')
  RETURNING id INTO v_product_a;

  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a1, v_product_a, 100)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100;

  -- ── Sesión sintética del tenant A (request.jwt.claims) ────────────────────
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE TENANCY-CAJA: auth.uid() no resuelve al anchor A con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ═══════ (2.2) POS + sesión de caja abierta de OTRO TENANT → P0422 ════════
  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_nb_movs, v_nb_sum
  FROM public.cash_movements WHERE session_id = v_session_b;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key   => 'gate-tgc-2-2',
      p_items             => jsonb_build_array(jsonb_build_object(
                               'product_id', v_product_a, 'quantity', 1,
                               'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_b,
      p_branch_id         => v_branch_a1,
      p_payment_method_id => v_pm_cash_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0422' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.2): rpc_quick_sale del tenant A con la sesión de caja ABIERTA del tenant B debería fallar con P0422 (cash_optin_requires_open_session). Hoy la venta se confirma y le deja a B un ingreso fantasma en su arqueo.';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_count, v_amount
  FROM public.cash_movements WHERE session_id = v_session_b;
  IF v_count <> v_nb_movs OR v_amount <> v_nb_sum THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.2-efectos): el rechazo dejó la caja de la víctima en % movimientos / % de saldo, esperaba % / % — el spec pide "sin efectos parciales", no sólo que falle.', v_count, v_amount, v_nb_movs, v_nb_sum;
  END IF;
  RAISE NOTICE 'PASS (2.2): rpc_quick_sale rechaza con P0422 la sesión de caja de otro tenant, y el arqueo de la víctima queda intacto.';

  -- ═══ (2.3) espejo por rpc_confirm_sales_order (orden creada aparte) ═══════
  INSERT INTO public.sales_orders (account_id, branch_id, client_id, status, total, created_by)
  VALUES (v_account_a, v_branch_a1, NULL, 'draft', 1000, v_user_a)
  RETURNING id INTO v_so_id;

  INSERT INTO public.sales_order_items (sales_order_id, account_id, product_id, quantity, price, subtotal)
  VALUES (v_so_id, v_account_a, v_product_a, 1, 1000, 1000);

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_nb_movs, v_nb_sum
  FROM public.cash_movements WHERE session_id = v_session_b;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_confirm_sales_order(
      p_idempotency_key   => 'gate-tgc-2-3',
      p_sales_order_id    => v_so_id,
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_b,
      p_payment_method_id => v_pm_cash_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0422' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.3): rpc_confirm_sales_order con la sesión de caja del tenant B debería fallar con P0422.';
  END IF;

  SELECT status INTO v_status FROM public.sales_orders WHERE id = v_so_id;
  IF v_status IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.3-orden): la orden quedó en estado % tras el rechazo, esperaba que siguiera en draft.', v_status;
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_count, v_amount
  FROM public.cash_movements WHERE session_id = v_session_b;
  IF v_count <> v_nb_movs OR v_amount <> v_nb_sum THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.3-efectos): el rechazo dejó % movimientos / % de saldo en la caja de la víctima, esperaba % / %.', v_count, v_amount, v_nb_movs, v_nb_sum;
  END IF;
  RAISE NOTICE 'PASS (2.3): rpc_confirm_sales_order rechaza con P0422 la sesión ajena, la orden sigue en draft y el arqueo de la víctima queda intacto.';

  -- ══ (2.4) sesión de OTRA SUCURSAL DEL MISMO TENANT → P0422 (sólo capa 1) ══
  -- Este es el caso que la capa 2 dejaría pasar: mismo account_id, otra
  -- sucursal. Sin este assert, D1 (dos capas con invariantes distintos) no
  -- está probado — y es exactamente lo que el FORMULARIO ya prohíbe.
  SELECT COUNT(*) INTO v_nb_movs FROM public.cash_movements WHERE session_id = v_session_a2;

  v_rejected := false;
  BEGIN
    PERFORM public.rpc_quick_sale(
      p_idempotency_key   => 'gate-tgc-2-4',
      p_items             => jsonb_build_array(jsonb_build_object(
                               'product_id', v_product_a, 'quantity', 1,
                               'price', 1000, 'subtotal', 1000)),
      p_payment_method    => 'cash',
      p_cash_session_id   => v_session_a2,   -- caja de la sucursal A2
      p_branch_id         => v_branch_a1,    -- venta en la sucursal A1
      p_payment_method_id => v_pm_cash_a
    );
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0422' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.4): una venta de la sucursal A1 imputada a la caja de la sucursal A2 (mismo tenant) debería fallar con P0422 — es el invariante de sucursal que el formulario ya cumple y que SÓLO la capa 1 puede expresar.';
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE session_id = v_session_a2;
  IF v_count <> v_nb_movs THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.4-efectos): el rechazo dejó % movimientos en la caja de la otra sucursal, esperaba %.', v_count, v_nb_movs;
  END IF;
  RAISE NOTICE 'PASS (2.4): la sesión de otra sucursal del mismo tenant se rechaza con P0422 (invariante de sucursal, capa 1).';

  -- ═══ (2.5) CAPA 2 — c28_register_cash_movement directo contra la caja de B ═
  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_nb_movs, v_nb_sum
  FROM public.cash_movements WHERE session_id = v_session_b;

  v_rejected := false;
  BEGIN
    PERFORM public.c28_register_cash_movement(v_session_b, 500, 'sale', NULL);
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLSTATE = 'P0401' THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.5): c28_register_cash_movement con los claims de A contra una sesión del tenant B debería fallar con P0401 (unauthorized). Hoy inserta: es la primitiva que deja el hueco abierto para cualquier caller futuro.';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_count, v_amount
  FROM public.cash_movements WHERE session_id = v_session_b;
  IF v_count <> v_nb_movs OR v_amount <> v_nb_sum THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.5-efectos): el rechazo dejó % movimientos / % de saldo en la caja ajena, esperaba % / %.', v_count, v_amount, v_nb_movs, v_nb_sum;
  END IF;
  RAISE NOTICE 'PASS (2.5): el helper intra-transacción rechaza con P0401 la sesión de otro tenant, sin insertar nada (backstop de la capa 2).';

  -- ═════ (3.5) CONTROL POSITIVO — el guard NO rompe el POS legítimo ═════════
  SELECT public.rpc_quick_sale(
    p_idempotency_key   => 'gate-tgc-3-5',
    p_items             => jsonb_build_array(jsonb_build_object(
                             'product_id', v_product_a, 'quantity', 2,
                             'price', 1000, 'subtotal', 2000)),
    p_payment_method    => 'cash',
    p_cash_session_id   => v_session_a1,   -- LA SESIÓN CORRECTA
    p_branch_id         => v_branch_a1,
    p_payment_method_id => v_pm_cash_a
  ) INTO v_result;

  v_so_id := (v_result->>'sales_order_id')::uuid;
  v_op_id := (v_result->>'operation_id')::uuid;

  IF v_so_id IS NULL OR (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.5): la venta POS legítima no devolvió una sales_order confirmada (resultado: %).', v_result;
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE session_id = v_session_a1;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.5-cantidad): la venta legítima escribió % movimientos en la caja propia, esperaba exactamente 1.', v_count;
  END IF;

  SELECT movement_type, reference_id, amount, balance_after
  INTO v_status, v_op_id, v_amount, v_balance
  FROM public.cash_movements WHERE session_id = v_session_a1;

  IF v_status <> 'sale' OR v_op_id IS DISTINCT FROM v_so_id OR v_amount <> 2000 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.5-fila): el movimiento quedó (tipo=%, reference_id=%, amount=%), esperaba (sale, %, 2000).', v_status, v_op_id, v_amount, v_so_id;
  END IF;

  SELECT status INTO v_status FROM public.sales_orders WHERE id = v_so_id;
  IF v_status IS DISTINCT FROM 'confirmed' THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.5-orden): la orden legítima quedó en %, esperaba confirmed.', v_status;
  END IF;
  RAISE NOTICE 'PASS (3.5): control positivo — la venta POS en efectivo con su propia sesión sigue funcionando y escribe exactamente 1 movimiento sale por el total.';

  -- ═ (3.9a) el camino de BORRADO sigue compensando caja sobre venta propia ══
  SELECT sale_operation_id INTO v_op_id FROM public.sales_orders WHERE id = v_so_id;

  PERFORM public.rpc_delete_sale_operation(
    p_operation_id => v_op_id,
    p_reason       => 'gate tenancy-caja 3.9a'
  );

  SELECT COUNT(*) INTO v_count
  FROM public.cash_movements
  WHERE session_id = v_session_a1 AND movement_type = 'sale_reversal';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.9a): borrar la venta propia debería dejar exactamente 1 contra-movimiento sale_reversal en la caja, hay % — la capa 2 no debe romper el camino de compensación.', v_count;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_amount FROM public.cash_movements WHERE session_id = v_session_a1;
  IF v_amount <> 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.9a-saldo): tras el borrado la caja debería quedar neteada en 0, quedó en %.', v_amount;
  END IF;
  RAISE NOTICE 'PASS (3.9a): rpc_delete_sale_operation sigue compensando la caja de una venta propia bajo la capa 2.';

  -- ═════ (3.7) SALDO FIRMADO — cobertura que la capa 2 degrada en 20260804000003 ═
  -- opening = 1000; +500 → 1500; −200 → 1300; +300 → 1600.
  -- Con el bug viejo (MAX(balance_after) en vez de opening + SUM(amount)) el
  -- tercero daría 1800. El gate (b) embebido en la migración de 2026-08-04
  -- deja de ejercitar esto porque su anchor no es miembro de su propia cuenta
  -- (D1) — la aserción se replica acá sobre un tenant bien provisionado.
  SELECT public.c28_register_cash_movement(v_session_a3, 500, 'sale', NULL) INTO v_mov_id;
  SELECT balance_after INTO v_balance FROM public.cash_movements WHERE id = v_mov_id;
  IF v_balance <> 1500 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.7-a): tras +500 sobre opening 1000 el balance_after debería ser 1500, es %.', v_balance;
  END IF;

  SELECT public.c28_register_cash_movement(v_session_a3, -200, 'withdrawal', NULL) INTO v_mov_id;
  SELECT balance_after INTO v_balance FROM public.cash_movements WHERE id = v_mov_id;
  IF v_balance <> 1300 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.7-b): tras −200 el balance_after debería ser 1300, es %.', v_balance;
  END IF;

  SELECT public.c28_register_cash_movement(v_session_a3, 300, 'sale', NULL) INTO v_mov_id;
  SELECT balance_after INTO v_balance FROM public.cash_movements WHERE id = v_mov_id;
  IF v_balance <> 1600 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.7-c): tras +300 el balance_after debería ser 1600 (opening + SUM), es % — con el bug de MAX(balance_after) daría 1800.', v_balance;
  END IF;
  RAISE NOTICE 'PASS (3.7): saldo firmado 1000 → 1500 → 1300 → 1600 sobre un tenant bien provisionado (cobertura recuperada del gate (b) de 20260804000003).';

  -- ═══════ (2.9) BARRIDO GLOBAL sobre TODA la tabla cash_movements ══════════
  SELECT COUNT(*) INTO v_count
  FROM public.cash_movements cm
  JOIN public.cash_sessions cs ON cs.id = cm.session_id
  JOIN public.cashboxes cb     ON cb.id = cs.cashbox_id
  JOIN public.branches b       ON b.id  = cb.branch_id
  JOIN public.sales_orders so  ON so.id = cm.reference_id
  WHERE so.account_id IS DISTINCT FROM b.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.9-ordenes): hay % movimientos de caja cuya sesión pertenece a un tenant distinto del de la sales_order que los originó — el invariante está roto en la base entera, no sólo en los caminos que este gate ejercita.', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.cash_movements cm
  JOIN public.cash_sessions cs ON cs.id = cm.session_id
  JOIN public.cashboxes cb     ON cb.id = cs.cashbox_id
  JOIN public.branches b       ON b.id  = cb.branch_id
  JOIN public.sales s          ON s.operation_id = cm.reference_id
  WHERE s.account_id IS DISTINCT FROM b.account_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (2.9-ventas): hay % movimientos de caja cuya sesión pertenece a un tenant distinto del de la venta (camino formulario) que los originó.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2.9): barrido global — cero movimientos de caja imputados a la caja de otro tenant en toda la base.';

  -- ══ (3.2) CANDADO DE POSICIÓN del guard en el core (D2) ═══════════════════
  -- Los cuerpos se leen SIN COMENTARIOS (se les quitan los `--` de línea antes
  -- de buscar): una MENCIÓN del identificador dentro de un comentario no es
  -- una llamada, y los comentarios de estos guards nombran justamente los
  -- literales que se buscan. Es el mismo falso positivo que la revisión
  -- adversarial le corrigió al chequeo (5a) del gate de ACLs.
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = '_c29_confirm_order_core';

  v_pos_guard := position('cash_optin_requires_open_session' in v_def);
  v_pos_prev  := position('cash_requires_session' in v_def);
  v_pos_write := position('INSERT INTO public.operation_idempotency' in v_def);

  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.2-literal): el cuerpo vivo de _c29_confirm_order_core no contiene el guard cash_optin_requires_open_session — el mismo literal que ya usa el formulario.';
  END IF;
  IF NOT (v_pos_prev < v_pos_guard AND v_pos_guard < v_pos_write) THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.2-posición): el guard debe caer DESPUÉS de cash_requires_session (%) y ANTES de la primera escritura, el INSERT de idempotencia (%); cayó en %.', v_pos_prev, v_pos_write, v_pos_guard;
  END IF;

  -- (3.8) los wrappers públicos heredan el guard: no lo tienen escrito.
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_quick_sale';
  IF position('cash_optin_requires_open_session' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.8-quick_sale): rpc_quick_sale no debería tener el guard escrito — lo HEREDA del core. Si aparece acá, alguien duplicó la validación en vez de reusarla.';
  END IF;

  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_confirm_sales_order';
  IF position('cash_optin_requires_open_session' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.8-confirm_sales_order): rpc_confirm_sales_order tampoco debería tener el guard escrito.';
  END IF;
  RAISE NOTICE 'PASS (3.2/3.8): el guard vive en el core, entre cash_requires_session y la primera escritura, y los dos wrappers públicos lo heredan sin tenerlo escrito.';

  -- ══ (3.3) CANDADO DE POSICIÓN del backstop en el helper ═══════════════════
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'c28_register_cash_movement';

  v_pos_guard := position('current_account_ids' in v_def);
  v_pos_write := position('INSERT INTO public.cash_movements' in v_def);

  IF v_pos_guard = 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.3-literal): el cuerpo vivo de c28_register_cash_movement no resuelve la cuenta por current_account_ids() — el backstop de tenant no está.';
  END IF;
  IF NOT (v_pos_guard < v_pos_write) THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.3-posición): el backstop debe caer ANTES del INSERT en cash_movements (%), cayó en %.', v_pos_write, v_pos_guard;
  END IF;
  IF position('is_account_writer' in v_def) <> 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.3-membresía): el backstop de la capa 2 usa MEMBRESÍA (current_account_ids), no is_account_writer — exigir permiso de escritura acá endurecería en silencio el rol del camino del formulario (D1 iii).';
  END IF;

  -- (3.9b) rpc_register_cash_movement sigue exigiendo permiso de ESCRITURA:
  -- el guard duplicado de la capa 2 no relaja su autorización.
  SELECT regexp_replace(pg_get_functiondef(p.oid), '--[^\n]*', '', 'g') INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_register_cash_movement';
  IF position('is_account_writer' in v_def) = 0 THEN
    RAISE EXCEPTION 'GATE TENANCY-CAJA FAILED (3.9b): rpc_register_cash_movement dejó de exigir is_account_writer — la capa 2 es un backstop de tenencia, no un reemplazo de la autorización.';
  END IF;
  RAISE NOTICE 'PASS (3.3/3.9b): el backstop de tenant precede al INSERT y usa membresía; rpc_register_cash_movement conserva su is_account_writer.';

  RAISE NOTICE 'GATE TENANCY-GUARD-CAJA-OUTBOX (h1) OK: sesión de caja ajena y de otra sucursal rechazadas por el POS (P0422) sin efectos parciales, backstop de tenant en el helper (P0401), POS legítimo y borrado con compensación intactos, saldo firmado recuperado y barrido global limpio.';
END $$;

-- ── Fase de cleanup ──────────────────────────────────────────────────────────
-- DO block SEPARADO que resuelve los ids por email en vez de heredar las
-- variables: así limpia también las corridas que se cortaron por alguno de los
-- caminos degrade-don't-fail (que hacen RETURN después de haber insertado los
-- anchors). Si el DO principal ABORTA, psql con ON_ERROR_STOP=1 corta antes de
-- llegar acá — pero en ese caso su transacción ya revirtió todo, incluidos los
-- anchors, así que no queda nada que limpiar.
-- Sin esto, la SEGUNDA corrida sobre la misma base aborta con
-- users_email_partial_key (el anchor usa un email fijo y un id nuevo, así que
-- el ON CONFLICT (id) DO NOTHING no lo cubre).
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users
  WHERE email IN ('tenancy-guard-caja-a@test.local',
                  'tenancy-guard-caja-b@test.local');

  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE TENANCY-CAJA: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  SELECT COALESCE(array_agg(DISTINCT account_id), ARRAY[]::uuid[]) INTO v_accounts
  FROM public.account_members WHERE user_id = ANY(v_users);

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements           WHERE account_id = ANY(v_accounts);
    DELETE FROM public.document_status_history  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.customer_account_movements m USING public.customer_accounts a
      WHERE m.customer_account_id = a.id AND a.account_id = ANY(v_accounts);
    DELETE FROM public.customer_accounts        WHERE account_id = ANY(v_accounts);
    DELETE FROM public.stock_movements          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sale_items               WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales                    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales_order_items i USING public.sales_orders o
      WHERE i.sales_order_id = o.id AND o.account_id = ANY(v_accounts);
    DELETE FROM public.sales_orders             WHERE account_id = ANY(v_accounts);
    -- Antes de borrar los events: las claves de idempotencia que escribe el
    -- dispatcher del outbox llevan operation_kind='event_consumer' y un
    -- user_id SENTINELA, no el del anchor, así que el DELETE por user_id de
    -- más abajo no las alcanza; y como operation_idempotency.event_id no tiene
    -- FK, quedarían apuntando a events ya borrados.
    DELETE FROM public.operation_idempotency
     WHERE operation_kind = 'event_consumer'
       AND event_id IN (SELECT id FROM public.events WHERE account_id = ANY(v_accounts));
    DELETE FROM public.events                   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products                 WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branches                 WHERE account_id = ANY(v_accounts);
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  -- email_logs.user_id es FK ON DELETE SET NULL: borrar el anchor NO borra la
  -- fila, la deja con user_id NULL y el recipient sintético adentro.
  DELETE FROM public.email_logs
   WHERE user_id = ANY(v_users)
      OR recipient IN ('tenancy-guard-caja-a@test.local',
                       'tenancy-guard-caja-b@test.local');
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE TENANCY-CAJA: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
