-- =============================================================================
-- MIGRATION: 20261027000001_subscription_webhook_idempotency_contract.sql
-- HOTFIX DE PRODUCCIÓN (2026-09-04, dinero real en juego).
--
-- Incidente: la cuenta b6005a59-b996-4a3c-bafd-6b89ee714e00
-- (tubecoventas6@gmail.com) contrató una suscripción real en MercadoPago
-- desde /planes. MP manda las notificaciones a POST /payments/webhook y el
-- backend responde 422 a TODAS las de suscripción:
--   type=subscription_preapproval        ids 7ccbebe460a24fbba077c2b22eaac5e3,
--                                             50681db010a341968e53c3880d52c3e9
--   type=subscription_authorized_payment ids 7031580836, 7031580844
-- Medido en prod (2026-09-04): public.subscriptions = 0 filas,
-- public.operation_idempotency WHERE operation_kind='subscription_webhook'
-- = 0 filas. El flujo muere en su PRIMERA escritura.
--
-- Causa raíz: backend/services/subscriptions.py::
-- _claim_subscription_webhook_idempotency hace
--   INSERT INTO public.operation_idempotency
--     (user_id, idempotency_key, operation_kind)
--   VALUES ('00000000-0000-0000-0000-000000000000'::uuid, $1,
--           'subscription_webhook')
-- SIN operation_id. 'subscription_webhook' SÍ está admitido por
-- operation_idempotency_operation_kind_check (20260906000001) — lo que
-- falta es la exención del CHECK
-- operation_idempotency_operation_id_contract, que hoy sólo exime a
-- 'event_consumer':
--   CHECK (operation_kind = 'event_consumer' OR operation_id IS NOT NULL)
-- Ese CHECK dispara asyncpg.CheckViolationError (SQLSTATE 23514), que
-- backend/core/errors.py::asyncpg_error_handler mapea 1:1 a HTTP 422 — eso
-- es exactamente lo que ve MercadoPago en cada notificación de suscripción.
--
-- Por qué la exención (y no una operation_id inventada): una notificación
-- de webhook no es una operación del dominio con una fila propia que
-- referenciar — es la MISMA razón por la que 'event_consumer' ya está
-- exento (marcadores de dedup del outbox, sin operation_id real). Fabricar
-- un UUID sólo para esquivar el CHECK falsearía el contrato en vez de
-- corregirlo.
--
-- Fix: reemplaza el CHECK por una unión de dos kinds exentos, mismo patrón
-- NOT VALID + VALIDATE que 20260906000001 (evita un lock largo sobre las
-- ~2.035 filas vivas en prod al momento de este hotfix).
--
-- Bug secundario (mismo diagnóstico, corregido en el backend en este mismo
-- PR, no en SQL): public.accounts NO tiene columna updated_at (columnas
-- reales verificadas en prod: id, billing_plan, billing_status, trial_plan,
-- trial_started_at, trial_expires_at, owner_user_id, created_at,
-- plan_expires_at, billing_exempt, billing_exempt_reason,
-- billing_exempt_granted_at, billing_exempt_granted_by,
-- default_payment_terms_days). subscriptions.py hacía
-- `UPDATE public.accounts SET ... updated_at = now()` en 5 lugares — eso
-- habría explotado con 42703 apenas este 422 se destrabara. Ver el diff de
-- backend/services/subscriptions.py en el mismo PR.
--
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- =============================================================================

-- ── CHECK del contrato por-fila de operation_id: exime también a
--    'subscription_webhook' (mismo motivo que 'event_consumer') ────────────
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.operation_idempotency'::regclass
      AND conname  = 'operation_idempotency_operation_id_contract'
  ) THEN
    ALTER TABLE public.operation_idempotency
      DROP CONSTRAINT operation_idempotency_operation_id_contract;
  END IF;

  ALTER TABLE public.operation_idempotency
    ADD CONSTRAINT operation_idempotency_operation_id_contract
    CHECK (
      operation_kind IN ('event_consumer', 'subscription_webhook')
      OR operation_id IS NOT NULL
    )
    NOT VALID;
END $$;

-- VALIDATE es no-op si ya está validado (re-ejecución segura — idempotente).
ALTER TABLE public.operation_idempotency
  VALIDATE CONSTRAINT operation_idempotency_operation_id_contract;
