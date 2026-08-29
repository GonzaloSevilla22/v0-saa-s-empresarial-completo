-- =============================================================================
-- GATE: test_gastos_forma_pago.sql
-- CHANGE: gastos-forma-pago — grupos 2, 3, 4, 5 y 6 (el tramo de dinero)
--
-- Pedido textual del PO (2026-08-28): "Modificar Módulo Gastos para incluir
-- identificación del gasto, ejemplo efectivo, transferencia y que estos
-- movimientos concilien caja y banco".
--
-- Qué ejercita, con dos tenants sintéticos y sesión vía request.jwt.claims
-- (mismo molde que test_tenancy_guard_caja_outbox.sql):
--
--   (2.x) ESQUEMA — expenses.payment_method_id con su FK y su ON DELETE SET
--         NULL; el CHECK de cash_movements.movement_type ampliado a 8 tipos
--         con expense_reversal; las filas históricas intactas; un
--         movement_type fuera del conjunto sigue rechazado.
--
--   (3.x) ALTA (rpc_create_expense) — derivación del kind desde el catálogo
--         (P0404), rechazo de credit (P0400, D3), branch_id persistido con el
--         COALESCE de la venta (D6), opt-in de caja con las TRES condiciones
--         del servidor (P0422, D1), pata bancaria incondicional (D2), guard de
--         cuenta bancaria exigible condicionado a que la organización tenga
--         bancos (P0412, D5) y atomicidad.
--
--   (4.x) EDICIÓN (rpc_update_expense) — inmutabilidad del gasto con dinero
--         posteado (P0423, D11) y contrato tri-estado (D12).
--
--   (5.x) BORRADO (rpc_delete_expense) — compensación de las dos patas (D8),
--         con el CONTROL NEGATIVO del guard de signo invertido: sin él, un
--         guard copiado verbatim de rpc_delete_sale_operation deja pasar el
--         borrado en silencio y este gate quedaría verde por omisión.
--
--   (6.x) REPORTE — rpc_payment_method_report suma total_spent sin mover los
--         números de ventas y compras, y rpc_branch_report empieza a ver los
--         gastos (efecto colateral de D6, verificado y no supuesto).
--
-- ⚠️ REGLA DE ESTE GATE: se asserta el EFECTO (la fila del contra-movimiento,
-- el SQLSTATE exacto, el saldo), NUNCA "no hubo error". El bug que D8
-- describe —el guard `v_cash_amount > 0` copiado tal cual, que es falso para
-- todo gasto— produce exactamente un "no hubo error".
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
--
-- Cleanup: DO block separado al final que resuelve los ids por email, así
-- limpia también las corridas cortadas por un camino degrade-don't-fail.
-- =============================================================================


-- ═════════════════════ (2) ESQUEMA — columna, FK y CHECK ═════════════════════
DO $$
DECLARE
  v_data_type    text;
  v_is_nullable  text;
  v_confdeltype  "char";
  v_conname      text;
  v_condef       text;
  v_count        integer;
BEGIN
  -- (2.1a) expenses.payment_method_id existe, es uuid y es nullable
  SELECT data_type, is_nullable INTO v_data_type, v_is_nullable
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'expenses'
    AND column_name = 'payment_method_id';

  IF v_data_type IS NULL THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1a): public.expenses no tiene la columna payment_method_id — el gasto sigue siendo el único documento operativo que no dice con qué se pagó.';
  END IF;

  IF v_data_type <> 'uuid' THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1a): expenses.payment_method_id es % y tiene que ser uuid (espejo exacto de sales.payment_method_id).', v_data_type;
  END IF;

  IF v_is_nullable <> 'YES' THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1a): expenses.payment_method_id tiene que ser NULLABLE — los 175 gastos históricos quedan sin imputar, sin backfill (D7).';
  END IF;

  -- (2.1b) FK a payment_methods con ON DELETE SET NULL
  SELECT c.conname, c.confdeltype INTO v_conname, v_confdeltype
  FROM   pg_constraint c
  JOIN   pg_class      t ON t.oid = c.conrelid
  JOIN   pg_namespace  n ON n.oid = t.relnamespace
  JOIN   pg_class      f ON f.oid = c.confrelid
  WHERE  n.nspname = 'public' AND t.relname = 'expenses' AND c.contype = 'f'
    AND  f.relname = 'payment_methods'
    AND  c.conkey = ARRAY[(SELECT attnum FROM pg_attribute
                           WHERE attrelid = t.oid AND attname = 'payment_method_id')];

  IF v_conname IS NULL THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1b): expenses.payment_method_id no tiene FK a public.payment_methods.';
  END IF;

  -- confdeltype: 'n' = SET NULL
  IF v_confdeltype <> 'n' THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1b): la FK % tiene confdeltype=% y tiene que ser ON DELETE SET NULL (n) — borrar una forma de pago no puede llevarse puesto el gasto.', v_conname, v_confdeltype;
  END IF;

  -- (2.1c) índice (account_id, payment_method_id)
  SELECT COUNT(*) INTO v_count
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND tablename = 'expenses'
    AND  indexdef LIKE '%account_id%' AND indexdef LIKE '%payment_method_id%';

  IF v_count = 0 THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1c): falta el índice (account_id, payment_method_id) en public.expenses — el filtro del listado y el reporte lo recorren.';
  END IF;

  -- (2.1d) el CHECK de cash_movements.movement_type incluye expense_reversal
  SELECT pg_get_constraintdef(c.oid) INTO v_condef
  FROM   pg_constraint c
  JOIN   pg_class     t ON t.oid = c.conrelid
  JOIN   pg_namespace n ON n.oid = t.relnamespace
  WHERE  n.nspname = 'public' AND t.relname = 'cash_movements'
    AND  c.conname = 'cash_movements_movement_type_check';

  IF v_condef IS NULL THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1d): no existe cash_movements_movement_type_check.';
  END IF;

  IF position('expense_reversal' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1d): el CHECK de cash_movements.movement_type no acepta expense_reversal — el borrado de un gasto en efectivo no tiene con qué compensar (D9). Definición viva: %', v_condef;
  END IF;

  -- Los 7 tipos previos siguen aceptados (la ampliación es aditiva, no un reemplazo)
  IF position('''sale''' in v_condef) = 0 OR position('''purchase_payment''' in v_condef) = 0
     OR position('''expense''' in v_condef) = 0 OR position('''advance''' in v_condef) = 0
     OR position('''withdrawal''' in v_condef) = 0 OR position('''sale_reversal''' in v_condef) = 0
     OR position('''adjustment''' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.1d): la ampliación del CHECK perdió alguno de los 7 tipos previos. Definición viva: %', v_condef;
  END IF;

  RAISE NOTICE 'PASS (2.1): expenses.payment_method_id uuid/nullable con FK ON DELETE SET NULL + índice, y el CHECK de cash_movements acepta los 8 tipos.';
END $$;


-- ═══ (2.3) TRIANGULACIÓN de esquema — históricos intactos y tipo inválido ════
DO $$
DECLARE
  v_count      integer;
  v_rejected   boolean;
  v_user       uuid := gen_random_uuid();
  v_account    uuid;
  v_branch     uuid;
  v_cashbox    uuid;
  v_session    uuid;
