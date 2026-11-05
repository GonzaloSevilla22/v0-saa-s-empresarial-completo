-- v31-ia-ratelimit-budget (H-11) — cuota mensual, ráfaga y reserva atómica del OCR de facturas.
--
-- `invoice-ocr` llamaba a OpenAI sin consultar ninguna cuota ni limitar la
-- frecuencia: un usuario autenticado podía disparar lecturas sin tope (costo y
-- DoS). Esta migración agrega:
--
--   1. Un contador y un límite PROPIOS del OCR (D1): una lectura de factura
--      cuesta un orden de magnitud más que una consulta de texto, así que no
--      consume `ai_queries_used`.
--        profiles.ai_ocr_used                 integer NOT NULL DEFAULT 0
--        profiles.ai_ocr_window_count         integer NOT NULL DEFAULT 0
--        profiles.ai_ocr_window_started_at    timestamptz NULL
--        plan_limits.max_ai_ocr_per_month     integer NOT NULL  (5/30/120/300, OQ-1)
--      Las tres columnas de profiles nacen SIN privilegio de escritura para
--      anon/authenticated (profiles tiene allow-list de columnas, ver
--      20261053000001): sólo las escribe la RPC SECURITY DEFINER y el cron.
--
--   2. rpc_reserve_ai_usage(p_counter text) RETURNS jsonb (D2/D3): reserva
--      ATÓMICA antes de llamar a OpenAI. Un solo UPDATE condicional incrementa
--      el contador mensual y avanza la ventana de ráfaga (3 lecturas / 60 s,
--      ventana fija) sólo si hay cupo y ráfaga disponible; dos transacciones
--      concurrentes se serializan por el lock de fila y la segunda re-evalúa el
--      WHERE sobre la versión ya incrementada (READ COMMITTED). NO hay SELECT
--      ... FOR UPDATE + UPDATE en dos pasos. Fail-closed: sin auth.uid() lanza
--      P0401; sin límite para el plan lanza P0503. El plan sale de
--      public.rpc_my_effective_plan() (cuenta activa), nunca de profiles.
--
--   3. El cron `reset-ai-counters` (mismo nombre, mismo schedule) resetea
--      también las tres columnas nuevas (D7).
--
-- Idempotente: ADD COLUMN IF NOT EXISTS, el seed sólo toca filas sin valor (no
-- pisa un ajuste posterior del PO en plan_limits), CREATE OR REPLACE con la
-- misma firma (la RPC es nueva; REVOKE/GRANT en este archivo), unschedule +
-- schedule del cron. Gate: supabase/tests/test_ia_ocr_cuota_reserva.sql.

-- ─── 1. Columnas ──────────────────────────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS ai_ocr_used integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_ocr_window_count integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS ai_ocr_window_started_at timestamptz;

ALTER TABLE public.plan_limits
  ADD COLUMN IF NOT EXISTS max_ai_ocr_per_month integer;

-- Seed por plan (OQ-1). Sólo filas sin valor: una reaplicación no pisa un
-- ajuste manual posterior del límite.
UPDATE public.plan_limits
   SET max_ai_ocr_per_month = CASE plan
         WHEN 'gratis'   THEN 5
         WHEN 'inicial'  THEN 30
         WHEN 'avanzado' THEN 120
         WHEN 'pro'      THEN 300
       END
 WHERE max_ai_ocr_per_month IS NULL
   AND plan IN ('gratis', 'inicial', 'avanzado', 'pro');

ALTER TABLE public.plan_limits
  ALTER COLUMN max_ai_ocr_per_month SET NOT NULL;

COMMENT ON COLUMN public.profiles.ai_ocr_used IS
  'Lecturas de factura (OCR) reservadas en el mes en curso. Sólo la escribe rpc_reserve_ai_usage y el cron reset-ai-counters.';
COMMENT ON COLUMN public.profiles.ai_ocr_window_count IS
  'Lecturas de factura reservadas dentro de la ventana de ráfaga vigente (máx. 3 por 60 s).';
COMMENT ON COLUMN public.profiles.ai_ocr_window_started_at IS
  'Inicio de la ventana fija de ráfaga del OCR; NULL = sin ventana abierta.';
COMMENT ON COLUMN public.plan_limits.max_ai_ocr_per_month IS
  'Lecturas de factura (OCR) por usuario y por mes: gratis 5, inicial 30, avanzado 120, pro 300.';

-- ─── 2. RPC de reserva atómica ────────────────────────────────────────────────

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

  -- Hoy hay una sola rama; el parámetro es el punto de extensión para
  -- queries/advice (Non-Goal: migrarlos ahora).
  IF p_counter IS DISTINCT FROM 'ocr' THEN
    RAISE EXCEPTION 'invalid counter: %', p_counter USING ERRCODE = '22023';
  END IF;

  -- El plan lo resuelve la fuente normativa (cuenta activa), no profiles.
  v_plan := public.rpc_my_effective_plan();

  SELECT pl.max_ai_ocr_per_month INTO v_limit
    FROM public.plan_limits pl
   WHERE pl.plan = v_plan;

  IF v_limit IS NULL THEN
    -- Fail-closed: sin límite no se concede nada.
    RAISE EXCEPTION 'plan limits unavailable for plan %', v_plan USING ERRCODE = 'P0503';
  END IF;

  -- Próxima renovación: el cron corre 00:00 UTC del día 1.
  v_reset_at := (date_trunc('month', now() AT TIME ZONE 'UTC') + interval '1 month') AT TIME ZONE 'UTC';

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
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_reserve_ai_usage(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_reserve_ai_usage(text) TO authenticated;

COMMENT ON FUNCTION public.rpc_reserve_ai_usage(text) IS
  'Reserva atómica de una lectura de factura (OCR) para el usuario autenticado: un solo UPDATE condicional incrementa el contador mensual y la ventana de ráfaga (3 por 60 s). Devuelve {allowed, used, limit, reset_at} o {allowed:false, reason: quota_exceeded|rate_limited, ...}. Fail-closed (P0401 sin sesión, 22023 contador inválido, P0503 sin límite). La reserva concedida no se devuelve. v31-ia-ratelimit-budget.';

-- ─── 3. Cron: el reset mensual también limpia el OCR ──────────────────────────
-- Mismo nombre y schedule que 20260606100000_ai_usage_counters.sql.

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
  $$UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, ai_ocr_used = 0, ai_ocr_window_count = 0, ai_ocr_window_started_at = NULL, usage_reset_at = now()$$
);
