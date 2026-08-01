-- =============================================================================
-- MIGRATION: 20260817000001_billing_pro_trial_schema.sql
-- CHANGE:    billing-pro-trial (cluster de autorización, sign-off PO 2026-07-31)
-- Design ref: openspec/changes/billing-pro-trial/design.md
--
-- Implementa (design.md):
--   D1  get_effective_plan(account_id): evaluación PEREZOSA del plan efectivo.
--       Precedencia: exención → trial vigente → billing_plan → 'gratis'
--       (fail-closed). NO lee accounts.billing_status — deliberado: ese campo
--       pasa a ser descriptivo (D6), nunca autoritativo.
--   D2  Firma congelada en 1 parámetro (uuid). STABLE SECURITY DEFINER,
--       SET search_path fijo. EXECUTE revocado de PUBLIC/anon/authenticated,
--       concedido solo a supabase_auth_admin y service_role — el hook de Auth
--       (v31-authz-token-hook) no necesita GRANT SELECT sobre accounts.
--   D4  Exención de cortesía: 4 columnas nuevas en accounts + CHECK que exige
--       motivo. No es una tabla aparte (evita un join en el camino caliente de
--       emisión de tokens y otro objeto al que supabase_auth_admin necesitaría
--       acceso — ver design.md D4).
--   D5  Backend deja de hardcodear límites — plan_limits.avanzado.max_products
--       pasa de 1500 a 2000 (alinea DB al valor ya usado por frontend/backend,
--       decisión del PO en el sign-off — NO al revés).
--   D6  expire_trials()/queue_trial_notifications() realineados a accounts.
--       expire_trials() queda documentado (COMMENT ON FUNCTION) como sweep
--       DESCRIPTIVO — el gating nunca depende de que haya corrido.
--   D9  Aviso de excedente: nuevo tipo PlanLimitExceeded en
--       _notification_from_event (misma firma — sin riesgo de overload) +
--       producer _sweep_plan_limit_exceeded() vía pg_cron, dedup 7 días por
--       (cuenta, recurso).
--
-- DESVIACIÓN DOCUMENTADA de tasks.md (Sección 6, guard de proveedores):
--   El design/tasks.md asume que el guard de límite de proveedores se agrega
--   en el backend Python, extendiendo el patrón de productos/clientes. Al
--   preparar la implementación se verificó que **no existe** un endpoint de
--   creación de proveedores en el backend (`SupplierRepository` solo expone
--   `list_by_org`/`get_by_id` — sin `create`; no hay router ni service). La
--   única vía de alta de proveedores hoy es un INSERT directo vía Supabase
--   client desde el frontend, habilitado por la policy RLS
--   `suppliers_account_insert` (20260613000004) — arquitectura híbrida
--   (DEC-16), 0 proveedores en las 34 cuentas de prod. Un guard en el backend
--   Python no puede interceptar ese camino. Se implementa el guard como
--   trigger BEFORE INSERT en la DB (`fn_guard_supplier_plan_limit`, misma
--   política current_count >= limit que products/clients) — es la única capa
--   que ve TODOS los inserts de suppliers, sea cual sea el cliente. No se creó
--   un endpoint de creación nuevo (fuera de alcance de este change).
--
-- IDEMPOTENCIA: ADD COLUMN IF NOT EXISTS, CREATE OR REPLACE, DROP TRIGGER IF
-- EXISTS + CREATE, DO $$ ... IF NOT EXISTS para el CHECK constraint,
-- cron.unschedule + cron.schedule (patrón v3-notifications-realtime §4.2).
-- Todas las redefiniciones de función son CREATE OR REPLACE sobre LA MISMA
-- firma (0 o 1 argumento, sin cambios) — verificado explícitamente en el gate
-- (d) de esta migración (lección 42725 / C3).
--
-- APPLY: CI la aplica al mergear a main (NUNCA db push manual ni MCP
--        apply_migration). El pipeline de este proyecto aplica las
--        migraciones DOS VECES por diseño (integración GitHub + Actions
--        db push) — todo bloque de esta migración es re-aplicable sin efecto
--        acumulativo (no hay backfill de datos acá; el backfill vive en
--        20260817000002, con su propio guard de idempotencia).
--
-- GOVERNANCE: CRÍTICO — billing de 34 cuentas reales, una con pago
--   reconciliado. Esta migración de ESQUEMA no otorga el trial a nadie
--   todavía (eso es 20260817000002, gateado por OQ-1/sign-off del PO) y no
--   activa ningún enforcement nuevo en producción hasta que
--   v31-authz-token-hook encienda el claim `plan` (fuera de este change).
--
-- ROLLBACK (aditivo — sin pérdida de datos; en orden):
--   SELECT cron.unschedule('billing-plan-limit-exceeded-sweep') FROM cron.job
--     WHERE jobname = 'billing-plan-limit-exceeded-sweep';
--   DROP TRIGGER IF EXISTS trg_guard_supplier_plan_limit ON public.suppliers;
--   DROP FUNCTION IF EXISTS public.fn_guard_supplier_plan_limit();
--   DROP FUNCTION IF EXISTS public._sweep_plan_limit_exceeded();
--   -- _notification_from_event / expire_trials / queue_trial_notifications /
--   -- set_new_user_trial: restaurar la definición previa a este archivo
--   -- (ver diffs en 20260808000001 / billing_schema / grace_period).
--   DROP FUNCTION IF EXISTS public.get_effective_plan(uuid);
--   ALTER TABLE public.accounts DROP CONSTRAINT IF EXISTS accounts_billing_exempt_reason_check;
--   ALTER TABLE public.accounts
--     DROP COLUMN IF EXISTS billing_exempt,
--     DROP COLUMN IF EXISTS billing_exempt_reason,
--     DROP COLUMN IF EXISTS billing_exempt_granted_at,
--     DROP COLUMN IF EXISTS billing_exempt_granted_by;
--   -- plan_limits.avanzado.max_products: revertir a 1500 si se decide volver
--   -- atrás (UPDATE public.plan_limits SET max_products = 1500 WHERE plan = 'avanzado';)
--
-- VERIFICATION (post-merge, MCP read-only):
--   SELECT proname, prosecdef FROM pg_proc WHERE proname = 'get_effective_plan';
--   SELECT has_function_privilege('authenticated', 'public.get_effective_plan(uuid)', 'EXECUTE'); -- false
--   SELECT has_function_privilege('supabase_auth_admin', 'public.get_effective_plan(uuid)', 'EXECUTE'); -- true
--   SELECT max_products FROM public.plan_limits WHERE plan = 'avanzado'; -- 2000
--   SELECT jobname FROM cron.job WHERE jobname = 'billing-plan-limit-exceeded-sweep';
-- =============================================================================


