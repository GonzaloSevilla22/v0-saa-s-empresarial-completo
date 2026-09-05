-- =============================================================================
-- GATE: test_receipts_subscription_charges.sql
-- BUGFIX: receipts-subscription-charges (2026-09-04, governance CRÍTICO —
-- billing, primera suscripción real de mp-real-subscriptions).
--
-- LAGUNA: "Recibos de Pago" del admin y el numerador de recibos
-- (assign_billing_receipt_number(), trigger trg_assign_billing_receipt_number)
-- sólo contemplaban event_type = 'plan_upgraded' (flujo legacy de pago
-- único). Los cobros de suscripción (mp-real-subscriptions) escriben
-- event_type = 'subscription_payment_approved' con TODO lo que un recibo
-- necesita, pero nunca recibían receipt_number ni aparecían en la lista.
-- Caso real: mercadopago_payment_id='176341057469', amount=24900,
-- to_plan='inicial', receipt_number quedó NULL hasta este fix.
--
-- Qué ejercita, con un usuario sintético (mismo molde que otros gates —
-- INSERT INTO auth.users + cleanup por CASCADE al borrar el usuario):
--
--   (1) INTROSPECCIÓN — el cuerpo VIVO (pg_get_functiondef) de
--       assign_billing_receipt_number() contiene AMBOS event_type en la
--       condición del trigger.
--   (2) COMPORTAMIENTO — un INSERT de billing_events con
--       event_type='subscription_payment_approved' y receipt_number no
--       especificado recibe un receipt_number con el formato
--       'RC-YYYY-NNNNNN' (el trigger lo asigna).
--   (3) REGRESIÓN — un INSERT con event_type='plan_upgraded' (el flujo
--       legacy) sigue recibiendo receipt_number exactamente igual que antes
--       de este fix — el fix amplía la condición, no la reemplaza.
--   (4) NEGATIVO — un event_type que NO es ninguno de los dos (ej.
--       'trial_expired', tipo real de billing_events) NO recibe
--       receipt_number — el trigger sigue acotado, no numera cualquier cosa.
--   (5) FACTURA C — el cuerpo VIVO de rpc_emit_subscription_payment_cae()
--       también reconoce 'subscription_payment_approved' (hallazgo real de
--       la verificación de este fix: sin esto, un cobro de suscripción
--       recién visible en la lista seguiría fallando con receipt_not_found
--       al intentar facturarlo — instrucción 2 del brief, "Factura C en
--       routers/fiscal.py si toma el recibo por id").
--   (6) BACKFILL IDEMPOTENTE — se ejercita EL MISMO bloque de backfill de la
--       migración (no una reimplementación) contra una fila sintética con
--       receipt_number NULL (trigger deshabilitado sólo para ese INSERT
--       puntual): la primera corrida le asigna número: la segunda corrida
--       NO lo cambia (WHERE receipt_number IS NULL ya no matchea).
--   (7) UNICIDAD — el índice único billing_events_receipt_number_key sigue
--       vivo: dos recibos nunca comparten número entre los dos flujos.
--
-- Degrade-don't-fail: si el INSERT sintético en auth.users no resuelve (p.ej.
-- políticas locales distintas), el gate emite NOTICE y no aborta — mismo
-- patrón que el resto de los gates con anchor sintético.
--
-- Cleanup: DELETE FROM auth.users al final — billing_events tiene
-- ON DELETE CASCADE, así que las filas sintéticas se van solas. Corre en
-- verde dos veces seguidas sobre la misma base.
-- =============================================================================

DO $$
DECLARE
  v_user            uuid := gen_random_uuid();
  v_email           text := 'gate-receipts-subscription-' || v_user::text || '@example.com';
  v_def_trigger     text;
  v_def_rpc         text;
  v_receipt_sub     text;
  v_receipt_legacy  text;
  v_receipt_other   text;
  v_backfill_id     uuid := gen_random_uuid();
  v_backfill_after1 text;
  v_backfill_after2 text;
  v_dup_count       integer;
  v_idx_def         text;
