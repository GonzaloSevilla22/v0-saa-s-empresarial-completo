-- =============================================================================
-- GATE: test_banco_caja_historial_ajustes.sql
-- CHANGE: banco-caja-historial-ajustes (tasks 2.1-2.7, 3.1-3.12)
--
-- Ejercita de verdad (sesión sintética vía request.jwt.claims, mismo patrón
-- que test_delete_guard_ledgers.sql / test_pagos_cableados_restantes.sql)
-- las piezas nuevas de este change:
--   (1) ANTI-OVERLOAD 42725: una sola firma viva de rpc_register_cash_movement
--       y c28_register_cash_movement (ambas ganaron p_description trailing).
--   (2) ACLs: authenticated con EXECUTE en las 4 funciones tocadas; anon/PUBLIC
--       sin acceso — sobrevivió el DROP+CREATE (rpc_register_cash_movement,
--       c28_register_cash_movement) y el CREATE OR REPLACE (rpc_close_cash_
--       session, rpc_register_bank_movement).
--   (3) Ajuste de caja con motivo persiste con balance_after correcto
--       (sobrante + y faltante -); sin motivo, cualquier camino de INSERT
--       rechaza por el CHECK (23514) — probado también con INSERT directo
--       (no solo vía RPC), como pide RN-98/D4.
--   (4) Cierre de sesión: SIN ajustes (adjustments_total=0, difference sin
--       cambios) · CON un ajuste que lleva difference a 0
--       (difference_before_adjustments queda como evidencia) · CON ajustes de
--       signos mixtos (+100/-30 → adjustments_total=+70).
--   (5) Ajuste de banco: con motivo se registra · sin motivo rechaza P0413
--       SIN consumir el slot de idempotencia (reintentar con la MISMA clave +
--       motivo tiene éxito, replayed=false) · transfer_in sin motivo sigue
--       funcionando (la exigencia es SOLO para manual_adjustment).
--   (6) Índice nuevo idx_cash_movements_session_created_desc existe.
--
-- Degrade-don't-fail: si el anchor sintético no resuelve auth.uid() bajo
-- request.jwt.claims local, el gate emite NOTICE y no aborta.
-- =============================================================================

-- ── (1) + (2): ANTI-OVERLOAD y ACLs — no requieren sesión de usuario ─────────

DO $$
DECLARE
  v_count integer;
BEGIN
  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_register_cash_movement';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (1a, 42725): esperaba 1 firma de rpc_register_cash_movement, hay % (¿faltó el DROP FUNCTION de la firma vieja de 4 args?).', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'c28_register_cash_movement';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (1b, 42725): esperaba 1 firma de c28_register_cash_movement, hay %.', v_count;
  END IF;

  RAISE NOTICE 'PASS (1): una sola firma de rpc_register_cash_movement y c28_register_cash_movement (5 args, p_description trailing).';

  -- ── (2) ACLs de las 4 funciones tocadas ────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_register_cash_movement'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (2a): authenticated no tiene EXECUTE sobre rpc_register_cash_movement.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_close_cash_session'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (2b): authenticated no tiene EXECUTE sobre rpc_close_cash_session.';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'rpc_register_bank_movement'
      AND has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (2c): authenticated no tiene EXECUTE sobre rpc_register_bank_movement.';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    IF EXISTS (
      SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'public'
        AND p.proname IN ('rpc_register_cash_movement', 'c28_register_cash_movement',
                           'rpc_close_cash_session', 'rpc_register_bank_movement')
        AND has_function_privilege('anon', p.oid, 'EXECUTE')
    ) THEN
      RAISE EXCEPTION 'GATE BCHA FAILED (2d): anon tiene EXECUTE sobre alguna de las 4 funciones tocadas — el REVOKE ALL FROM PUBLIC, anon, authenticated no se re-emitió.';
    END IF;
  END IF;

  RAISE NOTICE 'PASS (2): authenticated ejecuta las 4 funciones tocadas; anon/PUBLIC sin acceso.';

  -- ── (6) Índice nuevo ────────────────────────────────────────────────────────
  IF NOT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'cash_movements'
      AND indexname = 'idx_cash_movements_session_created_desc'
  ) THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (6): falta el índice idx_cash_movements_session_created_desc.';
  END IF;

  RAISE NOTICE 'PASS (6): idx_cash_movements_session_created_desc existe.';
