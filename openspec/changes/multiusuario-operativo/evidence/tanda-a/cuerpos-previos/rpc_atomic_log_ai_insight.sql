CREATE OR REPLACE FUNCTION public.rpc_atomic_log_ai_insight(p_type text, p_content text, p_source_function text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_profile        RECORD;
  v_insight_id     uuid;
  v_account_id     uuid;
  v_insight_record jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Lock del perfil para evitar carreras en el contador
  SELECT id, plan, insights_used INTO v_profile
  FROM profiles WHERE id = v_uid FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = 'no_data_found';
  END IF;

  -- Límite de plan free
  IF v_profile.plan = 'free' AND v_profile.insights_used >= 5 THEN
    RAISE EXCEPTION 'AI Insights limit reached for free plan' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Cuenta del usuario (primera membership; NULL tolerado, lo cubre el trigger)
  SELECT account_id INTO v_account_id
  FROM account_members WHERE user_id = v_uid ORDER BY account_id LIMIT 1;

  -- Insert en la tabla canónica unificada
  INSERT INTO insights (user_id, account_id, type, message, priority)
  VALUES (v_uid, v_account_id, p_type, p_content, 'media')
  RETURNING id INTO v_insight_id;

  -- Contador de uso
  UPDATE profiles SET insights_used = insights_used + 1 WHERE id = v_uid;

  -- Telemetría
  INSERT INTO analytics_events (user_id, event_name, event_data)
  VALUES (v_uid, 'insight_generated',
    jsonb_build_object('type', p_type, 'source_function', p_source_function, 'insight_id', v_insight_id));

  -- Detección de UMV (primer insight + primera operación)
  IF EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'operation_created')
  AND NOT EXISTS (SELECT 1 FROM analytics_events WHERE user_id = v_uid AND event_name = 'umv_reached')
  THEN
    INSERT INTO analytics_events (user_id, event_name, event_data)
    VALUES (v_uid, 'umv_reached',
      jsonb_build_object('type', 'insight_generated', 'insight_id', v_insight_id));
  END IF;

  SELECT to_jsonb(i) INTO v_insight_record FROM insights i WHERE id = v_insight_id;
  RETURN v_insight_record;
END;
$function$

-- ACL: {postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- COMMENT: (none)
