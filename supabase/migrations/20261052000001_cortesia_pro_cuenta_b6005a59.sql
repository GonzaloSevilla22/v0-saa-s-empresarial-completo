-- =============================================================================
-- Cortesía Pro para UNA cuenta — pedido explícito del PO (2026-09-21)
-- =============================================================================
--
-- Pedido textual: "quiero que pases la cuenta tubecoventas6@gmail.com al plan
-- pro por más que haya pagado el inicial".
--
-- Cuenta: b6005a59-b996-4a3c-bafd-6b89ee714e00 (una sola membresía para ese
-- email, medido en prod el 2026-09-21). Estado de partida medido:
--   billing_plan='inicial' · billing_status='active' · billing_exempt=false ·
--   trial vencido el 2026-08-30 · plan_expires_at=2026-10-14 ·
--   suscripción de MercadoPago fa624f9b… 'inicial' / 'authorized', próximo
--   cobro 2026-10-04.
--
-- POR QUÉ `billing_exempt` Y NO `billing_plan = 'pro'`
--   * `get_effective_plan` (cuerpo vivo) evalúa `billing_exempt` PRIMERO y
--     devuelve 'pro'. Es el único campo de plan que NADA reescribe: ni el
--     webhook de MercadoPago (`_apply_approved_charge` sólo toca
--     `plan_expires_at` y `billing_status`), ni los crons, ni triggers
--     (`public.accounts` no tiene ninguno).
--   * `billing_plan` queda en 'inicial' A PROPÓSITO: es lo que la cuenta paga de
--     verdad. Ponerlo en 'pro' borraría ese dato, sería reescribible por
--     `payments.py` y por la resolución de suscripciones ambiguas, y haría que
--     el MRR reclame $69.900 de alguien que paga $24.900.
--   * Es la misma vía de las 16 cuentas ya exentas (precedente versionado:
--     20260817000002_billing_pro_trial_backfill.sql §1).
--
-- EFECTOS CONOCIDOS Y ACEPTADOS (medidos antes de escribir)
--   * La cuenta sale de `mrr_ars` en `rpc_admin_business_kpis` (las exentas
--     aportan 0 por diseño, sign-off PO 2026-08-12): $94.800 -> $69.900 y
--     cuentas pagadoras 2 -> 1, aunque MercadoPago le siga cobrando $24.900.
--     Candidato anotado en CHANGES.md: que una exenta CON suscripción viva
--     aporte su importe real.
--   * Deja de recibir el aviso "tu suscripción está por vencer"
--     (`_produce_plan_expiring_soon` excluye a las exentas) y, si un cobro
--     falla o cancela, CONSERVA Pro: no existe `billing_exempt_expires_at`.
--     Por eso el motivo lleva una fecha de revisión.
--   * `/planes` le mostrará "acceso sin cargo" (texto genérico de las exentas).
--   * Los guards de FastAPI leen el claim `plan` del JWT: hasta 15 min de
--     ventana (o cerrar sesión y volver a entrar). Edge Functions y frontend
--     cambian al instante.
--   * Deja de dispararse el evento diario `PlanLimitExceeded` (513 clientes
--     contra el tope de 250 del plan Inicial; en Pro el tope es 3000) — sirve
--     como verificación de comportamiento al día siguiente.
--
-- IDEMPOTENCIA: UN solo statement. El INSERT se alimenta del RETURNING del
-- UPDATE, y el UPDATE exige `billing_exempt = false`: un re-apply no mueve nada
-- y no duplica la fila de auditoría. En una base sin esa cuenta (stack local,
-- CI, proyecto de previews) afecta 0 filas.
--
-- REVERSIÓN (sin pérdida de datos; el plan efectivo vuelve solo a 'inicial'):
--   UPDATE public.accounts
--      SET billing_exempt = false, billing_exempt_reason = NULL,
--          billing_exempt_granted_at = NULL, billing_exempt_granted_by = NULL
--    WHERE id = 'b6005a59-b996-4a3c-bafd-6b89ee714e00';
--
-- VERIFICACIÓN POST-MERGE (sólo lectura):
--   SELECT billing_exempt, billing_plan, plan_expires_at FROM public.accounts
--    WHERE id = 'b6005a59-b996-4a3c-bafd-6b89ee714e00';   -- true / inicial / 2026-10-14
--   SELECT count(*) FROM public.accounts WHERE billing_exempt;             -- 17 (era 16)
--   SELECT count(*) FROM public.billing_events
--    WHERE event_type = 'exemption_granted';                                -- 2 (era 1)
--   SELECT plan, status, next_payment_date FROM public.subscriptions
--    WHERE account_id = 'b6005a59-b996-4a3c-bafd-6b89ee714e00';            -- intacta
-- =============================================================================

WITH exempted AS (
  UPDATE public.accounts
  SET billing_exempt            = true,
      billing_exempt_reason     = 'Cortesía Pro — pedido del PO 2026-09-21. La cuenta CONSERVA su suscripción Inicial paga en MercadoPago ($24.900/mes); billing_plan queda en inicial a propósito. Efecto conocido: sale de mrr_ars y deja de recibir el aviso de vencimiento. REVISAR EL 2026-12-21.',
      billing_exempt_granted_at = now(),
      billing_exempt_granted_by = '3cf9b5f4-16ea-488c-9b71-b668aaa14191'::uuid
  WHERE id = 'b6005a59-b996-4a3c-bafd-6b89ee714e00'
    AND billing_exempt = false
  RETURNING id, owner_user_id, billing_plan
)
INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
SELECT
  owner_user_id,
  'exemption_granted',
  billing_plan,
  'pro',
  'Cortesía Pro otorgada por pedido del PO 2026-09-21; billing_plan permanece en inicial (lo que la cuenta paga).',
  jsonb_build_object(
    'account_id', id,
    'keeps_paid_subscription', 'inicial',
    'mrr_impact_ars', -24900,
    'review_on', '2026-12-21'
  )
FROM exempted;
