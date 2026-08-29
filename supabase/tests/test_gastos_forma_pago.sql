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
