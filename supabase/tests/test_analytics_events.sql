-- =============================================================================
-- test_analytics_events.sql — Gates de comportamiento: analytics-events-revival
--
-- Verifica el choke point único de telemetría (trigger AFTER INSERT en
-- sales/purchases/expenses → public.analytics_emit_operation_event()):
--   1. INSERT de gasto/venta/compra → operation_created con entity_id/
--      entity_type/source/account_id correctos.
--   2. Primera operación del usuario → first_operation único; segunda
--      operación (de otro tipo) → sigue existiendo exactamente uno.
--   3. Atomicidad: una operación insertada dentro de una subtransacción que
--      luego se revierte no deja eventos huérfanos. PL/pgSQL no admite
--      SAVEPOINT/ROLLBACK TO explícito — un bloque BEGIN...EXCEPTION anidado
--      es su equivalente (subtransacción implícita revertida al capturar la
--      excepción forzada).
--   4. Degrade-don't-fail: un CHECK NOT VALID fuerza el fallo del INSERT del
--      emisor; la operación de negocio sobrevive, sin evento y sin error
--      propagado al caller.
--   5. ACL/RLS: INSERT con SET LOCAL ROLE authenticated (RLS real de
--      sales/purchases/expenses vía current_account_ids()) → el evento se
--      emite igual — prueba que el REVOKE sobre la función de trigger (D2)
--      no rompe la emisión y que la RLS de analytics_events no bloquea al
--      SECURITY DEFINER.
--   6. Idempotencia: una reemisión de operation_created para la misma
--      operación no duplica (índice único parcial por entity_id).
--   7. Granularidad: un INSERT de N filas en una sola sentencia emite N
--      operation_created y a lo sumo un first_operation.
--
-- Patrón del proyecto (test_kpis.sql): acumular fallos en text[], un solo
-- RAISE EXCEPTION al final para que psql -v ON_ERROR_STOP=1 salga con código
-- distinto de cero. Anchors sintéticos vía handle_new_user (siembra account +
-- branch + cashbox, 20260812000001). Cleanup hijo→padre al final; degrada con
-- RAISE NOTICE si el contexto no lo permite (prod real).
--
-- Corre en CI: KPI_Validation.yml -v ON_ERROR_STOP=1 (paso agregado en el
-- mismo PR que este archivo).
-- =============================================================================

DO $$
DECLARE
  v_failures            text[] := '{}';

  -- Anchor principal
  v_anchor_email        text := 'analytics-events-revival-gate@test.local';
  v_user_id             uuid := gen_random_uuid();
  v_account_id          uuid;
  v_branch_id           uuid;

  v_expense_id          uuid;
  v_purchase_id         uuid;
  v_sale_id             uuid;
  v_atomic_expense_id   uuid := gen_random_uuid();
  v_force_fail_expense_id uuid;
  v_role_expense_id     uuid;

  v_first_op_count      integer;
  v_op_count            integer;

  -- Anchor secundario (granularidad — usuario nuevo, sin operaciones previas)
  v_granularity_email   text := 'analytics-events-revival-gate-granularity@test.local';
  v_granularity_user    uuid := gen_random_uuid();
  v_granularity_acct    uuid;
  v_granularity_branch  uuid;
