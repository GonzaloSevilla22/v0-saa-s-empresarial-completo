-- =============================================================================
-- MIGRATION: 20260817000002_billing_pro_trial_backfill.sql
-- CHANGE:    billing-pro-trial — backfill (D8), gate OQ-1 + sign-off PO
-- Design ref: openspec/changes/billing-pro-trial/design.md (D4, D8, OQ-1)
--
-- Separada de la migración de esquema (20260817000001) por tasks.md §9.3.
-- Requiere OQ-1 resuelta: las decisiones a continuación fueron confirmadas
-- por el PO (rondas de sign-off 2026-07-31) y están fijadas en el prompt de
-- apply de este change — NO se reabren acá:
--
--   EXENTA de cortesía (billing_exempt=true):
--     3834e5d7-f3a9-4496-8fdd-84edf8a8b252 (susanacavagnola@gmail.com,
--     "Sumar Ropa Deportiva"). El sign-off original tenía un typo de email
--     ("susanacavagno@") — ver design.md OQ-1 para la verificación completa.
--
--   PAGADORA (NO exenta, NO tocada por este backfill):
--     0f627a85-7d01-4323-8b3f-122bd834a4ab (danielsevilla64@gmail.com). Tiene
--     el único billing_events.plan_upgraded de prod (pago MercadoPago
--     reconciliado, honrado por el PO 2026-06-13). Conserva billing_plan='pro'
--     por la rama (3) de la precedencia de get_effective_plan — NO necesita
--     la exención de cortesía. Su vencimiento futuro lo maneja el change de
--     suscripciones MP (fuera de alcance acá) — por eso queda EXCLUIDA por id
--     de la UPDATE de trial, no solo por no estar exenta.
--
--   Resto (32 cuentas, incluidas las 5 con trial 'avanzado' en curso — OQ-3,
--   lectura literal del sign-off "TODAS las cuentas reciben 30 días de PRO"):
--     billing_plan → 'gratis' (destino post-trial explícito del sign-off,
--     NO "volver al plan contratado" — las 24 'avanzado' vienen del backfill
--     de beta C-01/D5, nunca pagaron), trial_plan → 'pro', trial_started_at
--     → now(), trial_expires_at → now()+30d, billing_status → 'trialing'.
--
-- IDEMPOTENCIA (riesgo #1 del change — el pipeline de este proyecto aplica
-- las migraciones DOS VECES por diseño: integración GitHub al mergear +
-- `db push` de Actions después):
--   - Exención: WHERE id = <uuid> AND billing_exempt = false — la 2ª pasada
--     no re-escribe billing_exempt_granted_at ni duplica el billing_events.
--   - Trial: WHERE billing_exempt = false AND id <> <pagadora> AND
--     trial_plan IS DISTINCT FROM 'pro' — la 2ª pasada no vuelve a tocar una
--     cuenta que ya quedó en trial_plan='pro' (NO extiende el reloj 30 días
--     más).
--   Esta migración se auto-verifica: aplica cada UPDATE dos veces en la
--   misma ejecución (ver Sección 3) y aborta si el segundo pase mueve algo
--   que no debería (task 9.4).
--
-- REVERSIÓN (sin restaurar backups — D8):
--   UPDATE public.accounts a
--   SET billing_plan = be.from_plan
--   FROM public.billing_events be
--   WHERE be.event_type = 'trial_pro_granted'
--     AND (be.metadata->>'account_id')::uuid = a.id;
--   -- + UPDATE ... SET billing_exempt = false WHERE id = '3834e5d7-...';
--
-- GOVERNANCE: CRÍTICO — 34 cuentas reales, una con pago reconciliado.
-- APPLY: CI/GitHub integration + Actions db push (NUNCA MCP apply_migration).
--
-- VERIFICATION (post-merge, MCP read-only — task 9.5):
--   SELECT count(*) FROM public.accounts WHERE billing_exempt = true;               -- 1
--   SELECT count(*) FROM public.accounts
--     WHERE billing_exempt = false AND trial_plan = 'pro'
--       AND id <> '0f627a85-7d01-4323-8b3f-122bd834a4ab';                           -- 32
--   SELECT billing_plan FROM public.accounts
--     WHERE id = '0f627a85-7d01-4323-8b3f-122bd834a4ab';                            -- 'pro' (intacta)
--   SELECT count(*) FROM public.billing_events
--     WHERE event_type IN ('trial_pro_granted','exemption_granted')
--       AND created_at > <timestamp del merge>;                                     -- 33 (32 + 1)
--   SELECT public.get_effective_plan(id) FROM public.accounts;                      -- 'pro' para las 34
-- =============================================================================