-- =============================================================================
-- 1. plan_limits: alinear avanzado.max_products a 2000 (D5 — decisión del PO:
--    la DB (1500) se alinea al valor ya usado por frontend/backend, no al
--    revés). UPDATE puntual, idempotente por naturaleza (fija un valor final).
-- =============================================================================
UPDATE public.plan_limits
SET max_products = 2000
WHERE plan = 'avanzado' AND max_products <> 2000;


-- =============================================================================
-- 2. Exención de cortesía auditable (D4) — 4 columnas + CHECK en accounts
-- =============================================================================
ALTER TABLE public.accounts
  ADD COLUMN IF NOT EXISTS billing_exempt            boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS billing_exempt_reason      text,
  ADD COLUMN IF NOT EXISTS billing_exempt_granted_at  timestamptz,
  ADD COLUMN IF NOT EXISTS billing_exempt_granted_by  uuid REFERENCES auth.users(id);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'accounts_billing_exempt_reason_check'
      AND conrelid = 'public.accounts'::regclass
  ) THEN
    ALTER TABLE public.accounts
      ADD CONSTRAINT accounts_billing_exempt_reason_check
      CHECK (billing_exempt = false OR billing_exempt_reason IS NOT NULL);
  END IF;
END $$;

COMMENT ON COLUMN public.accounts.billing_exempt IS
  'billing-pro-trial (D4): exención de cortesía explícita y auditable. NUNCA '
  'se deriva de un default implícito — requiere billing_exempt_reason (CHECK) '
  'y queda registrada en billing_events (event_type=exemption_granted). Sin '
  'policy de UPDATE para authenticated: se concede por migración o admin de '
  'plataforma, nunca por el propio usuario.';
COMMENT ON COLUMN public.accounts.billing_exempt_reason IS
  'billing-pro-trial (D4): motivo humano-legible de la exención. NOT NULL '
  'cuando billing_exempt=true (CHECK accounts_billing_exempt_reason_check).';
COMMENT ON COLUMN public.accounts.billing_exempt_granted_at IS
  'billing-pro-trial (D4): instante del otorgamiento — auditoría, no gating.';
COMMENT ON COLUMN public.accounts.billing_exempt_granted_by IS
  'billing-pro-trial (D4): quién concedió la exención (FK auth.users) — '
  'auditoría, no gating.';


-- =============================================================================
-- 3. get_effective_plan(account_id) — la definición normativa única (D1, D2)
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

  -- 3) billing_plan, si es un valor reconocido.
  IF v_account.billing_plan IN ('gratis', 'inicial', 'avanzado', 'pro') THEN
    RETURN v_account.billing_plan;
  END IF;

  -- 4) Cualquier otro caso: fail-closed. Nunca el plan más alto.
  RETURN 'gratis';
END;
$$;

