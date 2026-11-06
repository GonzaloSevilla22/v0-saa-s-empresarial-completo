-- ia-copilot-v2 (tanda A, governance MEDIO) — base de datos del Copiloto con herramientas.
--
-- El Copiloto pasa de una ruta de Next a la Edge Function `ai-copilot`. Esta migración
-- pone lo que esa función necesita en la base, todo ADITIVO:
--
--   1. ai_conversations: instrumentación por turno (model, tools_used, latency_ms,
--      prompt_tokens, completion_tokens, outcome, thread_id). El guardado estaba roto
--      desde junio: la policy `ai_conversations_account_insert` exige
--      `account_id IN current_account_ids()` y el guardado viejo insertaba sin
--      account_id (columna sin default ni trigger) -> la RLS lo rechazaba y el error se
--      tiraba al log. La función nueva inserta CON account_id.
--   2. profiles: ventana de ráfaga propia de las consultas (ai_queries_window_count,
--      ai_queries_window_started_at). Sin privilegio de escritura para cliente
--      (profiles tiene allow-list de columnas, ver 20261053000001): sólo la escriben la
--      RPC SECURITY DEFINER y el cron.
--   3. ai_feedback (D13): valoración «me sirvió / no me sirvió» por usuario y por sujeto
--      (copilot_answer | insight), RLS con SELECT propio, SIN privilegios de escritura
--      para anon/authenticated: se escribe sólo por rpc_set_ai_feedback.
--   4. rpc_reserve_ai_usage(p_counter text): gana la rama 'queries' (5 por 60 s) sin
--      tocar la de 'ocr'. Reescrita PARTIENDO DEL CUERPO VIVO de producción
--      (md5(replace(prosrc, E'\r','')) = 5e8e0795805ddedf2d905f3d03ea69ea, verificado el
--      2026-11-06 y idéntico al de 20261090000001). Misma firma: CREATE OR REPLACE, y se
--      re-emiten REVOKE/GRANT y COMMENT.
--   5. Cron `reset-ai-counters` (mismo nombre y schedule) resetea también la ventana de
--      las consultas.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, CHECK/policy con guarda, CREATE TABLE IF NOT
-- EXISTS, CREATE OR REPLACE con la misma firma, unschedule + schedule del cron.
-- Gate: supabase/tests/test_ia_copilot_v2.sql.

-- ─── 1. ai_conversations: instrumentación ────────────────────────────────────