-- =============================================================================
-- 1. Exención de cortesía (D4) — 1ª aplicación
-- =============================================================================
WITH exempted AS (
  UPDATE public.accounts
  SET billing_exempt           = true,
      billing_exempt_reason    = 'Cortesía — sign-off PO 2026-07-31 (Sumar Ropa Deportiva / susanacavagnola@gmail.com, OQ-1 confirmada por UUID; el sign-off original traía un typo de email)',
      billing_exempt_granted_at = now()
  WHERE id = '3834e5d7-f3a9-4496-8fdd-84edf8a8b252'
    AND billing_exempt = false
  RETURNING id, owner_user_id, billing_plan
)
INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
SELECT
  owner_user_id,
  'exemption_granted',
  billing_plan,
  billing_plan,
  'billing-pro-trial (D4): exención de cortesía otorgada — sign-off PO 2026-07-31, OQ-1 confirmada por UUID',
  jsonb_build_object('account_id', id)
FROM exempted;


-- =============================================================================
-- 2. Trial PRO de 30 días para las cuentas no exentas y no-pagadora (D8) —
--    1ª aplicación. La pagadora (0f627a85-...) queda excluida por id: su
--    billing_plan='pro' no se toca (ver cabecera).
-- =============================================================================
WITH candidates AS (
  SELECT id, owner_user_id, billing_plan AS prev_billing_plan
  FROM public.accounts
  WHERE billing_exempt = false
    AND id <> '0f627a85-7d01-4323-8b3f-122bd834a4ab'
    AND trial_plan IS DISTINCT FROM 'pro'
),
updated AS (
  UPDATE public.accounts a
  SET billing_plan      = 'gratis',
      trial_plan        = 'pro',
      trial_started_at  = now(),
      trial_expires_at  = now() + INTERVAL '30 days',
      billing_status    = 'trialing'
  FROM candidates c
  WHERE a.id = c.id
  RETURNING a.id, c.owner_user_id, c.prev_billing_plan, a.trial_expires_at
)
INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
SELECT
  owner_user_id,
  'trial_pro_granted',
  prev_billing_plan,
  'gratis',
  'billing-pro-trial (D8): trial PRO 30 días otorgado — sign-off PO 2026-07-31, OQ-1 confirmada por UUID. Destino post-trial explícito: gratis (no "volver al plan contratado" — avanzado provenía del backfill de beta C-01/D5, nunca pagado).',
  jsonb_build_object('account_id', id, 'trial_plan', 'pro', 'trial_expires_at', trial_expires_at)
FROM updated;


-- =============================================================================
-- 3. Prueba de idempotencia EN LA MISMA APLICACIÓN (task 9.4) — repite los
--    dos UPDATE anteriores una 2ª vez con predicados idénticos. Si el guard
--    de idempotencia fallara, la 2ª pasada movería trial_expires_at o
--    duplicaría billing_events — el DO block de abajo lo detecta y aborta.
-- =============================================================================
DO $verify$
DECLARE
  v_exempt_count_1     int;
  v_exempt_signature_1 text;
  v_trial_count_1      int;
  v_trial_signature_1  text;
  v_events_count_1     int;

  v_exempt_count_2     int;
  v_exempt_signature_2 text;
  v_trial_count_2      int;
  v_trial_signature_2  text;
  v_events_count_2     int;