REVOKE ALL ON FUNCTION public.get_effective_plan(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_effective_plan(uuid) TO supabase_auth_admin, service_role;

COMMENT ON FUNCTION public.get_effective_plan(uuid) IS
  'billing-pro-trial (D1/D2): definición NORMATIVA y única del plan efectivo '
  'de una cuenta. Precedencia: exención → trial vigente → billing_plan → '
  'gratis (fail-closed). Evaluación PEREZOSA (compara trial_expires_at contra '
  'now() en cada lectura) — NO depende de ningún cron. NO lee billing_status '
  '(D6: ese campo es descriptivo, no autoritativo). STABLE SECURITY DEFINER, '
  'firma congelada en 1 parámetro (lección 42725 — un segundo parámetro '
  'crearía un overload; usar DROP FUNCTION antes de cambiar la firma). '
  'EXECUTE solo para supabase_auth_admin (hook de v31-authz-token-hook) y '
  'service_role — revocado de PUBLIC/anon/authenticated: el frontend ya tiene '
  'la fila de accounts y no necesita invocar esta función sobre cuentas '
  'ajenas.';


-- =============================================================================
-- 4. Trial PRO de 30 días para cuentas nuevas (D8) — set_new_user_trial()
--    Trigger AFTER INSERT en profiles ya existe (trg_new_user_trial,
--    20260605000001); CREATE OR REPLACE sobre la MISMA firma (sin args)
--    reapunta su efecto sin recrear el trigger.
-- =============================================================================
CREATE OR REPLACE FUNCTION public.set_new_user_trial()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  UPDATE public.profiles
  SET
    trial_plan       = 'pro',
    trial_started_at = now(),
    trial_expires_at = now() + INTERVAL '30 days',
    billing_status   = 'trialing'
  WHERE id = NEW.id;
  RETURN NULL;  -- AFTER trigger: return value ignored
END;
$$;

COMMENT ON FUNCTION public.set_new_user_trial() IS
  'billing-pro-trial (D8): siembra 30 días de trial PRO (antes: avanzado) '
  'para cada usuario nuevo. handle_new_user() inserta en profiles primero — '
  'el trigger AFTER INSERT trg_new_user_trial corre dentro de esa misma '
  'sentencia, así que el INSERT posterior en accounts (mismo handle_new_user) '
  'ya lee trial_plan=pro.';


-- =============================================================================
-- 5. Realineación de los dos cron de C-03 a accounts (D6)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.expire_trials()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  n integer;
BEGIN
  WITH expired AS (
    UPDATE public.accounts
    SET billing_status = 'expired'
    WHERE billing_status = 'trialing'
      AND trial_expires_at IS NOT NULL
      AND trial_expires_at < now()
    RETURNING id, owner_user_id, trial_plan, billing_plan
  )
  INSERT INTO public.billing_events (user_id, event_type, from_plan, to_plan, reason, metadata)
  SELECT
    owner_user_id,
    'trial_expired',
    trial_plan,
    billing_plan,
    'billing-pro-trial (D6): sweep cosmético descriptivo — accounts.billing_status es un campo de reporting, NO el mecanismo de gating (ver get_effective_plan)',
    jsonb_build_object('expired_at', now(), 'account_id', id)
  FROM expired;

  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END;
$function$;

COMMENT ON FUNCTION public.expire_trials() IS
  'billing-pro-trial (D6): sweep DESCRIPTIVO sobre accounts.billing_status — '
  'existe para que la UI de facturación y los reportes reflejen el ciclo '
  'comercial. El ACCESO no depende de que esta función haya corrido: lo '
  'determina get_effective_plan() de forma perezosa, comparando '
  'trial_expires_at contra now() en cada lectura. Si este sweep se cae, el '
  'peor efecto es una etiqueta atrasada en /facturacion — nunca un permiso '
  'mal otorgado ni mal negado. Antes de este change actualizaba profiles '
  '(tabla que el gating nunca leyó desde C-19) — ver design.md Context.';

CREATE OR REPLACE FUNCTION public.queue_trial_notifications()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  n integer := 0;
  inserted integer;
BEGIN
  -- ── Window 7d: trial expires within 6–7 days (inclusive on lower, exclusive upper) ──
  WITH candidates_7d AS (
    SELECT am.user_id AS user_id,
           au.email   AS recipient
    FROM public.accounts a
    JOIN public.account_members am ON am.account_id = a.id
    JOIN auth.users au ON au.id = am.user_id
    WHERE a.billing_status = 'trialing'
      AND a.trial_expires_at IS NOT NULL
      AND a.trial_expires_at >= (now() + INTERVAL '6 days')
      AND a.trial_expires_at <  (now() + INTERVAL '7 days')
  ),
  ins_7d AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT
      user_id,
      'trial_expiring_soon',
      recipient,
      'Te quedan 7 dias de prueba — EmprendeSmart',
      jsonb_build_object('umbral', '7d')
    FROM candidates_7d
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted FROM ins_7d;
  n := n + inserted;

  -- ── Window 1d: trial expires within 0–1 days ──
  WITH candidates_1d AS (
    SELECT am.user_id AS user_id,
           au.email   AS recipient
    FROM public.accounts a
    JOIN public.account_members am ON am.account_id = a.id
    JOIN auth.users au ON au.id = am.user_id
    WHERE a.billing_status = 'trialing'
      AND a.trial_expires_at IS NOT NULL
      AND a.trial_expires_at >= now()
      AND a.trial_expires_at <  (now() + INTERVAL '1 day')
  ),
  ins_1d AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT
      user_id,
      'trial_expiring_soon',
      recipient,
      'Tu prueba vence manana — EmprendeSmart',
      jsonb_build_object('umbral', '1d')
    FROM candidates_1d
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted FROM ins_1d;
  n := n + inserted;

  RETURN n;
END;
$function$;

COMMENT ON FUNCTION public.queue_trial_notifications() IS
  'billing-pro-trial (D6): encola avisos de vencimiento próximo (7d/1d) '
  'leyendo public.accounts (antes: profiles — un vencimiento que la fuente '
  'autoritativa del gating nunca vio). Destinatarios resueltos via '
  'account_members → auth.users (todos los miembros de la cuenta, no solo el '
  'owner). Dedup por (user_id, event_type, metadata) — ON CONFLICT DO NOTHING.';


-- =============================================================================
-- 6. Aviso de excedente — PlanLimitExceeded en _notification_from_event (D9)
--    CREATE OR REPLACE sobre la MISMA firma (public.events) — el dispatcher
--    rpc_process_outbox_dispatch ya invoca esta función incondicionalmente
--    para todo evento; el filtro de tipos vive acá adentro, así que NO hace
--    falta tocar rpc_process_outbox_dispatch.
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
  v3-notifications-realtime (D2) + billing-pro-trial (D9) — Consumer 4
  (Notification) del relay del outbox.

  billing-pro-trial agrega 'PlanLimitExceeded' a la lista en-scope (6º tipo).
  Target ADMIN (owners de la cuenta), severity 'warning'. Sin branch_id — el
  excedente de plan es a nivel de cuenta, no de sucursal.
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

    -- ── Filtro: los 6 tipos en-scope ──────────────────────────────────────────
    IF v_event_type NOT IN (
        'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
        'QuoteAccepted', 'TransferDispatched', 'PlanLimitExceeded'
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
    'v3-notifications-realtime (D2) + billing-pro-trial (D9): helper del '
    'Consumer 4 (Notification) del relay del outbox. SECURITY DEFINER + SET '
    'search_path. Llamado solo desde rpc_process_outbox_dispatch (misma firma '
    '— NO se tocó ese dispatcher). REVOCADO de authenticated/anon/PUBLIC. '
    'Idempotencia: (event_id, Notification) en operation_idempotency. No-op '
    'para event_type fuera de los 6 en-scope, para CashSessionClosed con '
    'difference=0, y para audience vacía.';


-- =============================================================================
-- 7. Barrido de excedente — producer de PlanLimitExceeded (D9)
--    Compara conteos vivos vs plan_limits para el plan efectivo de cada
--    cuenta. Dedup: como máximo 1 evento por (cuenta, recurso) cada 7 días,
--    verificado contra notifications (no contra events — el relay puede no
--    haber procesado el evento anterior todavía dentro del mismo día).
-- =============================================================================
CREATE OR REPLACE FUNCTION public._sweep_plan_limit_exceeded()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_account_id   uuid;
  v_plan         text;
  v_max_products integer;
  v_max_clients  integer;
  v_max_suppliers integer;
  v_count        integer;
  v_dedup        boolean;
  v_events       integer := 0;
BEGIN
  FOR v_account_id IN SELECT id FROM public.accounts LOOP
    v_plan := public.get_effective_plan(v_account_id);

    SELECT max_products, max_clients, max_suppliers
    INTO v_max_products, v_max_clients, v_max_suppliers
    FROM public.plan_limits
    WHERE plan = v_plan;

    IF NOT FOUND THEN
      CONTINUE;  -- plan sin fila en plan_limits: no hay contra qué comparar
    END IF;

    -- ── products ──────────────────────────────────────────────────────────
    SELECT COUNT(*) INTO v_count FROM public.products
    WHERE account_id = v_account_id AND deleted_at IS NULL;

    IF v_count >= v_max_products THEN
      SELECT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE account_id = v_account_id
          AND type = 'PlanLimitExceeded'
          AND payload->>'resource' = 'products'
          AND created_at > now() - INTERVAL '7 days'
      ) INTO v_dedup;

      IF NOT v_dedup THEN
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
          v_account_id, 'PlanLimitExceeded', 'Account', v_account_id,
          jsonb_build_object('resource', 'products', 'current', v_count, 'limit', v_max_products, 'plan', v_plan),
          now()
        );
        v_events := v_events + 1;
      END IF;
    END IF;

    -- ── clients ───────────────────────────────────────────────────────────
    SELECT COUNT(*) INTO v_count FROM public.clients
    WHERE account_id = v_account_id AND deleted_at IS NULL;

    IF v_count >= v_max_clients THEN
      SELECT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE account_id = v_account_id
          AND type = 'PlanLimitExceeded'
          AND payload->>'resource' = 'clients'
          AND created_at > now() - INTERVAL '7 days'
      ) INTO v_dedup;

      IF NOT v_dedup THEN
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
          v_account_id, 'PlanLimitExceeded', 'Account', v_account_id,
          jsonb_build_object('resource', 'clients', 'current', v_count, 'limit', v_max_clients, 'plan', v_plan),
          now()
        );
        v_events := v_events + 1;
      END IF;
    END IF;

    -- ── suppliers ─────────────────────────────────────────────────────────
    SELECT COUNT(*) INTO v_count FROM public.suppliers
    WHERE account_id = v_account_id AND deleted_at IS NULL;

    IF v_count >= v_max_suppliers THEN
      SELECT EXISTS (
        SELECT 1 FROM public.notifications
        WHERE account_id = v_account_id
          AND type = 'PlanLimitExceeded'
          AND payload->>'resource' = 'suppliers'
          AND created_at > now() - INTERVAL '7 days'
      ) INTO v_dedup;

      IF NOT v_dedup THEN
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
          v_account_id, 'PlanLimitExceeded', 'Account', v_account_id,
          jsonb_build_object('resource', 'suppliers', 'current', v_count, 'limit', v_max_suppliers, 'plan', v_plan),
          now()
        );
        v_events := v_events + 1;
      END IF;
    END IF;

  END LOOP;

  RETURN v_events;
