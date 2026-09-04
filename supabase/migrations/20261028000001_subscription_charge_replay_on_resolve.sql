-- =============================================================================
-- MIGRATION: 20261028000001_subscription_charge_replay_on_resolve.sql
-- HOTFIX DE PRODUCCIÓN (2026-09-04, dinero real en juego — governance
-- CRÍTICO, billing).
--
-- Incidente (cronología completa en UTC, medida en prod):
--   21:47:03  subscription_preapproval 50681db010a341968e53c3880d52c3e9 →
--             subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1 nace
--             'ambiguous' (el matcheo por payer_email falló, account_id NULL).
--   21:51:23  subscription_authorized_payment 7031580844 (cuota processed,
--             pago MP 176341057469 aprobado, $24.900) — el backend reclama
--             la idempotencia pero, como account_id era NULL, salta el
--             UPDATE accounts.plan_expires_at, el INSERT billing_events
--             'subscription_payment_approved' y el mail de recibo. Esa
--             versión del código además dejaba next_payment_date/
--             last_payment_status en NULL (verificado en prod).
--   22:31:37  un admin resuelve la fila → account_id se asigna, plan y
--             billing_status se activan — pero el cobro de las 21:51 ya se
--             perdió: no hay forma de reconstruirlo desde lo guardado
--             localmente, y la idempotencia del webhook ya está reclamada
--             (MercadoPago no reintenta una notificación ya procesada).
--
-- Causa raíz de diseño: el docstring de resolve_ambiguous_subscription
-- decía "el dinero YA se acreditó en billing_events cuando llegó el cobro
-- — esto solo corrige la atribución". Eso es FALSO cuando la cuota llega
-- ANTES de la resolución manual — que es el caso NORMAL (MercadoPago manda
-- subscription_preapproval y subscription_authorized_payment con segundos
-- de diferencia; la resolución del admin llega horas después). Toda
-- suscripción ambigua-luego-resuelta perdía para siempre su primer recibo
-- y su vencimiento.
--
-- Fix (ver backend/services/subscriptions.py en el mismo PR):
--   1. process_subscription_authorized_payment_notification ahora persiste
--      SIEMPRE next_payment_date/last_payment_status/amount, y — mientras
--      la fila no tiene cuenta asignada — también el id del pago MP y el
--      de la cuota, en las DOS columnas nuevas de esta migración.
--   2. resolve_ambiguous_subscription replica esos efectos al resolver
--      (mismo helper `_apply_approved_charge` que usa el camino normal).
--   3. Endpoint admin POST /payments/subscriptions/{id}/replay-charges
--      reconstruye desde la API de MercadoPago los cobros de una
--      suscripción YA resuelta ANTES de este fix (como fa624f9b-..., que no
--      tiene nada guardado porque estas columnas no existían todavía
--      cuando se procesó su cobro) — reparación puntual, corre una vez.
--
-- Esta migración es puramente aditiva: 2 columnas TEXT nullable, sin
-- backfill (no hay forma de reconstruir el pasado desde la propia fila —
-- para eso está el endpoint de replay, que consulta a MercadoPago) y sin
-- CHECK/contrato (son ids de MercadoPago en bruto, sin un formato propio
-- que validar) — no amerita un gate SQL dedicado más allá de que la
-- migración sea IF NOT EXISTS (re-aplicable sin efecto acumulativo).
--
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
--
-- ROLLBACK (aditivo, sin pérdida de datos previos a este fix):
--   ALTER TABLE public.subscriptions
--     DROP COLUMN IF EXISTS pending_authorized_payment_id,
--     DROP COLUMN IF EXISTS pending_mercadopago_payment_id;
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT column_name FROM information_schema.columns
--     WHERE table_schema='public' AND table_name='subscriptions'
--     AND column_name IN ('pending_authorized_payment_id','pending_mercadopago_payment_id');
--     -- 2 filas
-- =============================================================================

ALTER TABLE public.subscriptions
  ADD COLUMN IF NOT EXISTS pending_authorized_payment_id text,
  ADD COLUMN IF NOT EXISTS pending_mercadopago_payment_id text;

COMMENT ON COLUMN public.subscriptions.pending_authorized_payment_id IS
  'H3 hotfix 2026-09-04: id del authorized_payment (cuota) de MercadoPago cuyo cobro se acreditó mientras esta fila todavía no tenía account_id asignado (status=ambiguous). Se replica al resolver via _apply_approved_charge y se limpia con clear_pending_charge — NULL significa "sin cobro pendiente de aplicar".';

COMMENT ON COLUMN public.subscriptions.pending_mercadopago_payment_id IS
  'H3 hotfix 2026-09-04: id del pago (payment.id) de MercadoPago asociado a pending_authorized_payment_id — discriminador de idempotencia en billing_events.mercadopago_payment_id al replicar el cobro.';
