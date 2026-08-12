-- =============================================================================
-- MIGRATION: 20260921000001_admin_kpi_freemium_retention.sql
-- CHANGE:    admin-kpi-refresh (grupos 8 y 9 de tasks.md — M2, gateados)
--
-- Sign-off PO 2026-08-12 sobre OQ-4 y OQ-5 (design.md D6/D7): desbloquea los
-- dos grupos que quedaban pendientes tras M1 (20260917000001, grupos 1-7).
-- Escrita SOBRE el cuerpo que dejó M1 (D11) — no sobre el original de
-- 20260228000400/20260430000005.
--
-- QUÉ HACE:
--
--   1. rpc_admin_business_kpis (CREATE OR REPLACE, misma firma): reemplaza
--      COMPLETO el bloque `freemium` (OQ-4, D6, recomendación A con B como
--      término preferente):
--        - Antes: profiles.plan (columna legacy, 'pro' en 35/35 perfiles,
--          nunca escrita por el motor de billing) → pro_users × 15 (mrr
--          ficticio, sin moneda), conversion_rate.
--        - Ahora: por cuenta, get_effective_plan(id) — REUTILIZADO, no
--          re-derivado (regla de reutilización del proyecto) — clasifica la
--          población (paying/trial/exempt/free) replicando la MISMA
--          precedencia que get_effective_plan ya aplica (exención → trial
--          vigente → billing_plan pago no vencido → gratis), porque
--          get_effective_plan colapsa todo a un string de plan y no expone
--          la razón; leer accounts.billing_exempt/trial_plan/trial_expires_at
--          es leer los MISMOS campos que get_effective_plan lee, no una
--          segunda definición de "qué plan tiene la cuenta".
--        - Cuenta con suscripción MP autorizada (subscriptions.status=
--          'authorized') aporta el importe REAL de la suscripción al MRR en
--          vez de la tarifa de lista (D6 término B, preferente sobre A —
--          hoy 100% de las cuentas cae a A porque subscriptions está vacía).
--        - Trials vigentes y cuentas exentas quedan EXCLUIDAS del MRR
--          (mrr_ars=0 para ambas), pero el trial suma a
--          trial_pipeline_mrr_ars (lo que valdría si convirtiera a su plan
--          de trial a tarifa de lista) — el número que importa antes del
--          2026-08-30, cuando vencen los 33 trials PRO de producción.
--        - Mueren pro_users/mrr/conversion_rate. Nacen: paying_accounts,
--          trial_accounts, exempt_accounts, free_accounts, mrr_ars,
--          trial_pipeline_mrr_ars. La moneda va en el nombre del campo
--          (antes: "$525" sin decir de qué moneda).
--
--   2. rpc_admin_retention_30d (DROP + CREATE: agrega p_horizon_days, cambia
--      la firma → 42P13 con CREATE OR REPLACE, igual que M1 con
--      observation_window_days/is_mature): implementa OQ-5/D7 opción C —
--      horizonte común censurado [30, H) con H=60 por defecto.
--        - Antes (M1): ventana FIJA [30,37) — observation_window_days=37
--          constante, is_mature = cohort_period < now() - 37 días.
--        - Ahora: p_horizon_days integer DEFAULT 60 (nuevo parámetro).
--          retained_30d = operó entre el día 30 y el día p_horizon_days
--          desde la activación. observation_window_days = p_horizon_days
--          (ya NO es una constante). is_mature = cohort_period < now() -
--          p_horizon_days días. Con H=37 esta definición DEGENERA en la
--          vieja (D7: "C es A cuando H=37, B cuando H=∞") — el default pasa
--          a 60 porque con 7 usuarios activados totales una ventana de
--          apenas 7 días [30,37) da casi siempre 0% y el panel se lee como
--          muerto; 60 da una ventana de oportunidad de 30 días.
--        - El backfill de eventos históricos (PR #394, 926 operation_created
--          source='backfill', cohortes desde marzo) ya pobló datos para que
--          esta definición calcule algo real, no ceros.
--        - Cierra PA-07 (knowledge-base/10_preguntas_abiertas.md).
--
-- FUERA DE ALCANCE: no se toca ningún otro bloque de rpc_admin_business_kpis
--   (adoption/community/ai quedan como M1 los dejó); no se agrega backfill de
--   subscriptions (la tabla sigue vacía hasta que MP real esté activo,
--   mp-real-subscriptions); no se cambia billing_plan/trial de ninguna cuenta
--   real (es lectura agregada — governance MEDIO, se lee billing, no se
--   escribe).
--
-- GOVERNANCE: MEDIO — lectura agregada de billing (get_effective_plan,
--   subscriptions, plan_limits), cero escritura, cero cambio de gating real.
--
-- IDEMPOTENCIA: CREATE OR REPLACE para (1) — misma firma, sin riesgo de
--   overload. DROP FUNCTION IF EXISTS + CREATE para (2) — drop-then-create
--   es idempotente por construcción. GRANT/REVOKE son no-op si se repiten.
--   El pipeline de este proyecto aplica cada migración dos veces por diseño
--   (integración GitHub + `db push` de Actions).
--
-- APPLY: vía CI al mergear a main. NUNCA con el MCP `apply_migration`.
--
-- ROLLBACK: rpc_admin_business_kpis vuelve a la versión que dejó M1
--   (20260917000001) con CREATE OR REPLACE. rpc_admin_retention_30d con
--   DROP FUNCTION IF EXISTS public.rpc_admin_retention_30d(text, timestamptz,
--   timestamptz, integer) + CREATE de la firma de 3 argumentos que dejó M1 +
--   su GRANT/REVOKE. Sin migración de datos que revertir: el change es de
--   lectura.
--
-- VERIFICATION (post-merge, MCP read-only, SOLO SELECT):
--   SELECT (public.rpc_admin_business_kpis(now() - interval '30 days', now()))->'freemium';
--   SELECT * FROM public.rpc_admin_retention_30d('week', now() - interval '180 days', now());
--   SELECT proname, COUNT(*) FROM pg_proc WHERE proname IN
--     ('rpc_admin_business_kpis','rpc_admin_retention_30d')
--     AND pronamespace = 'public'::regnamespace GROUP BY proname; -- 1 cada una
-- =============================================================================


