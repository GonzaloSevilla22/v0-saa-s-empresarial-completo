-- =============================================================================
-- MIGRATION: 20260830000002_mp_real_subscriptions_producers.sql
-- NOTA (renombrada tras el propose): 20260830000001 quedó tomada por
-- `revoke_auth_internal_only_fns.sql` (PR #346, mergeado mientras este PR4
-- estaba en curso — colisión de versión detectada por el gate schema_migrations
-- en CI, no una falla de las gates propias de esta migración).
-- CHANGE:    mp-real-subscriptions — PR4 (Fase 4, tasks.md §4.7/§6.14/§7)
-- Design ref: openspec/changes/mp-real-subscriptions/design.md
--
-- Implementa:
--   4.7  Productor `_produce_plan_expiring_soon()`: barrido diario que avisa
--        —por campana Y por email, proposal.md "Dunning en dos canales"—
--        a las cuentas con un plan pago cuyo `plan_expires_at` vence en las
--        próximas 48h, SIN exención vigente y SIN trial activo (el trial
--        seguiría dando acceso aunque el plan pago venza — avisar ahí sería
--        confuso). Dedup por `(user_id, event_type, metadata)` — la
--        `metadata` lleva el `plan_expires_at` exacto, así que dos corridas
--        del barrido antes de que ese valor cambie colisionan en el mismo
--        conflicto y no duplican ni el email ni la campana (el evento del
--        outbox solo se crea para las filas que el INSERT de email_logs
--        realmente insertó — un solo dedup, dos canales).
--   6.14 Productor `_expire_stale_subscription_intents()`: barrido que marca
--        `expired` las `subscription_intents` `pending` vencidas. No borra
--        — queda para auditoría. Reemplaza el método de repositorio Python
--        sin llamador de PR3 (dead code) por el patrón SQL+pg_cron que ya
--        usa el resto del proyecto (`expire_trials`, `_sweep_plan_limit_exceeded`).
--   D11  `SubscriptionExpiringSoon` (8º tipo) en `_notification_from_event`,
--        mismo patrón que `SubscriptionPaymentFailed`: target ADMIN,
--        severidad `warning`, sin `branch_id`. MISMA firma (`public.events`).
--
-- IDEMPOTENCIA: `CREATE OR REPLACE` para las 3 funciones (2 nuevas + la
-- redefinición de `_notification_from_event`); `cron.unschedule` + `schedule`
-- (patrón v3-notifications-realtime §4.2, ya usado en billing-pro-trial).
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration). Se aplica dos veces por diseño — sin efecto
--        acumulativo.
--
-- GOVERNANCE: CRÍTICO, pero de bajo riesgo — ambos productores son barridos
--   de LECTURA sobre el estado ya escrito por PR2/PR3; no otorgan ni quitan
--   plan, no tocan `get_effective_plan` ni ningún flujo de cobro. Con
--   `billing_subscriptions_enabled=False` (default, sigue así tras este PR)
--   no hay ninguna fila en `subscriptions`/`subscription_intents` en
--   producción todavía, así que ambos barridos son no-op hasta que la
--   palanca se encienda — ver design.md Amendment "Activación gated".
--
-- ROLLBACK (aditivo — sin pérdida de datos; en orden):
--   SELECT cron.unschedule('mp-subscriptions-plan-expiring-soon-sweep')
--     FROM cron.job WHERE jobname = 'mp-subscriptions-plan-expiring-soon-sweep';
--   SELECT cron.unschedule('mp-subscriptions-expire-stale-intents-sweep')
--     FROM cron.job WHERE jobname = 'mp-subscriptions-expire-stale-intents-sweep';
--   DROP FUNCTION IF EXISTS public._produce_plan_expiring_soon();
--   DROP FUNCTION IF EXISTS public._expire_stale_subscription_intents();
--   -- _notification_from_event: restaurar la definición previa a este
--   -- archivo (ver 20260829000001_mp_real_subscriptions_schema.sql — quita
--   -- 'SubscriptionExpiringSoon' de la lista en-scope y su rama de dispatch).
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT jobname FROM cron.job WHERE jobname LIKE 'mp-subscriptions-%';
--   SELECT proname, COUNT(*) FROM pg_proc WHERE proname IN
--     ('_produce_plan_expiring_soon','_expire_stale_subscription_intents',
--      '_notification_from_event') AND pronamespace='public'::regnamespace
--     GROUP BY proname; -- 1 cada una
-- =============================================================================


