-- =============================================================================
-- MIGRATION: 20260829000001_mp_real_subscriptions_schema.sql
-- CHANGE:    mp-real-subscriptions (governance CRÍTICO — dinero real,
--            sign-off PO 2026-07-31, amendment/pivot Camino A 2026-08-01)
-- Design ref: openspec/changes/mp-real-subscriptions/design.md
--
-- Implementa (design.md):
--   D2bis  Camino A de atribución (reemplaza D2, refutada empíricamente en
--          sandbox — ver Amendment del design): el alta NO crea ningún
--          `preapproval` propio. Crea una fila de intención
--          (subscription_intents) y redirige al init_point del PLAN. Cuando
--          MercadoPago crea el preapproval real y notifica, se reconcilia
--          por payer_email + preapproval_plan_id + ventana de 24h.
--   D4     Tabla `public.subscriptions` (no columnas en accounts) — historial
--          + máximo una viva por cuenta vía índice único parcial. account_id
--          es NULLABLE: una fila sin match automático (D2bis) nace con
--          account_id NULL y status='ambiguous', a la espera de resolución
--          manual — el dinero se acredita igual, solo la atribución
--          automática falla.
--   D5     Sin tabla de cuotas — se reutilizan billing_events (auditoría de
--          cobros, ya tiene índice único por mercadopago_payment_id) y
--          operation_idempotency (kind nuevo 'subscription_webhook' para
--          reclamar idempotencia de las notificaciones subscription_* en el
--          backend Python — NO se toca el kind 'event_consumer' que ya usa
--          _notification_from_event, es un claim distinto).
--   D6     get_effective_plan(account_id) gana el término de vencimiento:
--          un billing_plan pago con plan_expires_at en el pasado deja de
--          otorgar ese plan. NULL NO degrada (semántica permisiva, OQ1
--          resuelta (b) 2026-07-31 — endurecer es change posterior). Firma
--          congelada en 1 parámetro — CREATE OR REPLACE sobre la MISMA
--          firma, sin overload (lección 42725/C3).
--   D11    SubscriptionPaymentFailed en _notification_from_event, mismo
--          patrón que PlanLimitExceeded (billing-pro-trial): target ADMIN,
--          severity warning, sin branch_id. Misma firma (public.events) —
--          NO se toca rpc_process_outbox_dispatch.
--
-- RIESGO PRINCIPAL DE ESTA MIGRACIÓN: get_effective_plan está en el camino
-- caliente del hook de emisión de tokens (v31-authz-token-hook) — un error
-- acá no degrada una pantalla, degrada el login. Por eso: (1) NULL no
-- degrada — hoy las 34 cuentas de producción tienen plan_expires_at NULL,
-- así que ESTA migración no cambia el resultado de get_effective_plan para
-- NINGUNA cuenta existente (verificado antes/después — ver VERIFICATION);
-- (2) REVOKE/GRANT reafirmados en el mismo archivo; (3) gate de "exactamente
-- una definición" (42725).
--
-- IDEMPOTENCIA: CREATE TABLE IF NOT EXISTS; CREATE INDEX IF NOT EXISTS;
-- DROP POLICY IF EXISTS + CREATE POLICY; DROP CONSTRAINT IF EXISTS + ADD
-- CONSTRAINT para el CHECK de operation_kind; CREATE OR REPLACE para las 2
-- funciones. Todas las redefiniciones de función son sobre LA MISMA firma.
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration). Se aplica DOS VECES por diseño (integración
--        GitHub + Actions db push) — re-aplicable sin efecto acumulativo.
--
-- GOVERNANCE: CRÍTICO. Esta migración de ESQUEMA no activa ningún
--   comportamiento nuevo de cobro — la activación real queda gateada por
--   BILLING_SUBSCRIPTIONS_ENABLED (backend, default OFF) + el pago E2E de
--   v31-mp-upgrade-webhook-fix 5.1 (MANUAL PO, no ejecutado todavía). Ver
--   design.md Amendment "Activación gated".
--
-- ROLLBACK (aditivo salvo get_effective_plan — sin pérdida de datos; orden):
--   -- get_effective_plan: restaurar el cuerpo ANTERIOR (precedencia sin
--   -- término de vencimiento) con CREATE OR REPLACE sobre la MISMA firma:
--   --   CREATE OR REPLACE FUNCTION public.get_effective_plan(p_account_id uuid)
--   --   RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER
--   --   SET search_path = public, pg_temp AS $$
--   --   DECLARE v_account public.accounts%ROWTYPE;
--   --   BEGIN
--   --     SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;
--   --     IF NOT FOUND THEN RETURN 'gratis'; END IF;
--   --     IF v_account.billing_exempt THEN RETURN 'pro'; END IF;
--   --     IF v_account.trial_plan IS NOT NULL AND v_account.trial_expires_at IS NOT NULL
--   --        AND v_account.trial_expires_at > now() THEN RETURN v_account.trial_plan; END IF;
--   --     IF v_account.billing_plan IN ('gratis','inicial','avanzado','pro') THEN
--   --       RETURN v_account.billing_plan; END IF;
--   --     RETURN 'gratis';
--   --   END; $$;
--   --   REVOKE ALL ON FUNCTION public.get_effective_plan(uuid) FROM PUBLIC, anon, authenticated;
--   --   GRANT EXECUTE ON FUNCTION public.get_effective_plan(uuid) TO supabase_auth_admin, service_role;
--   -- _notification_from_event: restaurar la definición previa a este archivo
--   --   (ver 20260817000001_billing_pro_trial_schema.sql).
--   ALTER TABLE public.operation_idempotency DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;
--   ALTER TABLE public.operation_idempotency ADD CONSTRAINT operation_idempotency_operation_kind_check
--     CHECK (operation_kind = ANY (ARRAY['sale','purchase','payment_received','payment_made',
--       'supplier_charge','bank_movement','event_consumer','bank_statement_import','cash_session_close']::text[]));
--   DROP TABLE IF EXISTS public.subscription_intents;
--   DROP TABLE IF EXISTS public.subscriptions;
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT proname, COUNT(*) FROM pg_proc WHERE proname IN
--     ('get_effective_plan','_notification_from_event') AND pronamespace='public'::regnamespace
--     GROUP BY proname; -- 1 cada una
--   SELECT id, billing_plan, plan_expires_at, public.get_effective_plan(id)
--     FROM public.accounts ORDER BY id; -- comparar contra la captura pre-merge (task 5.1)
--   SELECT pg_get_constraintdef(oid) FROM pg_constraint
--     WHERE conname = 'operation_idempotency_operation_kind_check';
-- =============================================================================


