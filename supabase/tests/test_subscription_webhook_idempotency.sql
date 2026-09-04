-- =============================================================================
-- GATE: test_subscription_webhook_idempotency.sql
-- HOTFIX: subscription-webhook-idempotency-contract (2026-09-04, dinero real).
--
-- 20261027000001 amplía operation_idempotency_operation_id_contract para
-- eximir también a operation_kind = 'subscription_webhook' (no sólo
-- 'event_consumer'). Antes de este fix, TODA notificación de webhook de
-- suscripción de MercadoPago moría con 23514 (CheckViolationError) →
-- backend/core/errors.py la mapea 1:1 a HTTP 422 — exactamente lo que
-- MercadoPago recibía en prod para type=subscription_preapproval y
-- type=subscription_authorized_payment (0 filas en subscriptions y en
-- operation_idempotency WHERE operation_kind='subscription_webhook').
--
-- Qué ejercita:
--   (1) INSERT con operation_kind='subscription_webhook' y operation_id
--       NULL → ÉXITO (la exención nueva). Es exactamente lo que hace
--       backend/services/subscriptions.py::_claim_subscription_webhook_idempotency.
--   (2) INSERT con operation_kind='sale' y operation_id NULL → sigue
--       rechazado con 23514 — el contrato NO se debilitó para el resto de
--       los kinds, sólo se le sumó una excepción puntual.
--   (3) Introspección: el CHECK vivo (pg_get_constraintdef) contiene
--       'subscription_webhook' junto a 'event_consumer' en la exención.
--   (4) Idempotencia de la migración: reaplicar el DROP+ADD dos veces en
--       esta misma corrida deja exactamente UNA constraint con ese nombre.
--
-- RED (antes de 20261027000001): (1) falla con 23514 → el DO block del
-- assert 1 lanza RAISE EXCEPTION y el gate completo sale en rojo.
-- GREEN (con la migración aplicada): los 4 asserts pasan.
--
-- -v ON_ERROR_STOP=1 obligatorio: sin la flag psql imprime los RAISE
-- EXCEPTION y sale 0, o sea que un assert fallido se vería verde.
-- Cleanup: cada fila insertada por este gate se borra al final por su
-- idempotency_key sintética — corre en verde dos veces seguidas sobre la
-- misma base sin dejar residuos ni colisionar con la corrida anterior.
-- =============================================================================

DO $$
DECLARE
  v_user            uuid := gen_random_uuid();
  v_key             text := 'gate-subscription-webhook-' || v_user::text;
  v_sale_key        text := 'gate-sale-no-operation-id-' || v_user::text;
  v_status          text;
  v_rejected        boolean;
  v_condef          text;
  v_constraint_count integer;
BEGIN

  -- ── (1) subscription_webhook con operation_id NULL → ÉXITO ────────────────
  -- Mismo INSERT literal que _claim_subscription_webhook_idempotency: sin
  -- operation_id, user_id sentinel-shaped (acá uno propio del gate para no
  -- pisar el sentinel real 00000000-0000-0000-0000-000000000000).
  BEGIN
    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind)
    VALUES (v_user, v_key, 'subscription_webhook');
  EXCEPTION
    WHEN check_violation THEN
      RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (1): INSERT operation_kind=''subscription_webhook'' con operation_id NULL fue RECHAZADO por un CHECK — la exención de 20261027000001 no está viva. Aplicá la migración.';
  END;

  PERFORM 1 FROM public.operation_idempotency
  WHERE user_id = v_user AND operation_kind = 'subscription_webhook' AND idempotency_key = v_key
    AND operation_id IS NULL;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (1): el INSERT no dejó la fila esperada (operation_id NULL).';
  END IF;
  RAISE NOTICE 'PASS (1): subscription_webhook con operation_id NULL se acepta.';

  -- ── (2) sale con operation_id NULL → sigue RECHAZADO (23514) ──────────────
  v_rejected := false;
  BEGIN
    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind)
    VALUES (v_user, v_sale_key, 'sale');
  EXCEPTION
    WHEN check_violation THEN v_rejected := true;
  END;
  IF NOT v_rejected THEN
    RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (2): operation_kind=''sale'' con operation_id NULL fue ACEPTADO — el contrato por-fila se debilitó para kinds que no son la exención nueva.';
  END IF;
  RAISE NOTICE 'PASS (2): sale con operation_id NULL sigue rechazado — el contrato del resto de los kinds está intacto.';

  -- ── (3) Introspección: el CHECK vivo incluye ambos kinds exentos ──────────
  SELECT pg_get_constraintdef(oid) INTO v_condef
  FROM pg_constraint
  WHERE conrelid = 'public.operation_idempotency'::regclass
    AND conname  = 'operation_idempotency_operation_id_contract';

  IF v_condef IS NULL THEN
    RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (3): no existe operation_idempotency_operation_id_contract.';
  END IF;

  IF position('''subscription_webhook''' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (3): el CHECK vivo no menciona subscription_webhook. Definición viva: %', v_condef;
  END IF;

  IF position('''event_consumer''' in v_condef) = 0 THEN
    RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (3): el CHECK vivo perdió la exención original de event_consumer. Definición viva: %', v_condef;
  END IF;
  RAISE NOTICE 'PASS (3): el CHECK vivo exime event_consumer Y subscription_webhook. Definición: %', v_condef;

  -- Cleanup de este gate (antes del check de idempotencia, para no
  -- interferir con la re-aplicación de la migración).
  DELETE FROM public.operation_idempotency WHERE user_id = v_user;

  RAISE NOTICE '=== All subscription-webhook-idempotency-contract tests passed (3/3) ===';
END;
$$;

-- ── (4) Idempotencia de la migración: reaplicar el DROP+ADD dos veces ───────
-- deja exactamente UNA constraint con ese nombre y la misma definición.
DO $$
DECLARE
  v_count integer;
BEGIN
  ALTER TABLE public.operation_idempotency
    DROP CONSTRAINT IF EXISTS operation_idempotency_operation_id_contract;
  ALTER TABLE public.operation_idempotency
    ADD CONSTRAINT operation_idempotency_operation_id_contract
    CHECK (
      operation_kind IN ('event_consumer', 'subscription_webhook')
      OR operation_id IS NOT NULL
    )
    NOT VALID;
  ALTER TABLE public.operation_idempotency
    VALIDATE CONSTRAINT operation_idempotency_operation_id_contract;

  ALTER TABLE public.operation_idempotency
    DROP CONSTRAINT IF EXISTS operation_idempotency_operation_id_contract;
  ALTER TABLE public.operation_idempotency
    ADD CONSTRAINT operation_idempotency_operation_id_contract
    CHECK (
      operation_kind IN ('event_consumer', 'subscription_webhook')
      OR operation_id IS NOT NULL
    )
    NOT VALID;
  ALTER TABLE public.operation_idempotency
    VALIDATE CONSTRAINT operation_idempotency_operation_id_contract;

  SELECT count(*) INTO v_count
  FROM pg_constraint
  WHERE conrelid = 'public.operation_idempotency'::regclass
    AND conname  = 'operation_idempotency_operation_id_contract';

  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE SUBSCRIPTION-WEBHOOK-IDEMPOTENCY FAILED (4): reaplicar el DROP+ADD dejó % constraints con ese nombre (esperado 1).', v_count;
  END IF;
  RAISE NOTICE 'PASS (4): reaplicar el DROP+ADD dos veces deja exactamente una constraint vigente.';
END;
$$;
