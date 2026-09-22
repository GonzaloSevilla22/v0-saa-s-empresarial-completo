-- =============================================================================
-- Registro de auditoría: 5 trials Pro extendidos por el PO (bonificación)
-- =============================================================================
--
-- La auditoría del 2026-09-22 (fix accounts-privilege-columns, tarea A3)
-- encontró 5 cuentas con `trial_plan = 'pro'` y `trial_expires_at` más allá
-- del trial de 30 días firmado el 2026-07-31, sin ninguna fila de respaldo en
-- `billing_events`. El PO confirmó el 2026-09-22 que las bonificó él y que
-- deben durar EXACTAMENTE hasta la fecha que puso, no para siempre.
--
-- Esta migración NO cambia ningún plan ni ninguna fecha: sólo deja el rastro
-- de auditoría que faltaba, para que después del hecho se distinga una
-- bonificación legítima de un cambio sin origen. El vencimiento lo aplica el
-- mecanismo existente: `get_effective_plan` sólo honra el trial mientras
-- `trial_expires_at > now()`, y el cron diario `expire-trials` (03:00 UTC)
-- marca `billing_status = 'expired'` y registra `trial_expired`.
--
-- Idempotente: cada fila lleva metadata.source y se inserta sólo si no existe.
-- En una base sin estas cuentas (local, CI, previews) inserta 0 filas.
-- =============================================================================

INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
SELECT
  a.owner_user_id,
  'trial_pro_granted',
  'gratis',
  'pro',
  'Bonificación del PO — trial Pro extendido hasta ' || a.trial_expires_at::date::text
    || ' (confirmado por el PO el 2026-09-22; vence solo en esa fecha por get_effective_plan + cron expire-trials).',
  jsonb_build_object(
    'account_id',       a.id,
    'source',           'po-bonificacion-2026-09-22',
    'trial_expires_at', a.trial_expires_at
  )
FROM public.accounts a
WHERE a.id IN (
  '192b9efe-44f5-4882-87da-7202295c18ea',
  '43e71ff4-de35-41b8-b91b-e17d713172ec',
  'c1f562da-d185-48e0-94f8-b214928b3cbc',
  'f715d4f0-eba2-42d4-bbc5-8436a4d6d394',
  '00038cff-68d1-4eec-ae5d-bd57f1fef917'
)
  AND a.trial_plan = 'pro'
  AND NOT EXISTS (
    SELECT 1 FROM public.billing_events be
    WHERE be.user_id = a.owner_user_id
      AND be.metadata->>'source' = 'po-bonificacion-2026-09-22'
  );