BEGIN
  -- ── setup: usuario sintético (billing_events.user_id FK → auth.users) ──────
  BEGIN
    INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
    VALUES (v_user, 'authenticated', 'authenticated', v_email, now(), now(),
            jsonb_build_object('name', 'Gate Receipts Subscription', 'phone', '', 'locality', '', 'province', ''))
    ON CONFLICT (id) DO NOTHING;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'DEGRADE (setup): no se pudo crear el usuario sintético (%). Gate omitido sin abortar.', SQLERRM;
    RETURN;
  END;

  -- ── (1) introspección: el trigger reconoce ambos event_type ────────────────
  SELECT pg_get_functiondef('public.assign_billing_receipt_number'::regproc) INTO v_def_trigger;

  IF position('plan_upgraded' in v_def_trigger) = 0
     OR position('subscription_payment_approved' in v_def_trigger) = 0 THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (1): el cuerpo vivo de assign_billing_receipt_number() no reconoce los dos event_type ("plan_upgraded" y "subscription_payment_approved"). Aplicá 20261029000001. Cuerpo vivo: %', v_def_trigger;
  END IF;
  RAISE NOTICE 'PASS (1): assign_billing_receipt_number() reconoce ambos event_type.';

  -- ── (2) comportamiento: subscription_payment_approved recibe número ────────
  INSERT INTO public.billing_events (user_id, event_type, to_plan, amount, mercadopago_payment_id)
  VALUES (v_user, 'subscription_payment_approved', 'inicial', 24900, 'gate-sub-' || v_user::text)
  RETURNING receipt_number INTO v_receipt_sub;

  IF v_receipt_sub IS NULL THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (2): un billing_events subscription_payment_approved quedó con receipt_number NULL — exactamente el bug del caso real (mercadopago_payment_id 176341057469).';
  END IF;

  IF v_receipt_sub !~ '^RC-\d{4}-\d{6}$' THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (2): el receipt_number asignado (%) no matchea el formato RC-YYYY-NNNNNN.', v_receipt_sub;
  END IF;
  RAISE NOTICE 'PASS (2): subscription_payment_approved recibe receipt_number (%).', v_receipt_sub;

  -- ── (3) regresión: plan_upgraded (legacy) sigue igual ───────────────────────
  INSERT INTO public.billing_events (user_id, event_type, to_plan, amount, mercadopago_payment_id)
  VALUES (v_user, 'plan_upgraded', 'pro', 69900, 'gate-legacy-' || v_user::text)
  RETURNING receipt_number INTO v_receipt_legacy;

  IF v_receipt_legacy IS NULL OR v_receipt_legacy !~ '^RC-\d{4}-\d{6}$' THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (3): plan_upgraded dejó de recibir un receipt_number válido (%) — el fix tiene que AMPLIAR la condición, no reemplazarla.', v_receipt_legacy;
  END IF;
  RAISE NOTICE 'PASS (3): plan_upgraded (legacy) sigue numerando igual (%).', v_receipt_legacy;

  -- ── (4) negativo: un event_type ajeno no recibe número ──────────────────────
  INSERT INTO public.billing_events (user_id, event_type)
  VALUES (v_user, 'trial_expired')
  RETURNING receipt_number INTO v_receipt_other;

  IF v_receipt_other IS NOT NULL THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (4): un event_type ajeno (trial_expired) recibió receipt_number (%) — el trigger dejó de estar acotado.', v_receipt_other;
  END IF;
  RAISE NOTICE 'PASS (4): un event_type ajeno no recibe receipt_number.';

  -- ── (5) Factura C: rpc_emit_subscription_payment_cae reconoce ambos ─────────
  SELECT pg_get_functiondef('public.rpc_emit_subscription_payment_cae'::regproc) INTO v_def_rpc;

  IF position('subscription_payment_approved' in v_def_rpc) = 0 THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (5): rpc_emit_subscription_payment_cae() todavía sólo resuelve billing_events con event_type=''plan_upgraded'' — un cobro de suscripción visible en "Recibos de Pago" seguiría fallando con receipt_not_found al intentar facturarlo. Cuerpo vivo: %', v_def_rpc;
  END IF;
  RAISE NOTICE 'PASS (5): rpc_emit_subscription_payment_cae() reconoce subscription_payment_approved.';

  -- ── (6) backfill idempotente: mismo bloque que la migración, 2 corridas ─────
  ALTER TABLE public.billing_events DISABLE TRIGGER trg_assign_billing_receipt_number;
  INSERT INTO public.billing_events (id, user_id, event_type, to_plan, amount, mercadopago_payment_id, receipt_number, created_at)
  VALUES (v_backfill_id, v_user, 'subscription_payment_approved', 'avanzado', 39900, 'gate-backfill-' || v_user::text, NULL, now());
  ALTER TABLE public.billing_events ENABLE TRIGGER trg_assign_billing_receipt_number;

  -- primera corrida: mismo UPDATE que el DO block de 20261029000001, acotado
  -- por WHERE receipt_number IS NULL — sólo toca la fila recién insertada.
  UPDATE public.billing_events
  SET    receipt_number =
           'RC-' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY') || '-' ||
           lpad(nextval('billing_receipt_seq')::text, 6, '0')
  WHERE  id = v_backfill_id AND receipt_number IS NULL;

  SELECT receipt_number INTO v_backfill_after1 FROM public.billing_events WHERE id = v_backfill_id;

  IF v_backfill_after1 IS NULL OR v_backfill_after1 !~ '^RC-\d{4}-\d{6}$' THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (6a): el backfill no asignó un receipt_number válido a la fila sintética con receipt_number NULL (resultado: %).', v_backfill_after1;
  END IF;

  -- segunda corrida (reaplicar la migración): no-op, el WHERE ya no matchea.
  UPDATE public.billing_events
  SET    receipt_number =
           'RC-' || to_char(created_at AT TIME ZONE 'UTC', 'YYYY') || '-' ||
           lpad(nextval('billing_receipt_seq')::text, 6, '0')
  WHERE  id = v_backfill_id AND receipt_number IS NULL;

  SELECT receipt_number INTO v_backfill_after2 FROM public.billing_events WHERE id = v_backfill_id;

  IF v_backfill_after2 IS DISTINCT FROM v_backfill_after1 THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (6b): reaplicar el backfill CAMBIÓ el receipt_number (% -> %) — no es idempotente, renumeraría en cada reaplicación de la migración.', v_backfill_after1, v_backfill_after2;
  END IF;
  RAISE NOTICE 'PASS (6): backfill asigna número (%) y reaplicarlo es un no-op.', v_backfill_after1;

  -- ── (7) unicidad: el índice único sobre receipt_number sigue vivo ───────────
  SELECT indexdef INTO v_idx_def
  FROM   pg_indexes
  WHERE  schemaname = 'public' AND tablename = 'billing_events'
    AND  indexname = 'billing_events_receipt_number_key';

  IF v_idx_def IS NULL THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (7): falta billing_events_receipt_number_key — sin el índice único, dos recibos de flujos distintos podrían terminar con el mismo número.';
  END IF;

  SELECT count(*) INTO v_dup_count
  FROM   public.billing_events
  WHERE  receipt_number IN (v_receipt_sub, v_receipt_legacy, v_backfill_after1)
  GROUP  BY receipt_number
  HAVING count(*) > 1;

  IF v_dup_count > 0 THEN
    RAISE EXCEPTION 'GATE RECEIPTS-SUBSCRIPTION-CHARGES FAILED (7): se detectaron receipt_number duplicados entre los flujos.';
  END IF;
  RAISE NOTICE 'PASS (7): billing_events_receipt_number_key vivo, sin duplicados entre flujos.';

  RAISE NOTICE 'GATE RECEIPTS-SUBSCRIPTION-CHARGES: TODOS LOS ASSERTS PASARON.';