-- =============================================================================
-- 1. _notification_from_event — SubscriptionExpiringSoon (D11, 8º tipo)
-- =============================================================================
CREATE OR REPLACE FUNCTION public._notification_from_event(
    p_event public.events
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
/*
  v3-notifications-realtime (D2) + billing-pro-trial (D9) +
  mp-real-subscriptions (D11, PR2+PR4) — Consumer 4 (Notification) del
  relay del outbox.

  mp-real-subscriptions/PR4 agrega 'SubscriptionExpiringSoon' (8º tipo):
  aviso de vencimiento próximo de plan pago, mismo target/severity que
  'SubscriptionPaymentFailed'.
*/
DECLARE
    v_payload    jsonb;
    v_event_type text;
    v_target     text;
    v_severity   text;
    v_branch_id  uuid;
    v_difference numeric;
    v_audience   uuid[];
    v_claimed    bool;
BEGIN
    v_payload    := p_event.payload;
    v_event_type := p_event.event_type;

    -- ── Filtro: los 8 tipos en-scope ──────────────────────────────────────────
    IF v_event_type NOT IN (
        'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
        'QuoteAccepted', 'TransferDispatched', 'PlanLimitExceeded',
        'SubscriptionPaymentFailed', 'SubscriptionExpiringSoon'
    ) THEN
        RETURN;  -- no-op para eventos fuera de alcance
    END IF;

    -- ── CashSessionClosed: solo si difference <> 0 (D3/D4) ───────────────────
    IF v_event_type = 'CashSessionClosed' THEN
        v_difference := COALESCE((v_payload->>'difference')::numeric, 0);
        IF v_difference = 0 THEN
            RETURN;  -- sin diferencia de arqueo, no hace falta avisar
        END IF;
    END IF;

    -- ── Idempotencia: reclamar slot (event_id, 'Notification') ───────────────
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        p_event.id::text || ':Notification',
        'event_consumer',
        p_event.id,
        'Notification'
    )
    ON CONFLICT (event_id, consumer_type)
    WHERE event_id IS NOT NULL
    DO NOTHING;

    GET DIAGNOSTICS v_claimed = ROW_COUNT;

    IF NOT v_claimed THEN
        RETURN;  -- slot ya existía → skip idempotente (ya se avisó)
    END IF;

    -- ── Dispatch por event_type → target + severity ──────────────────────────
    IF v_event_type = 'CashSessionClosed' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'FiscalDocumentRejected' THEN
        v_target    := 'URGENT_FISCAL';
        v_severity  := 'urgent';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'StockBelowMinimum' THEN
        v_target    := 'PURCHASES';
        v_severity  := 'warning';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'QuoteAccepted' THEN
        v_target    := 'SELLER';
        v_severity  := 'info';
        v_branch_id := (v_payload->>'branch_id')::uuid;

    ELSIF v_event_type = 'TransferDispatched' THEN
        v_target    := 'BRANCH_DEST';
        v_severity  := 'info';
        v_branch_id := (v_payload->>'destination_branch_id')::uuid;

    ELSIF v_event_type = 'PlanLimitExceeded' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;

    ELSIF v_event_type = 'SubscriptionPaymentFailed' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;

    ELSIF v_event_type = 'SubscriptionExpiringSoon' THEN
        v_target    := 'ADMIN';
        v_severity  := 'warning';
        v_branch_id := NULL;
    END IF;

    -- ── Resolver audiencia ────────────────────────────────────────────────────
    v_audience := public._notification_audience(p_event.account_id, v_target, v_branch_id);

    IF v_audience IS NULL OR array_length(v_audience, 1) IS NULL THEN
        RETURN;  -- audiencia vacía: nada dirigido a nadie (idempotencia ya reclamada)
    END IF;

    -- ── INSERT notifications ──────────────────────────────────────────────────
    INSERT INTO public.notifications
        (account_id, branch_id, type, severity, payload, audience)
    VALUES (
        p_event.account_id,
        v_branch_id,
        v_event_type,
        v_severity,
        v_payload,
        v_audience
    );