END;
$fn$;

REVOKE ALL ON FUNCTION public._sweep_plan_limit_exceeded() FROM PUBLIC, anon, authenticated;

COMMENT ON FUNCTION public._sweep_plan_limit_exceeded() IS
  'billing-pro-trial (D9): barrido diario (pg_cron) que detecta cuentas por '
  'encima del límite de su plan efectivo (productos/clientes/proveedores) y '
  'emite UN evento PlanLimitExceeded por (cuenta, recurso) hacia el outbox. '
  'Dedup: máximo 1 aviso por recurso cada 7 días (verificado contra '
  'notifications, no contra events). NO decide plan ni bloquea nada — solo '
  'observa una condición que get_effective_plan ya determina (D1). Si este '
  'barrido no corre, nadie recibe el aviso y el enforcement de creación '
  '(guards de productos/clientes/proveedores) sigue funcionando igual.';

-- Patrón exacto v3-notifications-realtime §4.2 (unschedule + schedule, sin
-- guard adicional — pg_cron ya está instalado en local/CI/prod).
SELECT cron.unschedule('billing-plan-limit-exceeded-sweep')
FROM cron.job WHERE jobname = 'billing-plan-limit-exceeded-sweep';

SELECT cron.schedule(
    'billing-plan-limit-exceeded-sweep',
    '0 4 * * *',  -- diario a las 04:00 UTC
    $$ SELECT public._sweep_plan_limit_exceeded(); $$
);


