-- 4. Atomic RPC for AI Insights Usage Tracking
CREATE OR REPLACE FUNCTION public.rpc_atomic_log_ai_insight(
  p_user_id uuid,
  p_type text,
  p_content text,
  p_source_function text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_profile RECORD;
  v_insight_id uuid;
  v_insight_record jsonb;
BEGIN
  -- Lock profile to avoid racing usage limits
  SELECT id, plan, insights_used, insights_reset_at INTO v_profile
  FROM profiles
  WHERE id = p_user_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found (404)' USING ERRCODE = 'no_data_found';
  END IF;

  -- Check limits dynamically natively
  IF v_profile.plan = 'free' AND v_profile.insights_used >= 5 THEN
    RAISE EXCEPTION 'AI Insights limit reached for free plan (403)' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- 1) Insert Insight (Server-Side timestamp)
  INSERT INTO insights (user_id, type, content, actionable)
  VALUES (p_user_id, p_type, p_content, 'actionable_extracted_from_content')
  RETURNING id INTO v_insight_id;

  -- 2) Increment Usage Safe
  UPDATE profiles
  SET insights_used = insights_used + 1
  WHERE id = p_user_id;

  -- 3) Telemetry (UMV logic tracking)
  INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
  VALUES (p_user_id, 'insight_generated', jsonb_build_object('type', p_type, 'source_function', p_source_function, 'insight_id', v_insight_id), DEFAULT);

  -- 4) Check if UMV Reached contextually
  -- A user reaches UMV when they have both an 'insight_generated' and 'operation_created'
  IF EXISTS (
    SELECT 1 FROM analytics_events 
    WHERE user_id = p_user_id AND event_name = 'operation_created'
  ) AND NOT EXISTS (
    SELECT 1 FROM analytics_events 
    WHERE user_id = p_user_id AND event_name = 'umv_reached'
  ) THEN
    INSERT INTO analytics_events (user_id, event_name, event_data, created_at)
    VALUES (p_user_id, 'umv_reached', jsonb_build_object('type', 'insight_generated', 'insight_id', v_insight_id), DEFAULT);
  END IF;

  SELECT to_jsonb(i) INTO v_insight_record FROM insights i WHERE id = v_insight_id;
  RETURN v_insight_record;
END;
$$;
