-- ═══════════════════════════════════════════════════════════════════════════
-- test_outbox_single_dispatcher.sql — un solo despachador del outbox
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Origen: tenancy-guard-caja-outbox, tramo h2/h2 bis (hotfix 2026-08-24, OQ-1
-- firmada por el PO). Este archivo NO es cobertura nueva "de yapa": es el
-- **nuevo domicilio** de los invariantes de comportamiento que hasta hoy
-- cubrían los cinco archivos de tests del relay Python retirado
-- (backend/tests/outbox/test_audit_consumer.py, test_email_consumer.py,
-- test_idempotency.py, test_relay_select.py, test_e2e_outbox.py).
--
-- Por qué mudarlos y no borrarlos. `OutboxRelayService` era una segunda
-- implementación —incompleta— del relay: corría 2 de los 4 consumers
-- (AuditLog y EmailNotification) y marcaba `processed_at` igual, compitiendo
-- con `rpc_process_outbox_dispatch` por el mismo flag. Todo evento que ganaba
-- el relay Python perdía para siempre su asiento contable (Consumer 3) y su
-- notificación (Consumer 4). Se retiró el servicio; los invariantes que sus
-- tests afirmaban —con mocks— siguen siendo verdad del sistema, y acá se
-- afirman contra el despachador REAL en Postgres real, que es una prueba más
-- fuerte que la que se retira.
--
-- Dónde queda cada invariante (tabla completa en el PR del hotfix):
--   · orden y presencia de los 4 consumers, etiquetas de consumer_type,
--     sentinel de idempotencia, FOR UPDATE SKIP LOCKED, "nunca UPDATE/DELETE
--     sobre audit_logs" → backend/tests/migrations/test_events_reconcile.py,
--     aserciones ESTÁTICAS sobre el texto de la migración. Ojo con la letra
--     chica, porque una versión previa de este encabezado decía "sobre el SQL
--     vivo del dispatcher" y NO era cierto: ese job de pytest corre sin DB
--     (suite hermética, ver .github/workflows/Backend_Tests.yml) y por lo
--     tanto no puede leer `pg_get_functiondef`. Lo más cerca del cuerpo vivo
--     que puede estar es la migración MÁS NUEVA que redefine la función
--     —hoy 20261005000001_delete_guard_ledgers.sql, cuyo cuerpo se verificó
--     byte a byte idéntico al `prosrc` vivo el 2026-08-24— y ahí apuntan
--     ahora esas aserciones, con un test propio que falla si aparece una
--     redefinición más nueva y nadie mueve el puntero.
--   · comportamiento en runtime (lo que los mocks simulaban) → ESTE archivo,
--     contra el despachador REAL. Incluye el scope COMPLETO del email: los
--     tres tipos in-scope (sale_created, stock_adjusted, plan_changed) y uno
--     fuera de scope, los cuatro con su efecto verificado.
--   · que nadie más pueda marcar processed_at → chequeo (5) de
--     test_function_acl_gate.sql + gate (6) de acá (redundancia deliberada,
--     mismo criterio que los chequeos (3) y (4) de aquel archivo).
--
-- Aislamiento: TODO el archivo corre dentro de un BEGIN … ROLLBACK explícito.
-- No es adorno: `rpc_process_outbox_dispatch` procesa TODO lo pendiente de la
-- base, no sólo la cuenta sintética de este gate (su lote se elige por
-- `processed_at IS NULL`, sin filtro de cuenta — es un relay). En CI la base
-- nace de un `db reset` y no hay nada ajeno, pero en un stack local COMPARTIDO
-- —el caso normal en este proyecto— una corrida sin rollback le drenaba el
-- outbox a las cuentas de prueba de otra sesión, y el chequeo (7) de "cero
-- residuos" no lo veía porque sólo mira la cuenta sintética. Con el ROLLBACK,
-- el gate no deja NADA: ni sus filas ni el `processed_at` de eventos ajenos.
-- El rollback es correcto porque la RPC es una FUNCTION plpgsql y por lo tanto
-- NO puede hacer COMMIT propio (verificado además sobre el cuerpo vivo: cero
-- ocurrencias de COMMIT/ROLLBACK/dblink/pg_background); sus BEGIN/EXCEPTION
-- por evento son subtransacciones, que la transacción externa revierte igual.
--
-- Cuenta sintética fija, además del rollback: `public.events`,
-- `public.audit_logs` y `public.email_logs` no tienen FK a `accounts`
-- (verificado 2026-08-24), así que el gate no necesita provisionar un tenant —
-- un UUID reservado alcanza y las aserciones pueden ser exactas.
--
-- Cleanup: se limpia AL PRINCIPIO y AL FINAL igual, y el chequeo (7) verifica
-- cero residuos, para que el archivo siga siendo correcto si alguien lo corre
-- suelto sin la transacción. Corre dos veces seguidas en verde.
--
-- Usa RAISE EXCEPTION para que psql retorne exit code 1 en cualquier falla.
-- Requiere -v ON_ERROR_STOP=1 (sin la flag psql imprime los errores y sale 0,
-- y además NO llegaría al ROLLBACK final con la transacción abortada).
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