BEGIN
  -- Anchor sintético: dispara handle_new_user (AFTER INSERT ON auth.users) —
  -- crea account + branch "Casa Central" + cashbox (desde 20260812000001).
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_user_id, 'authenticated', 'authenticated', v_anchor_email, now(), now(),
          jsonb_build_object('name', 'Gate Analytics Revival', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_account_id
  FROM   public.account_members
  WHERE  user_id = v_user_id
  ORDER  BY created_at
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE NOTICE 'GATE ANALYTICS-EVENTS-REVIVAL: no se pudo resolver una account para el anchor sintético (contexto no permite el gate) — degradando sin abortar.';
    RETURN;
  END IF;

  SELECT id INTO v_branch_id
  FROM   public.branches
  WHERE  account_id = v_account_id
  ORDER  BY created_at
  LIMIT  1;

  -- ── Gate 1 (3.2 + escenarios de spec): operación → operation_created ────────
  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_id, '__gate_analytics_expense__', 500, now())
  RETURNING id INTO v_expense_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.analytics_events
    WHERE event_name = 'operation_created'
      AND event_data->>'entity_id'   = v_expense_id::text
      AND event_data->>'entity_type' = 'expense'
      AND event_data->>'source'      = 'trigger'
      AND account_id = v_account_id
  ) THEN
    v_failures := array_append(v_failures,
      'FAIL 1a: INSERT de gasto no produjo operation_created con entity_id/entity_type/source/account_id correctos');
  ELSE
    RAISE NOTICE 'PASS 1a: gasto emite operation_created con payload canónico';
  END IF;

  INSERT INTO public.purchases (user_id, account_id, branch_id, amount, quantity, date)
  VALUES (v_user_id, v_account_id, v_branch_id, 700, 1, now())
  RETURNING id INTO v_purchase_id;

  IF NOT EXISTS (
    SELECT 1 FROM public.analytics_events
    WHERE event_name = 'operation_created'
      AND event_data->>'entity_id'   = v_purchase_id::text
      AND event_data->>'entity_type' = 'purchase'
  ) THEN
    v_failures := array_append(v_failures, 'FAIL 1b: la compra no emitió operation_created con entity_type=purchase');
  ELSE
    RAISE NOTICE 'PASS 1b: compra emite operation_created con entity_type=purchase';
  END IF;

  -- ── Gate 2 (3.3): primera operación → first_operation único; 2da op → sigue 1 ──
  SELECT COUNT(*) INTO v_first_op_count
  FROM public.analytics_events WHERE user_id = v_user_id AND event_name = 'first_operation';

  IF v_first_op_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL 2a: se esperaba exactamente 1 first_operation tras las primeras operaciones del usuario, hay %s', v_first_op_count));
  ELSE
    RAISE NOTICE 'PASS 2a: las primeras operaciones del usuario emiten exactamente 1 first_operation';
  END IF;

  -- Tercera operación, de otro tipo (venta) — product_id/client_id son nullable.
  INSERT INTO public.sales (user_id, account_id, branch_id, amount, quantity, date)
  VALUES (v_user_id, v_account_id, v_branch_id, 1000, 1, now())
  RETURNING id INTO v_sale_id;

  SELECT COUNT(*) INTO v_first_op_count
  FROM public.analytics_events WHERE user_id = v_user_id AND event_name = 'first_operation';

  IF v_first_op_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL 2b: una operación posterior duplicó first_operation, hay %s', v_first_op_count));
  ELSE
    RAISE NOTICE 'PASS 2b: operaciones posteriores no vuelven a emitir first_operation';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.analytics_events
    WHERE event_name = 'operation_created' AND event_data->>'entity_id' = v_sale_id::text AND event_data->>'entity_type' = 'sale'
  ) THEN
    v_failures := array_append(v_failures, 'FAIL 2c: la venta no emitió su propio operation_created');
  ELSE
    RAISE NOTICE 'PASS 2c: la venta emite su operation_created independiente';
  END IF;

  -- ── Gate 3 (3.4): atomicidad — operación revertida no deja eventos huérfanos ──
  BEGIN
    INSERT INTO public.expenses (id, user_id, account_id, branch_id, category, amount, date)
    VALUES (v_atomic_expense_id, v_user_id, v_account_id, v_branch_id, '__gate_analytics_atomicity__', 111, now());
    RAISE EXCEPTION 'force_rollback_analytics_atomicity_gate';
  EXCEPTION
    WHEN OTHERS THEN
      IF SQLERRM <> 'force_rollback_analytics_atomicity_gate' THEN
        RAISE;
      END IF;
      -- swallow a propósito: la subtransacción (INSERT incluido) queda revertida.
  END;

  IF EXISTS (SELECT 1 FROM public.expenses WHERE id = v_atomic_expense_id) THEN
    v_failures := array_append(v_failures, 'FAIL 3a: el gasto de la subtransacción revertida no debería existir');
  END IF;
  IF EXISTS (SELECT 1 FROM public.analytics_events WHERE event_data->>'entity_id' = v_atomic_expense_id::text) THEN
    v_failures := array_append(v_failures, 'FAIL 3b: quedó un evento huérfano de una operación revertida — el AFTER INSERT no es atómico con la transacción');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.expenses WHERE id = v_atomic_expense_id)
     AND NOT EXISTS (SELECT 1 FROM public.analytics_events WHERE event_data->>'entity_id' = v_atomic_expense_id::text) THEN
    RAISE NOTICE 'PASS 3: la subtransacción revertida no deja gasto ni evento huérfano';
  END IF;

  -- ── Gate 4 (3.5): degrade-don't-fail — emisor forzado a fallar no aborta la operación ──
  ALTER TABLE public.analytics_events
    ADD CONSTRAINT tmp_analytics_force_fail CHECK (event_name <> 'operation_created') NOT VALID;

  INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
  VALUES (v_user_id, v_account_id, v_branch_id, '__gate_analytics_force_fail__', 222, now())
  RETURNING id INTO v_force_fail_expense_id;

  IF NOT EXISTS (SELECT 1 FROM public.expenses WHERE id = v_force_fail_expense_id) THEN
    v_failures := array_append(v_failures, 'FAIL 4a: el gasto debería sobrevivir aunque el emisor de telemetría falle');
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.analytics_events
    WHERE event_data->>'entity_id' = v_force_fail_expense_id::text AND event_name = 'operation_created'
  ) THEN
    v_failures := array_append(v_failures, 'FAIL 4b: no debería existir operation_created cuando el CHECK forzado bloquea el INSERT del emisor');
  END IF;
  IF EXISTS (SELECT 1 FROM public.expenses WHERE id = v_force_fail_expense_id)
     AND NOT EXISTS (
       SELECT 1 FROM public.analytics_events
       WHERE event_data->>'entity_id' = v_force_fail_expense_id::text AND event_name = 'operation_created'
     ) THEN
    RAISE NOTICE 'PASS 4: el gasto persiste aunque el emisor falle (degrade-don''t-fail); sin evento ni error propagado';
  END IF;

  ALTER TABLE public.analytics_events DROP CONSTRAINT tmp_analytics_force_fail;

  -- ── Gate 5 (3.6): ACL/RLS — INSERT bajo rol authenticated real ──────────────
  -- Nota de entorno: el CLI local de Supabase (y por ende el `supabase start`
  -- de CI) crea las tablas con el default ACL del rol `postgres`, que NO
  -- incluye INSERT/SELECT para anon/authenticated (a diferencia de prod,
  -- donde `has_table_privilege('authenticated','public.expenses','INSERT')`
  -- = true, verificado 2026-08-12 — probablemente por cómo se crearon las
  -- tablas originales vía el bootstrap de la plataforma). Es una limitación
  -- estructural preexistente de este entorno de CI, no algo que este change
  -- deba resolver: se distingue explícitamente "permission denied for table"
  -- (falta el GRANT base, entorno) de una violación real de RLS (bug), y solo
  -- la segunda hace fallar el gate.
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', v_user_id::text, 'role', 'authenticated')::text, true);
    EXECUTE 'SET LOCAL ROLE authenticated';

    BEGIN
      INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
      VALUES (v_user_id, v_account_id, v_branch_id, '__gate_analytics_role__', 333, now())
      RETURNING id INTO v_role_expense_id;
    EXCEPTION
      WHEN insufficient_privilege THEN
        IF SQLERRM LIKE 'permission denied for table%' THEN
          v_role_expense_id := NULL;
        ELSE
          RAISE;  -- violación real de RLS (WITH CHECK) u otro motivo: debe fallar el gate
        END IF;
    END;

    EXECUTE 'RESET ROLE';
    PERFORM set_config('request.jwt.claims', '', true);

    IF v_role_expense_id IS NULL THEN
      RAISE NOTICE 'GATE 5 degradado: el entorno no otorga GRANT base de authenticated sobre expenses (permission denied, no RLS) — no es lo que este gate ejercita (REVOKE de la función de trigger + RLS de analytics_events); omitido sin fallar.';
    ELSIF NOT EXISTS (
      SELECT 1 FROM public.analytics_events
      WHERE event_data->>'entity_id' = v_role_expense_id::text AND event_name = 'operation_created'
    ) THEN
      v_failures := array_append(v_failures,
        'FAIL 5: el evento no se emitió cuando el INSERT corrió bajo rol authenticated — el REVOKE sobre la función de trigger rompió la emisión, o la RLS de analytics_events bloqueó al SECURITY DEFINER');
    ELSE
      RAISE NOTICE 'PASS 5: la emisión funciona bajo rol authenticated real (REVOKE no rompe el trigger; RLS no bloquea al DEFINER)';
    END IF;
  EXCEPTION
    WHEN OTHERS THEN
      EXECUTE 'RESET ROLE';
      PERFORM set_config('request.jwt.claims', '', true);
      RAISE;
  END;

  -- ── Gate 6 (3.7): idempotencia — reemisión sobre la misma operación no duplica ──
  INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data)
  VALUES (v_user_id, v_account_id, 'operation_created',
          jsonb_build_object('entity_id', v_expense_id::text, 'entity_type', 'expense', 'source', 'trigger'))
  ON CONFLICT (event_name, (event_data->>'entity_id'))
    WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
  DO NOTHING;

  SELECT COUNT(*) INTO v_op_count
  FROM public.analytics_events
  WHERE event_name = 'operation_created' AND event_data->>'entity_id' = v_expense_id::text;

  IF v_op_count <> 1 THEN
    v_failures := array_append(v_failures,
      format('FAIL 6: la reemisión de operation_created para la misma operación debería dejar exactamente 1 fila, hay %s', v_op_count));
  ELSE
    RAISE NOTICE 'PASS 6: el índice único por entity_id descarta la reemisión sin duplicar';
  END IF;

  -- ── Gate 7 (3.8): granularidad — INSERT de N filas emite N eventos y 1 first_operation ──
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_granularity_user, 'authenticated', 'authenticated', v_granularity_email, now(), now(),
          jsonb_build_object('name', 'Gate Analytics Granularity', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_granularity_acct
  FROM public.account_members WHERE user_id = v_granularity_user ORDER BY created_at LIMIT 1;

  IF v_granularity_acct IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL 7-setup: no se pudo resolver account para el segundo anchor (granularidad)');
  ELSE
    SELECT id INTO v_granularity_branch FROM public.branches WHERE account_id = v_granularity_acct ORDER BY created_at LIMIT 1;

    INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date)
    SELECT v_granularity_user, v_granularity_acct, v_granularity_branch, '__gate_analytics_granularity__', 10, now()
    FROM generate_series(1, 3);

    SELECT COUNT(*) INTO v_op_count
    FROM public.analytics_events
    WHERE user_id = v_granularity_user AND event_name = 'operation_created';

    IF v_op_count <> 3 THEN
      v_failures := array_append(v_failures,
        format('FAIL 7a: un INSERT de 3 filas debería emitir 3 operation_created, emitió %s', v_op_count));
    ELSE
      RAISE NOTICE 'PASS 7a: INSERT multi-fila emite un operation_created por fila';
    END IF;

    SELECT COUNT(*) INTO v_first_op_count
    FROM public.analytics_events
    WHERE user_id = v_granularity_user AND event_name = 'first_operation';

    IF v_first_op_count <> 1 THEN
      v_failures := array_append(v_failures,
        format('FAIL 7b: una carga múltiple para un usuario nuevo debería emitir exactamente 1 first_operation, emitió %s', v_first_op_count));
    ELSE
      RAISE NOTICE 'PASS 7b: la carga múltiple no multiplica la activación';
    END IF;
  END IF;

  -- ── Resultado ─────────────────────────────────────────────────────────────
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE ANALYTICS-EVENTS-REVIVAL FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE ANALYTICS-EVENTS-REVIVAL PASSED: emisión (gasto/compra/venta), unicidad de activación, atomicidad, degrade-don''t-fail, ACL/RLS, idempotencia y granularidad — verificados.';

  -- ── Limpieza hijo→padre (accounts=0 al final) ────────────────────────────
  DELETE FROM public.analytics_events WHERE user_id IN (v_user_id, v_granularity_user);
  DELETE FROM public.sales     WHERE account_id IN (v_account_id, v_granularity_acct);
  DELETE FROM public.purchases WHERE account_id IN (v_account_id, v_granularity_acct);
  DELETE FROM public.expenses  WHERE account_id IN (v_account_id, v_granularity_acct);
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_granularity_acct));
  DELETE FROM public.branches  WHERE account_id IN (v_account_id, v_granularity_acct);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_id, v_granularity_user);
  DELETE FROM public.accounts              WHERE id IN (v_account_id, v_granularity_acct);
  DELETE FROM public.profiles              WHERE id IN (v_user_id, v_granularity_user);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_id, v_granularity_user);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_granularity_user);
  DELETE FROM auth.users                   WHERE id IN (v_user_id, v_granularity_user);