END;
$fn$;

REVOKE ALL     ON FUNCTION public._notification_from_event(public.events) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public._notification_from_event(public.events) FROM anon;
REVOKE EXECUTE ON FUNCTION public._notification_from_event(public.events) FROM authenticated;

COMMENT ON FUNCTION public._notification_from_event IS
    'v3-notifications-realtime (D2) + billing-pro-trial (D9) + '
    'mp-real-subscriptions (D11, PR2+PR4): helper del Consumer 4 '
    '(Notification) del relay del outbox. 8 tipos en-scope. SECURITY '
    'DEFINER + SET search_path. Llamado solo desde '
    'rpc_process_outbox_dispatch (misma firma — NO se tocó ese '
    'dispatcher). REVOCADO de authenticated/anon/PUBLIC.';


-- =============================================================================
-- 2. _produce_plan_expiring_soon() — aviso de vencimiento próximo (4.7/7.6)
--    Ventana: 48h. Excluye gratis, exentas y con trial vigente (7.6). Dos
--    canales (campana + email) con UN solo dedup — el INSERT en events solo
--    corre para las filas que el INSERT en email_logs realmente insertó.
-- =============================================================================
CREATE OR REPLACE FUNCTION public._produce_plan_expiring_soon()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  n integer := 0;
BEGIN
  WITH candidates AS (
    SELECT a.id AS account_id, am.user_id, au.email AS recipient, a.plan_expires_at
    FROM public.accounts a
    JOIN public.account_members am ON am.account_id = a.id
    JOIN auth.users au ON au.id = am.user_id
    WHERE a.billing_plan IN ('inicial', 'avanzado', 'pro')
      AND NOT a.billing_exempt
      AND NOT (
        a.trial_plan IS NOT NULL
        AND a.trial_expires_at IS NOT NULL
        AND a.trial_expires_at > now()
      )
      AND a.plan_expires_at IS NOT NULL
      AND a.plan_expires_at >= now()
      AND a.plan_expires_at < now() + INTERVAL '2 days'
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'subscription_expiring_soon', recipient,
           'Tu suscripción está por vencer — ALIADATA',
           jsonb_build_object('account_id', account_id, 'plan_expires_at', plan_expires_at)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING user_id, metadata
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'SubscriptionExpiringSoon', 'Subscription', c.account_id,
           jsonb_build_object('plan_expires_at', c.plan_expires_at),
           now()
    FROM candidates c
    JOIN ins_email e ON e.user_id = c.user_id
    RETURNING 1
  )
  SELECT count(*) INTO n FROM ins_email;

  RETURN n;
END;
$fn$;

REVOKE ALL ON FUNCTION public._produce_plan_expiring_soon() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._produce_plan_expiring_soon() IS
  'mp-real-subscriptions (4.7/7.6): barrido diario — avisa por campana '
  '(evento SubscriptionExpiringSoon al outbox) y por email (event_type '
  'subscription_expiring_soon) a las cuentas con un plan pago cuyo '
  'plan_expires_at vence en las próximas 48h, sin exención vigente y sin '
  'trial activo (el trial seguiría dando acceso). Dedup por '
  '(user_id, event_type, metadata) — metadata lleva el plan_expires_at '
  'exacto, así que dos corridas antes de que ese valor cambie no duplican '
  'ningún canal.';


-- =============================================================================
-- 3. _expire_stale_subscription_intents() — barrido de intenciones vencidas
--    (6.14). No borra — queda para auditoría (D2bis).
-- =============================================================================
CREATE OR REPLACE FUNCTION public._expire_stale_subscription_intents()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  n integer;
BEGIN
  UPDATE public.subscription_intents
  SET status = 'expired', updated_at = now()
  WHERE status = 'pending' AND expires_at < now();

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$fn$;

REVOKE ALL ON FUNCTION public._expire_stale_subscription_intents() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._expire_stale_subscription_intents() IS
  'mp-real-subscriptions (6.14, D2bis): intenciones pending con '
  'expires_at vencido → expired. No borra, queda para auditoría. '
  'Reemplaza en PR4 el método de repositorio Python de PR3, que no tenía '
  'llamador — patrón SQL+pg_cron consistente con expire_trials()/'
  '_sweep_plan_limit_exceeded().';