BEGIN
  -- ── Señales ANTES de la 2ª pasada ────────────────────────────────────────
  SELECT count(*), COALESCE(string_agg(id::text || ':' || billing_exempt_granted_at::text, ',' ORDER BY id), '')
  INTO v_exempt_count_1, v_exempt_signature_1
  FROM public.accounts WHERE billing_exempt = true;

  SELECT count(*), COALESCE(string_agg(id::text || ':' || trial_expires_at::text, ',' ORDER BY id), '')
  INTO v_trial_count_1, v_trial_signature_1
  FROM public.accounts
  WHERE billing_exempt = false AND trial_plan = 'pro' AND id <> '0f627a85-7d01-4323-8b3f-122bd834a4ab';

  SELECT count(*) INTO v_events_count_1
  FROM public.billing_events WHERE event_type IN ('trial_pro_granted', 'exemption_granted');

  -- ══════════════════════════════════════════════════════════════════════
  -- 2ª aplicación — SQL idéntico a las secciones 1 y 2 de arriba.
  -- ══════════════════════════════════════════════════════════════════════
  WITH exempted AS (
    UPDATE public.accounts
    SET billing_exempt           = true,
        billing_exempt_reason    = 'Cortesía — sign-off PO 2026-07-31 (Sumar Ropa Deportiva / susanacavagnola@gmail.com, OQ-1 confirmada por UUID; el sign-off original traía un typo de email)',
        billing_exempt_granted_at = now()
    WHERE id = '3834e5d7-f3a9-4496-8fdd-84edf8a8b252'
      AND billing_exempt = false
    RETURNING id, owner_user_id, billing_plan
  )
  INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
  SELECT owner_user_id, 'exemption_granted', billing_plan, billing_plan,
         'billing-pro-trial (D4): exención de cortesía otorgada — sign-off PO 2026-07-31, OQ-1 confirmada por UUID',
         jsonb_build_object('account_id', id)
  FROM exempted;

  WITH candidates AS (
    SELECT id, owner_user_id, billing_plan AS prev_billing_plan
    FROM public.accounts
    WHERE billing_exempt = false
      AND id <> '0f627a85-7d01-4323-8b3f-122bd834a4ab'
      AND trial_plan IS DISTINCT FROM 'pro'
  ),
  updated AS (
    UPDATE public.accounts a
    SET billing_plan      = 'gratis',
        trial_plan        = 'pro',
        trial_started_at  = now(),
        trial_expires_at  = now() + INTERVAL '30 days',
        billing_status    = 'trialing'
    FROM candidates c
    WHERE a.id = c.id
    RETURNING a.id, c.owner_user_id, c.prev_billing_plan, a.trial_expires_at
  )
  INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
  SELECT owner_user_id, 'trial_pro_granted', prev_billing_plan, 'gratis',
         'billing-pro-trial (D8): trial PRO 30 días otorgado — sign-off PO 2026-07-31, OQ-1 confirmada por UUID. Destino post-trial explícito: gratis.',
         jsonb_build_object('account_id', id, 'trial_plan', 'pro', 'trial_expires_at', trial_expires_at)
  FROM updated;

  -- ── Señales DESPUÉS de la 2ª pasada ──────────────────────────────────────
  SELECT count(*), COALESCE(string_agg(id::text || ':' || billing_exempt_granted_at::text, ',' ORDER BY id), '')
  INTO v_exempt_count_2, v_exempt_signature_2
  FROM public.accounts WHERE billing_exempt = true;

  SELECT count(*), COALESCE(string_agg(id::text || ':' || trial_expires_at::text, ',' ORDER BY id), '')
  INTO v_trial_count_2, v_trial_signature_2
  FROM public.accounts
  WHERE billing_exempt = false AND trial_plan = 'pro' AND id <> '0f627a85-7d01-4323-8b3f-122bd834a4ab';

  SELECT count(*) INTO v_events_count_2
  FROM public.billing_events WHERE event_type IN ('trial_pro_granted', 'exemption_granted');

  -- ── Aserciones de idempotencia (task 9.4) ────────────────────────────────
  IF v_exempt_signature_1 <> v_exempt_signature_2 OR v_exempt_count_1 <> v_exempt_count_2 THEN
    RAISE EXCEPTION 'GATE 9.4 FAILED: la 2ª pasada movió billing_exempt_granted_at o el conteo de exentas (antes: % filas [%], después: % filas [%]) — el guard de idempotencia de la exención está roto',
      v_exempt_count_1, v_exempt_signature_1, v_exempt_count_2, v_exempt_signature_2;
  END IF;

  IF v_trial_signature_1 <> v_trial_signature_2 OR v_trial_count_1 <> v_trial_count_2 THEN
    RAISE EXCEPTION 'GATE 9.4 FAILED: la 2ª pasada movió trial_expires_at o el conteo de cuentas en trial (antes: % filas, después: % filas) — extendería el trial 30 días más en cada re-aplicación (riesgo #1 del change)',
      v_trial_count_1, v_trial_count_2;
  END IF;

  IF v_events_count_2 <> v_events_count_1 THEN
    RAISE EXCEPTION 'GATE 9.4 FAILED: la 2ª pasada insertó % fila(s) nueva(s) en billing_events (antes %, después %) — se esperaban 0 filas nuevas en una re-aplicación idempotente',
      v_events_count_2 - v_events_count_1, v_events_count_1, v_events_count_2;
  END IF;

  -- ── Diagnóstico (informativo — los conteos reales dependen de si esto
  --    corre en CI vacío [0/0] o en prod [1 exenta / 32 en trial]) ─────────
  RAISE NOTICE '=== billing-pro-trial backfill — verificación de idempotencia (task 9.4) ===';
  RAISE NOTICE 'Cuentas exentas (billing_exempt=true):                    %', v_exempt_count_2;
  RAISE NOTICE 'Cuentas con trial_plan=pro (no exentas, no pagadora):     %', v_trial_count_2;
  RAISE NOTICE 'Filas nuevas en billing_events (trial_pro_granted/exemption_granted): %', v_events_count_2;
  RAISE NOTICE 'Idempotencia verificada: la 2ª pasada no movió trial_expires_at ni duplicó billing_events.';
  RAISE NOTICE '=== billing-pro-trial backfill: OK ===';