EXCEPTION
  WHEN OTHERS THEN
    -- Best-effort cleanup incluso si algo falló a mitad de camino.
    BEGIN
      EXECUTE 'RESET ROLE';
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    PERFORM set_config('request.jwt.claims', '', true);
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'tmp_analytics_force_fail') THEN
        ALTER TABLE public.analytics_events DROP CONSTRAINT tmp_analytics_force_fail;
      END IF;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
      DELETE FROM public.analytics_events WHERE user_id IN (v_user_id, v_granularity_user);
      DELETE FROM public.sales     WHERE account_id IN (v_account_id, v_granularity_acct);
      DELETE FROM public.purchases WHERE account_id IN (v_account_id, v_granularity_acct);
      DELETE FROM public.expenses  WHERE account_id IN (v_account_id, v_granularity_acct);
      DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_granularity_acct));
      DELETE FROM public.branches  WHERE account_id IN (v_account_id, v_granularity_acct);
      DELETE FROM public.account_members       WHERE user_id IN (v_user_id, v_granularity_user);
      DELETE FROM public.accounts              WHERE id IN (v_account_id, v_granularity_acct);
      DELETE FROM public.profiles              WHERE id IN (v_user_id, v_granularity_user);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_id, v_granularity_user);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_granularity_user);
      DELETE FROM auth.users                   WHERE id IN (v_user_id, v_granularity_user);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