BEGIN
  -- (2.3a) ninguna fila histórica de expenses quedó con imputación inventada:
  -- toda fila creada ANTES de que exista la columna tiene payment_method_id
  -- NULL. Se mide sobre las filas cuya created_at es anterior a la de la
  -- columna misma — en una base recién reseteada el conjunto puede ser vacío,
  -- y eso no invalida el assert: lo que se prohíbe es un backfill (D7).
  SELECT COUNT(*) INTO v_count
  FROM   public.expenses
  WHERE  payment_method_id IS NOT NULL
    AND  created_at < (SELECT COALESCE(MAX(created_at), now())
                       FROM public.expenses WHERE payment_method_id IS NULL);

  -- No se puede exigir 0 en una base con tráfico del propio gate; lo que se
  -- exige es que la MIGRACIÓN no haya escrito nada: ninguna fila con
  -- payment_method_id y sin usuario que la haya imputado no existe como
  -- concepto. El control real de "sin backfill" es el (2.3a-bis) de abajo.
  RAISE NOTICE 'INFO (2.3a): % gastos con forma de pago imputada anteriores al último gasto sin imputar.', v_count;

  -- (2.3a-bis) CONTROL DE NO-BACKFILL: la migración no puede contener ningún
  -- UPDATE sobre expenses.payment_method_id. Se verifica sobre el efecto: si
  -- existiera un backfill, TODOS los gastos tendrían forma de pago. En una
  -- base recién reseteada hay 0 gastos, así que el assert se expresa al revés:
  -- no puede haber ningún gasto con payment_method_id que no tenga user_id
  -- (o sea, escrito por algo que no fue un usuario).
  SELECT COUNT(*) INTO v_count
  FROM   public.expenses
  WHERE  payment_method_id IS NOT NULL AND user_id IS NULL;

  IF v_count > 0 THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.3a): % gastos con forma de pago imputada y sin user_id — huele a backfill, que D7 prohíbe explícitamente.', v_count;
  END IF;

  -- (2.3b) los movimientos de caja históricos siguen siendo válidos: el CHECK
  -- ampliado no invalida ninguna fila existente (se valida por construcción —
  -- si alguna fila violara el CHECK, el ADD CONSTRAINT habría abortado la
  -- migración). Se deja el conteo como evidencia.
  SELECT COUNT(*) INTO v_count FROM public.cash_movements;
  RAISE NOTICE 'INFO (2.3b): % movimientos de caja sobrevivieron a la ampliación del CHECK.', v_count;

  -- (2.3c) un movement_type fuera del conjunto ampliado SIGUE siendo rechazado.
  -- Se necesita una sesión real (FK NOT NULL), así que se arma un anchor mínimo.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'gastos-forma-pago-check@test.local',
          now(), now(), jsonb_build_object('name', 'Gate Gastos CHECK'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE GASTOS-FORMA-PAGO (2.3c): no se pudo provisionar el anchor del CHECK — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch  FROM public.branches  WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox FROM public.cashboxes WHERE branch_id  = v_branch  ORDER BY created_at LIMIT 1;

  IF v_cashbox IS NULL THEN
    RAISE NOTICE 'GATE GASTOS-FORMA-PAGO (2.3c): sin caja sembrada para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox, 'open', 0, v_user) RETURNING id INTO v_session;

  v_rejected := false;
  BEGIN
    INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by)
    VALUES (v_session, 100, 'tip', 100, v_user);
  EXCEPTION
    WHEN check_violation THEN v_rejected := true;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.3c): el CHECK ampliado aceptó movement_type=''tip'' — la ampliación reemplazó el conjunto en vez de extenderlo.';
  END IF;

  -- (2.3d) expense_reversal SÍ es aceptado por el CHECK (control positivo del
  -- mismo assert: sin él, un CHECK que rechazara todo también pasaría 2.3c).
  INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by)
  VALUES (v_session, 100, 'expense_reversal', 100, v_user);

  -- (2.3e) idempotencia del CHECK: re-emitir el DROP+ADD deja exactamente una
  -- constraint con ese nombre.
  SELECT COUNT(*) INTO v_count
  FROM   pg_constraint c
  JOIN   pg_class     t ON t.oid = c.conrelid
  JOIN   pg_namespace n ON n.oid = t.relnamespace
  WHERE  n.nspname = 'public' AND t.relname = 'cash_movements'
    AND  c.conname = 'cash_movements_movement_type_check';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS-FORMA-PAGO FAILED (2.3e): hay % constraints cash_movements_movement_type_check (esperaba 1).', v_count;
  END IF;

  RAISE NOTICE 'PASS (2.3): históricos intactos, ''tip'' rechazado, ''expense_reversal'' aceptado, CHECK único.';
END $$;


-- ── Cleanup del anchor del CHECK (2.3c) ─────────────────────────────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('gastos-forma-pago-check@test.local');

  IF array_length(v_users, 1) IS NULL THEN RETURN; END IF;

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
    DELETE FROM public.expenses          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods   WHERE account_id = ANY(v_accounts);
    SET session_replication_role = replica;
    DELETE FROM public.branches          WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts        WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles        WHERE id = ANY(v_users);
  DELETE FROM public.email_logs      WHERE user_id = ANY(v_users)
                                        OR recipient IN ('gastos-forma-pago-check@test.local');
  DELETE FROM auth.users             WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE GASTOS-FORMA-PAGO: cleanup del anchor de esquema completo.';
END $$;


-- ═════════════════ (3) ALTA — rpc_create_expense ════════════════════════════
-- Fixtures de los grupos 3, 4, 5 y 6. Se crean acá y los bloques siguientes
-- los re-resuelven por nombre/email (las variables de un DO no sobreviven al
-- bloque), así que cada bloque corre solo.
--   Tenant A ── el que opera. Tiene banco (para el guard P0412 de D5).
--   Tenant B ── el ajeno. Su caja y su banco son las víctimas de los asserts
--               de tenencia.
--   Tenant C ── SIN ninguna cuenta bancaria: el caso complementario de D5
--               (33 de 37 organizaciones de prod están así).
--   Usuario D ── miembro de A SIN rol de escritura.
DO $$
DECLARE
  v_email_a       text := 'gastos-forma-pago-a@test.local';
  v_email_b       text := 'gastos-forma-pago-b@test.local';
  v_email_c       text := 'gastos-forma-pago-c@test.local';
  v_email_d       text := 'gastos-forma-pago-d@test.local';
  v_user_a        uuid := gen_random_uuid();
  v_user_b        uuid := gen_random_uuid();
  v_user_c        uuid := gen_random_uuid();
  v_user_d        uuid := gen_random_uuid();
  v_account_a     uuid;
  v_account_b     uuid;
  v_account_c     uuid;
  v_branch_a1     uuid;
  v_branch_a2     uuid;
  v_branch_a3     uuid;
  v_branch_b      uuid;
  v_cashbox_a1    uuid;
  v_cashbox_a2    uuid;
  v_cashbox_a3    uuid;
  v_cashbox_a4    uuid;
  v_cashbox_b     uuid;
  v_ba_a          uuid;
  v_ba_b          uuid;
  v_product_a     uuid;
