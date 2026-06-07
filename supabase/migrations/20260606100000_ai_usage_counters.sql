-- C-04: Atomic AI usage increment RPC + monthly reset cron job

-- ─── RPC: rpc_increment_ai_usage ──────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_increment_ai_usage(
  p_user_id UUID,
  p_counter  TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  -- Guard: only a user can increment their own counter
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  IF p_counter = 'queries' THEN
    UPDATE public.profiles
    SET ai_queries_used = ai_queries_used + 1
    WHERE id = p_user_id;
  ELSIF p_counter = 'advice' THEN
    UPDATE public.profiles
    SET ai_advice_used = ai_advice_used + 1
    WHERE id = p_user_id;
  ELSE
    RAISE EXCEPTION 'invalid counter: %', p_counter;
  END IF;
END;
$$;

-- Restrict to authenticated users only
REVOKE ALL ON FUNCTION public.rpc_increment_ai_usage(UUID, TEXT) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_increment_ai_usage(UUID, TEXT) TO authenticated;

-- ─── CRON: monthly reset of AI usage counters ─────────────────────────────────
-- Runs 00:00 UTC on the 1st of each month; resets all profiles atomically.

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
  $$UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, usage_reset_at = now()$$
);