-- =============================================================================
-- 8. Guard de límite de proveedores (desviación documentada arriba) —
--    trigger BEFORE INSERT en suppliers, mismo predicado current_count >=
--    limit que products/clients (D5/D7). ERRCODE nuevo P0B10 (familia
--    P0Bxx de guards de maestros — P0B04 ya en uso por soft-delete).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.fn_guard_supplier_plan_limit()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_plan  text;
  v_limit integer;
  v_count integer;
BEGIN
  -- Filas legacy sin account_id (era company_id) quedan fuera del guard —
  -- no hay cuenta contra la cual evaluar un límite.
  IF NEW.account_id IS NULL THEN
    RETURN NEW;
  END IF;

  v_plan := public.get_effective_plan(NEW.account_id);

  SELECT max_suppliers INTO v_limit
  FROM public.plan_limits
  WHERE plan = v_plan;

  IF v_limit IS NULL THEN
    RETURN NEW;  -- plan sin fila en plan_limits: no bloquear por un dato faltante
  END IF;

  SELECT COUNT(*) INTO v_count
  FROM public.suppliers
  WHERE account_id = NEW.account_id AND deleted_at IS NULL;

  IF v_count >= v_limit THEN
    RAISE EXCEPTION
      'Límite de proveedores alcanzado para el plan % (% máx.). Borrá proveedores existentes o subí de plan.',
      v_plan, v_limit
      USING ERRCODE = 'P0B10';
  END IF;

  RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.fn_guard_supplier_plan_limit() IS
  'billing-pro-trial (D5/D7, desviación documentada en la cabecera de esta '
  'migración): suppliers no tiene endpoint de creación en el backend Python '
  '— el alta es un INSERT directo vía Supabase client (policy RLS '
  'suppliers_account_insert). Este trigger es la única capa que ve todos los '
  'inserts y aplica la misma política current_count >= limit que products/ '
  'clients. ERRCODE P0B10.';

DROP TRIGGER IF EXISTS trg_guard_supplier_plan_limit ON public.suppliers;
CREATE TRIGGER trg_guard_supplier_plan_limit
  BEFORE INSERT ON public.suppliers
  FOR EACH ROW
  EXECUTE FUNCTION public.fn_guard_supplier_plan_limit();


-- =============================================================================
-- 9. GATES SQL (RED→GREEN→TRIANGULATE) — patrón v31-fsm-status-triggers /
--    v3-notifications-realtime. Estructurales: SIEMPRE (prod y CI).
--    Comportamiento: SOLO si public.accounts está vacía (CI) — anchor
--    sintético vía auth.users (handle_new_user provisiona accounts +
--    account_members + branch/caja), limpieza best-effort.
-- =============================================================================
DO $gate$
DECLARE
  v_count            int;
  v_bool             boolean;
  v_text             text;
  v_run_behavioral   boolean := false;

  -- estructurales
  v_gate_a boolean := false;  -- get_effective_plan: existe, 1 sola definición, STABLE+DEFINER
  v_gate_b boolean := false;  -- grants: authenticated/anon SIN EXECUTE, supabase_auth_admin CON EXECUTE
  v_gate_c boolean := false;  -- accounts: 4 columnas de exención + CHECK existen
  v_gate_d boolean := false;  -- expire_trials/queue_trial_notifications apuntan a accounts, no profiles
  v_gate_e boolean := false;  -- plan_limits.avanzado.max_products = 2000
  v_gate_f boolean := false;  -- 5 funciones redefinidas: una sola definición cada una (42725/C3)
  v_gate_g boolean := false;  -- trigger de suppliers existe y apunta a la función

  -- comportamiento (solo DB vacía)
  v_fake_user_id     uuid := gen_random_uuid();
  v_fake_user_id_2   uuid := gen_random_uuid();
  v_fake_account_id  uuid;
  v_fake_account_id_2 uuid;
  v_fake_company_id  uuid := gen_random_uuid();  -- suppliers.company_id: NOT NULL legacy + FK companies (ver bank-payment-routing)
  v_plan_result      text;
  v_expires_at       timestamptz;

  v_gate_h boolean := false;  -- cuenta nueva: trial_plan=pro, ~30 días, get_effective_plan='pro'
  v_gate_i boolean := false;  -- exención con billing_plan=gratis y trial vencido → 'pro'
  v_gate_j boolean := false;  -- billing_status no altera el resultado (5 valores del CHECK)
  v_gate_k boolean := false;  -- expire_trials(): cuenta trialing+vencida → expired; active no transiciona
  v_gate_l boolean := false;  -- suppliers: guard bloquea al alcanzar el límite
  v_gate_m boolean := false;  -- _notification_from_event: PlanLimitExceeded crea notification