BEGIN
  -- Anchors
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_a, 'authenticated', 'authenticated', v_email_a, now(), now(),
          jsonb_build_object('name', 'Gate Gastos A'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_b, 'authenticated', 'authenticated', v_email_b, now(), now(),
          jsonb_build_object('name', 'Gate Gastos B'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_c, 'authenticated', 'authenticated', v_email_c, now(), now(),
          jsonb_build_object('name', 'Gate Gastos C'))
  ON CONFLICT (id) DO NOTHING;
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_d, 'authenticated', 'authenticated', v_email_d, now(), now(),
          jsonb_build_object('name', 'Gate Gastos D'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_c FROM public.account_members WHERE user_id = v_user_c ORDER BY created_at LIMIT 1;

  IF v_account_a IS NULL OR v_account_b IS NULL OR v_account_c IS NULL
     OR v_account_a = v_account_b OR v_account_a = v_account_c THEN
    RAISE NOTICE 'GATE GASTOS-FORMA-PAGO (setup): no se pudieron provisionar 3 tenants independientes — degradando sin abortar.';
    RETURN;
  END IF;

  -- Usuario D: miembro de A SIN rol de escritura.
  -- ⚠️ Hay que RETIRARLE su propia cuenta auto-provisionada, donde es owner.
  -- Todas las RPCs del proyecto resuelven el tenant con
  -- `SELECT cai FROM current_account_ids() LIMIT 1`, así que si D conserva su
  -- cuenta propia el guard is_account_writer se evalúa sobre ESA y pasa — y el
  -- assert quedaría verde midiendo otra cosa.
  DELETE FROM public.account_members WHERE user_id = v_user_d;
  INSERT INTO public.account_members (account_id, user_id, role)
  VALUES (v_account_a, v_user_d, 'member');

  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_b  FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;

  IF v_branch_a1 IS NULL OR v_branch_b IS NULL THEN
    RAISE NOTICE 'GATE GASTOS-FORMA-PAGO (setup): sucursales no sembradas — degradando sin abortar.';
    RETURN;
  END IF;

  -- Segunda sucursal de A: sostiene el assert de "sesión de caja de OTRA
  -- sucursal del mismo tenant" (el que sólo la capa 1 del opt-in puede cubrir).
  INSERT INTO public.branches (account_id, name) VALUES (v_account_a, '__gate_gfp_branch_a2__')
  RETURNING id INTO v_branch_a2;

  -- Tercera sucursal de A, SIN caja: es la que se cierra en el assert 3.5d.
  -- No puede ser la a2 — trg_guard_branch_decommission (P0428, del change
  -- sucursal-guard-vaciado-auditoria) prohíbe cerrar una sucursal con una
  -- sesión de caja abierta, y la a2 tiene la suya para el assert del opt-in.
  INSERT INTO public.branches (account_id, name) VALUES (v_account_a, '__gate_gfp_branch_a3__')
  RETURNING id INTO v_branch_a3;

  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_gfp_cashbox_a1__')
  RETURNING id INTO v_cashbox_a1;
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a2, '__gate_gfp_cashbox_a2__')
  RETURNING id INTO v_cashbox_a2;
  -- Caja del control negativo de 5.4b: su sesión se CIERRA en medio del assert,
  -- así que no puede compartirse con nadie.
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_gfp_cashbox_a3__')
  RETURNING id INTO v_cashbox_a3;
  -- Caja con la sesión CERRADA del assert 3.7c (una caja aparte: la sesión
  -- cerrada no puede convivir con los asserts que necesitan la suya abierta).
  INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_a1, '__gate_gfp_cashbox_a4__')
  RETURNING id INTO v_cashbox_a4;
  SELECT id INTO v_cashbox_b FROM public.cashboxes WHERE branch_id = v_branch_b ORDER BY created_at LIMIT 1;
  IF v_cashbox_b IS NULL THEN
    INSERT INTO public.cashboxes (branch_id, name) VALUES (v_branch_b, '__gate_gfp_cashbox_b__')
    RETURNING id INTO v_cashbox_b;
  END IF;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a1, 'open', 10000, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a2, 'open', 0, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_a4, 'closed', 0, v_user_a);
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_b, 'open', 0, v_user_b);

  -- Bancos: A y B tienen; C NO tiene ninguna (caso complementario de D5).
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_a, '__gate_gfp_bank_a__', 'ARS', 100000) RETURNING id INTO v_ba_a;
  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_b, '__gate_gfp_bank_b__', 'ARS', 0) RETURNING id INTO v_ba_b;

  -- Forma de pago de A con destino bancario POR DEFECTO configurado: sostiene
  -- el escenario "El destino por defecto de la forma de pago evita el rechazo".
  -- El catálogo sembrado tiene los 7 kinds con bank_account_id NULL (0/37 en
  -- prod), así que hace falta una entrada propia.
  INSERT INTO public.payment_methods (account_id, name, kind, is_active, bank_account_id)
  VALUES (v_account_a, '__gate_gfp_pm_transfer_default__', 'transfer', TRUE, v_ba_a);

  -- Forma de pago INACTIVA y forma de pago BORRADA de A (asserts de 3.3).
  INSERT INTO public.payment_methods (account_id, name, kind, is_active)
  VALUES (v_account_a, '__gate_gfp_pm_inactive__', 'other', FALSE);
  INSERT INTO public.payment_methods (account_id, name, kind, is_active, deleted_at)
  VALUES (v_account_a, '__gate_gfp_pm_deleted__', 'other', TRUE, now());

  -- Producto con stock: lo consume el CONTROL NEGATIVO de no-regresión (3.12),
  -- que registra una VENTA por transferencia sin cuenta destino y exige que
  -- siga procediendo sin movimiento — la prueba de que el guard P0412 quedó en
  -- el caller de gasto y no en el helper compartido.
  INSERT INTO public.products (user_id, account_id, name, price, cost, sku)
  VALUES (v_user_a, v_account_a, '__gate_gfp_product__', 500, 200, 'GATE-GFP-1')
  RETURNING id INTO v_product_a;
  INSERT INTO public.branch_stock (account_id, branch_id, product_id, quantity)
  VALUES (v_account_a, v_branch_a1, v_product_a, 100)
  ON CONFLICT (branch_id, product_id) DO UPDATE SET quantity = 100;

  INSERT INTO public.cost_centers (account_id, name, code, is_active)
  VALUES (v_account_a, '__gate_gfp_cc_a__', 'GFP-A', TRUE);
  INSERT INTO public.cost_centers (account_id, name, code, is_active)
  VALUES (v_account_b, '__gate_gfp_cc_b__', 'GFP-B', TRUE);

  RAISE NOTICE 'SETUP OK: 3 tenants (A opera, B ajeno, C sin bancos) + usuario D sin rol de escritura.';
END $$;