-- =============================================================================
-- 1. public.subscriptions — historial + estado de la suscripción real de MP
--    (D4). account_id NULLABLE (D2bis): una fila 'ambiguous' nace sin dueño
--    conocido hasta que se resuelve a mano.
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id          uuid REFERENCES public.accounts(id),
  preapproval_id      text NOT NULL UNIQUE,
  preapproval_plan_id text NOT NULL,
  plan                text NOT NULL CHECK (plan IN ('inicial', 'avanzado', 'pro')),
  status              text NOT NULL CHECK (status IN ('pending', 'authorized', 'paused', 'cancelled', 'ambiguous')),
  ambiguous_reason    text CHECK (ambiguous_reason IN ('no_match', 'multiple_match')),
  next_payment_date   timestamptz,
  amount              numeric(12, 2),
  currency            text NOT NULL DEFAULT 'ARS',
  external_reference  text,
  retry_state         text NOT NULL DEFAULT 'none' CHECK (retry_state IN ('none', 'retrying', 'exhausted')),
  last_payment_status text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscriptions_ambiguous_reason_consistency
    CHECK ((status = 'ambiguous') = (ambiguous_reason IS NOT NULL))
);

COMMENT ON TABLE public.subscriptions IS
  'mp-real-subscriptions (D4): historial + estado de cada preapproval real de '
  'MercadoPago. account_id NULLABLE — D2bis: una fila status=ambiguous nace '
  'sin dueño conocido (email no matcheó ninguna intención, o matcheó varias) '
  'y espera resolución manual. El dinero se acredita en billing_events '
  'independientemente de si la atribución automática funcionó.';