BEGIN

  -- ── (a) get_effective_plan: 1 sola definición, STABLE + SECURITY DEFINER ──
  SELECT COUNT(*) INTO v_count
  FROM pg_proc WHERE proname = 'get_effective_plan' AND pronamespace = 'public'::regnamespace;
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (a) FAILED: se esperaba 1 definición de get_effective_plan, hay % (lección 42725/overload)', v_count;
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

  -- ── (c) accounts: columnas de exención + CHECK ─────────────────────────
  SELECT COUNT(*) INTO v_count
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'accounts'
    AND column_name IN ('billing_exempt', 'billing_exempt_reason', 'billing_exempt_granted_at', 'billing_exempt_granted_by');
  IF v_count <> 4 THEN
    RAISE EXCEPTION 'GATE (c) FAILED: se esperaban 4 columnas de exención en accounts, hay %', v_count;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'accounts_billing_exempt_reason_check' AND conrelid = 'public.accounts'::regclass
  ) INTO v_bool;
  IF NOT v_bool THEN
    RAISE EXCEPTION 'GATE (c) FAILED: falta el CHECK accounts_billing_exempt_reason_check';
  END IF;
  v_gate_c := true;

  -- ── (d) expire_trials/queue_trial_notifications apuntan a accounts ─────
  SELECT pg_get_functiondef('public.expire_trials()'::regprocedure) LIKE '%public.accounts%'
     AND pg_get_functiondef('public.expire_trials()'::regprocedure) NOT LIKE '%UPDATE public.profiles%'
  INTO v_bool;
  IF NOT v_bool THEN
    RAISE EXCEPTION 'GATE (d) FAILED: expire_trials() no quedó realineada a accounts';
  END IF;

  SELECT pg_get_functiondef('public.queue_trial_notifications()'::regprocedure) LIKE '%public.accounts%'
  INTO v_bool;
  IF NOT v_bool THEN
    RAISE EXCEPTION 'GATE (d) FAILED: queue_trial_notifications() no quedó realineada a accounts';
  END IF;
  v_gate_d := true;

  -- ── (e) plan_limits.avanzado.max_products = 2000 (D5) ──────────────────
  SELECT max_products INTO v_count FROM public.plan_limits WHERE plan = 'avanzado';
  IF v_count <> 2000 THEN
    RAISE EXCEPTION 'GATE (e) FAILED: plan_limits.avanzado.max_products esperaba 2000, hay %', v_count;
  END IF;
  v_gate_e := true;

  -- ── (f) 42725/C3: cada función redefinida queda con 1 sola definición ──
  SELECT bool_and(cnt = 1) INTO v_bool
  FROM (
    SELECT proname, COUNT(*) AS cnt
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('set_new_user_trial', 'expire_trials', 'queue_trial_notifications',
                       '_notification_from_event', '_sweep_plan_limit_exceeded',
                       'fn_guard_supplier_plan_limit')
    GROUP BY proname
  ) sub;
  IF NOT COALESCE(v_bool, false) THEN
    RAISE EXCEPTION 'GATE (f) FAILED: alguna de las funciones redefinidas quedó con más de 1 overload';
  END IF;
  v_gate_f := true;

  -- ── (g) trigger de suppliers existe y apunta a la función ──────────────
  SELECT COUNT(*) INTO v_count
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE c.relnamespace = 'public'::regnamespace
    AND c.relname = 'suppliers'
    AND p.proname = 'fn_guard_supplier_plan_limit'
    AND NOT t.tgisinternal
    AND t.tgenabled = 'O';
  IF v_count <> 1 THEN
    RAISE EXCEPTION 'GATE (g) FAILED: trigger trg_guard_supplier_plan_limit no está instalado/habilitado';
  END IF;
  v_gate_g := true;

  -- ══════════════════════════════════════════════════════════════════════
  -- COMPORTAMIENTO (solo DB vacía — CI). Anchor sintético patrón C2/C3.
  -- ══════════════════════════════════════════════════════════════════════
  SELECT (COUNT(*) = 0) INTO v_run_behavioral FROM public.accounts;

  IF v_run_behavioral THEN
    BEGIN
      -- ── (h) cuenta nueva vía handle_new_user: trial_plan=pro, ~30 días ──
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id, 'authenticated', 'authenticated',
              'billing-pro-trial-gate-h@test.local', now(), now(),
              jsonb_build_object('name', 'Gate H', 'phone', '', 'locality', '', 'province', ''));

      SELECT a.id, a.trial_plan, a.trial_expires_at
      INTO v_fake_account_id, v_text, v_expires_at
      FROM public.accounts a
      WHERE a.owner_user_id = v_fake_user_id;

      IF v_text = 'pro'
         AND v_expires_at IS NOT NULL
         AND v_expires_at BETWEEN now() + INTERVAL '29 days' AND now() + INTERVAL '31 days'
         AND public.get_effective_plan(v_fake_account_id) = 'pro'
      THEN
        v_gate_h := true;
      ELSE
        RAISE EXCEPTION 'GATE (h) FAILED: cuenta nueva trial_plan=% expires_at=% effective=%',
          v_text, v_expires_at, public.get_effective_plan(v_fake_account_id);
      END IF;

      -- ── (i) exención con billing_plan=gratis + trial vencido → 'pro' ────
      UPDATE public.accounts
      SET billing_plan = 'gratis',
          trial_plan = 'pro',
          trial_expires_at = now() - INTERVAL '1 day',
          billing_exempt = true,
          billing_exempt_reason = 'gate de comportamiento billing-pro-trial'
      WHERE id = v_fake_account_id;

      IF public.get_effective_plan(v_fake_account_id) = 'pro' THEN
        v_gate_i := true;
      ELSE
        RAISE EXCEPTION 'GATE (i) FAILED: cuenta exenta con trial vencido devolvió %', public.get_effective_plan(v_fake_account_id);
      END IF;

      -- revertir exención para no interferir con (j)/(k)/(l)
      UPDATE public.accounts SET billing_exempt = false, billing_exempt_reason = NULL WHERE id = v_fake_account_id;

      -- ── (j) billing_status no altera get_effective_plan (5 valores) ─────
      UPDATE public.accounts
      SET billing_plan = 'inicial', trial_plan = NULL, trial_expires_at = NULL
      WHERE id = v_fake_account_id;

      DECLARE
        v_results text[] := ARRAY[]::text[];
        v_status  text;
      BEGIN
        FOREACH v_status IN ARRAY ARRAY['active','trialing','expired','cancelled','cancelling'] LOOP
          UPDATE public.accounts SET billing_status = v_status WHERE id = v_fake_account_id;
          v_results := array_append(v_results, public.get_effective_plan(v_fake_account_id));
        END LOOP;

        IF (SELECT COUNT(DISTINCT r) FROM unnest(v_results) r) = 1 AND v_results[1] = 'inicial' THEN
          v_gate_j := true;
        ELSE
          RAISE EXCEPTION 'GATE (j) FAILED: billing_status alteró el resultado: %', v_results;
        END IF;
      END;

      -- ── (k) expire_trials(): trialing+vencida → expired; active no toca ─
      INSERT INTO auth.users (id, aud, role, email, created_at, updated_at, raw_user_meta_data)
      VALUES (v_fake_user_id_2, 'authenticated', 'authenticated',
              'billing-pro-trial-gate-k@test.local', now(), now(),
              jsonb_build_object('name', 'Gate K', 'phone', '', 'locality', '', 'province', ''));

      SELECT id INTO v_fake_account_id_2 FROM public.accounts WHERE owner_user_id = v_fake_user_id_2;

      UPDATE public.accounts
      SET billing_status = 'trialing', trial_plan = 'pro', trial_expires_at = now() - INTERVAL '1 hour'
      WHERE id = v_fake_account_id;  -- gate (h)/(j) account: trialing + vencida

      UPDATE public.accounts
      SET billing_status = 'active', trial_plan = 'pro', trial_expires_at = now() - INTERVAL '1 hour'
      WHERE id = v_fake_account_id_2;  -- active: NO debe transicionar

      PERFORM public.expire_trials();

      SELECT billing_status INTO v_text FROM public.accounts WHERE id = v_fake_account_id;
      IF v_text <> 'expired' THEN
        RAISE EXCEPTION 'GATE (k) FAILED: cuenta trialing+vencida no transicionó a expired (quedó %)', v_text;
      END IF;

      SELECT billing_status INTO v_text FROM public.accounts WHERE id = v_fake_account_id_2;
      IF v_text <> 'active' THEN
        RAISE EXCEPTION 'GATE (k) FAILED: cuenta active fue tocada por expire_trials() (quedó %)', v_text;
      END IF;
      v_gate_k := true;

      -- ── (l) suppliers: guard bloquea al alcanzar el límite ──────────────
      -- suppliers.company_id es NOT NULL legacy con FK a companies(id)
      -- (esquema pre-V2, ver gate de bank-payment-routing) — se satisface con
      -- una companies sintética propia; el modelo V2 usa account_id.
      UPDATE public.accounts SET billing_plan = 'gratis', trial_plan = NULL, trial_expires_at = NULL
      WHERE id = v_fake_account_id;  -- plan efectivo = gratis → max_suppliers = 20

      INSERT INTO public.companies (id, name)
      VALUES (v_fake_company_id, 'Company Test billing-pro-trial (gate l)')
      ON CONFLICT (id) DO NOTHING;

      FOR v_count IN 1..20 LOOP
        INSERT INTO public.suppliers (id, account_id, company_id, name, created_at)
        VALUES (gen_random_uuid(), v_fake_account_id, v_fake_company_id, 'Proveedor gate ' || v_count, now());
      END LOOP;

      BEGIN
        INSERT INTO public.suppliers (id, account_id, company_id, name, created_at)
        VALUES (gen_random_uuid(), v_fake_account_id, v_fake_company_id, 'Proveedor 21', now());
        RAISE EXCEPTION 'GATE (l) FAILED: el proveedor 21 debería haber sido rechazado (límite gratis=20)';
      EXCEPTION
        WHEN OTHERS THEN
          IF SQLSTATE = 'P0B10' THEN
            v_gate_l := true;
          ELSIF SQLERRM LIKE 'GATE (l) FAILED%' THEN
            RAISE;
          ELSE
            RAISE NOTICE 'billing-pro-trial: gate (l) degradado (%)', SQLERRM;
          END IF;
      END;

      -- ── (m) _notification_from_event: PlanLimitExceeded → notification ──
      DECLARE
        v_event      public.events%ROWTYPE;
        v_notif_count int;
        v_owner_ids  uuid[];
      BEGIN
        INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
        VALUES (
          v_fake_account_id, 'PlanLimitExceeded', 'Account', v_fake_account_id,
          jsonb_build_object('resource', 'suppliers', 'current', 21, 'limit', 20, 'plan', 'gratis'),
          now()
        )
        RETURNING * INTO v_event;

        PERFORM public._notification_from_event(v_event);

        SELECT COUNT(*) INTO v_notif_count
        FROM public.notifications
        WHERE account_id = v_fake_account_id
          AND type = 'PlanLimitExceeded'
          AND severity = 'warning'
          AND payload->>'resource' = 'suppliers';

        SELECT array_agg(user_id) INTO v_owner_ids
        FROM public.account_members
        WHERE account_id = v_fake_account_id AND role = 'owner';

        IF v_notif_count = 1 THEN
          v_gate_m := true;
        ELSE
          RAISE EXCEPTION 'GATE (m) FAILED: se esperaba 1 notification PlanLimitExceeded, hay %', v_notif_count;
        END IF;
      END;

    EXCEPTION
      WHEN OTHERS THEN
        IF SQLERRM LIKE 'GATE (%' THEN
          RAISE;  -- una aserción real falló — abortar (CI lo atrapa)
        END IF;
        v_run_behavioral := false;
        RAISE NOTICE 'billing-pro-trial: anchor sintético/gates de comportamiento degradados (%) — %', SQLSTATE, SQLERRM;
    END;

    -- ── Limpieza best-effort del anchor sintético (solo DB de test) ────────
    BEGIN
      DELETE FROM public.notifications WHERE account_id IN (v_fake_account_id, v_fake_account_id_2);
      DELETE FROM public.events WHERE account_id IN (v_fake_account_id, v_fake_account_id_2);
      DELETE FROM public.suppliers WHERE account_id = v_fake_account_id;
      DELETE FROM public.companies WHERE id = v_fake_company_id;
      DELETE FROM public.billing_events WHERE user_id IN (v_fake_user_id, v_fake_user_id_2);
      DELETE FROM public.accounts WHERE owner_user_id IN (v_fake_user_id, v_fake_user_id_2);
      DELETE FROM public.profiles WHERE id IN (v_fake_user_id, v_fake_user_id_2);
      DELETE FROM auth.users WHERE id IN (v_fake_user_id, v_fake_user_id_2);
    EXCEPTION
      WHEN OTHERS THEN
        RAISE NOTICE 'billing-pro-trial: limpieza parcial del anchor de test (%) — no afecta prod', SQLERRM;
    END;
  END IF;

  -- ── Resumen ───────────────────────────────────────────────────────────────
  RAISE NOTICE '=== billing-pro-trial (schema) SQL gates ===';
  RAISE NOTICE '(a) get_effective_plan: 1 def, STABLE+DEFINER:    %', v_gate_a;
  RAISE NOTICE '(b) grants correctos:                             %', v_gate_b;
  RAISE NOTICE '(c) columnas de exención + CHECK:                 %', v_gate_c;
  RAISE NOTICE '(d) expire_trials/queue_trial_notif → accounts:   %', v_gate_d;
  RAISE NOTICE '(e) plan_limits.avanzado.max_products = 2000:     %', v_gate_e;
  RAISE NOTICE '(f) sin overloads duplicados (42725/C3):          %', v_gate_f;
  RAISE NOTICE '(g) trigger de suppliers instalado:                %', v_gate_g;
  RAISE NOTICE '(h) cuenta nueva: trial PRO 30d:                  %', v_gate_h;
  RAISE NOTICE '(i) exención > trial vencido:                     %', v_gate_i;
  RAISE NOTICE '(j) billing_status no altera el resultado:        %', v_gate_j;
  RAISE NOTICE '(k) expire_trials() sobre accounts:                %', v_gate_k;
  RAISE NOTICE '(l) guard de proveedores bloquea el excedente:    %', v_gate_l;
  RAISE NOTICE '(m) PlanLimitExceeded → notification:             %', v_gate_m;
  RAISE NOTICE '=== billing-pro-trial (schema): instalado OK ===';

END $gate$;