-- ─────────────────────────────────────────────────────────────────────────────
-- 1. rpc_admin_business_kpis — bloque `freemium` real (OQ-4, D6)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_admin_business_kpis(
  date_from timestamptz DEFAULT (now() - interval '30 days'),
  date_to timestamptz DEFAULT now()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
  v_total_users bigint;
  v_mau bigint;
  v_activated_users bigint;
  v_paying_accounts bigint;
  v_trial_accounts bigint;
  v_exempt_accounts bigint;
  v_free_accounts bigint;
  v_mrr_ars numeric;
  v_trial_pipeline_mrr_ars numeric;
  v_community_activity bigint;
  v_active_pools bigint;
  v_ai_reports bigint;
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  -- 1. Adoption Metrics — SIN CAMBIOS (M1).
  SELECT COUNT(*) INTO v_total_users FROM profiles;

  SELECT COUNT(DISTINCT user_id) INTO v_mau
  FROM analytics_events
  WHERE created_at > (now() - interval '30 days');

  SELECT COUNT(DISTINCT user_id) INTO v_activated_users
  FROM analytics_events
  WHERE event_name = 'first_operation';

  -- 2. Freemium Metrics (OQ-4, D6): plan efectivo × tarifa, con el importe
  --    real de una suscripción MP viva cuando existe (término B, preferente
  --    sobre A). get_effective_plan(id) es la ÚNICA fuente de qué plan tiene
  --    una cuenta — REUTILIZADA acá (regla de reutilización antes que
  --    repetición), no re-derivada. La clasificación de POBLACIÓN
  --    (paying/trial/exempt/free) replica la misma precedencia que
  --    get_effective_plan aplica internamente sobre los mismos campos de
  --    accounts (exención → trial vigente → billing_plan pago no vencido →
  --    gratis) porque la función devuelve sólo un string de plan, no la
  --    razón por la que llegó a él — MRR y trial_pipeline necesitan esa
  --    razón para decidir qué población excluir.
  WITH account_billing AS (
    SELECT
      a.id AS account_id,
      a.billing_exempt,
      a.trial_plan,
      (a.trial_plan IS NOT NULL
        AND a.trial_expires_at IS NOT NULL
        AND a.trial_expires_at > now()) AS has_active_trial,
      public.get_effective_plan(a.id) AS effective_plan,
      (
        SELECT s.amount
        FROM public.subscriptions s
        WHERE s.account_id = a.id AND s.status = 'authorized'
        ORDER BY s.updated_at DESC
        LIMIT 1
      ) AS subscription_amount
    FROM public.accounts a
  ),
  account_population AS (
    SELECT
      ab.account_id,
      CASE
        WHEN ab.billing_exempt THEN 'exempt'
        WHEN ab.has_active_trial THEN 'trial'
        WHEN ab.effective_plan IN ('inicial', 'avanzado', 'pro') THEN 'paying'
        ELSE 'free'
      END AS population,
      -- Trials y exentas NUNCA aportan MRR (D6, sign-off PO 2026-08-12).
      CASE
        WHEN ab.billing_exempt THEN 0
        WHEN ab.has_active_trial THEN 0
        WHEN ab.effective_plan IN ('inicial', 'avanzado', 'pro')
          THEN COALESCE(ab.subscription_amount, pl_effective.price_monthly, 0)
        ELSE 0
      END AS mrr_contribution,
      -- Pipeline: lo que valdría el trial si convirtiera a su plan, a tarifa
      -- de lista. Una cuenta exenta con trial activo NO cuenta acá tampoco
      -- (la exención tiene precedencia — nunca sería una conversión paga).
      CASE
        WHEN ab.has_active_trial AND NOT ab.billing_exempt
          THEN COALESCE(pl_trial.price_monthly, 0)
        ELSE 0
      END AS trial_pipeline_contribution
    FROM account_billing ab
    LEFT JOIN public.plan_limits pl_effective ON pl_effective.plan = ab.effective_plan
    LEFT JOIN public.plan_limits pl_trial     ON pl_trial.plan     = ab.trial_plan
  )
  SELECT
    COUNT(*) FILTER (WHERE population = 'paying'),
    COUNT(*) FILTER (WHERE population = 'trial'),
    COUNT(*) FILTER (WHERE population = 'exempt'),
    COUNT(*) FILTER (WHERE population = 'free'),
    COALESCE(SUM(mrr_contribution), 0),
    COALESCE(SUM(trial_pipeline_contribution), 0)
  INTO v_paying_accounts, v_trial_accounts, v_exempt_accounts, v_free_accounts,
       v_mrr_ars, v_trial_pipeline_mrr_ars
  FROM account_population;

  -- 3. Community Metrics — SIN CAMBIOS (M1: tablas transaccionales, reutiliza
  --    get_admin_community_interactions).
  v_community_activity := public.get_admin_community_interactions(date_from, date_to);
  SELECT COUNT(*) INTO v_active_pools FROM community.purchase_pools;

  -- 4. IA Metrics — SIN CAMBIOS.
  SELECT COUNT(*) INTO v_ai_reports
  FROM analytics_events
  WHERE event_name = 'insight_generated'
    AND created_at BETWEEN date_from AND date_to;

  SELECT jsonb_build_object(
    'adoption', jsonb_build_object(
      'total_users', v_total_users,
      'mau', v_mau,
      'activation_rate', CASE WHEN v_total_users > 0 THEN (v_activated_users::numeric / v_total_users * 100)::int ELSE 0 END
    ),
    'freemium', jsonb_build_object(
      'paying_accounts', v_paying_accounts,
      'trial_accounts', v_trial_accounts,
      'exempt_accounts', v_exempt_accounts,
      'free_accounts', v_free_accounts,
      'mrr_ars', v_mrr_ars,
      'trial_pipeline_mrr_ars', v_trial_pipeline_mrr_ars
    ),
    'community', jsonb_build_object(
      'total_activity', v_community_activity,
      'active_pools', v_active_pools
    ),
    'ai', jsonb_build_object(
      'total_insights', v_ai_reports,
      'alerts_triggered', (SELECT COUNT(*) FROM analytics_events WHERE event_name = 'operation_created' AND (event_data->>'type' = 'stock_alert'))
    )
  ) INTO result;

  RETURN result;
END;
$$;


-- ─────────────────────────────────────────────────────────────────────────────
-- 2. rpc_admin_retention_30d — horizonte censurado [30,H) con H=60 (OQ-5, D7)
-- ─────────────────────────────────────────────────────────────────────────────
-- 42P13: agregar un parámetro cambia la firma → Postgres rechaza CREATE OR
-- REPLACE contra la firma VIEJA de 3 argumentos. El DROP resetea las ACLs →
-- se reaplican GRANT/REVOKE abajo en esta misma migración (mismo patrón que
-- M1 usó para esta función). A partir de acá la firma es la NUEVA de 4
-- argumentos — CREATE OR REPLACE (no CREATE a secas) para que reaplicar esta
-- misma migración una segunda vez (el pipeline de este proyecto aplica cada
-- migración dos veces por diseño) no falle con "already exists with same
-- argument types" contra la firma que la primera pasada ya creó.
DROP FUNCTION IF EXISTS public.rpc_admin_retention_30d(text, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.rpc_admin_retention_30d(
  cohort_granularity text DEFAULT 'week',
  date_from timestamptz DEFAULT (now() - interval '90 days'),
  date_to timestamptz DEFAULT now(),
  p_horizon_days integer DEFAULT 60
)
RETURNS TABLE (
  cohort_start timestamptz,
  cohort_size bigint,
  retained_30d bigint,
  retention_rate numeric,
  observation_window_days integer,
  is_mature boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NOT public.is_admin(auth.uid()) THEN
    RAISE EXCEPTION 'Access denied: Admin only';
  END IF;

  IF p_horizon_days IS NULL OR p_horizon_days <= 30 THEN
    RAISE EXCEPTION 'p_horizon_days debe ser mayor a 30 (ventana de retención empieza en el día 30)';
  END IF;

  RETURN QUERY
  WITH user_cohorts AS (
    SELECT
      user_id,
      date_trunc(cohort_granularity, created_at) AS cohort_period,
      created_at AS activation_time
    FROM public.analytics_events
    WHERE event_name = 'first_operation'
      AND created_at BETWEEN date_from AND date_to
  ),
  user_retention AS (
    -- OQ-5/D7 opción C: retenido si operó en el horizonte censurado
    -- [30, p_horizon_days) desde la activación — no en la ventana fija
    -- [30,37) que M1 dejó. Con p_horizon_days=37 esta consulta degenera
    -- exactamente en la definición anterior.
    SELECT DISTINCT
      c.user_id,
      c.cohort_period
    FROM user_cohorts c
    JOIN public.analytics_events e ON c.user_id = e.user_id
    WHERE e.event_name = 'operation_created'
      AND e.created_at >= c.activation_time + interval '30 days'
      AND e.created_at < c.activation_time + (p_horizon_days || ' days')::interval
  ),
  cohort_sizes AS (
    SELECT cohort_period, COUNT(user_id) AS total_users
    FROM user_cohorts
    GROUP BY cohort_period
  ),
  retained_sizes AS (
    SELECT cohort_period, COUNT(user_id) AS retained_users
    FROM user_retention
    GROUP BY cohort_period
  )
  SELECT
    cs.cohort_period AS cohort_start,
    cs.total_users AS cohort_size,
    COALESCE(rs.retained_users, 0) AS retained_30d,
    ROUND((COALESCE(rs.retained_users, 0)::numeric / cs.total_users::numeric) * 100, 2) AS retention_rate,
    p_horizon_days AS observation_window_days,
    (cs.cohort_period < now() - (p_horizon_days || ' days')::interval) AS is_mature
  FROM cohort_sizes cs
  LEFT JOIN retained_sizes rs ON cs.cohort_period = rs.cohort_period
  ORDER BY cs.cohort_period;
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_admin_retention_30d(text, timestamptz, timestamptz, integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_retention_30d(text, timestamptz, timestamptz, integer) FROM PUBLIC, anon;


-- ─────────────────────────────────────────────────────────────────────────────
-- 3. Superficie de autorización — GRANT/REVOKE idempotentes (defensa en
--    profundidad: CREATE OR REPLACE de (1) conserva ACLs; sólo (2) las
--    necesitaba por el DROP+CREATE)
-- ─────────────────────────────────────────────────────────────────────────────
GRANT EXECUTE ON FUNCTION public.rpc_admin_business_kpis(timestamptz, timestamptz) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_admin_business_kpis(timestamptz, timestamptz) FROM PUBLIC, anon;

-- ── GATE — exactamente una definición por proname + ACLs correctas ──────────
DO $$
DECLARE
  v_sig      text;
  v_dup      int;
  v_fns      CONSTANT text[] := ARRAY[
    'public.rpc_admin_business_kpis(timestamptz, timestamptz)',
    'public.rpc_admin_retention_30d(text, timestamptz, timestamptz, integer)'
  ];
  v_pronames CONSTANT text[] := ARRAY[
    'rpc_admin_business_kpis', 'rpc_admin_retention_30d'
  ];
BEGIN
  FOREACH v_sig IN ARRAY v_fns LOOP
    IF NOT has_function_privilege('authenticated', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: % sin EXECUTE para authenticated', v_sig;
    END IF;
    IF has_function_privilege('anon', to_regprocedure(v_sig), 'EXECUTE') THEN
      RAISE EXCEPTION 'GATE FAILED: % con EXECUTE para anon', v_sig;
    END IF;
  END LOOP;

  FOREACH v_sig IN ARRAY v_pronames LOOP
    SELECT COUNT(*) INTO v_dup
    FROM pg_proc p JOIN pg_namespace n ON p.pronamespace = n.oid
    WHERE n.nspname = 'public' AND p.proname = v_sig;

    IF v_dup <> 1 THEN
      RAISE EXCEPTION 'GATE FAILED: % tiene % definiciones (anti-42725)', v_sig, v_dup;
    END IF;
  END LOOP;
END $$;

-- =============================================================================
-- END OF MIGRATION 20260921000001_admin_kpi_freemium_retention.sql
-- =============================================================================