-- ── (3.1-3.5) alta básica, derivación del kind, credit, sucursal ─────────────
DO $$
DECLARE
  v_user_a     uuid;  v_user_d   uuid;
  v_account_a  uuid;  v_account_b uuid;
  v_branch_a1  uuid;  v_branch_a2 uuid;  v_branch_a3 uuid;  v_branch_b uuid;
  v_pm_other_a uuid;  v_pm_credit_a uuid; v_pm_other_b uuid;
  v_pm_inactive uuid; v_pm_deleted uuid;
  v_cc_a       uuid;  v_cc_b uuid;
  v_result     jsonb;
  v_exp_id     uuid;
  v_row        RECORD;
  v_count      integer;
  v_sqlstate   text;
  v_rejected   boolean;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'gastos-forma-pago-a@test.local';
  SELECT id INTO v_user_d FROM auth.users WHERE email = 'gastos-forma-pago-d@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE GASTOS (3): sin anchor A — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members
    WHERE user_id = (SELECT id FROM auth.users WHERE email = 'gastos-forma-pago-b@test.local') ORDER BY created_at LIMIT 1;
  IF v_account_a IS NULL OR v_account_b IS NULL THEN RAISE NOTICE 'GATE GASTOS (3): setup incompleto — degradando.'; RETURN; END IF;

  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a AND name NOT LIKE '__gate_gfp_branch%' ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a2 FROM public.branches WHERE account_id = v_account_a AND name = '__gate_gfp_branch_a2__';
  SELECT id INTO v_branch_a3 FROM public.branches WHERE account_id = v_account_a AND name = '__gate_gfp_branch_a3__';
  SELECT id INTO v_branch_b  FROM public.branches WHERE account_id = v_account_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_pm_other_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'other' AND is_active AND deleted_at IS NULL AND name NOT LIKE '__gate_gfp%' LIMIT 1;
  SELECT id INTO v_pm_credit_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'credit' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_other_b FROM public.payment_methods WHERE account_id = v_account_b AND kind = 'other' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_inactive FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_gfp_pm_inactive__';
  SELECT id INTO v_pm_deleted  FROM public.payment_methods WHERE account_id = v_account_a AND name = '__gate_gfp_pm_deleted__';
  SELECT id INTO v_cc_a FROM public.cost_centers WHERE account_id = v_account_a AND name = '__gate_gfp_cc_a__';
  SELECT id INTO v_cc_b FROM public.cost_centers WHERE account_id = v_account_b AND name = '__gate_gfp_cc_b__';

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE GASTOS (3): auth.uid() no resuelve al anchor A — degradando.';
    RETURN;
  END IF;

  -- ═══ (3.1) alta SIN forma de pago: persiste y NO toca ningún libro ════════
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 1500, p_date => public.reporting_local_today(),
    p_description => 'gate 3.1'
  );
  v_exp_id := (v_result->>'expense_id')::uuid;

  SELECT * INTO v_row FROM public.expenses WHERE id = v_exp_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1): el alta sin forma de pago no persistió el gasto.';
  END IF;
  IF v_row.payment_method_id IS NOT NULL THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1): el gasto sin forma de pago quedó imputado a % — un gasto sin imputación es válido y tiene que quedar en NULL.', v_row.payment_method_id;
  END IF;
  IF v_row.account_id <> v_account_a THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1): el gasto quedó en la cuenta % y el tenant se resuelve desde la SESIÓN (esperaba %).', v_row.account_id, v_account_a;
  END IF;

  -- (3.5a) sin sucursal informada toma la default de la cuenta (D6, RN-93)
  IF v_row.branch_id IS DISTINCT FROM public.c26_default_branch(v_account_a) THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.5a): el gasto sin sucursal informada quedó con branch_id % y esperaba la default % — RN-93 exige branch_id en todo gasto y el guard de sucursal del opt-in de caja lo necesita.', v_row.branch_id, public.c26_default_branch(v_account_a);
  END IF;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_exp_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1): un gasto sin forma de pago escribió % movimientos de caja.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1): un gasto sin forma de pago escribió % movimientos bancarios.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.1/3.5a): alta sin forma de pago persiste con la sucursal default y sin tocar libros.';

  -- ═══ (3.1b) alta CON forma de pago activa de la cuenta (kind other) ═══════
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 2500, p_date => public.reporting_local_today(),
    p_description => 'gate 3.1b', p_cost_center_id => v_cc_a, p_payment_method_id => v_pm_other_a
  );
  v_exp_id := (v_result->>'expense_id')::uuid;

  SELECT * INTO v_row FROM public.expenses WHERE id = v_exp_id;
  IF v_row.payment_method_id IS DISTINCT FROM v_pm_other_a THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1b): payment_method_id quedó en % y esperaba %.', v_row.payment_method_id, v_pm_other_a;
  END IF;
  IF v_row.cost_center_id IS DISTINCT FROM v_cc_a THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1b): cost_center_id quedó en % y esperaba % — el alta no puede perder el contexto que recibe.', v_row.cost_center_id, v_cc_a;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_exp_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1b): kind=other escribió % movimientos de caja — other es una etiqueta sin efecto en libros.', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.1b): kind=other escribió % movimientos bancarios.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.1b): alta con forma de pago other imputa, conserva el centro de costo y no mueve libros.';

  -- ═══ (3.3) derivación del kind desde el catálogo → P0404 en los 3 casos ═══
  --   ajena · inactiva · borrada. Predicado copiado literal del baseline de
  --   rpc_create_sale_operation_v2 (id + account_id + is_active + deleted_at).
  FOR v_row IN
    SELECT unnest(ARRAY[v_pm_other_b, v_pm_inactive, v_pm_deleted]) AS pm,
           unnest(ARRAY['de otra cuenta', 'inactiva', 'borrada'])   AS caso
  LOOP
    SELECT COUNT(*) INTO v_count FROM public.expenses WHERE account_id = v_account_a;
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_create_expense(
        p_category => 'Servicios', p_amount => 100, p_date => public.reporting_local_today(),
        p_payment_method_id => v_row.pm
      );
    EXCEPTION WHEN OTHERS THEN
      v_sqlstate := SQLSTATE;
      IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.3): una forma de pago % fue aceptada — el predicado de derivación del kind tiene que rechazarla con P0404.', v_row.caso;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.expenses WHERE account_id = v_account_a AND category = 'Servicios' AND amount = 100;
    IF v_count <> 0 THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.3-efectos): el rechazo por forma de pago % dejó % filas nuevas en expenses.', v_row.caso, v_count;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (3.3): forma de pago ajena, inactiva y borrada rechazadas con P0404, sin fila nueva.';

  -- ═══ (3.4) [OQ-3] kind = credit → P0400, con el texto que redirige ════════
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 999, p_date => public.reporting_local_today(),
      p_payment_method_id => v_pm_credit_a
    );
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
    IF SQLSTATE = 'P0400' AND position('compra a proveedor' in SQLERRM) > 0 THEN v_rejected := true;
    ELSIF SQLSTATE = 'P0400' THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.4-mensaje): credit se rechaza con P0400 pero el mensaje no redirige a la compra a proveedor: "%"', SQLERRM;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.4): un gasto con forma de pago kind=credit fue aceptado — expenses no tiene contraparte (ni supplier_id ni client_id), no hay cuenta corriente que cargar (D3).';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.expenses WHERE account_id = v_account_a AND amount = 999;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.4-efectos): el rechazo de credit dejó % filas en expenses.', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.4): kind=credit rechazado con P0400 y el mensaje redirige a la compra a proveedor.';

  -- ═══ (3.5b) con sucursal informada la respeta ════════════════════════════
  v_result := public.rpc_create_expense(
    p_category => 'Alquiler', p_amount => 3000, p_date => public.reporting_local_today(),
    p_branch_id => v_branch_a2
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  SELECT * INTO v_row FROM public.expenses WHERE id = v_exp_id;
  IF v_row.branch_id IS DISTINCT FROM v_branch_a2 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.5b): la sucursal informada no se respetó (quedó %, esperaba %).', v_row.branch_id, v_branch_a2;
  END IF;

  -- (3.5c) sucursal AJENA → P0404
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Alquiler', p_amount => 31, p_date => public.reporting_local_today(),
      p_branch_id => v_branch_b
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0404' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.5c): se aceptó una sucursal de otra cuenta.';
  END IF;

  -- (3.5d) sucursal CERRADA → P0422
  UPDATE public.branches SET status = 'closed' WHERE id = v_branch_a3;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Alquiler', p_amount => 32, p_date => public.reporting_local_today(),
      p_branch_id => v_branch_a3
    );
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0422' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  UPDATE public.branches SET status = 'active' WHERE id = v_branch_a3;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.5d): se aceptó una sucursal cerrada — el predicado se copia de rpc_create_sale_operation_v2, que la rechaza con P0422.';
  END IF;
  RAISE NOTICE 'PASS (3.5): sucursal default, informada, ajena (P0404) y cerrada (P0422).';

  -- ═══ (3.2b) miembro SIN rol de escritura → P0401 ═════════════════════════
  IF v_user_d IS NOT NULL THEN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_d::text, 'role', 'authenticated')::text, true);
    SELECT COUNT(*) INTO v_count FROM public.expenses WHERE account_id = v_account_a;
    v_rejected := false;
    BEGIN
      PERFORM public.rpc_create_expense(
        p_category => 'Servicios', p_amount => 77, p_date => public.reporting_local_today()
      );
    EXCEPTION WHEN OTHERS THEN
      IF SQLSTATE = 'P0401' THEN v_rejected := true; ELSE RAISE; END IF;
    END;
    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.2b): un miembro sin rol de escritura creó un gasto — un SECURITY DEFINER deja la RLS fuera de juego, la autorización se re-establece explícitamente.';
    END IF;
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
    RAISE NOTICE 'PASS (3.2b): el miembro sin rol de escritura es rechazado con P0401.';
  END IF;
END $$;