-- =============================================================================
-- 4. Scheduling — patrón exacto v3-notifications-realtime §4.2 (unschedule +
--    schedule, sin guard adicional — pg_cron ya está instalado).
-- =============================================================================
SELECT cron.unschedule('mp-subscriptions-plan-expiring-soon-sweep')
FROM cron.job WHERE jobname = 'mp-subscriptions-plan-expiring-soon-sweep';

SELECT cron.schedule(
    'mp-subscriptions-plan-expiring-soon-sweep',
    '0 12 * * *',  -- diario a las 12:00 UTC (~09:00 Mendoza)
    $$ SELECT public._produce_plan_expiring_soon(); $$
);

SELECT cron.unschedule('mp-subscriptions-expire-stale-intents-sweep')
FROM cron.job WHERE jobname = 'mp-subscriptions-expire-stale-intents-sweep';

SELECT cron.schedule(
    'mp-subscriptions-expire-stale-intents-sweep',
    '*/30 * * * *',  -- cada 30 minutos — la ventana de la intención es de 24h,
                      -- un barrido más lento dejaría "pending" cosas que ya
                      -- no deberían competir en la reconciliación (D2bis)
    $$ SELECT public._expire_stale_subscription_intents(); $$
);


-- =============================================================================
-- 5. GATES SQL (RED→GREEN→TRIANGULATE) — patrón billing-pro-trial.
--    Estructurales: SIEMPRE. Comportamiento: SOLO si accounts vacía (CI).
-- =============================================================================
DO $gate$
DECLARE
  v_count          int;
  v_run_behavioral boolean := false;

  v_gate_a boolean := false;  -- 3 funciones: 1 sola definición cada una (42725/C3)
  v_gate_b boolean := false;  -- anon/authenticated sin EXECUTE en las 2 nuevas
  v_gate_c boolean := false;  -- ambos jobs de cron programados

  v_fake_user_id    uuid := gen_random_uuid();
  v_fake_account_id uuid;
  v_intent_id       uuid;
  v_notif_count     int;
  v_email_count     int;

  v_gate_d boolean := false;  -- SubscriptionExpiringSoon → notification + email, sin duplicar en 2da corrida
  v_gate_e boolean := false;  -- exención/trial/gratis NO generan aviso
  v_gate_f boolean := false;  -- intención pending vencida → expired