END $$;

-- ── (3)-(5): comportamiento con datos reales — sesión sintética ──────────────

DO $$
DECLARE
  v_anchor_email    text := 'banco-caja-historial-ajustes-gate@test.local';
  v_user_id         uuid := gen_random_uuid();
  v_account_id      uuid;
  v_branch_id       uuid;
  v_cashbox_id      uuid;
  v_bank_account_id uuid;

  v_session_a       uuid;  -- sin ajustes
  v_session_b       uuid;  -- un ajuste que lleva difference a 0
  v_session_c       uuid;  -- ajustes de signos mixtos

  v_result          jsonb;
  v_movement_id     uuid;
  v_balance_after   numeric;
  v_reason          text;
  v_caught          boolean;
BEGIN
  -- ── Anchor sintético (auto-provisioning vía handle_new_user) ────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Banco Caja Historial Ajustes'))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id FROM public.account_members WHERE user_id = v_user_id ORDER BY created_at LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE BCHA: no se pudo resolver cuenta para el anchor sintético — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id  FROM public.branches  WHERE account_id = v_account_id ORDER BY created_at LIMIT 1;
  SELECT id INTO v_cashbox_id FROM public.cashboxes WHERE branch_id  = v_branch_id  ORDER BY created_at LIMIT 1;

  IF v_branch_id IS NULL OR v_cashbox_id IS NULL THEN
    RAISE NOTICE 'GATE BCHA: branch/cashbox no disponibles para el anchor — degradando sin abortar.';
    RETURN;
  END IF;

  INSERT INTO public.bank_accounts (account_id, name, currency, opening_balance)
  VALUES (v_account_id, '__gate_bcha_bank__', 'ARS', 1000)
  RETURNING id INTO v_bank_account_id;

  PERFORM set_config('request.jwt.claims',
    json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);

  IF auth.uid() IS DISTINCT FROM v_user_id THEN
    RAISE NOTICE 'GATE BCHA: auth.uid() no resuelve al anchor con request.jwt.claims local — se omiten los asserts que invocan las RPCs.';
    RETURN;
  END IF;

  -- ═══════════════════ (3) Ajuste de caja: sobrante y faltante ═══════════════

  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_id, 'open', 8000, v_user_id)
  RETURNING id INTO v_session_a;

  -- Sobrante +500 con motivo → balance_after = 8500
  v_result := public.rpc_register_cash_movement(v_session_a, 500, 'adjustment', NULL, 'sobrante detectado en el conteo del mediodía');
  v_movement_id := (v_result->>'movement_id')::uuid;
  SELECT balance_after INTO v_balance_after FROM public.cash_movements WHERE id = v_movement_id;
  IF v_balance_after <> 8500 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (3a): balance_after esperado 8500, es %.', v_balance_after;
  END IF;

  -- Faltante -300 con motivo → balance_after = 8200
  v_result := public.rpc_register_cash_movement(v_session_a, -300, 'adjustment', NULL, 'faltante por vuelto mal dado');
  v_movement_id := (v_result->>'movement_id')::uuid;
  SELECT balance_after INTO v_balance_after FROM public.cash_movements WHERE id = v_movement_id;
  IF v_balance_after <> 8200 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (3b): balance_after esperado 8200, es %.', v_balance_after;
  END IF;

  RAISE NOTICE 'PASS (3a-b): ajuste de caja sobrante/faltante con motivo — balance_after correcto.';

  -- Sin motivo (NULL) — CHECK rechaza, ninguna fila queda
  v_caught := false;
  BEGIN
    PERFORM public.rpc_register_cash_movement(v_session_a, 100, 'adjustment', NULL, NULL);
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (3c): un adjustment sin motivo debía violar el CHECK y no lo hizo.';
  END IF;

  -- Sin motivo (blanco) por INSERT directo — mismo CHECK, camino distinto (RN-98)
  v_caught := false;
  BEGIN
    INSERT INTO public.cash_movements (session_id, amount, movement_type, balance_after, created_by, description)
    VALUES (v_session_a, 1, 'adjustment', 9999, v_user_id, '   ');
  EXCEPTION WHEN check_violation THEN
    v_caught := true;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (3d): un adjustment con motivo en blanco (solo espacios) por INSERT directo debía violar el CHECK.';
  END IF;

  RAISE NOTICE 'PASS (3c-d): ajuste de caja sin motivo (NULL vía RPC, blanco vía INSERT directo) rechazado por el CHECK — ninguna fila fantasma.';

  -- Cerrar v_session_a — solo una sesión abierta por caja a la vez
  -- (one_open_per_cashbox), y las secciones (4)/(4c) necesitan abrir sesiones
  -- nuevas en la MISMA caja del anchor.
  PERFORM public.rpc_close_cash_session(v_session_a, 8200, NULL);

  -- ═══════════════════ (4) Cierre: adjustments_total / difference_before_adjustments ═══════

  -- (4a) Sesión SIN ajustes — comportamiento idéntico al de antes de este change
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_id, 'open', 1000, v_user_id)
  RETURNING id INTO v_session_b;

  v_result := public.rpc_close_cash_session(v_session_b, 1000, NULL);
  IF (v_result->>'adjustments_total')::numeric <> 0 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4a): adjustments_total esperado 0, es %.', v_result->>'adjustments_total';
  END IF;
  IF (v_result->>'difference')::numeric <> 0 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4a): difference esperado 0, es %.', v_result->>'difference';
  END IF;
  IF (v_result->>'difference_before_adjustments')::numeric <> 0 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4a): difference_before_adjustments esperado 0, es %.', v_result->>'difference_before_adjustments';
  END IF;

  RAISE NOTICE 'PASS (4a): cierre sin ajustes — adjustments_total=0, difference y difference_before_adjustments iguales, sin cambios de comportamiento.';

  -- (4b) Un ajuste que lleva la diferencia a cero: esperado sin ajustes 900,
  -- ajuste +100, contado 1000 → difference=0, difference_before_adjustments=+100
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_id, 'open', 900, v_user_id)
  RETURNING id INTO v_session_c;

  PERFORM public.rpc_register_cash_movement(v_session_c, 100, 'adjustment', NULL, 'ajuste para igualar el conteo');

  v_result := public.rpc_close_cash_session(v_session_c, 1000, NULL);
  IF (v_result->>'difference')::numeric <> 0 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4b): difference esperado 0 (ajuste tapó la diferencia), es %.', v_result->>'difference';
  END IF;
  IF (v_result->>'adjustments_total')::numeric <> 100 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4b): adjustments_total esperado 100, es %.', v_result->>'adjustments_total';
  END IF;
  IF (v_result->>'difference_before_adjustments')::numeric <> 100 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4b, señal antifraude RN-95): difference_before_adjustments esperado 100 (lo que habría dado el arqueo sin el ajuste), es % — la señal quedó tapada.', v_result->>'difference_before_adjustments';
  END IF;

  -- La transición queda con el motivo mencionando el ajuste
  SELECT reason INTO v_reason FROM public.document_status_history
  WHERE document_type = 'cash_session' AND document_id = v_session_c
  ORDER BY occurred_at DESC LIMIT 1;
  IF v_reason IS NULL OR position('ajustes de caja' in v_reason) = 0 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4b): el reason de la transición open→closed no menciona los ajustes: %.', v_reason;
  END IF;

  RAISE NOTICE 'PASS (4b, GATE ANTIFRAUDE): ajuste de +100 lleva difference a 0, pero difference_before_adjustments=100 deja la señal evidenciada — no tapada.';

  -- (4c) Ajustes de signos mixtos (+100 y -30) → adjustments_total = +70.
  -- Sesión nueva (v_session_b, ya cerrada en 4a — se reasigna la variable):
  -- reabrir una sesión cerrada sería inválido en producción, más fiel al
  -- ledger append-only real usar una tercera sesión.
  INSERT INTO public.cash_sessions (cashbox_id, status, opening_balance, opened_by)
  VALUES (v_cashbox_id, 'open', 500, v_user_id)
  RETURNING id INTO v_session_b;  -- reutiliza la variable, ya cerrada arriba

  PERFORM public.rpc_register_cash_movement(v_session_b, 100, 'adjustment', NULL, 'sobrante parcial');
  PERFORM public.rpc_register_cash_movement(v_session_b, -30, 'adjustment', NULL, 'faltante parcial');

  v_result := public.rpc_close_cash_session(v_session_b, 570, NULL);
  IF (v_result->>'adjustments_total')::numeric <> 70 THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (4c): adjustments_total esperado 70 (100-30), es %.', v_result->>'adjustments_total';
  END IF;

  RAISE NOTICE 'PASS (4c): ajustes de signos mixtos (+100/-30) → adjustments_total=70.';

  -- ═══════════════════ (5) Ajuste de banco: motivo obligatorio, sin quemar idempotencia ═══

  -- Con motivo → se registra
  v_result := public.rpc_register_bank_movement('gate-bcha-adj-1', v_bank_account_id, -1200, 'manual_adjustment', CURRENT_DATE, v_branch_id, 'diferencia contra extracto de agosto');
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (5a): ajuste bancario con motivo debía registrarse (replayed=false), resultado: %.', v_result;
  END IF;

  RAISE NOTICE 'PASS (5a): ajuste bancario con motivo se registra normalmente.';

  -- Sin motivo → P0413, y la MISMA Idempotency-Key no queda quemada
  v_caught := false;
  BEGIN
    PERFORM public.rpc_register_bank_movement('gate-bcha-adj-2', v_bank_account_id, -500, 'manual_adjustment', CURRENT_DATE, v_branch_id, NULL);
  EXCEPTION WHEN OTHERS THEN
    IF SQLSTATE = 'P0413' THEN
      v_caught := true;
    ELSE
      RAISE;
    END IF;
  END;
  IF NOT v_caught THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (5b): ajuste bancario sin motivo debía rechazar con P0413.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.operation_idempotency
    WHERE user_id = v_user_id AND operation_kind = 'bank_movement' AND idempotency_key = 'gate-bcha-adj-2'
  ) THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (5b): el rechazo P0413 consumió el slot de idempotencia — un reintento con motivo quedaría bloqueado como replay.';
  END IF;

  -- Reintentar con la MISMA clave + motivo → éxito real (replayed=false), no un replay fantasma
  v_result := public.rpc_register_bank_movement('gate-bcha-adj-2', v_bank_account_id, -500, 'manual_adjustment', CURRENT_DATE, v_branch_id, 'reintento con motivo');
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (5b): el reintento con la misma Idempotency-Key y motivo debía registrarse (replayed=false), resultado: %.', v_result;
  END IF;

  RAISE NOTICE 'PASS (5b): ajuste bancario sin motivo rechaza P0413 SIN quemar el slot de idempotencia — el reintento con la misma clave y motivo tiene éxito real.';

  -- transfer_in sin motivo sigue funcionando (la exigencia es solo para manual_adjustment)
  v_result := public.rpc_register_bank_movement('gate-bcha-transfer-1', v_bank_account_id, 300, 'transfer_in', CURRENT_DATE, v_branch_id, NULL);
  IF (v_result->>'replayed')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'GATE BCHA FAILED (5c): transfer_in sin motivo debía seguir funcionando, resultado: %.', v_result;
  END IF;

  RAISE NOTICE 'PASS (5c): transfer_in sin motivo sigue funcionando — la exigencia P0413 es exclusiva de manual_adjustment.';

  RAISE NOTICE 'GATE BCHA: todos los asserts pasaron.';
END $$;