-- ── (3.6-3.8) PATA DE CAJA — opt-in con las tres condiciones del servidor ────
-- 🛑 Tramo de severidad ALTA: acá empieza la escritura de dinero.
-- El bloque de la RPC se copia VERBATIM del baseline de
-- rpc_create_sale_operation_v2 con las dos únicas adaptaciones que D1 autoriza:
-- p_date declarado `date` y comparado DIRECTO contra reporting_local_today(), y
-- c28_register_cash_movement(sesión, -importe, 'expense', id_del_gasto).
DO $$
DECLARE
  v_user_a      uuid;  v_user_b uuid;
  v_account_a   uuid;  v_account_b uuid;
  v_branch_a1   uuid;  v_branch_a2 uuid;
  v_session_a1  uuid;  v_session_a2 uuid;  v_session_a4_closed uuid;  v_session_b uuid;
  v_pm_cash_a   uuid;  v_pm_transfer_a uuid;  v_pm_transfer_default uuid;
  v_result      jsonb; v_exp_id uuid;
  v_count       integer; v_count_before integer;
  v_amount      numeric; v_amount_before numeric;
  v_balance     numeric;
  v_mov         RECORD;
  v_rejected    boolean;
  v_sqlstate    text;
  v_caso        text;
  v_n           integer;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'gastos-forma-pago-a@test.local';
  SELECT id INTO v_user_b FROM auth.users WHERE email = 'gastos-forma-pago-b@test.local';
  IF v_user_a IS NULL THEN RAISE NOTICE 'GATE GASTOS (3.6): sin anchor A — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members WHERE user_id = v_user_b ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a AND name NOT LIKE '__gate_gfp_branch%' ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a2 FROM public.branches WHERE account_id = v_account_a AND name = '__gate_gfp_branch_a2__';
  SELECT cs.id INTO v_session_a1 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_gfp_cashbox_a1__' AND cs.status = 'open';
  SELECT cs.id INTO v_session_a2 FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_gfp_cashbox_a2__' AND cs.status = 'open';
  SELECT cs.id INTO v_session_a4_closed FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    WHERE cb.name = '__gate_gfp_cashbox_a4__' AND cs.status = 'closed';
  SELECT cs.id INTO v_session_b FROM public.cash_sessions cs JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches b ON b.id = cb.branch_id
    WHERE b.account_id = v_account_b AND cs.status = 'open' LIMIT 1;
  SELECT id INTO v_pm_cash_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_transfer_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' AND is_active AND deleted_at IS NULL AND name NOT LIKE '__gate_gfp%' LIMIT 1;
  -- Transferencia CON destino bancario por defecto: la usa el caso "kind no
  -- efectivo" de 3.7b. Con la transferencia SIN destino, el guard P0412 de D5
  -- —que corre antes del INSERT, como toda validación— dispararía primero y el
  -- assert mediría otra cosa. La condición que se quiere ejercitar acá es la
  -- PRIMERA del opt-in de caja, no la bancaria.
  SELECT id INTO v_pm_transfer_default FROM public.payment_methods WHERE name = '__gate_gfp_pm_transfer_default__';

  IF v_session_a1 IS NULL OR v_session_a2 IS NULL OR v_session_a4_closed IS NULL
     OR v_session_b IS NULL OR v_pm_cash_a IS NULL OR v_pm_transfer_a IS NULL
     OR v_pm_transfer_default IS NULL THEN
    RAISE NOTICE 'GATE GASTOS (3.6): fixtures de caja incompletos — degradando.';
    RETURN;
  END IF;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE GASTOS (3.6): auth.uid() no resuelve — degradando.'; RETURN;
  END IF;

  -- ═══ (3.6) CAMINO FELIZ: efectivo + sesión abierta de la sucursal + hoy ═══
  SELECT COALESCE(SUM(amount), 0) INTO v_amount_before
  FROM public.cash_movements WHERE session_id = v_session_a1;

  v_result := public.rpc_create_expense(
    p_category => 'Insumos', p_amount => 1200, p_date => public.reporting_local_today(),
    p_description => 'gate 3.6', p_payment_method_id => v_pm_cash_a,
    p_cash_session_id => v_session_a1
  );
  v_exp_id := (v_result->>'expense_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_exp_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.6): el gasto en efectivo escribió % movimientos de caja, esperaba exactamente 1. El tipo ''expense'' está aceptado por el CHECK desde C-28 y nunca tuvo un productor: este change lo activa.', v_count;
  END IF;

  SELECT * INTO v_mov FROM public.cash_movements WHERE reference_id = v_exp_id;
  IF v_mov.movement_type <> 'expense' THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.6): el movimiento quedó con movement_type=%, esperaba ''expense''.', v_mov.movement_type;
  END IF;
  IF v_mov.amount <> -1200 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.6): el movimiento quedó con amount=%, esperaba -1200 (egreso, signo NEGATIVO — lo fija el validador de signo de backend/schemas/cash.py).', v_mov.amount;
  END IF;
  IF v_mov.session_id <> v_session_a1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.6): el movimiento fue a la sesión % y esperaba la informada %.', v_mov.session_id, v_session_a1;
  END IF;

  SELECT COALESCE(SUM(amount), 0) INTO v_amount FROM public.cash_movements WHERE session_id = v_session_a1;
  IF v_amount <> v_amount_before - 1200 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.6-saldo): la suma de movimientos de la sesión pasó de % a %, esperaba % — el saldo posterior tiene que DISMINUIR en el importe del gasto.', v_amount_before, v_amount, v_amount_before - 1200;
  END IF;
  RAISE NOTICE 'PASS (3.6): gasto en efectivo de hoy con caja abierta escribe 1 movimiento ''expense'' de -1200 vinculado al gasto, y el saldo baja.';

  -- ═══ (3.7a) cash_session_id NULO = no-op, aun con kind cash ══════════════
  v_result := public.rpc_create_expense(
    p_category => 'Insumos', p_amount => 1300, p_date => public.reporting_local_today(),
    p_payment_method_id => v_pm_cash_a
  );
  v_exp_id := (v_result->>'expense_id')::uuid;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = v_exp_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.7a): sin p_cash_session_id el alta escribió % movimientos — la ausencia es un NO-OP (D1: el opt-in nunca puede bloquear el registro del gasto).', v_count;
  END IF;

  -- (3.7a-bis) el gasto RETROACTIVO sin sesión se registra normalmente: el
  -- registro del gasto NUNCA queda bloqueado por el estado de la caja.
  v_result := public.rpc_create_expense(
    p_category => 'Insumos', p_amount => 1350,
    p_date => public.reporting_local_today() - 1,
    p_payment_method_id => v_pm_cash_a
  );
  IF (v_result->>'expense_id') IS NULL THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.7a-bis): un gasto retroactivo en efectivo SIN sesión de caja no se pudo registrar.';
  END IF;
  RAISE NOTICE 'PASS (3.7a): sin sesión informada el alta es no-op de caja, y el gasto retroactivo se registra igual.';

  -- ═══ (3.7b-e) las tres condiciones del servidor rechazan con P0422 ═══════
  --   b) kind no efectivo con sesión informada
  --   c) sesión CERRADA
  --   d) sesión abierta de OTRA SUCURSAL del mismo tenant
  --   e) fecha anterior a hoy
  FOR v_caso, v_n IN
    SELECT * FROM (VALUES ('kind no efectivo', 1), ('sesión cerrada', 2),
                          ('sesión de otra sucursal', 3), ('fecha de ayer', 4)) t(c, n)
  LOOP
    SELECT COUNT(*) INTO v_count_before FROM public.expenses WHERE account_id = v_account_a;
    v_rejected := false;
    v_sqlstate := NULL;
    BEGIN
      IF v_n = 1 THEN
        PERFORM public.rpc_create_expense(
          p_category => 'Insumos', p_amount => 141, p_date => public.reporting_local_today(),
          p_payment_method_id => v_pm_transfer_default, p_cash_session_id => v_session_a1);
      ELSIF v_n = 2 THEN
        PERFORM public.rpc_create_expense(
          p_category => 'Insumos', p_amount => 142, p_date => public.reporting_local_today(),
          p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_a4_closed);
      ELSIF v_n = 3 THEN
        PERFORM public.rpc_create_expense(
          p_category => 'Insumos', p_amount => 143, p_date => public.reporting_local_today(),
          p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_a2);
      ELSE
        PERFORM public.rpc_create_expense(
          p_category => 'Insumos', p_amount => 144, p_date => public.reporting_local_today() - 1,
          p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_a1);
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_sqlstate := SQLSTATE;
      IF SQLSTATE = 'P0422' THEN v_rejected := true; ELSE RAISE; END IF;
    END;

    IF NOT v_rejected THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.7 %): el opt-in de caja aceptó el caso — las TRES condiciones se verifican en el SERVIDOR, nunca se confía en la UI (D1).', v_caso;
    END IF;

    SELECT COUNT(*) INTO v_count_before FROM public.expenses
    WHERE account_id = v_account_a AND amount IN (141, 142, 143, 144);
    IF v_count_before <> 0 THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.7 %-efectos): el rechazo dejó % filas en expenses — el RAISE de la pata de caja corre DESPUÉS del INSERT y tiene que revertirlo (atomicidad, task 3.13).', v_caso, v_count_before;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS (3.7b-e): kind no efectivo, sesión cerrada, sesión de otra sucursal y fecha de ayer rechazados con P0422, sin fila nueva.';

  -- ═══ (3.7f) ZONA HORARIA — el resultado NO depende del TimeZone de la sesión
  -- ⚠️ Éste es el caso que el "gasto de hoy a las 15:00" NO detecta: a las
  -- 18:00 UTC cae en el mismo día calendario y pasaría igual con un
  -- `p_date timestamptz` castado con `::date`. Con p_date DATE el resultado es
  -- invariante por construcción; con timestamptz::date diverge en la franja
  -- 21:00-23:59 ART, que es justo cuando el microemprendedor cierra el día.
  PERFORM set_config('TimeZone', 'UTC', true);
  v_result := public.rpc_create_expense(
    p_category => 'Insumos', p_amount => 151, p_date => public.reporting_local_today(),
    p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_a1);
  IF (v_result->>'expense_id') IS NULL THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.7f-UTC): el alta con TimeZone=UTC no devolvió expense_id.';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = (v_result->>'expense_id')::uuid;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.7f-UTC): con TimeZone=UTC el gasto de HOY no registró su movimiento de caja (% movimientos).', v_count;
  END IF;

  PERFORM set_config('TimeZone', 'America/Argentina/Mendoza', true);
  v_result := public.rpc_create_expense(
    p_category => 'Insumos', p_amount => 152, p_date => public.reporting_local_today(),
    p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_a1);
  SELECT COUNT(*) INTO v_count FROM public.cash_movements WHERE reference_id = (v_result->>'expense_id')::uuid;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.7f-ART): con TimeZone=America/Argentina/Mendoza el mismo alta no registró su movimiento — el resultado NO puede depender de la zona de la sesión (D1).';
  END IF;
  PERFORM set_config('TimeZone', 'UTC', true);
  RAISE NOTICE 'PASS (3.7f): idéntica aceptación bajo TimeZone=UTC y TimeZone=America/Argentina/Mendoza.';

  -- ═══ (3.8) sesión de caja de OTRA ORGANIZACIÓN → rechazo sin efectos ══════
  -- No hace falta agregar una sola línea: la CAPA 1 del opt-in (la sucursal
  -- efectiva) ya la rechaza con P0422 —la sesión ajena cuelga de otra sucursal—
  -- y la CAPA 2 (el backstop de tenant P0401 que tenancy-guard-caja-outbox puso
  -- en c28_register_cash_movement) cubre a todo caller futuro. El gate acepta
  -- cualquiera de las dos y deja registrado cuál disparó: lo que NO se acepta
  -- es que pase, ni que la víctima quede tocada.
  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_count_before, v_amount_before
  FROM public.cash_movements WHERE session_id = v_session_b;

  v_rejected := false; v_sqlstate := NULL;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Insumos', p_amount => 161, p_date => public.reporting_local_today(),
      p_payment_method_id => v_pm_cash_a, p_cash_session_id => v_session_b);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
    IF SQLSTATE IN ('P0422', 'P0401') THEN v_rejected := true; ELSE RAISE; END IF;
  END;

  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.8): el alta aceptó la sesión de caja de OTRA organización — le dejaría a la víctima un egreso fantasma en su arqueo.';
  END IF;

  SELECT COUNT(*), COALESCE(SUM(amount), 0) INTO v_count, v_amount
  FROM public.cash_movements WHERE session_id = v_session_b;
  IF v_count <> v_count_before OR v_amount <> v_amount_before THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.8-efectos): la caja de la víctima quedó en % movimientos / % de saldo, esperaba % / %.', v_count, v_amount, v_count_before, v_amount_before;
  END IF;
  RAISE NOTICE 'PASS (3.8): sesión de caja de otra organización rechazada con % y sin tocar el arqueo ajeno — sin una línea nueva.', v_sqlstate;