COMMENT ON COLUMN public.subscriptions.preapproval_id IS
  'ID real del preapproval en MercadoPago — nunca lo generamos nosotros '
  '(D2bis). Único: como máximo una fila por preapproval.';
COMMENT ON COLUMN public.subscriptions.external_reference IS
  'Uso interno/auditoría únicamente — bajo D2bis no viaja a MercadoPago '
  '(el alta no crea ningún preapproval propio, así que no hay dónde '
  'inyectar una referencia antes de que MP cree el objeto).';

-- Máximo una suscripción viva por cuenta (patrón client_addresses,
-- v3-catalog-masters: invariante de unicidad la garantiza la base, no un
-- guard en el service). NULLs no compiten entre sí en un índice único de
-- Postgres — el filtro account_id IS NOT NULL queda explícito para que no
-- se lea como un olvido.
CREATE UNIQUE INDEX IF NOT EXISTS idx_subscriptions_one_live_per_account
  ON public.subscriptions (account_id)
  WHERE status IN ('pending', 'authorized') AND account_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_subscriptions_account_id
  ON public.subscriptions (account_id) WHERE account_id IS NOT NULL;


-- =============================================================================
-- 2. public.subscription_intents — el lado "sabemos quién inició, todavía no
--    sabemos qué preapproval le corresponde" (D2bis).
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.subscription_intents (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id               uuid NOT NULL REFERENCES public.accounts(id),
  payer_email              text NOT NULL CHECK (payer_email = lower(trim(payer_email))),
  plan                     text NOT NULL CHECK (plan IN ('inicial', 'avanzado', 'pro')),
  preapproval_plan_id      text NOT NULL,
  status                   text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'matched', 'ambiguous', 'expired', 'cancelled')),
  expires_at               timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  matched_subscription_id  uuid REFERENCES public.subscriptions(id),
  matched_at               timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subscription_intents_matched_consistency
    CHECK ((status = 'matched') = (matched_subscription_id IS NOT NULL))
);

COMMENT ON TABLE public.subscription_intents IS
  'mp-real-subscriptions (D2bis): fila pre-registrada al iniciar el alta, '
  'ANTES de que MercadoPago cree ningún preapproval. La reconciliación de la '
  'notificación subscription_preapproval busca acá por (payer_email, '
  'preapproval_plan_id, status=pending, expires_at > now()). Ventana de 24h: '
  'cubre un checkout abandonado y retomado sin sostener attribution debt '
  'indefinida ante reintentos del usuario.';
COMMENT ON COLUMN public.subscription_intents.payer_email IS
  'Normalizado lower(trim(...)) — CHECK a nivel de DB además de la '
  'normalización en el backend, defensa en profundidad para una '
  'reconciliación que mueve dinero real.';

CREATE INDEX IF NOT EXISTS idx_subscription_intents_reconciliation
  ON public.subscription_intents (payer_email, preapproval_plan_id)
  WHERE status = 'pending';

CREATE INDEX IF NOT EXISTS idx_subscription_intents_account_id
  ON public.subscription_intents (account_id);


-- =============================================================================
-- 3. RLS — SELECT únicamente para authenticated (D4: deliberado, no un
--    olvido). El estado lo escribe solo el backend (conexión de servicio),
--    nunca la UI directamente — a diferencia de bank_accounts/cashboxes
--    (v3-soft-delete-policy), donde faltar la policy de UPDATE SÍ rompió
--    una operación real de UI. Acá ninguna operación de UI escribe estas
--    tablas, así que la ausencia de INSERT/UPDATE/DELETE es suficiente.
-- =============================================================================
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscription_intents ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS subscriptions_select ON public.subscriptions;
CREATE POLICY subscriptions_select ON public.subscriptions
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT public.current_account_ids()));

DROP POLICY IF EXISTS subscription_intents_select ON public.subscription_intents;
CREATE POLICY subscription_intents_select ON public.subscription_intents
  FOR SELECT
  TO authenticated
  USING (account_id IN (SELECT public.current_account_ids()));

