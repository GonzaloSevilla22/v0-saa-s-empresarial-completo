-- Función para obtener la Tasa UMV (Admin KPI)
-- Mide el % de usuarios activados que lograron alcanzar el valor principal (Insight)
CREATE OR REPLACE FUNCTION get_admin_umv_rate(
  p_date_from timestamptz,
  p_date_to timestamptz
)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rate numeric;
BEGIN
  -- Regla 3.6: Validar fechas invertidas devolviendo 0%
  IF p_date_from > p_date_to THEN
    RETURN 0::numeric;
  END IF;

  -- Lógica de Cohorte UMV
  WITH activated_users AS (
    -- Denominador: Cohorte de usuarios que lograron activarse ('first_operation') en el período
    SELECT DISTINCT user_id 
    FROM public.analytics_events
    WHERE event_name = 'first_operation'
      AND created_at >= p_date_from 
      AND created_at <= p_date_to
  ),
  umv_users AS (
    -- Numerador: Intersección de la cohorte activada que además alcanzó el UMV ('insight_generated')
    -- Nota para el futuro: Aquí se podría agregar "AND event_data->>'type' = 'X'" para desgloses
    SELECT DISTINCT ae.user_id
    FROM public.analytics_events ae
    INNER JOIN activated_users au ON ae.user_id = au.user_id
    WHERE ae.event_name = 'insight_generated'
      AND ae.created_at >= p_date_from 
      AND ae.created_at <= p_date_to
  )
  -- Cálculo 100% en SQL con protección contra división por cero
  SELECT 
    COALESCE(
      ROUND(
        ( (SELECT COUNT(*) FROM umv_users)::numeric / NULLIF((SELECT COUNT(*) FROM activated_users), 0)::numeric ) * 100, 
        2
      ), 
      0::numeric
    ) INTO v_rate;

  RETURN v_rate;
END;
$$;
