-- Función para obtener la Tasa de Activación basada en Cohortes (Admin KPI)
-- Elimina la lógica calculada en el cliente y garantiza consistencia.

CREATE OR REPLACE FUNCTION get_admin_activation_rate(
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

  -- Cálculo 100% en SQL usando lógica de Cohorte
  WITH cohort_users AS (
    -- Denominador: Usuarios que se registraron exclusivamente en el período seleccionado
    SELECT id 
    FROM public.profiles 
    WHERE created_at >= p_date_from 
      AND created_at <= p_date_to
  ),
  activated_cohort_users AS (
    -- Numerador: Intersección (INNER JOIN) entre el cohort y quienes lograron activarse
    SELECT COUNT(DISTINCT ae.user_id) AS activated_count
    FROM public.analytics_events ae
    INNER JOIN cohort_users cu ON ae.user_id = cu.id
    WHERE ae.event_name = 'first_operation'
  )
  -- Cálculo seguro previniendo división por cero (NULLIF) e insertando cero por defecto (COALESCE)
  SELECT 
    COALESCE(
      ROUND(
        (acu.activated_count::numeric / NULLIF((SELECT COUNT(*) FROM cohort_users), 0)::numeric) * 100, 
        2
      ), 
      0::numeric
    ) INTO v_rate
  FROM activated_cohort_users acu;

  RETURN v_rate;
END;
$$;