END $$;

-- ── (3.9-3.13) PATA BANCARIA — llamada incondicional al helper compartido ────
-- 🛑 Tramo de severidad ALTA. La RPC invoca
-- _pay_register_operation_bank_movement(..., 'out', 'expense', id, p_date,
-- sucursal, NULL) SIN ningún IF previo, calcada de la de
-- rpc_create_purchase_operation. El helper decide: predicado de kind bancario,
-- resolución y validación de la cuenta (P0412), rechazo de cuenta sobre kind no
-- bancario (P0400), mapa kind→movement_type, signo y guard de período
-- conciliado (P0424). NO se toca el helper (D5): el endurecimiento vive en el
-- caller de gasto.
DO $$
DECLARE
  v_user_a     uuid;  v_user_c uuid;
  v_account_a  uuid;  v_account_b uuid;  v_account_c uuid;
  v_branch_a1  uuid;
  v_ba_a       uuid;  v_ba_b uuid;
  v_pm_transfer_a uuid; v_pm_transfer_default uuid; v_pm_card_a uuid; v_pm_cash_a uuid;
  v_pm_transfer_c uuid;
  v_product_a  uuid;
  v_result     jsonb; v_exp_id uuid;
  v_bm         RECORD;
  v_count      integer; v_count_before integer;
  v_amount     numeric;
  v_rejected   boolean; v_sqlstate text;
  v_import_id  uuid;
  v_pm_check   uuid;
  v_today      date;