ALTER TABLE public.ai_conversations
  ADD COLUMN IF NOT EXISTS model text,
  ADD COLUMN IF NOT EXISTS tools_used jsonb NOT NULL DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS latency_ms integer,
  ADD COLUMN IF NOT EXISTS prompt_tokens integer,
  ADD COLUMN IF NOT EXISTS completion_tokens integer,
  ADD COLUMN IF NOT EXISTS outcome text,
  ADD COLUMN IF NOT EXISTS thread_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conrelid = 'public.ai_conversations'::regclass
       AND conname = 'ai_conversations_outcome_check'
  ) THEN
    ALTER TABLE public.ai_conversations
      ADD CONSTRAINT ai_conversations_outcome_check
      CHECK (outcome IS NULL OR outcome IN ('answer', 'clarification', 'fallback', 'error'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_ai_conversations_user_created
  ON public.ai_conversations (user_id, created_at DESC);

COMMENT ON COLUMN public.ai_conversations.model IS
  'Modelo de OpenAI que respondió el turno (NULL en las filas anteriores a ia-copilot-v2).';
COMMENT ON COLUMN public.ai_conversations.tools_used IS
  'Herramientas llamadas en el turno: [{name, ok, rows, ms}], sin argumentos de texto libre.';
COMMENT ON COLUMN public.ai_conversations.outcome IS
  'Resultado del turno: answer | clarification | fallback | error.';
COMMENT ON COLUMN public.ai_conversations.thread_id IS
  'Agrupa los turnos de una misma conversación de la pantalla.';

-- ─── 2. profiles: ventana de ráfaga de las consultas ─────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS ai_queries_window_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_queries_window_started_at timestamptz;

COMMENT ON COLUMN public.profiles.ai_queries_window_count IS
  'Consultas de IA reservadas dentro de la ventana de ráfaga vigente (máx. 5 por 60 s). Sólo la escribe rpc_reserve_ai_usage y el cron reset-ai-counters.';
COMMENT ON COLUMN public.profiles.ai_queries_window_started_at IS
  'Inicio de la ventana fija de ráfaga de las consultas de IA; NULL = sin ventana abierta.';

-- ─── 3. ai_feedback ──────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.ai_feedback (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  account_id   uuid NOT NULL REFERENCES public.accounts(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  subject_type text NOT NULL CHECK (subject_type IN ('copilot_answer', 'insight')),
  subject_id   uuid NOT NULL,
  rating       text NOT NULL CHECK (rating IN ('useful', 'not_useful')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, subject_type, subject_id)
);

ALTER TABLE public.ai_feedback ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS ai_feedback_own_select ON public.ai_feedback;
CREATE POLICY ai_feedback_own_select ON public.ai_feedback
  FOR SELECT TO authenticated
  USING (user_id = auth.uid() AND account_id IN (SELECT public.current_account_ids()));

-- Sin policies de escritura Y sin privilegio: se escribe sólo por rpc_set_ai_feedback.
REVOKE ALL ON TABLE public.ai_feedback FROM PUBLIC, anon, authenticated;
GRANT SELECT ON TABLE public.ai_feedback TO authenticated;

CREATE INDEX IF NOT EXISTS idx_ai_feedback_account_subject_created
  ON public.ai_feedback (account_id, subject_type, created_at);

COMMENT ON TABLE public.ai_feedback IS
  'Valoración «me sirvió / no me sirvió» por usuario sobre una respuesta de IA (copilot_answer; insight lo habilita ia-insights-tablero). subject_id es polimórfico, sin FK dura: la integridad la da rpc_set_ai_feedback. Escritura sólo por esa RPC.';

CREATE OR REPLACE FUNCTION public.rpc_set_ai_feedback(
  p_subject_type text,
  p_subject_id   uuid,
  p_rating       text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_uid     uuid := auth.uid();
  v_account uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  IF p_subject_type IS NULL OR p_subject_type NOT IN ('copilot_answer', 'insight') THEN
    RAISE EXCEPTION 'invalid subject_type: %', p_subject_type USING ERRCODE = '22023';
  END IF;
  IF p_rating IS NOT NULL AND p_rating NOT IN ('useful', 'not_useful') THEN
    RAISE EXCEPTION 'invalid rating: %', p_rating USING ERRCODE = '22023';
  END IF;
  IF p_subject_id IS NULL THEN
    RAISE EXCEPTION 'subject_id is required' USING ERRCODE = '22023';
  END IF;

  -- La rama 'insight' la habilita el change ia-insights-tablero.
  IF p_subject_type = 'insight' THEN
    RAISE EXCEPTION 'subject_type insight is not enabled yet' USING ERRCODE = '22023';
  END IF;

  -- copilot_answer: una fila de ai_conversations del MISMO usuario y de una cuenta suya.
  SELECT c.account_id INTO v_account
    FROM public.ai_conversations c
   WHERE c.id = p_subject_id
     AND c.user_id = v_uid
     AND c.account_id IN (SELECT public.current_account_ids());
  IF v_account IS NULL THEN
    RAISE EXCEPTION 'subject not found' USING ERRCODE = 'P0404';
  END IF;

  IF p_rating IS NULL THEN
    DELETE FROM public.ai_feedback f
     WHERE f.user_id = v_uid AND f.subject_type = p_subject_type AND f.subject_id = p_subject_id;
  ELSE
    INSERT INTO public.ai_feedback AS f (account_id, user_id, subject_type, subject_id, rating)
    VALUES (v_account, v_uid, p_subject_type, p_subject_id, p_rating)
    ON CONFLICT (user_id, subject_type, subject_id)
    DO UPDATE SET rating = EXCLUDED.rating, account_id = EXCLUDED.account_id, updated_at = now();
  END IF;

  RETURN jsonb_build_object(
    'subject_type', p_subject_type,
    'subject_id', p_subject_id,
    'rating', p_rating
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_set_ai_feedback(text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_set_ai_feedback(text, uuid, text) TO authenticated;

COMMENT ON FUNCTION public.rpc_set_ai_feedback(text, uuid, text) IS
  'Guarda (upsert), cambia o borra (p_rating NULL) la valoración useful|not_useful del usuario autenticado sobre una respuesta del Copiloto propia. P0401 sin sesión, 22023 dominio (y insight, aún no habilitado), P0404 sujeto inexistente o ajeno. ia-copilot-v2.';

-- ─── 4. rpc_reserve_ai_usage: rama 'queries' ─────────────────────────────────
-- Partida: cuerpo vivo de 20261090000001 (md5 5e8e0795805ddedf2d905f3d03ea69ea). La rama
-- 'ocr' conserva el cuerpo de partida línea por línea dentro del IF; 'queries' es una rama
-- hermana con su propio UPDATE condicional único.

CREATE OR REPLACE FUNCTION public.rpc_reserve_ai_usage(p_counter text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  -- Ráfaga (OQ-4): 3 lecturas por ventana fija de 60 s, por usuario. Literales
  -- a propósito: no se configuran por plan.
  c_burst_max    CONSTANT integer  := 3;
  c_burst_window CONSTANT interval := interval '60 seconds';
  -- Ráfaga de las consultas del Copiloto (ia-copilot-v2, OQ-2): 5 por 60 s.
  c_q_burst_max  CONSTANT integer  := 5;

  v_uid      uuid := auth.uid();
  v_plan     text;
  v_limit    integer;
  v_used     integer;
  v_wcount   integer;
  v_wstart   timestamptz;
  v_reset_at timestamptz;
  v_retry    integer;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Contadores reservables: 'ocr' (lecturas de factura) y 'queries' (consultas del
  -- Copiloto). 'advice' y cualquier otro siguen en 22023.
  IF p_counter IS DISTINCT FROM 'ocr' AND p_counter IS DISTINCT FROM 'queries' THEN
    RAISE EXCEPTION 'invalid counter: %', p_counter USING ERRCODE = '22023';
  END IF;

  -- El plan lo resuelve la fuente normativa (cuenta activa), no profiles.
  v_plan := public.rpc_my_effective_plan();

  -- Próxima renovación: el cron corre 00:00 UTC del día 1.
  v_reset_at := (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC';

  IF p_counter = 'ocr' THEN
    SELECT pl.max_ai_ocr_per_month INTO v_limit
      FROM public.plan_limits pl
     WHERE pl.plan = v_plan;

    IF v_limit IS NULL THEN
      -- Fail-closed: sin límite no se concede nada.
      RAISE EXCEPTION 'plan limits unavailable for plan %', v_plan USING ERRCODE = 'P0503';
    END IF;

    -- UN solo UPDATE condicional: serializa por el lock de fila y re-evalúa el
    -- WHERE sobre la versión incrementada si otra transacción llegó antes.
    UPDATE public.profiles p
       SET ai_ocr_used = p.ai_ocr_used + 1,
           ai_ocr_window_count = CASE
             WHEN p.ai_ocr_window_started_at IS NULL
                  OR p.ai_ocr_window_started_at <= now() - c_burst_window
             THEN 1
             ELSE p.ai_ocr_window_count + 1
           END,
           ai_ocr_window_started_at = CASE
             WHEN p.ai_ocr_window_started_at IS NULL
                  OR p.ai_ocr_window_started_at <= now() - c_burst_window
             THEN now()
             ELSE p.ai_ocr_window_started_at
           END
     WHERE p.id = v_uid
       AND p.ai_ocr_used < v_limit
       AND (p.ai_ocr_window_started_at IS NULL
            OR p.ai_ocr_window_started_at <= now() - c_burst_window
            OR p.ai_ocr_window_count < c_burst_max)
    RETURNING p.ai_ocr_used INTO v_used;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'allowed', true,
        'used', v_used,
        'limit', v_limit,
        'reset_at', v_reset_at
      );
    END IF;

    -- Denegada: se relee (sin lock) para decir por qué.
    SELECT p.ai_ocr_used, p.ai_ocr_window_count, p.ai_ocr_window_started_at
      INTO v_used, v_wcount, v_wstart
      FROM public.profiles p
     WHERE p.id = v_uid;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'profile not found' USING ERRCODE = 'P0503';
    END IF;

    -- Precedencia: sin cupo mensual gana sobre la ráfaga.
    IF v_used >= v_limit THEN
      RETURN jsonb_build_object(
        'allowed', false,
        'reason', 'quota_exceeded',
        'used', v_used,
        'limit', v_limit,
        'reset_at', v_reset_at
      );
    END IF;

    v_retry := LEAST(60, GREATEST(1, ceil(
      extract(epoch FROM (c_burst_window - (now() - COALESCE(v_wstart, now()))))
    )::integer));

    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'rate_limited',
      'retry_after_seconds', v_retry
    );
  END IF;

  -- ── Rama 'queries' (ia-copilot-v2): comparte ai_queries_used con las demás
  -- funciones de IA (check + incremento), que tocan la misma columna con UPDATE atómico.
  SELECT pl.max_ai_queries_per_month INTO v_limit
    FROM public.plan_limits pl
   WHERE pl.plan = v_plan;

  IF v_limit IS NULL THEN
    RAISE EXCEPTION 'plan limits unavailable for plan %', v_plan USING ERRCODE = 'P0503';
  END IF;

  UPDATE public.profiles p
     SET ai_queries_used = p.ai_queries_used + 1,
         ai_queries_window_count = CASE
           WHEN p.ai_queries_window_started_at IS NULL
                OR p.ai_queries_window_started_at <= now() - c_burst_window
           THEN 1
           ELSE p.ai_queries_window_count + 1
         END,
         ai_queries_window_started_at = CASE
           WHEN p.ai_queries_window_started_at IS NULL
                OR p.ai_queries_window_started_at <= now() - c_burst_window
           THEN now()
           ELSE p.ai_queries_window_started_at
         END
   WHERE p.id = v_uid
     AND p.ai_queries_used < v_limit
     AND (p.ai_queries_window_started_at IS NULL
          OR p.ai_queries_window_started_at <= now() - c_burst_window
          OR p.ai_queries_window_count < c_q_burst_max)
  RETURNING p.ai_queries_used INTO v_used;

  IF FOUND THEN
    RETURN jsonb_build_object(
      'allowed', true,
      'used', v_used,
      'limit', v_limit,
      'reset_at', v_reset_at
    );
  END IF;

  SELECT p.ai_queries_used, p.ai_queries_window_count, p.ai_queries_window_started_at
    INTO v_used, v_wcount, v_wstart
    FROM public.profiles p
   WHERE p.id = v_uid;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'profile not found' USING ERRCODE = 'P0503';
  END IF;

  IF v_used >= v_limit THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'reason', 'quota_exceeded',
      'used', v_used,
      'limit', v_limit,
      'reset_at', v_reset_at
    );
  END IF;

  v_retry := LEAST(60, GREATEST(1, ceil(
    extract(epoch FROM (c_burst_window - (now() - COALESCE(v_wstart, now()))))
  )::integer));

  RETURN jsonb_build_object(
    'allowed', false,
    'reason', 'rate_limited',
    'retry_after_seconds', v_retry
  );
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_reserve_ai_usage(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reserve_ai_usage(text) TO authenticated;

COMMENT ON FUNCTION public.rpc_reserve_ai_usage(text) IS
  'Reserva atómica de una unidad de IA para el usuario autenticado: un solo UPDATE condicional incrementa el contador mensual y la ventana de ráfaga. p_counter = ocr (lecturas de factura, ráfaga 3 por 60 s) o queries (consultas del Copiloto, ráfaga 5 por 60 s). Devuelve {allowed, used, limit, reset_at} o {allowed:false, reason: quota_exceeded|rate_limited, ...}. Fail-closed (P0401 sin sesión, 22023 contador inválido, P0503 sin límite). La reserva concedida no se devuelve. v31-ia-ratelimit-budget + ia-copilot-v2.';

-- ─── 5. Cron: el reset mensual también limpia la ventana de las consultas ────

DO $$
BEGIN
  PERFORM cron.unschedule('reset-ai-counters');
EXCEPTION WHEN OTHERS THEN
  -- Job did not exist yet — safe to ignore
END;
$$;

SELECT cron.schedule(
  'reset-ai-counters',
  '0 0 1 * *',
  $$UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL, ai_queries_window_count = 0, ai_queries_window_started_at = NULL, usage_reset_at = now()$$
);

-- ─── 6. Introspección final (aborta si algo no quedó como se declara) ─────────

DO $$
DECLARE
  v_oid oid;
BEGIN
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'ai_conversations'
         AND column_name IN ('model', 'tools_used', 'latency_ms', 'prompt_tokens', 'completion_tokens', 'outcome', 'thread_id')) <> 7 THEN
    RAISE EXCEPTION 'ia-copilot-v2: faltan columnas en ai_conversations.';
  END IF;
  IF (SELECT count(*) FROM information_schema.columns
       WHERE table_schema = 'public' AND table_name = 'profiles'
         AND column_name IN ('ai_queries_window_count', 'ai_queries_window_started_at')) <> 2 THEN
    RAISE EXCEPTION 'ia-copilot-v2: faltan columnas en profiles.';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.ai_feedback'::regclass) THEN
    RAISE EXCEPTION 'ia-copilot-v2: ai_feedback sin RLS.';
  END IF;
  IF has_table_privilege('anon', 'public.ai_feedback', 'SELECT')
     OR has_table_privilege('anon', 'public.ai_feedback', 'INSERT')
     OR has_table_privilege('authenticated', 'public.ai_feedback', 'INSERT')
     OR has_table_privilege('authenticated', 'public.ai_feedback', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.ai_feedback', 'DELETE')
     OR has_table_privilege('authenticated', 'public.ai_feedback', 'TRUNCATE') THEN
    RAISE EXCEPTION 'ia-copilot-v2: ai_feedback con privilegios de más para anon/authenticated.';
  END IF;

  v_oid := to_regprocedure('public.rpc_set_ai_feedback(text,uuid,text)');
  IF v_oid IS NULL OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'ia-copilot-v2: ACL de rpc_set_ai_feedback incorrecta.';
  END IF;
  v_oid := to_regprocedure('public.rpc_reserve_ai_usage(text)');
  IF v_oid IS NULL OR has_function_privilege('anon', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'ia-copilot-v2: ACL de rpc_reserve_ai_usage incorrecta.';
  END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'rpc_reserve_ai_usage' AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'ia-copilot-v2: rpc_reserve_ai_usage quedó con más de una definición.';
  END IF;
  IF position('queries' IN pg_get_functiondef(v_oid)) = 0
     OR position('ai_ocr_window_count' IN pg_get_functiondef(v_oid)) = 0 THEN
    RAISE EXCEPTION 'ia-copilot-v2: rpc_reserve_ai_usage no tiene las dos ramas.';
  END IF;
  IF (SELECT count(*) FROM cron.job WHERE jobname = 'reset-ai-counters' AND command LIKE '%ai_queries_window_count = 0%'
         AND command LIKE '%ai_ocr_window_count = 0%') <> 1 THEN
    RAISE EXCEPTION 'ia-copilot-v2: el cron reset-ai-counters no quedó con las columnas nuevas.';
  END IF;
END $$;