END $verify$;


-- =============================================================================
-- 4. Verificación puntual de las 2 cuentas especiales (informativo — no
--    aborta si no existen, p.ej. en un CI con accounts vacía).
-- =============================================================================
DO $special_accounts$
DECLARE
  v_payer_plan   text;
  v_payer_exempt boolean;
  v_courtesy_exempt boolean;
  v_courtesy_effective text;
BEGIN
  SELECT billing_plan, billing_exempt INTO v_payer_plan, v_payer_exempt
  FROM public.accounts WHERE id = '0f627a85-7d01-4323-8b3f-122bd834a4ab';

  IF FOUND THEN
    IF v_payer_plan <> 'pro' OR v_payer_exempt <> false THEN
      RAISE EXCEPTION 'GATE FAILED: la cuenta pagadora (0f627a85-...) fue alterada por el backfill (billing_plan=%, billing_exempt=%) — no debía tocarse',
        v_payer_plan, v_payer_exempt;
    END IF;
    RAISE NOTICE 'Cuenta pagadora (0f627a85-...): intacta — billing_plan=pro, billing_exempt=false.';
  ELSE
    RAISE NOTICE 'Cuenta pagadora (0f627a85-...) no existe en esta DB (esperado en CI con accounts vacía).';
  END IF;

  SELECT billing_exempt INTO v_courtesy_exempt
  FROM public.accounts WHERE id = '3834e5d7-f3a9-4496-8fdd-84edf8a8b252';

  IF FOUND THEN
    v_courtesy_effective := public.get_effective_plan('3834e5d7-f3a9-4496-8fdd-84edf8a8b252'::uuid);
    IF NOT v_courtesy_exempt OR v_courtesy_effective <> 'pro' THEN
      RAISE EXCEPTION 'GATE FAILED: la cuenta de cortesía (3834e5d7-...) no quedó exenta correctamente (billing_exempt=%, effective_plan=%)',
        v_courtesy_exempt, v_courtesy_effective;
    END IF;
    RAISE NOTICE 'Cuenta de cortesía (3834e5d7-...): exenta — get_effective_plan()=pro.';
  ELSE
    RAISE NOTICE 'Cuenta de cortesía (3834e5d7-...) no existe en esta DB (esperado en CI con accounts vacía).';
  END IF;
END $special_accounts$;