BEGIN
  SELECT id INTO v_user_a FROM auth.users WHERE email = 'gastos-forma-pago-a@test.local';
  SELECT id INTO v_user_c FROM auth.users WHERE email = 'gastos-forma-pago-c@test.local';
  IF v_user_a IS NULL OR v_user_c IS NULL THEN RAISE NOTICE 'GATE GASTOS (3.9): sin anchors — degradando.'; RETURN; END IF;

  SELECT account_id INTO v_account_a FROM public.account_members WHERE user_id = v_user_a ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_c FROM public.account_members WHERE user_id = v_user_c ORDER BY created_at LIMIT 1;
  SELECT account_id INTO v_account_b FROM public.account_members
    WHERE user_id = (SELECT id FROM auth.users WHERE email = 'gastos-forma-pago-b@test.local') ORDER BY created_at LIMIT 1;
  SELECT id INTO v_branch_a1 FROM public.branches WHERE account_id = v_account_a AND name NOT LIKE '__gate_gfp_branch%' ORDER BY created_at LIMIT 1;
  SELECT id INTO v_ba_a FROM public.bank_accounts WHERE name = '__gate_gfp_bank_a__';
  SELECT id INTO v_ba_b FROM public.bank_accounts WHERE name = '__gate_gfp_bank_b__';
  SELECT id INTO v_pm_transfer_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'transfer' AND is_active AND deleted_at IS NULL AND name NOT LIKE '__gate_gfp%' LIMIT 1;
  SELECT id INTO v_pm_transfer_default FROM public.payment_methods WHERE name = '__gate_gfp_pm_transfer_default__';
  SELECT id INTO v_pm_card_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'card' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_cash_a FROM public.payment_methods WHERE account_id = v_account_a AND kind = 'cash' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_pm_transfer_c FROM public.payment_methods WHERE account_id = v_account_c AND kind = 'transfer' AND is_active AND deleted_at IS NULL LIMIT 1;
  SELECT id INTO v_product_a FROM public.products WHERE account_id = v_account_a AND name = '__gate_gfp_product__';

  IF v_ba_a IS NULL OR v_ba_b IS NULL OR v_pm_transfer_a IS NULL OR v_pm_transfer_default IS NULL
     OR v_pm_card_a IS NULL OR v_pm_transfer_c IS NULL THEN
    RAISE NOTICE 'GATE GASTOS (3.9): fixtures bancarios incompletos — degradando.'; RETURN;
  END IF;

  v_today := public.reporting_local_today();

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  IF auth.uid() IS DISTINCT FROM v_user_a THEN
    RAISE NOTICE 'GATE GASTOS (3.9): auth.uid() no resuelve — degradando.'; RETURN;
  END IF;

  -- ═══ (3.10a) transferencia con cuenta resuelta: egreso con la FECHA DEL GASTO
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 2200, p_date => v_today - 2,
    p_description => 'gate 3.10a', p_payment_method_id => v_pm_transfer_a,
    p_bank_account_id => v_ba_a);
  v_exp_id := (v_result->>'expense_id')::uuid;

  SELECT COUNT(*) INTO v_count FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10a): el gasto por transferencia escribió % movimientos bancarios, esperaba 1.', v_count;
  END IF;

  SELECT * INTO v_bm FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_bm.movement_type <> 'transfer_out' THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10a): movement_type=% y esperaba transfer_out (el mapa kind→movement_type vive en el helper).', v_bm.movement_type;
  END IF;
  IF v_bm.amount <> -2200 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10a): amount=% y esperaba -2200 (egreso: el signo lo pone el helper con direction=out).', v_bm.amount;
  END IF;
  IF v_bm.value_date IS DISTINCT FROM v_today - 2 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10a): value_date=% y esperaba la FECHA DEL GASTO (%). Con value_date NULL el movimiento cae en created_at y la sugerencia automática (monto exacto, ±3 días) se desalinea del extracto — el objetivo del PO se cumpliría a medias.', v_bm.value_date, v_today - 2;
  END IF;
  IF v_bm.bank_account_id <> v_ba_a THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10a): el movimiento fue a la cuenta % y esperaba la informada %.', v_bm.bank_account_id, v_ba_a;
  END IF;
  IF v_bm.branch_id IS DISTINCT FROM v_branch_a1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10a): branch_id=% y esperaba la sucursal efectiva del gasto (%).', v_bm.branch_id, v_branch_a1;
  END IF;

  -- ═══ (3.10b-spec) el movimiento NACE CONCILIABLE ═════════════════════════
  IF v_bm.reconciliation_status <> 'unreconciled' THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10b): el movimiento nació con reconciliation_status=% y tiene que nacer ''unreconciled'' — aparece en los pendientes de conciliar por su sola existencia, sin tabla ni RPC intermedia.', v_bm.reconciliation_status;
  END IF;

  -- La sugerencia automática lo engancha: se replica LITERAL el predicado de
  -- BankReconciliationRepository.suggestions (monto exacto + |value_date diff|
  -- <= SUGGESTION_DATE_WINDOW_DAYS = 3 + unreconciled + sin match activo).
  -- La definición canónica vive en el repositorio Python; acá se verifica que
  -- el movimiento del gasto CAE dentro de ella, que es lo que el objetivo
  -- literal del PO ("que estos movimientos concilien banco") exige.
  INSERT INTO public.bank_statement_imports
    (bank_account_id, account_id, file_name, file_hash, period_from, period_to, line_count, imported_by)
  VALUES (v_ba_a, v_account_a, '__gate_gfp_extracto__.csv', '__gate_gfp_hash__',
          v_today - 10, v_today, 1, v_user_a)
  RETURNING id INTO v_import_id;

  INSERT INTO public.bank_statement_lines
    (import_id, bank_account_id, account_id, line_no, value_date, description, amount)
  VALUES (v_import_id, v_ba_a, v_account_a, 1, v_today - 1, 'Transferencia servicios', -2200);

  SELECT COUNT(*) INTO v_count
  FROM public.bank_statement_lines l
  JOIN public.bank_movements bm
    ON bm.bank_account_id = l.bank_account_id
   AND l.amount = bm.amount
   AND ABS(l.value_date - COALESCE(bm.value_date, bm.created_at::date)) <= 3
  WHERE l.import_id = v_import_id
    AND bm.id = v_bm.id
    AND bm.reconciliation_status = 'unreconciled'
    AND NOT EXISTS (SELECT 1 FROM public.reconciliation_matches m
                    WHERE m.statement_line_id = l.id AND m.status = 'active');
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10b): la sugerencia automática NO engancha el movimiento del gasto contra la línea del extracto del mismo importe dentro de la ventana de ±3 días (% emparejamientos).', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.10a/3.10b): transferencia escribe transfer_out por -2200 con la fecha del gasto como fecha valor, nace unreconciled y la sugerencia lo engancha.';

  -- ═══ (3.10c) TARJETA se asienta BRUTO con su tipo propio ═════════════════
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 2300, p_date => v_today,
    p_payment_method_id => v_pm_card_a, p_bank_account_id => v_ba_a);
  v_exp_id := (v_result->>'expense_id')::uuid;
  SELECT * INTO v_bm FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_bm.movement_type <> 'card_settlement' OR v_bm.amount <> -2300 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10c): tarjeta dio movement_type=% / amount=%, esperaba card_settlement / -2300 (bruto).', v_bm.movement_type, v_bm.amount;
  END IF;

  -- ═══ (3.10d) efectivo NO toca el banco ═══════════════════════════════════
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 2400, p_date => v_today,
    p_payment_method_id => v_pm_cash_a);
  SELECT COUNT(*) INTO v_count FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = (v_result->>'expense_id')::uuid;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10d): un gasto en efectivo escribió % movimientos bancarios.', v_count;
  END IF;

  -- ═══ (3.10e) cuenta bancaria informada sobre un kind NO bancario → P0400 ═
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 2500, p_date => v_today,
      p_payment_method_id => v_pm_cash_a, p_bank_account_id => v_ba_a);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0400' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10e): se aceptó una cuenta bancaria explícita junto a un kind NO bancario — el helper lo rechaza con P0400, no lo ignora en silencio.';
  END IF;

  -- ═══ (3.10f) cuenta bancaria de OTRA organización → rechazo sin efectos ══
  SELECT COUNT(*) INTO v_count_before FROM public.bank_movements WHERE bank_account_id = v_ba_b;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 2600, p_date => v_today,
      p_payment_method_id => v_pm_transfer_a, p_bank_account_id => v_ba_b);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
    IF SQLSTATE = 'P0412' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10f): se aceptó una cuenta bancaria de otra organización.';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE bank_account_id = v_ba_b;
  IF v_count <> v_count_before THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10f-efectos): quedaron movimientos en la cuenta bancaria ajena (% vs %).', v_count, v_count_before;
  END IF;
  RAISE NOTICE 'PASS (3.10c-f): tarjeta bruta, efectivo sin banco, cuenta sobre kind no bancario (P0400) y cuenta ajena (P0412) sin efectos.';

  -- ═══ (3.10g) PERÍODO CONCILIADO Y CERRADO → P0424 que revierte TODO ══════
  INSERT INTO public.reconciliation_sessions
    (bank_account_id, account_id, status, period_from, period_to, statement_closing_balance, opened_by, closed_by, closed_at)
  VALUES (v_ba_a, v_account_a, 'closed', v_today - 30, v_today - 20, 0, v_user_a, v_user_a, now());

  SELECT COUNT(*) INTO v_count_before FROM public.expenses WHERE account_id = v_account_a;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 2700, p_date => v_today - 25,
      p_payment_method_id => v_pm_transfer_a, p_bank_account_id => v_ba_a);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0424' THEN v_rejected := true; ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10g): se aceptó un gasto con fecha dentro de un período de conciliación ya cerrado — el guard P0424 del helper rechaza la operación ENTERA.';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.expenses WHERE account_id = v_account_a;
  IF v_count <> v_count_before THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10g/3.13-atomicidad): el P0424 de la pata BANCARIA dejó % gastos y esperaba % — el RAISE corre DESPUÉS del INSERT del gasto y tiene que revertirlo.', v_count, v_count_before;
  END IF;
  RAISE NOTICE 'PASS (3.10g/3.13): período conciliado cerrado rechaza con P0424 y revierte también el gasto (atomicidad de la pata bancaria).';

  -- ═══ (3.10h) CONTROL NEGATIVO DE D10 — ni evento ni asiento ══════════════
  -- D10 declara el asiento contable fuera de alcance y la RPC no inserta en
  -- public.events (eso además la deja fuera del chequeo (5) del gate de ACLs).
  -- Sin control negativo la garantía se cumple por accidente hasta que alguien
  -- agregue un INSERT.
  SELECT COUNT(*) INTO v_count_before FROM public.events WHERE account_id = v_account_a;
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 2800, p_date => v_today,
    p_payment_method_id => v_pm_transfer_a, p_bank_account_id => v_ba_a);
  v_exp_id := (v_result->>'expense_id')::uuid;
  SELECT COUNT(*) INTO v_count FROM public.events WHERE account_id = v_account_a;
  IF v_count <> v_count_before THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10h): el alta del gasto insertó % eventos en public.events — D10 declara la emisión al outbox FUERA DE ALCANCE y ese INSERT metería a la RPC en el chequeo (5) del gate de ACLs.', v_count - v_count_before;
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.journal_entries WHERE account_id = v_account_a;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.10h): el alta del gasto creó % asientos contables — el asiento del gasto está diferido a V2.6 (D10).', v_count;
  END IF;
  RAISE NOTICE 'PASS (3.10h): el gasto con movimiento bancario no emite eventos al outbox ni crea asiento contable.';

  -- ═══ (3.11) [OQ-2 / D5] guard de cuenta bancaria EXIGIBLE ════════════════
  -- La organización A TIENE cuentas bancarias activas y la forma de pago de
  -- transferencia NO tiene destino por defecto (0 de 37 catálogos configurados
  -- en prod): sin override, el helper devolvería NULL SIN ERROR y el pedido
  -- literal del PO fallaría en silencio. El guard vive en el caller de gasto.
  SELECT COUNT(*) INTO v_count_before FROM public.expenses WHERE account_id = v_account_a;
  v_rejected := false;
  BEGIN
    PERFORM public.rpc_create_expense(
      p_category => 'Servicios', p_amount => 2900, p_date => v_today,
      p_payment_method_id => v_pm_transfer_a);
  EXCEPTION WHEN OTHERS THEN
    v_sqlstate := SQLSTATE;
    IF SQLSTATE = 'P0412' AND position('cuenta bancaria' in SQLERRM) > 0 THEN v_rejected := true;
    ELSE RAISE; END IF;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.11): un gasto por transferencia SIN cuenta destino resoluble, en una organización CON cuentas bancarias activas, fue aceptado — degradaría en silencio y no aparecería nunca en la conciliación (D5).';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.expenses WHERE account_id = v_account_a;
  IF v_count <> v_count_before THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.11-efectos): el rechazo P0412 dejó % gastos y esperaba %.', v_count, v_count_before;
  END IF;

  -- (3.11b) el DESTINO POR DEFECTO de la forma de pago evita el rechazo
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 3100, p_date => v_today,
    p_payment_method_id => v_pm_transfer_default);
  v_exp_id := (v_result->>'expense_id')::uuid;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id AND bank_account_id = v_ba_a;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.11b): con destino bancario POR DEFECTO configurado en la forma de pago, el gasto registró % movimientos contra esa cuenta y esperaba 1 (sin rechazo).', v_count;
  END IF;

  -- (3.11c) organización SIN ninguna cuenta bancaria: se guarda como etiqueta,
  -- sin movimiento y SIN error (33 de 37 organizaciones de prod están así — un
  -- guard incondicional las dejaría sin poder registrar un gasto por
  -- transferencia hasta que carguen una cuenta).
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_c::text, 'role', 'authenticated')::text, true);
  v_result := public.rpc_create_expense(
    p_category => 'Servicios', p_amount => 3200, p_date => v_today,
    p_payment_method_id => v_pm_transfer_c);
  v_exp_id := (v_result->>'expense_id')::uuid;
  IF v_exp_id IS NULL THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.11c): la organización SIN cuentas bancarias no pudo registrar un gasto por transferencia — el guard tiene que ser CONDICIONAL (D5).';
  END IF;
  SELECT COUNT(*) INTO v_count FROM public.bank_movements
  WHERE source_doc_type = 'expense' AND source_doc_ref = v_exp_id;
  IF v_count <> 0 THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.11c): la organización sin bancos registró % movimientos bancarios.', v_count;
  END IF;
  SELECT payment_method_id INTO v_pm_check FROM public.expenses WHERE id = v_exp_id;
  IF v_pm_check IS DISTINCT FROM v_pm_transfer_c THEN
    RAISE EXCEPTION 'GATE GASTOS FAILED (3.11c): el gasto de la organización sin bancos perdió su imputación — se guarda como etiqueta, con su forma de pago.';
  END IF;
  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_a::text, 'role', 'authenticated')::text, true);
  RAISE NOTICE 'PASS (3.11): P0412 cuando hay bancos y no resuelve; destino por defecto evita el rechazo; organización sin bancos guarda el gasto sin error.';

  -- ═══ (3.12) CONTROL NEGATIVO DE NO-REGRESIÓN sobre el helper compartido ══
  -- Prueba DIRECTA de que el endurecimiento quedó en el caller de gasto y no
  -- en el punto de paso común: la MISMA condición que rechaza el gasto
  -- (organización con bancos + transferencia sin destino resuelto) tiene que
  -- dejar pasar la VENTA, sin movimiento, igual que antes de este change. La
  -- spec bank-movement lo exige: "sin cuenta resuelta la venta sigue
  -- funcionando igual que antes".
  IF v_product_a IS NOT NULL THEN
    SELECT COUNT(*) INTO v_count_before FROM public.bank_movements WHERE account_id = v_account_a;
    v_result := public.rpc_create_sale_operation_v2(
      p_idempotency_key => 'gate-gfp-3-12',
      p_client_id       => NULL,
      p_date            => v_today,
      p_currency        => 'ARS',
      p_items           => jsonb_build_array(jsonb_build_object(
                             'product_id', v_product_a, 'amount', 500, 'quantity', 1)),
      p_payment_method_id => v_pm_transfer_a
    );
    IF (v_result->>'operation_id') IS NULL THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.12): la venta por transferencia sin cuenta destino resuelta fue rechazada — el endurecimiento se filtró al helper compartido y rompió venta/compra/POS.';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.bank_movements WHERE account_id = v_account_a;
    IF v_count <> v_count_before THEN
      RAISE EXCEPTION 'GATE GASTOS FAILED (3.12): la venta sin cuenta destino escribió % movimientos bancarios y esperaba 0 (procede sin movimiento, igual que antes).', v_count - v_count_before;
    END IF;
    RAISE NOTICE 'PASS (3.12): la venta por transferencia sin cuenta destino sigue procediendo sin movimiento — el guard quedó en el caller de gasto.';
  ELSE
    RAISE NOTICE 'GATE GASTOS (3.12): sin producto sintético — control de no-regresión omitido.';
  END IF;