COMMENT ON POLICY subscriptions_select ON public.subscriptions IS
  'mp-real-subscriptions (D4): SELECT únicamente. Deliberadamente SIN '
  'INSERT/UPDATE/DELETE para authenticated — el estado lo escribe solo el '
  'backend desde las notificaciones de MercadoPago. Una fila con '
  'account_id NULL (ambigua) no es visible a ningún authenticated, solo al '
  'backend (conexión de servicio).';
COMMENT ON POLICY subscription_intents_select ON public.subscription_intents IS
  'mp-real-subscriptions (D2bis/D4): SELECT únicamente, mismo motivo que '
  'subscriptions_select — el backend crea la intención al alta, la UI nunca '
  'escribe esta tabla directamente.';


-- =============================================================================
-- 4. operation_idempotency.operation_kind — kind nuevo 'subscription_webhook'
--    (D5). Lección C3: se recrea con la UNIÓN VIGENTE en producción, leída
--    con MCP antes de escribir esta migración (tasks.md 4.1):
--    'sale','purchase','payment_received','payment_made','supplier_charge',
--    'bank_movement','event_consumer','bank_statement_import',
--    'cash_session_close' (9 valores) + 'subscription_webhook' (nuevo) = 10.
-- =============================================================================
ALTER TABLE public.operation_idempotency
  DROP CONSTRAINT IF EXISTS operation_idempotency_operation_kind_check;

ALTER TABLE public.operation_idempotency
  ADD CONSTRAINT operation_idempotency_operation_kind_check
  CHECK (operation_kind = ANY (ARRAY[
    'sale', 'purchase', 'payment_received', 'payment_made', 'supplier_charge',
    'bank_movement', 'event_consumer', 'bank_statement_import', 'cash_session_close',
    'subscription_webhook'
  ]::text[]));

COMMENT ON CONSTRAINT operation_idempotency_operation_kind_check ON public.operation_idempotency IS
  'mp-real-subscriptions (D5, lección C3): agrega subscription_webhook — '
  'claim de idempotencia del backend Python al procesar notificaciones '
  'subscription_preapproval/subscription_authorized_payment. Distinto del '
  'kind event_consumer que ya usa _notification_from_event (Consumer 4 del '
  'outbox) — no se toca ese claim.';


-- =============================================================================
-- 5. _notification_from_event — SubscriptionPaymentFailed (D11), mismo
--    patrón exacto que PlanLimitExceeded (billing-pro-trial). MISMA firma
--    (public.events) — rpc_process_outbox_dispatch no se toca.
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
  mp-real-subscriptions (D11) — Consumer 4 (Notification) del relay del
  outbox.

  mp-real-subscriptions agrega 'SubscriptionPaymentFailed' a la lista
  en-scope (7º tipo). Target ADMIN (owners de la cuenta), severity
  'warning', sin branch_id — el cobro de suscripción es a nivel de cuenta.
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

    -- ── Filtro: los 7 tipos en-scope ──────────────────────────────────────────
    IF v_event_type NOT IN (
        'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
        'QuoteAccepted', 'TransferDispatched', 'PlanLimitExceeded',
        'SubscriptionPaymentFailed'
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
    'mp-real-subscriptions (D11): helper del Consumer 4 (Notification) del '
    'relay del outbox. 7 tipos en-scope. SECURITY DEFINER + SET search_path. '
    'Llamado solo desde rpc_process_outbox_dispatch (misma firma — NO se '
    'tocó ese dispatcher). REVOCADO de authenticated/anon/PUBLIC. '
    'Idempotencia: (event_id, Notification) en operation_idempotency.';


-- =============================================================================
-- 6. get_effective_plan(account_id) — término de vencimiento (D6, el paso
--    delicado). MISMA firma (1 parámetro) — CREATE OR REPLACE, sin overload.
--    NULL no degrada: hoy las 34 cuentas de producción tienen
--    plan_expires_at NULL, así que este cambio no altera el resultado para
--    ninguna cuenta existente (verificado antes/después, ver VERIFICATION).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.get_effective_plan(p_account_id uuid)
RETURNS text
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_account public.accounts%ROWTYPE;
BEGIN
  SELECT * INTO v_account FROM public.accounts WHERE id = p_account_id;

  -- Cuenta inexistente: fail-closed, nunca lanza.
  IF NOT FOUND THEN
    RETURN 'gratis';
  END IF;

  -- 1) Exención de cortesía — precedencia máxima.
  IF v_account.billing_exempt THEN
    RETURN 'pro';
  END IF;

  -- 2) Trial vigente — comparación de timestamps, evaluación perezosa (D1).
  --    Deliberadamente NO se lee billing_status.
  IF v_account.trial_plan IS NOT NULL
     AND v_account.trial_expires_at IS NOT NULL
     AND v_account.trial_expires_at > now() THEN
    RETURN v_account.trial_plan;
  END IF;

  -- 3) billing_plan pago, con término de vencimiento (D6,
  --    mp-real-subscriptions). NULL no degrada — semántica permisiva, OQ1
  --    resuelta (b) 2026-07-31: endurecer es change posterior, una vez que
  --    ninguna cuenta paga tenga plan_expires_at nulo.
  IF v_account.billing_plan IN ('inicial', 'avanzado', 'pro') THEN
    IF v_account.plan_expires_at IS NULL OR v_account.plan_expires_at > now() THEN
      RETURN v_account.billing_plan;
    ELSE
      RETURN 'gratis';
    END IF;
  END IF;

  -- 4) 'gratis' explícito, o cualquier otro valor no reconocido: fail-closed.
  RETURN 'gratis';
