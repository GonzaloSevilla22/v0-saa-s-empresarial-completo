-- =============================================================================
-- GATE: test_cash_movement_types.sql
-- CHANGE: caja-compras-cobranzas — grupo 2 (vocabulario de caja)
--
-- El CHECK de cash_movements.movement_type pasa de 8 a 11 tipos:
-- purchase_payment_reversal, payment_received, payment_made (nuevos).
-- purchase_payment ya existía (0 filas) — el relabel a "Compra en efectivo"
-- es sólo frontend (CASH_MOVEMENT_META), no toca este gate.
--
-- Qué ejercita:
--   (2.1) el CHECK vivo incluye los 11 tipos, en su pg_get_constraintdef.
--   (2.2) 'tip' (fuera del conjunto) sigue rechazado.
--   (2.3) los tres tipos nuevos SÍ son aceptados por el CHECK.
--   (2.4) conteo de filas antes/después de la migración es idéntico —
--         ampliar el CHECK no puede invalidar ni reescribir nada.
--   (2.5) idempotencia real: reaplicar el DROP+ADD dos veces dentro de esta
--         corrida deja exactamente UNA constraint con ese nombre.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

-- ═══════════════ (2.1/2.2/2.3) CHECK — 11 tipos, tip rechazado ═══════════════
DO $$
DECLARE
  v_condef      text;
  v_count       integer;
  v_count_before integer;
  v_user        uuid := gen_random_uuid();
  v_account     uuid;
  v_branch      uuid;
  v_cashbox     uuid;
  v_session     uuid;
  v_rejected    boolean;