END $$;

-- @@CLEANUP@@
-- ── Fase de cleanup de los tenants sintéticos A/B/C y del usuario D ─────────
-- DO block SEPARADO que resuelve los ids por email en vez de heredar las
-- variables: así limpia también las corridas que se cortaron por alguno de los
-- caminos degrade-don't-fail. Si algún DO principal ABORTA, psql con
-- ON_ERROR_STOP=1 corta antes de llegar acá — pero en ese caso su transacción
-- ya revirtió todo, incluidos los anchors, así que no queda nada que limpiar.
-- Sin esto, la SEGUNDA corrida sobre la misma base aborta con
-- users_email_partial_key (el anchor usa un email fijo y un id nuevo, así que
-- el ON CONFLICT (id) DO NOTHING no lo cubre).
DO $$
DECLARE
  v_emails   text[] := ARRAY[
    'gastos-forma-pago-a@test.local',
    'gastos-forma-pago-b@test.local',
    'gastos-forma-pago-c@test.local',
    'gastos-forma-pago-d@test.local'
  ];
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email = ANY(v_emails);

  IF array_length(v_users, 1) IS NULL THEN
    RAISE NOTICE 'GATE GASTOS-FORMA-PAGO: cleanup sin anchors que limpiar.';
    RETURN;
  END IF;

  -- Membresías + cuentas propietarias: al usuario D se le retira su membresía
  -- propia en el setup (ver el bloque de fixtures), así que sin el UNION con
  -- accounts.owner_user_id su cuenta auto-provisionada quedaría huérfana.
  SELECT COALESCE(array_agg(DISTINCT a), ARRAY[]::uuid[]) INTO v_accounts
  FROM (
    SELECT account_id AS a FROM public.account_members WHERE user_id = ANY(v_users)
    UNION
    SELECT id         AS a FROM public.accounts        WHERE owner_user_id = ANY(v_users)
  ) x;

  IF array_length(v_accounts, 1) IS NOT NULL THEN
    DELETE FROM public.reconciliation_matches m USING public.reconciliation_sessions s
      WHERE m.session_id = s.id AND s.account_id = ANY(v_accounts);
    DELETE FROM public.reconciliation_sessions  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_statement_lines     WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_statement_imports   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cash_movements cm USING public.cash_sessions cs, public.cashboxes cb, public.branches b
      WHERE cm.session_id = cs.id AND cs.cashbox_id = cb.id AND cb.branch_id = b.id
        AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cash_sessions cs USING public.cashboxes cb, public.branches b
      WHERE cs.cashbox_id = cb.id AND cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.cashboxes cb USING public.branches b
      WHERE cb.branch_id = b.id AND b.account_id = ANY(v_accounts);
    DELETE FROM public.bank_movements           WHERE account_id = ANY(v_accounts);
    DELETE FROM public.bank_accounts            WHERE account_id = ANY(v_accounts);
    DELETE FROM public.journal_lines jl USING public.journal_entries je
      WHERE jl.entry_id = je.id AND je.account_id = ANY(v_accounts);
    DELETE FROM public.journal_entries          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.document_status_history  WHERE account_id = ANY(v_accounts);
    DELETE FROM public.stock_movements          WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sale_items               WHERE account_id = ANY(v_accounts);
    DELETE FROM public.sales                    WHERE account_id = ANY(v_accounts);
    DELETE FROM public.expenses                 WHERE account_id = ANY(v_accounts);
    DELETE FROM public.purchases                WHERE account_id = ANY(v_accounts);
    DELETE FROM public.operation_idempotency
     WHERE operation_kind = 'event_consumer'
       AND event_id IN (SELECT id FROM public.events WHERE account_id = ANY(v_accounts));
    DELETE FROM public.events                   WHERE account_id = ANY(v_accounts);
    DELETE FROM public.branch_stock             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.products                 WHERE account_id = ANY(v_accounts);
    DELETE FROM public.cost_centers             WHERE account_id = ANY(v_accounts);
    DELETE FROM public.payment_methods          WHERE account_id = ANY(v_accounts);
    -- sucursal-guard-vaciado-auditoria: branches prohíbe el borrado físico
    -- SIEMPRE (trigger trg_guard_branch_decommission, P0428). Bypass explícito
    -- para el cleanup del fixture sintético — session_replication_role sólo lo
    -- puede fijar un rol con privilegio de superusuario (postgres en CI); no
    -- abre ningún camino para authenticated/anon vía PostgREST.
    SET session_replication_role = replica;
    DELETE FROM public.branches                 WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.operation_idempotency WHERE user_id = ANY(v_users);
  DELETE FROM public.account_members       WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts              WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles              WHERE id = ANY(v_users);
  -- email_logs.user_id es FK ON DELETE SET NULL: borrar el anchor NO borra la
  -- fila, la deja con user_id NULL y el recipient sintético adentro.
  DELETE FROM public.email_logs
   WHERE user_id = ANY(v_users) OR recipient = ANY(v_emails);
  DELETE FROM auth.users                   WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE GASTOS-FORMA-PAGO: cleanup completo (% anchors) — el gate vuelve a correr en verde sobre la misma base.', array_length(v_users, 1);
END $$;