DO $$
DECLARE
  -- UUID reservado para este gate. No pertenece a ninguna cuenta real.
  v_acc CONSTANT uuid := '0ba7e001-0000-4000-8000-000000000001';
  v_ev_email     uuid;   -- 'sale_created'      → AuditLog + Email
  v_ev_stock     uuid;   -- 'stock_adjusted'    → AuditLog + Email (2º tipo in-scope)
  v_ev_plan      uuid;   -- 'plan_changed'      → AuditLog + Email (3º tipo in-scope)
  v_ev_neutral   uuid;   -- fuera del scope de todos salvo AuditLog
  v_ev_fallido   uuid;   -- 'CreditNoteIssued' sin asiento original → Consumer 3 revienta
  v_procesados   int;
  v_n            int;
  v_audit_1      int;
  v_email_1      int;
BEGIN
  -- ── Pre-limpieza (hace el archivo re-corrible aunque una corrida anterior
  --    haya abortado a mitad de camino) ──────────────────────────────────────
  DELETE FROM public.operation_idempotency
   WHERE event_id IN (SELECT id FROM public.events WHERE account_id = v_acc);
  DELETE FROM public.audit_logs WHERE account_id = v_acc;
  DELETE FROM public.email_logs WHERE metadata->>'account_id' = v_acc::text;
  DELETE FROM public.events     WHERE account_id = v_acc;

  -- ── Semilla: cinco eventos pendientes de la cuenta sintética ──────────────
  -- Los TRES tipos in-scope del Consumer 2 están representados. No es
  -- redundancia: el scope del email es un CASE de tres ramas más un ELSE, y
  -- con un solo tipo sembrado el gate verificaba una rama y confiaba en el
  -- resto. Ahora las cuatro ramas se ejercitan en runtime, en la misma corrida.
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'sale_created', 'Sale', gen_random_uuid(),
          jsonb_build_object('email', 'gate-outbox@example.invalid'), now())
  RETURNING id INTO v_ev_email;

  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'stock_adjusted', 'Product', gen_random_uuid(),
          jsonb_build_object('email', 'gate-stock@example.invalid'), now())
  RETURNING id INTO v_ev_stock;

  -- Sin 'email' en el payload: ejercita además el COALESCE del destinatario,
  -- que cae a 'account:<uuid>' cuando el evento no trae mail.
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'plan_changed', 'Account', gen_random_uuid(), '{}'::jsonb, now())
  RETURNING id INTO v_ev_plan;

  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'OutboxGateNeutralEvent', 'Probe', gen_random_uuid(), '{}'::jsonb, now())
  RETURNING id INTO v_ev_neutral;

  -- CreditNoteIssued apuntando a una orden inexistente: _journal_post_from_event
  -- levanta journal_entry_original_not_found. Es la forma más limpia de
  -- provocar un fallo REAL del Consumer 3 sin romper nada.
  INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (v_acc, 'CreditNoteIssued', 'SalesOrder', gen_random_uuid(),
          jsonb_build_object('source_sales_order_id', gen_random_uuid()), now())
  RETURNING id INTO v_ev_fallido;

  -- ═════════════════════════════════════════════════════════════════════════
  -- Corrida 1 del despachador
  -- ═════════════════════════════════════════════════════════════════════════
  SELECT public.rpc_process_outbox_dispatch(1000) INTO v_procesados;

  -- ── (1) Camino feliz: processed_at + AuditLog + Email ─────────────────────
  -- Reemplaza: test_relay_select::test_relay_processes_pending_events /
  -- test_relay_marks_processed_after_consumers_succeed,
  -- test_audit_consumer::test_audit_consumer_writes_one_row,
  -- test_email_consumer::test_email_for_in_scope_type,
  -- test_e2e_outbox::test_sale_created_to_audit_log.
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = v_ev_email AND processed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (1): el evento sale_created % quedó sin processed_at tras la corrida del despachador.', v_ev_email;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.audit_logs WHERE account_id = v_acc AND action = 'sale_created';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (1): el Consumer 1 (AuditLog) debe escribir exactamente 1 fila para el evento sale_created — encontradas %.', v_n;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.email_logs
  WHERE metadata->>'event_id' = v_ev_email::text
    AND event_type = 'sale_created'
    AND status     = 'pending'
    AND subject    = 'Nueva venta registrada'
    AND recipient  = 'gate-outbox@example.invalid';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (1): el Consumer 2 (Email) debe dejar exactamente 1 fila pending en email_logs con el subject y el destinatario del payload — encontradas %.', v_n;
  END IF;

  -- Marcadores de idempotencia: uno por consumer que corrió.
  SELECT count(*) INTO v_n
  FROM public.operation_idempotency
  WHERE event_id = v_ev_email
    AND operation_kind = 'event_consumer'
    AND consumer_type IN ('AuditLog', 'EmailNotification');
  IF v_n <> 2 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (1): esperaba 2 marcadores de idempotencia (AuditLog + EmailNotification) para el evento sale_created — encontrados %.', v_n;
  END IF;

  -- ── (2) Scoping del Consumer 2: EXACTAMENTE 3 tipos generan email ─────────
  -- Reemplaza: test_email_consumer::test_no_email_for_out_of_scope_type y
  -- test_email_scope_contains_expected_types (que afirmaban lo mismo sobre la
  -- constante EMAIL_EVENT_TYPES del servicio retirado). El scope se verifica
  -- ENTERO: los tres tipos in-scope con su subject, más uno fuera de scope.
  SELECT count(*) INTO v_n
  FROM public.email_logs
  WHERE metadata->>'event_id' = v_ev_stock::text
    AND event_type = 'stock_adjusted'
    AND status     = 'pending'
    AND subject    = 'Ajuste de stock realizado'
    AND recipient  = 'gate-stock@example.invalid';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): stock_adjusted está dentro del scope del Consumer 2 y debe dejar 1 fila pending con su propio subject — encontradas %.', v_n;
  END IF;

  -- plan_changed viene SIN 'email' en el payload: el destinatario tiene que
  -- caer al COALESCE 'account:<uuid>', no quedar NULL ni saltear el consumer.
  SELECT count(*) INTO v_n
  FROM public.email_logs
  WHERE metadata->>'event_id' = v_ev_plan::text
    AND event_type = 'plan_changed'
    AND status     = 'pending'
    AND subject    = 'Tu plan ha sido actualizado'
    AND recipient  = 'account:' || v_acc::text;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): plan_changed está dentro del scope del Consumer 2 y, sin email en el payload, su destinatario debe caer al COALESCE account:<uuid> — filas encontradas %.', v_n;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = v_ev_stock AND processed_at IS NOT NULL)
     OR NOT EXISTS (SELECT 1 FROM public.events WHERE id = v_ev_plan AND processed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): stock_adjusted (%) y plan_changed (%) deben quedar procesados tras la corrida.', v_ev_stock, v_ev_plan;
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = v_ev_neutral AND processed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): un evento fuera del scope de los Consumers 2/3/4 igual debe procesarse (sólo AuditLog corre) — % quedó pendiente.', v_ev_neutral;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.audit_logs WHERE account_id = v_acc AND action = 'OutboxGateNeutralEvent';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): el Consumer 1 corre para TODO evento, sin filtro de tipo — filas de audit para el evento neutro: %.', v_n;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.email_logs WHERE metadata->>'event_id' = v_ev_neutral::text;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): un evento fuera de (sale_created, stock_adjusted, plan_changed) NO debe generar email — filas: %.', v_n;
  END IF;

  -- ── (3) Consumer fallido: sin processed_at, sin efectos parciales, sin
  --        abortar el resto del lote ─────────────────────────────────────────
  -- Reemplaza: test_relay_select::test_relay_marks_processed_at_only_after_
  -- audit_commits / test_consumer_failure_leaves_event_unprocessed /
  -- test_one_event_failure_does_not_abort_others,
  -- test_audit_consumer::test_audit_failure_keeps_event_unprocessed,
  -- test_e2e_outbox::test_relay_raises_leaves_processed_at_null.
  -- Es el invariante que más caro sale perder: sin él, un consumer roto cierra
  -- eventos en silencio y la contabilidad se pierde sin que nadie se entere.
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = v_ev_fallido AND processed_at IS NULL) THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (3): un evento cuyo Consumer 3 falla NO debe quedar marcado como procesado — % quedó cerrado sin su asiento.', v_ev_fallido;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.audit_logs WHERE account_id = v_acc AND action = 'CreditNoteIssued';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (3): el aislamiento por evento (BEGIN/EXCEPTION/END) debe revertir TODOS los efectos del evento fallido, incluida la fila de audit del Consumer 1 — encontradas %.', v_n;
  END IF;

  SELECT count(*) INTO v_n
  FROM public.operation_idempotency WHERE event_id = v_ev_fallido;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (3): un marcador de idempotencia sobreviviente al evento fallido impediría que el retry vuelva a correr ese consumer — encontrados %.', v_n;
  END IF;

  IF v_procesados < 4 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (3): el fallo de UN evento no debe abortar el lote — el despachador informó % procesados, esperaba al menos los 4 sanos (sale_created, stock_adjusted, plan_changed y el neutro).', v_procesados;
  END IF;

  -- Cierre del scope del email: exactamente 3 filas para la cuenta sintética,
  -- una por tipo in-scope. Ni el neutro ni el fallido aportan ninguna.
  SELECT count(*) INTO v_n
  FROM public.email_logs WHERE metadata->>'account_id' = v_acc::text;
  IF v_n <> 3 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (2): el Consumer 2 debe generar exactamente 3 emails (uno por tipo in-scope) para los 5 eventos sembrados — encontrados %.', v_n;
  END IF;

  -- ═════════════════════════════════════════════════════════════════════════
  -- Corrida 2 — reproceso
  -- ═════════════════════════════════════════════════════════════════════════
  SELECT count(*) INTO v_audit_1 FROM public.audit_logs WHERE account_id = v_acc;
  SELECT count(*) INTO v_email_1 FROM public.email_logs WHERE metadata->>'account_id' = v_acc::text;

  PERFORM public.rpc_process_outbox_dispatch(1000);

  -- ── (4) Reproceso idempotente: cero duplicados ────────────────────────────
  -- Reemplaza: test_idempotency::test_reprocessed_event_one_audit_row /
  -- test_independent_idempotency_per_consumer,
  -- test_e2e_outbox::test_event_processed_twice_is_idempotent /
  -- test_concurrent_relay_runs_do_not_double_process.
  SELECT count(*) INTO v_n FROM public.audit_logs WHERE account_id = v_acc;
  IF v_n <> v_audit_1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (4): reprocesar duplicó filas de audit_logs (antes=%, después=%) — la idempotencia por (event_id, consumer_type) no está funcionando.', v_audit_1, v_n;
  END IF;

  SELECT count(*) INTO v_n FROM public.email_logs WHERE metadata->>'account_id' = v_acc::text;
  IF v_n <> v_email_1 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (4): reprocesar duplicó filas de email_logs (antes=%, después=%).', v_email_1, v_n;
  END IF;

  -- ── (5) El evento fallido se reintenta, nunca se cierra en silencio ───────
  -- Reemplaza: test_e2e_outbox::test_relay_retries_on_next_run.
  IF NOT EXISTS (SELECT 1 FROM public.events WHERE id = v_ev_fallido AND processed_at IS NULL) THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (5): el evento fallido debe seguir pendiente tras la segunda corrida (retry), no cerrarse — % quedó marcado.', v_ev_fallido;
  END IF;

  -- ── (6) Un solo despachador: nadie más puede marcar processed_at ──────────
  -- El invariante estructural detrás de todo el hotfix. Redundante a propósito
  -- con el chequeo (5) de test_function_acl_gate.sql: acá se afirma como
  -- propiedad del dominio del outbox, allá como propiedad del inventario de
  -- ACLs. Un GRANT que se cuele tiene que hacer sonar las dos alarmas.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    IF has_function_privilege('authenticated', 'public.rpc_process_outbox_batch(integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.rpc_process_outbox_batch(integer)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (6): rpc_process_outbox_batch volvió a ser alcanzable desde el rol de aplicación — devuelve el payload completo de los eventos de TODOS los tenants. Ver 20261012000001_revoke_outbox_cross_tenant.sql.';
    END IF;
    IF has_function_privilege('authenticated', 'public.rpc_mark_event_processed(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.rpc_mark_event_processed(uuid)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (6): rpc_mark_event_processed volvió a ser alcanzable desde el rol de aplicación — cerrar un evento ajeno suprime su asiento contable para siempre. Ver 20261012000001_revoke_outbox_cross_tenant.sql.';
    END IF;
    IF has_function_privilege('authenticated', 'public.rpc_process_outbox_dispatch(integer)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.rpc_process_outbox_dispatch(integer)'::regprocedure, 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (6): rpc_process_outbox_dispatch quedó expuesta — el despachador completo se dispara por el camino de servicio con require_platform_admin, no por PostgREST.';
    END IF;

    -- ── (6 bis) La puerta de al lado: la TABLA public.events ────────────────
    -- Revocar las tres RPCs y dejar la tabla escribible sería mover el
    -- picaporte de lado: `processed_at` es una columna común y un
    -- `PATCH /rest/v1/events?id=eq.<uuid>` la cierra igual de bien que la RPC.
    -- Hoy eso no funciona por una sola razón —la tabla tiene RLS con dos
    -- policies, `events_select` (r) y `events_writer_insert` (a), y ninguna de
    -- UPDATE ni de DELETE; un UPDATE sin policy afecta 0 filas y NO da error—,
    -- o sea que la puerta la cerraba la AUSENCIA de una policy y nadie lo
    -- afirmaba. Acá se afirma por los dos lados: sin privilegio de tabla Y sin
    -- policy de escritura alcanzable desde el rol de aplicación.
    IF to_regclass('public.events') IS NOT NULL THEN
      IF has_table_privilege('authenticated', 'public.events', 'UPDATE')
         OR has_table_privilege('authenticated', 'public.events', 'DELETE')
         OR has_table_privilege('anon', 'public.events', 'UPDATE')
         OR has_table_privilege('anon', 'public.events', 'DELETE') THEN
        RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (6 bis): anon o authenticated conservan UPDATE/DELETE sobre la TABLA public.events. Con una policy de escritura —presente o futura— eso alcanza para cerrar eventos ajenos por PostgREST sin tocar ninguna RPC. Ver 20261012000001_revoke_outbox_cross_tenant.sql §2.';
      END IF;

      SELECT count(*) INTO v_n
      FROM pg_policy p
      JOIN pg_class c ON c.oid = p.polrelid
      JOIN pg_namespace ns ON ns.oid = c.relnamespace
      WHERE ns.nspname = 'public' AND c.relname = 'events'
        AND p.polcmd IN ('w', 'd', '*')          -- UPDATE, DELETE, ALL
        AND (   p.polroles = '{0}'::oid[]        -- PUBLIC ⇒ alcanza a authenticated
             OR 'authenticated'::regrole::oid = ANY (p.polroles));

      IF v_n <> 0 THEN
        RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (6 bis): apareció(n) % policy/policies de UPDATE/DELETE/ALL sobre public.events alcanzable(s) por authenticated. El outbox es append-only para el rol de aplicación: sólo el despachador (SECURITY DEFINER, owner) cierra eventos. Si la policy hace falta por otro motivo, primero justificarla en el PR y decidir explícitamente qué pasa con processed_at.', v_n;
      END IF;
    END IF;
  END IF;

  -- ── Cleanup ───────────────────────────────────────────────────────────────
  DELETE FROM public.operation_idempotency
   WHERE event_id IN (SELECT id FROM public.events WHERE account_id = v_acc);
  DELETE FROM public.audit_logs WHERE account_id = v_acc;
  DELETE FROM public.email_logs WHERE metadata->>'account_id' = v_acc::text;
  DELETE FROM public.events     WHERE account_id = v_acc;

  -- ── (7) Cero residuos: el gate no ensucia la DB de la corrida de CI ───────
  SELECT (SELECT count(*) FROM public.events     WHERE account_id = v_acc)
       + (SELECT count(*) FROM public.audit_logs WHERE account_id = v_acc)
       + (SELECT count(*) FROM public.email_logs WHERE metadata->>'account_id' = v_acc::text)
    INTO v_n;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'GATE OUTBOX-DISPATCHER FAILED (7): el cleanup dejó % filas de la cuenta sintética — la segunda corrida del gate arrancaría sucia.', v_n;
  END IF;

  RAISE NOTICE 'GATE OUTBOX-DISPATCHER OK: consumers 1/2 con efecto verificado, scope de email completo (3 tipos in-scope + 1 fuera), evento fallido sin processed_at ni efectos parciales, lote no abortado, reproceso sin duplicados, retry preservado, outbox fuera del alcance del rol de aplicación (funciones Y tabla), cero residuos.';
END $$;

-- El ROLLBACK es parte del contrato del gate, no una precaución: deshace
-- también el `processed_at` que el despachador le haya puesto a eventos
-- pendientes AJENOS de un stack local compartido (procesa por
-- `processed_at IS NULL`, sin filtro de cuenta). Ver el encabezado.
ROLLBACK;