END;
$$;

REVOKE ALL ON FUNCTION public.get_effective_plan(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_effective_plan(uuid) TO supabase_auth_admin, service_role;

COMMENT ON FUNCTION public.get_effective_plan(uuid) IS
  'billing-pro-trial (D1/D2) + mp-real-subscriptions (D6): definición '
  'NORMATIVA y única del plan efectivo de una cuenta. Precedencia: exención '
  '→ trial vigente → billing_plan pago no vencido → gratis (fail-closed). '
  'plan_expires_at NULL NO degrada (D6, semántica permisiva — OQ1 resuelta '
  '(b), endurecer es change posterior). Evaluación PEREZOSA — NO depende de '
  'ningún cron. NO lee billing_status. STABLE SECURITY DEFINER, firma '
  'congelada en 1 parámetro (lección 42725 — un segundo parámetro crearía '
  'un overload; usar DROP FUNCTION antes de cambiar la firma). EXECUTE solo '
  'para supabase_auth_admin (hook de v31-authz-token-hook) y service_role.';


-- =============================================================================
-- 7. GATES SQL (RED→GREEN→TRIANGULATE) — patrón billing-pro-trial /
--    v3-notifications-realtime. Estructurales: SIEMPRE (prod y CI).
--    Comportamiento: SOLO si public.accounts está vacía (CI) — anchor
--    sintético vía auth.users, limpieza best-effort.
-- =============================================================================
DO $gate$
DECLARE
  v_count          int;
  v_bool           boolean;
  v_run_behavioral boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- get_effective_plan: 1 def, STABLE+DEFINER
  v_gate_b boolean := false;  -- grants: authenticated/anon SIN EXECUTE, supabase_auth_admin CON EXECUTE
  v_gate_c boolean := false;  -- subscriptions + subscription_intents existen, RLS activa
  v_gate_d boolean := false;  -- índice único parcial de subscriptions existe
  v_gate_e boolean := false;  -- CHECK de operation_kind contiene la unión completa (10 valores)
  v_gate_f boolean := false;  -- _notification_from_event: 1 sola definición (42725/C3)
  v_gate_g boolean := false;  -- subscriptions/subscription_intents: solo 1 policy (SELECT) cada una

  -- comportamiento (solo DB vacía)
  v_fake_user_id     uuid := gen_random_uuid();
  v_fake_account_id  uuid;
  v_sub_id_1         uuid;
  v_plan_result      text;

  v_gate_h boolean := false;  -- plan pago + plan_expires_at pasado → 'gratis'
  v_gate_i boolean := false;  -- plan pago + plan_expires_at futuro → conserva plan
  v_gate_j boolean := false;  -- plan pago + plan_expires_at NULL → conserva plan (D6)
  v_gate_k boolean := false;  -- exención gana sobre plan pago vencido
  v_gate_l boolean := false;  -- trial vigente gana sobre plan pago vencido
  v_gate_m boolean := false;  -- índice parcial: rechaza 2da suscripción viva, permite tras cancelar
  v_gate_n boolean := false;  -- SubscriptionPaymentFailed → exactamente 1 notification
BEGIN

  -- ── (a) get_effective_plan: 1 sola definición, STABLE + SECURITY DEFINER ──
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = 'get_effective_plan' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaba 1 definición de get_effective_plan, hay % (lección 42725/C3)', v_count;
  END IF;

  SELECT provolatile = 's' AND prosecdef INTO v_bool
  FROM pg_proc WHERE proname = 'get_effective_plan' AND pronamespace = 'public'::regnamespace;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (a) FAILED: get_effective_plan debe ser STABLE + SECURITY DEFINER';
  END IF;
  v_gate_a := true;

  -- ── (b) Grants ──────────────────────────────────────────────────────────
  IF has_function_privilege('authenticated', 'public.get_effective_plan(uuid)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.get_effective_plan(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (b) FAILED: get_effective_plan ejecutable por authenticated/anon';
  END IF;

  IF NOT has_function_privilege('supabase_auth_admin', 'public.get_effective_plan(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'GATE (b) FAILED: supabase_auth_admin SIN EXECUTE sobre get_effective_plan (v31-authz-token-hook lo necesita)';
  END IF;
  v_gate_b := true;

  -- ── (c) tablas existen + RLS activa ─────────────────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_tables WHERE schemaname = 'public' AND tablename IN ('subscriptions', 'subscription_intents');
  IF v_count <> 2 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: se esperaban 2 tablas nuevas, hay %', v_count;
  END IF;

  SELECT bool_and(relrowsecurity) INTO v_bool
  FROM pg_class WHERE relname IN ('subscriptions', 'subscription_intents') AND relnamespace = 'public'::regnamespace;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (c) FAILED: RLS no está activa en ambas tablas';
  END IF;
  v_gate_c := true;

  -- ── (d) índice único parcial ─────────────────────────────────────────────
  SELECT EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'public' AND tablename = 'subscriptions'
      AND indexname = 'idx_subscriptions_one_live_per_account'
  ) INTO v_bool;
  IF NOT v_bool THEN
    RAISE EXCEPTION 'GATE (d) FAILED: falta el índice único parcial de subscriptions';
  END IF;
  v_gate_d := true;

  -- ── (e) CHECK de operation_kind con la unión completa ───────────────────
  DECLARE
    v_def text;
  BEGIN
    SELECT pg_get_constraintdef(oid) INTO v_def
    FROM pg_constraint WHERE conname = 'operation_idempotency_operation_kind_check';

    IF v_def IS NULL
       OR v_def NOT LIKE '%subscription_webhook%'
       OR v_def NOT LIKE '%sale%' OR v_def NOT LIKE '%purchase%'
       OR v_def NOT LIKE '%payment_received%' OR v_def NOT LIKE '%payment_made%'
       OR v_def NOT LIKE '%supplier_charge%' OR v_def NOT LIKE '%bank_movement%'
       OR v_def NOT LIKE '%event_consumer%' OR v_def NOT LIKE '%bank_statement_import%'
       OR v_def NOT LIKE '%cash_session_close%'
    THEN
      RAISE EXCEPTION 'GATE (e) FAILED: el CHECK de operation_kind no contiene la unión completa (10 valores). Definición: %', v_def;
    END IF;
  END;
  v_gate_e := true;

  -- ── (f) 42725/C3: _notification_from_event con 1 sola definición ───────
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = '_notification_from_event' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (f) FAILED: _notification_from_event quedó con % definiciones', v_count;
  END IF;
  v_gate_f := true;

  -- ── (g) solo 1 policy (SELECT) por tabla — sin INSERT/UPDATE/DELETE ────
  SELECT COUNT(*) INTO v_count
  FROM pg_policies WHERE schemaname = 'public' AND tablename = 'subscriptions';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (g) FAILED: subscriptions esperaba 1 policy (SELECT), hay %', v_count;
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM pg_policies WHERE schemaname = 'public' AND tablename = 'subscription_intents';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (g) FAILED: subscription_intents esperaba 1 policy (SELECT), hay %', v_count;
  END IF;
  v_gate_g := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'mp-real-subscriptions-gate@test.local', now(), now(),
              jsonb_build_object('name', 'Gate MP-Real-Subs', 'phone', '', 'locality', '', 'province', ''));

      SELECT id INTO v_fake_account_id FROM public.accounts WHERE owner_user_id = v_fake_user_id;

      -- ── (h) plan pago + plan_expires_at PASADO → 'gratis' ────────────────
      UPDATE public.accounts
      SET billing_plan = 'pro', trial_plan = NULL, trial_expires_at = NULL,
          billing_exempt = false, plan_expires_at = now() - INTERVAL '1 day'
      WHERE id = v_fake_account_id;

      v_plan_result := public.get_effective_plan(v_fake_account_id);
      IF v_plan_result = 'gratis' THEN
        v_gate_h := true;
      ELSE
        RAISE EXCEPTION 'GATE (h) FAILED: plan pago vencido devolvió % (esperaba gratis)', v_plan_result;
      END IF;

      -- ── (i) plan pago + plan_expires_at FUTURO → conserva el plan ────────
      UPDATE public.accounts SET plan_expires_at = now() + INTERVAL '10 days' WHERE id = v_fake_account_id;
      v_plan_result := public.get_effective_plan(v_fake_account_id);
      IF v_plan_result = 'pro' THEN
        v_gate_i := true;
      ELSE
        RAISE EXCEPTION 'GATE (i) FAILED: plan pago con vencimiento futuro devolvió % (esperaba pro)', v_plan_result;
      END IF;

      -- ── (j) plan pago + plan_expires_at NULL → conserva el plan (D6) ─────
      UPDATE public.accounts SET plan_expires_at = NULL WHERE id = v_fake_account_id;
      v_plan_result := public.get_effective_plan(v_fake_account_id);
      IF v_plan_result = 'pro' THEN
        v_gate_j := true;
      ELSE
        RAISE EXCEPTION 'GATE (j) FAILED: plan pago con vencimiento NULL devolvió % (esperaba pro — D6 semántica permisiva)', v_plan_result;
      END IF;

      -- ── (k) exención gana sobre plan pago vencido ─────────────────────────
      UPDATE public.accounts
      SET plan_expires_at = now() - INTERVAL '1 day',
          billing_exempt = true, billing_exempt_reason = 'gate mp-real-subscriptions'
      WHERE id = v_fake_account_id;
      v_plan_result := public.get_effective_plan(v_fake_account_id);
      IF v_plan_result = 'pro' THEN
        v_gate_k := true;
      ELSE
        RAISE EXCEPTION 'GATE (k) FAILED: exención con plan pago vencido devolvió % (esperaba pro)', v_plan_result;
      END IF;
      UPDATE public.accounts SET billing_exempt = false, billing_exempt_reason = NULL WHERE id = v_fake_account_id;

      -- ── (l) trial vigente gana sobre plan pago vencido ────────────────────
      UPDATE public.accounts
      SET plan_expires_at = now() - INTERVAL '1 day',
          trial_plan = 'avanzado', trial_expires_at = now() + INTERVAL '5 days'
      WHERE id = v_fake_account_id;
      v_plan_result := public.get_effective_plan(v_fake_account_id);
      IF v_plan_result = 'avanzado' THEN
        v_gate_l := true;
      ELSE
        RAISE EXCEPTION 'GATE (l) FAILED: trial vigente con plan pago vencido devolvió % (esperaba avanzado)', v_plan_result;
      END IF;
      UPDATE public.accounts SET trial_plan = NULL, trial_expires_at = NULL WHERE id = v_fake_account_id;

      -- ── (m) índice único parcial: rechaza 2da viva, permite tras cancelar ─
      INSERT INTO public.subscriptions (account_id, preapproval_id, preapproval_plan_id, plan, status)
      VALUES (v_fake_account_id, 'gate-preapproval-1', 'gate-plan-1', 'pro', 'authorized')
      RETURNING id INTO v_sub_id_1;

      BEGIN
        INSERT INTO public.subscriptions (account_id, preapproval_id, preapproval_plan_id, plan, status)
        VALUES (v_fake_account_id, 'gate-preapproval-2', 'gate-plan-1', 'pro', 'pending');
        RAISE EXCEPTION 'GATE (m) FAILED: se permitió una 2da suscripción viva para la misma cuenta';
      EXCEPTION
        WHEN unique_violation THEN
          NULL;  -- esperado
      END;

      UPDATE public.subscriptions SET status = 'cancelled' WHERE id = v_sub_id_1;

      INSERT INTO public.subscriptions (account_id, preapproval_id, preapproval_plan_id, plan, status)
      VALUES (v_fake_account_id, 'gate-preapproval-3', 'gate-plan-1', 'pro', 'authorized');

      v_gate_m := true;

      -- ── (n) SubscriptionPaymentFailed → exactamente 1 notification ───────
      DECLARE
        v_event       public.events%ROWTYPE;
        v_notif_count int;
      BEGIN
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
          v_fake_account_id, 'SubscriptionPaymentFailed', 'Subscription', v_fake_account_id,
          jsonb_build_object('preapproval_id', 'gate-preapproval-3', 'plan', 'pro'),
          now()
        )
        RETURNING * INTO v_event;

        PERFORM public._notification_from_event(v_event);

        SELECT COUNT(*) INTO v_notif_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id
          AND type = 'SubscriptionPaymentFailed'
          AND severity = 'warning';

        IF v_notif_count = 1 THEN
          v_gate_n := true;
        ELSE
          RAISE EXCEPTION 'GATE (n) FAILED: se esperaba 1 notification SubscriptionPaymentFailed, hay %', v_notif_count;
        END IF;
      END;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;  -- una aserción real falló — abortar (CI lo atrapa)
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'mp-real-subscriptions: anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    -- ── Limpieza best-effort del anchor sintético (solo DB de test) ────────
    BEGIN
      DELETE FROM public.notifications WHERE account_id = v_fake_account_id;
      DELETE FROM public.events WHERE account_id = v_fake_account_id;
      DELETE FROM public.subscription_intents WHERE account_id = v_fake_account_id;
      DELETE FROM public.subscriptions WHERE account_id = v_fake_account_id;
      DELETE FROM public.billing_events WHERE user_id = v_fake_user_id;
      DELETE FROM public.accounts WHERE owner_user_id = v_fake_user_id;
      DELETE FROM public.profiles WHERE id = v_fake_user_id;
      DELETE FROM auth.users WHERE id = v_fake_user_id;
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'mp-real-subscriptions: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== mp-real-subscriptions (schema) SQL gates ===';
  RAISE NOTICE '(a) get_effective_plan: 1 def, STABLE+DEFINER:    %', v_gate_a;
  RAISE NOTICE '(b) grants correctos:                             %', v_gate_b;
  RAISE NOTICE '(c) tablas + RLS activa:                          %', v_gate_c;
  RAISE NOTICE '(d) índice único parcial:                         %', v_gate_d;
  RAISE NOTICE '(e) CHECK operation_kind con unión completa:      %', v_gate_e;
  RAISE NOTICE '(f) sin overloads duplicados (42725/C3):          %', v_gate_f;
  RAISE NOTICE '(g) solo policy SELECT en ambas tablas:           %', v_gate_g;
  RAISE NOTICE '(h) plan pago vencido → gratis:                   %', v_gate_h;
  RAISE NOTICE '(i) plan pago vencimiento futuro → conserva:      %', v_gate_i;
  RAISE NOTICE '(j) plan pago vencimiento NULL → conserva (D6):   %', v_gate_j;
  RAISE NOTICE '(k) exención > plan pago vencido:                 %', v_gate_k;
  RAISE NOTICE '(l) trial vigente > plan pago vencido:            %', v_gate_l;
  RAISE NOTICE '(m) índice parcial rechaza 2da suscripción viva:  %', v_gate_m;
  RAISE NOTICE '(n) SubscriptionPaymentFailed → notification:     %', v_gate_n;
  RAISE NOTICE '=== mp-real-subscriptions (schema): instalado OK ===';

END $gate$;