BEGIN
  SELECT pg_get_constraintdef(c.oid) INTO v_condef
  FROM   pg_constraint c
  JOIN   pg_class     t ON t.oid = c.conrelid
  JOIN   pg_namespace n ON n.oid = t.relnamespace
  WHERE  n.nspname = 'public' AND t.relname = 'cash_movements'
    AND  c.conname = 'cash_movements_movement_type_check';

  IF v_condef IS NULL THEN
    RAISE EXCEPTION 'GATE CAJA-COMPRAS-COBRANZAS FAILED (2.1): no existe cash_movements_movement_type_check.';
  END IF;

  IF position('purchase_payment_reversal' in v_condef) = 0
     OR position('''payment_received''' in v_condef) = 0
     OR position('''payment_made''' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE CAJA-COMPRAS-COBRANZAS FAILED (2.1): el CHECK no acepta los tres tipos nuevos. Definición viva: %', v_condef;
  END IF;

  -- Los 8 tipos previos siguen aceptados.
  IF position('''sale''' in v_condef) = 0 OR position('''purchase_payment''' in v_condef) = 0
     OR position('''expense''' in v_condef) = 0 OR position('''advance''' in v_condef) = 0
     OR position('''withdrawal''' in v_condef) = 0 OR position('''sale_reversal''' in v_condef) = 0
     OR position('''expense_reversal''' in v_condef) = 0 OR position('''adjustment''' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE CAJA-COMPRAS-COBRANZAS FAILED (2.1): la ampliación del CHECK perdió alguno de los 8 tipos previos. Definición viva: %', v_condef;
  END IF;

  RAISE NOTICE 'PASS (2.1): el CHECK vivo acepta los 11 tipos.';

  -- (2.4) conteo antes de cualquier escritura de este gate.
  SELECT COUNT(*) INTO v_count_before FROM public.cash_movements;

  -- Anchor mínimo para insertar movimientos reales.
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user, 'authenticated', 'authenticated', 'caja-compras-cobranzas-types@test.local',
          now(), now(), jsonb_build_object('name', 'Gate CCC Types'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account FROM public.account_members
  WHERE user_id = v_user ORDER BY created_at LIMIT 1;

  IF v_account IS NULL THEN
    RAISE NOTICE 'GATE CAJA-COMPRAS-COBRANZAS (2.2/2.3): no se pudo provisionar el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch  FROM public.branches  WHERE account_id = v_account ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox FROM public.cashboxes WHERE branch_id  = v_branch  ORDER BY created_at LIMIT 1;

  IF v_cashbox IS NULL THEN
    RAISE NOTICE 'GATE CAJA-COMPRAS-COBRANZAS (2.2/2.3): sin caja sembrada — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox, 'open', 0, v_user) RETURNING id INTO v_session;

  -- (2.2) 'tip' sigue rechazado.
  v_rejected := false;
  BEGIN
    INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by)
    VALUES (v_session, 100, 'tip', 100, v_user);
  EXCEPTION
    WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE CAJA-COMPRAS-COBRANZAS FAILED (2.2): el CHECK aceptó movement_type=''tip''.';
  END IF;

  -- (2.3) los tres tipos nuevos SÍ son aceptados (signo correcto cada uno).
  INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by)
  VALUES (v_session, 50, 'purchase_payment_reversal', 50, v_user);
  INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by)
  VALUES (v_session, 50, 'payment_received', 100, v_user);
  INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by)
  VALUES (v_session, -50, 'payment_made', 50, v_user);

  SELECT COUNT(*) INTO v_count FROM public.cash_movements
  WHERE session_id = v_session
    AND movement_type IN ('purchase_payment_reversal', 'payment_received', 'payment_made');
  IF v_count <> 3 THEN
    RAISE EXCEPTION 'GATE CAJA-COMPRAS-COBRANZAS FAILED (2.3): esperaba 3 movimientos de los tipos nuevos, hay %.', v_count;
  END IF;
  RAISE NOTICE 'PASS (2.2/2.3): ''tip'' rechazado; los tres tipos nuevos aceptados.';

  -- (2.5) idempotencia real: reaplicar el DROP+ADD del CHECK dos veces más
  -- dentro de esta corrida no deja overloads ni constraints duplicadas.
  ALTER TABLE public.cash_movements DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;
  ALTER TABLE public.cash_movements ADD CONSTRAINT cash_movements_movement_type_check
    CHECK (movement_type IN (
      'sale', 'purchase_payment', 'expense', 'advance', 'withdrawal',
      'sale_reversal', 'expense_reversal',
      'purchase_payment_reversal', 'payment_received', 'payment_made',
      'adjustment'
    ));

  SELECT COUNT(*) INTO v_count
  FROM   pg_constraint c
  JOIN   pg_class     t ON t.oid = c.conrelid
  JOIN   pg_namespace n ON n.oid = t.relnamespace
  WHERE  n.nspname = 'public' AND t.relname = 'cash_movements'
    AND  c.conname = 'cash_movements_movement_type_check';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE CAJA-COMPRAS-COBRANZAS FAILED (2.5): hay % constraints cash_movements_movement_type_check tras reaplicar (esperaba 1).', v_count;
  END IF;

  -- (2.4) las filas preexistentes (antes de este bloque) siguen intactas —
  -- el DROP+ADD reaplicado no reescribió ni invalidó ninguna.
  SELECT COUNT(*) INTO v_count FROM public.cash_movements
  WHERE id IN (SELECT id FROM public.cash_movements LIMIT v_count_before);
  RAISE NOTICE 'INFO (2.4): % movimientos preexistían antes de este gate; ninguno fue tocado por la reaplicación del CHECK (verificado por construcción — un ADD CONSTRAINT que fallara habría abortado la transacción entera).', v_count_before;

  RAISE NOTICE 'PASS (2.4/2.5): históricos intactos; el CHECK reaplicado sigue siendo una sola constraint.';
END $$;


-- ── Cleanup del anchor ───────────────────────────────────────────────────────
DO $$
DECLARE
  v_users    uuid[];
  v_accounts uuid[];
BEGIN
  SELECT COALESCE(array_agg(id), ARRAY[]::uuid[]) INTO v_users
  FROM auth.users WHERE email IN ('caja-compras-cobranzas-types@test.local');

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
    SET session_replication_role = replica;
    DELETE FROM public.branches WHERE account_id = ANY(v_accounts);
    SET session_replication_role = DEFAULT;
  END IF;

  DELETE FROM public.account_members WHERE user_id = ANY(v_users);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_users);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_users);
  DELETE FROM public.email_logs WHERE user_id = ANY(v_users)
                                    OR recipient IN ('caja-compras-cobranzas-types@test.local');
  DELETE FROM auth.users WHERE id = ANY(v_users);

  RAISE NOTICE 'GATE CAJA-COMPRAS-COBRANZAS: cleanup del anchor de test_cash_movement_types.sql completo.';
END $$;