END;
$$;

-- ── cleanup: billing_events se va por CASCADE. accounts (auto-provisioning
-- de la cuenta + sucursal por defecto al crear el usuario) tiene FK sin
-- CASCADE, hay que borrarla antes que auth.users. Además
-- trg_guard_branch_decommission (sucursal-guard-vaciado-auditoria) prohíbe
-- el borrado físico de una sucursal aun en cascada — mismo bypass que usan
-- los demás gates con anchors sintéticos: session_replication_role=replica
-- sólo alrededor del DELETE que la dispara.
DO $$
DECLARE
  v_ids uuid[];
BEGIN
  SELECT array_agg(id) INTO v_ids
  FROM auth.users WHERE email LIKE 'gate-receipts-subscription-%@example.com';

  DELETE FROM public.account_members WHERE user_id = ANY(v_ids);
  SET session_replication_role = replica;
  DELETE FROM public.accounts WHERE owner_user_id = ANY(v_ids);
  SET session_replication_role = DEFAULT;
  DELETE FROM public.profiles WHERE id = ANY(v_ids);
  DELETE FROM auth.users      WHERE id = ANY(v_ids);
EXCEPTION WHEN OTHERS THEN
  SET session_replication_role = DEFAULT;
  RAISE NOTICE 'DEGRADE (cleanup): no se pudo limpiar el usuario sintético (%).', SQLERRM;
END;
$$;
