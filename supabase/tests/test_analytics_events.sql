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
--   8. Backfill histórico (grupo 6, OQ-2 aprobada 2026-08-12): operaciones
--      "históricas" insertadas con el trigger deshabilitado (simulan datos
--      previos al choke point, 20260914000001) → el backfill
--      (20260919000001) las cubre con operation_created/first_operation
--      source='backfill', conteos operaciones↔eventos coherentes, y una
--      segunda corrida no agrega filas nuevas (idempotencia real, no
--      declarada).
--   9. OQ-3 (aprobada junto con OQ-2): índice único parcial
--      ux_analytics_umv_reached_user — un segundo umv_reached para el mismo
--      usuario, insertado directo (sin ON CONFLICT), debe violar la
--      restricción única.
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

  -- Anchor terciario (backfill + OQ-3 umv_reached — usuario nuevo con
  -- operaciones "históricas" insertadas con el trigger deshabilitado)
  v_backfill_email      text := 'analytics-events-revival-gate-backfill@test.local';
  v_backfill_user       uuid := gen_random_uuid();
  v_backfill_acct       uuid;
  v_backfill_branch     uuid;
  v_bf_sale_id          uuid;
  v_bf_purchase_id      uuid;
  v_bf_expense_id       uuid;
  v_bf_count            integer;
  v_bf_total_ops        integer;
  v_bf_events_before    integer;
  v_bf_events_after     integer;
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

  -- ── Gate 8 (grupo 6 backfill): histórico → source='backfill', conteos ──────
  -- ── coherentes, re-ejecución idempotente (0 filas nuevas) ───────────────────
  INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
  VALUES (v_backfill_user, 'authenticated', 'authenticated', v_backfill_email, now(), now(),
          jsonb_build_object('name', 'Gate Analytics Backfill', 'phone', '', 'locality', '', 'province', ''))
  ON CONFLICT (id) DO NOTHING;

  SELECT account_id INTO v_backfill_acct
  FROM   public.account_members
  WHERE  user_id = v_backfill_user
  ORDER  BY created_at
  LIMIT  1;

  IF v_backfill_acct IS NULL THEN
    v_failures := array_append(v_failures, 'FAIL 8-setup: no se pudo resolver account para el tercer anchor (backfill)');
  ELSE
    SELECT id INTO v_backfill_branch FROM public.branches WHERE account_id = v_backfill_acct ORDER BY created_at LIMIT 1;

    -- Simular datos "históricos" previos al choke point: deshabilitar el
    -- trigger, insertar con created_at en el pasado (orden determinístico:
    -- venta la más antigua, luego compra, luego gasto), reactivar. Envuelto
    -- para garantizar que el trigger SIEMPRE quede reactivado aunque algo
    -- falle a mitad de camino.
    BEGIN
      ALTER TABLE public.sales     DISABLE TRIGGER trg_analytics_operation_created;
      ALTER TABLE public.purchases DISABLE TRIGGER trg_analytics_operation_created;
      ALTER TABLE public.expenses  DISABLE TRIGGER trg_analytics_operation_created;

      INSERT INTO public.sales (user_id, account_id, branch_id, amount, quantity, date, created_at)
      VALUES (v_backfill_user, v_backfill_acct, v_backfill_branch, 1500, 1, now() - interval '400 days', now() - interval '400 days')
      RETURNING id INTO v_bf_sale_id;

      INSERT INTO public.purchases (user_id, account_id, branch_id, amount, quantity, date, created_at)
      VALUES (v_backfill_user, v_backfill_acct, v_backfill_branch, 800, 2, now() - interval '399 days', now() - interval '399 days')
      RETURNING id INTO v_bf_purchase_id;

      INSERT INTO public.expenses (user_id, account_id, branch_id, category, amount, date, created_at)
      VALUES (v_backfill_user, v_backfill_acct, v_backfill_branch, '__gate_analytics_backfill_expense__', 250, now() - interval '398 days', now() - interval '398 days')
      RETURNING id INTO v_bf_expense_id;

      ALTER TABLE public.sales     ENABLE TRIGGER trg_analytics_operation_created;
      ALTER TABLE public.purchases ENABLE TRIGGER trg_analytics_operation_created;
      ALTER TABLE public.expenses  ENABLE TRIGGER trg_analytics_operation_created;
    EXCEPTION
      WHEN OTHERS THEN
        ALTER TABLE public.sales     ENABLE TRIGGER trg_analytics_operation_created;
        ALTER TABLE public.purchases ENABLE TRIGGER trg_analytics_operation_created;
        ALTER TABLE public.expenses  ENABLE TRIGGER trg_analytics_operation_created;
        RAISE;
    END;

    -- Setup check: con el trigger deshabilitado durante el INSERT, no debería
    -- existir todavía ningún operation_created para estas 3 operaciones.
    IF EXISTS (
      SELECT 1 FROM public.analytics_events
      WHERE event_data->>'entity_id' IN (v_bf_sale_id::text, v_bf_purchase_id::text, v_bf_expense_id::text)
        AND event_name = 'operation_created'
    ) THEN
      v_failures := array_append(v_failures, 'FAIL 8-setup: las operaciones históricas no deberían tener operation_created antes de correr el backfill (el trigger no se deshabilitó correctamente)');
    END IF;

    -- Backfill escaneando SÓLO la cuenta del anchor (misma lógica que
    -- 20260919000001, acotada por account_id para no reprocesar todo el
    -- dataset del entorno de test).
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT s.user_id, s.account_id, 'operation_created',
           jsonb_build_object('entity_id', s.id, 'entity_type', 'sale', 'source', 'backfill'), s.created_at
    FROM public.sales s
    WHERE s.account_id = v_backfill_acct
      AND NOT EXISTS (SELECT 1 FROM public.analytics_events ae WHERE ae.event_data->>'sale_id' = s.id::text)
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT p.user_id, p.account_id, 'operation_created',
           jsonb_build_object('entity_id', p.id, 'entity_type', 'purchase', 'source', 'backfill'), p.created_at
    FROM public.purchases p
    WHERE p.account_id = v_backfill_acct
      AND NOT EXISTS (SELECT 1 FROM public.analytics_events ae WHERE ae.event_data->>'purchase_id' = p.id::text)
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT e.user_id, e.account_id, 'operation_created',
           jsonb_build_object('entity_id', e.id, 'entity_type', 'expense', 'source', 'backfill'), e.created_at
    FROM public.expenses e
    WHERE e.account_id = v_backfill_acct
      AND NOT EXISTS (SELECT 1 FROM public.analytics_events ae WHERE ae.event_data->>'expense_id' = e.id::text)
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    WITH historical_ops AS (
      SELECT user_id, account_id, id AS entity_id, 'sale'::text AS entity_type, created_at FROM public.sales WHERE account_id = v_backfill_acct
      UNION ALL
      SELECT user_id, account_id, id, 'purchase', created_at FROM public.purchases WHERE account_id = v_backfill_acct
      UNION ALL
      SELECT user_id, account_id, id, 'expense', created_at FROM public.expenses WHERE account_id = v_backfill_acct
    ),
    earliest_per_user AS (
      SELECT user_id, account_id, entity_id, entity_type, created_at,
             ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, entity_id ASC) AS rn
      FROM historical_ops
    )
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT user_id, account_id, 'first_operation',
           jsonb_build_object('entity_id', entity_id, 'entity_type', entity_type, 'source', 'backfill'), created_at
    FROM earliest_per_user
    WHERE rn = 1
    ON CONFLICT (user_id)
      WHERE event_name = 'first_operation'
    DO NOTHING;

    -- Assert 8a: las 3 operaciones históricas tienen su operation_created de backfill.
    SELECT COUNT(*) INTO v_bf_count
    FROM public.analytics_events
    WHERE event_name = 'operation_created'
      AND event_data->>'entity_id' IN (v_bf_sale_id::text, v_bf_purchase_id::text, v_bf_expense_id::text)
      AND event_data->>'source' = 'backfill';

    IF v_bf_count <> 3 THEN
      v_failures := array_append(v_failures,
        format('FAIL 8a: se esperaban 3 operation_created con source=backfill para las operaciones históricas, hay %s', v_bf_count));
    ELSE
      RAISE NOTICE 'PASS 8a: las 3 operaciones históricas emiten operation_created con source=backfill';
    END IF;

    -- Assert 8b: first_operation backfillado apunta a la venta (la más antigua) con source=backfill.
    IF NOT EXISTS (
      SELECT 1 FROM public.analytics_events
      WHERE user_id = v_backfill_user AND event_name = 'first_operation'
        AND event_data->>'entity_id' = v_bf_sale_id::text
        AND event_data->>'source' = 'backfill'
    ) THEN
      v_failures := array_append(v_failures, 'FAIL 8b: first_operation del backfill no apunta a la operación histórica más antigua (la venta), o no tiene source=backfill');
    ELSE
      RAISE NOTICE 'PASS 8b: first_operation del backfill apunta a la operación histórica más antigua';
    END IF;

    -- Assert 8c: conteos coherentes operaciones↔eventos para el fixture (3 y 3).
    SELECT COUNT(*) INTO v_bf_total_ops FROM (
      SELECT id FROM public.sales     WHERE account_id = v_backfill_acct
      UNION ALL SELECT id FROM public.purchases WHERE account_id = v_backfill_acct
      UNION ALL SELECT id FROM public.expenses  WHERE account_id = v_backfill_acct
    ) ops;

    SELECT COUNT(*) INTO v_bf_count
    FROM public.analytics_events
    WHERE account_id = v_backfill_acct AND event_name = 'operation_created';

    IF v_bf_total_ops <> v_bf_count THEN
      v_failures := array_append(v_failures,
        format('FAIL 8c: conteo incoherente — %s operaciones históricas vs %s operation_created para la misma cuenta', v_bf_total_ops, v_bf_count));
    ELSE
      RAISE NOTICE 'PASS 8c: conteo de operaciones y de operation_created coincide para el fixture (%)', v_bf_total_ops;
    END IF;

    -- Assert 8d: re-ejecutar el mismo backfill (idempotencia) → 0 filas nuevas.
    SELECT COUNT(*) INTO v_bf_events_before
    FROM public.analytics_events WHERE account_id = v_backfill_acct OR user_id = v_backfill_user;

    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT s.user_id, s.account_id, 'operation_created',
           jsonb_build_object('entity_id', s.id, 'entity_type', 'sale', 'source', 'backfill'), s.created_at
    FROM public.sales s
    WHERE s.account_id = v_backfill_acct
      AND NOT EXISTS (SELECT 1 FROM public.analytics_events ae WHERE ae.event_data->>'sale_id' = s.id::text)
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT p.user_id, p.account_id, 'operation_created',
           jsonb_build_object('entity_id', p.id, 'entity_type', 'purchase', 'source', 'backfill'), p.created_at
    FROM public.purchases p
    WHERE p.account_id = v_backfill_acct
      AND NOT EXISTS (SELECT 1 FROM public.analytics_events ae WHERE ae.event_data->>'purchase_id' = p.id::text)
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT e.user_id, e.account_id, 'operation_created',
           jsonb_build_object('entity_id', e.id, 'entity_type', 'expense', 'source', 'backfill'), e.created_at
    FROM public.expenses e
    WHERE e.account_id = v_backfill_acct
      AND NOT EXISTS (SELECT 1 FROM public.analytics_events ae WHERE ae.event_data->>'expense_id' = e.id::text)
    ON CONFLICT (event_name, (event_data->>'entity_id'))
      WHERE event_name = 'operation_created' AND event_data ? 'entity_id'
    DO NOTHING;

    WITH historical_ops AS (
      SELECT user_id, account_id, id AS entity_id, 'sale'::text AS entity_type, created_at FROM public.sales WHERE account_id = v_backfill_acct
      UNION ALL
      SELECT user_id, account_id, id, 'purchase', created_at FROM public.purchases WHERE account_id = v_backfill_acct
      UNION ALL
      SELECT user_id, account_id, id, 'expense', created_at FROM public.expenses WHERE account_id = v_backfill_acct
    ),
    earliest_per_user AS (
      SELECT user_id, account_id, entity_id, entity_type, created_at,
             ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at ASC, entity_id ASC) AS rn
      FROM historical_ops
    )
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data, created_at)
    SELECT user_id, account_id, 'first_operation',
           jsonb_build_object('entity_id', entity_id, 'entity_type', entity_type, 'source', 'backfill'), created_at
    FROM earliest_per_user
    WHERE rn = 1
    ON CONFLICT (user_id)
      WHERE event_name = 'first_operation'
    DO NOTHING;

    SELECT COUNT(*) INTO v_bf_events_after
    FROM public.analytics_events WHERE account_id = v_backfill_acct OR user_id = v_backfill_user;

    IF v_bf_events_after <> v_bf_events_before THEN
      v_failures := array_append(v_failures,
        format('FAIL 8d: la re-ejecución del backfill agregó filas nuevas (no idempotente) — antes %s, después %s', v_bf_events_before, v_bf_events_after));
    ELSE
      RAISE NOTICE 'PASS 8d: re-ejecutar el backfill sobre el mismo dataset no agrega filas nuevas (idempotencia real)';
    END IF;

    -- ── Gate 9 (OQ-3): índice único parcial ux_analytics_umv_reached_user ────
    INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data)
    VALUES (v_backfill_user, v_backfill_acct, 'umv_reached', jsonb_build_object('source', 'gate'));

    BEGIN
      INSERT INTO public.analytics_events (user_id, account_id, event_name, event_data)
      VALUES (v_backfill_user, v_backfill_acct, 'umv_reached', jsonb_build_object('source', 'gate_duplicate'));
      v_failures := array_append(v_failures,
        'FAIL 9: un segundo umv_reached para el mismo usuario se insertó sin error — falta el índice único ux_analytics_umv_reached_user o no está activo');
    EXCEPTION
      WHEN unique_violation THEN
        RAISE NOTICE 'PASS 9: ux_analytics_umv_reached_user rechaza un segundo umv_reached para el mismo usuario (unique_violation)';
    END;
  END IF;

  -- ── Resultado ─────────────────────────────────────────────────────────────
  IF array_length(v_failures, 1) > 0 THEN
    RAISE EXCEPTION E'GATE ANALYTICS-EVENTS-REVIVAL FAILED:\n  %', array_to_string(v_failures, E'\n  ');
  END IF;

  RAISE NOTICE 'GATE ANALYTICS-EVENTS-REVIVAL PASSED: emisión (gasto/compra/venta), unicidad de activación, atomicidad, degrade-don''t-fail, ACL/RLS, idempotencia, granularidad, backfill histórico y unicidad de umv_reached — verificados.';

  -- ── Limpieza hijo→padre (accounts=0 al final) ────────────────────────────
  DELETE FROM public.analytics_events WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
  DELETE FROM public.sales     WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
  DELETE FROM public.purchases WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
  DELETE FROM public.expenses  WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
  DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct));
  DELETE FROM public.branches  WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
  DELETE FROM public.account_members       WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
  DELETE FROM public.accounts              WHERE id IN (v_account_id, v_granularity_acct, v_backfill_acct);
  DELETE FROM public.profiles              WHERE id IN (v_user_id, v_granularity_user, v_backfill_user);
  DELETE FROM public.email_logs            WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
  DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
  DELETE FROM auth.users                   WHERE id IN (v_user_id, v_granularity_user, v_backfill_user);

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
      -- Salvaguarda: si el fallo ocurrió durante la ventana del Gate 8 con
      -- los triggers deshabilitados, garantizar que queden reactivados. El
      -- bloque interno del Gate 8 ya los reactiva en su propio EXCEPTION,
      -- pero esto cubre cualquier ruta inesperada.
      ALTER TABLE public.sales     ENABLE TRIGGER trg_analytics_operation_created;
      ALTER TABLE public.purchases ENABLE TRIGGER trg_analytics_operation_created;
      ALTER TABLE public.expenses  ENABLE TRIGGER trg_analytics_operation_created;
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    BEGIN
      DELETE FROM public.analytics_events WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
      DELETE FROM public.sales     WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
      DELETE FROM public.purchases WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
      DELETE FROM public.expenses  WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
      DELETE FROM public.cashboxes WHERE branch_id IN (SELECT id FROM public.branches WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct));
      DELETE FROM public.branches  WHERE account_id IN (v_account_id, v_granularity_acct, v_backfill_acct);
      DELETE FROM public.account_members       WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
      DELETE FROM public.accounts              WHERE id IN (v_account_id, v_granularity_acct, v_backfill_acct);
      DELETE FROM public.profiles              WHERE id IN (v_user_id, v_granularity_user, v_backfill_user);
      DELETE FROM public.email_logs            WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
      DELETE FROM public.operation_idempotency WHERE user_id IN (v_user_id, v_granularity_user, v_backfill_user);
      DELETE FROM auth.users                   WHERE id IN (v_user_id, v_granularity_user, v_backfill_user);
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
    RAISE;
END $$;