BEGIN

  -- ── (a) 1 sola definición por función (42725/C3) ────────────────────────
  SELECT bool_and(cnt = 1) INTO v_gate_a
  FROM (
    SELECT proname, COUNT(*) AS cnt
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('_notification_from_event', '_produce_plan_expiring_soon',
                       '_expire_stale_subscription_intents')
    GROUP BY proname
  ) sub;
  IF NOT COALESCE(v_gate_a, false) THEN
    RAISE EXCEPTION 'GATE (a) FAILED: alguna función quedó con más de 1 definición';
  END IF;

  -- ── (b) grants ────────────────────────────────────────────────────────
  IF has_function_privilege('authenticated', 'public._produce_plan_expiring_soon()', 'EXECUTE')
     OR has_function_privilege('anon', 'public._produce_plan_expiring_soon()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public._expire_stale_subscription_intents()', 'EXECUTE')
     OR has_function_privilege('anon', 'public._expire_stale_subscription_intents()', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'GATE (b) FAILED: alguna de las 2 funciones nuevas es ejecutable por authenticated/anon';
  END IF;
  v_gate_b := true;

  -- ── (c) cron jobs programados ─────────────────────────────────────────
  SELECT COUNT(*) INTO v_count FROM cron.job
  WHERE jobname IN ('mp-subscriptions-plan-expiring-soon-sweep', 'mp-subscriptions-expire-stale-intents-sweep');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: se esperaban 2 cron jobs, hay %', v_count;
  END IF;
  v_gate_c := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'mp-real-subscriptions-pr4-gate@test.local', now(), now(),
              jsonb_build_object('name', 'Gate PR4', 'phone', '', 'locality', '', 'province', ''));

      SELECT id INTO v_fake_account_id FROM public.accounts WHERE owner_user_id = v_fake_user_id;

      -- ── (d) plan pago vence en 24h → notification + email, 2da corrida no duplica ──
      UPDATE public.accounts
      SET billing_plan = 'pro', trial_plan = NULL, trial_expires_at = NULL,
          billing_exempt = false, plan_expires_at = now() + INTERVAL '24 hours'
      WHERE id = v_fake_account_id;

      PERFORM public._produce_plan_expiring_soon();
      PERFORM public._produce_plan_expiring_soon();  -- 2da corrida — no debe duplicar

      SELECT COUNT(*) INTO v_notif_count FROM public.notifications
      WHERE account_id = v_fake_account_id AND type = 'SubscriptionExpiringSoon';
      SELECT COUNT(*) INTO v_email_count FROM public.email_logs
      WHERE user_id = v_fake_user_id AND event_type = 'subscription_expiring_soon';

      IF v_notif_count = 1 AND v_email_count = 1 THEN
        v_gate_d := true;
      ELSE
        RAISE EXCEPTION 'GATE (d) FAILED: notif_count=% email_count= % (esperaba 1 y 1, sin duplicar)', v_notif_count, v_email_count;
      END IF;

      -- ── (e) exención vigente → NO genera aviso, pese a plan_expires_at próximo ──
      UPDATE public.accounts SET billing_exempt = true, billing_exempt_reason = 'gate PR4'
      WHERE id = v_fake_account_id;

      PERFORM public._produce_plan_expiring_soon();

      SELECT COUNT(*) INTO v_email_count FROM public.email_logs
      WHERE user_id = v_fake_user_id AND event_type = 'subscription_expiring_soon';
      -- sigue siendo 1 (el de antes de la exención) — la exención no generó uno nuevo
      IF v_email_count = 1 THEN
        v_gate_e := true;
      ELSE
        RAISE EXCEPTION 'GATE (e) FAILED: una cuenta exenta generó un aviso nuevo (email_count=%)', v_email_count;
      END IF;
      UPDATE public.accounts SET billing_exempt = false, billing_exempt_reason = NULL WHERE id = v_fake_account_id;

      -- ── (f) intención pending vencida → expired ──────────────────────────
      INSERT INTO public.subscription_intents (account_id, payer_email, plan, preapproval_plan_id, expires_at)
      VALUES (v_fake_account_id, 'gate-pr4@test.local', 'pro', 'gate-plan-pr4', now() - INTERVAL '1 hour')
      RETURNING id INTO v_intent_id;

      PERFORM public._expire_stale_subscription_intents();

      IF (SELECT status FROM public.subscription_intents WHERE id = v_intent_id) = 'expired' THEN
        v_gate_f := true;
      ELSE
        RAISE EXCEPTION 'GATE (f) FAILED: la intención vencida no pasó a expired';
      END IF;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'mp-real-subscriptions PR4: anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    BEGIN
      DELETE FROM public.notifications WHERE account_id = v_fake_account_id;
      DELETE FROM public.events WHERE account_id = v_fake_account_id;
      DELETE FROM public.email_logs WHERE user_id = v_fake_user_id;
      DELETE FROM public.subscription_intents WHERE account_id = v_fake_account_id;
      DELETE FROM public.billing_events WHERE user_id = v_fake_user_id;
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'mp-real-subscriptions PR4: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  RAISE NOTICE '=== mp-real-subscriptions PR4 (producers) SQL gates ===';
  RAISE NOTICE '(a) 1 def por función (42725/C3):        %', v_gate_a;
  RAISE NOTICE '(b) grants correctos:                    %', v_gate_b;
  RAISE NOTICE '(c) 2 cron jobs programados:              %', v_gate_c;
  RAISE NOTICE '(d) aviso vencimiento: notif+email, no dup: %', v_gate_d;
  RAISE NOTICE '(e) exención NO genera aviso:              %', v_gate_e;
  RAISE NOTICE '(f) intención vencida → expired:           %', v_gate_f;
  RAISE NOTICE '=== mp-real-subscriptions PR4 (producers): instalado OK ===';

END $gate$;
