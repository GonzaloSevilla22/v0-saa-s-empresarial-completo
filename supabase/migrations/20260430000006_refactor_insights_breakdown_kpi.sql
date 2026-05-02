-- Función para obtener la generación de Insights IA agrupados por tipo (Admin KPI)
-- Elimina el hardcodeo de fechas previo y permite análisis dinámico

CREATE OR REPLACE FUNCTION get_admin_insights_breakdown(
  p_date_from timestamptz,
  p_date_to timestamptz
)
RETURNS TABLE (
  insight_type text,
  total bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Regla 3.6: Validar fechas invertidas devolviendo estructura vacía
  -- Un RETURN sin query en una función RETURNS TABLE devuelve 0 filas (array vacío)
  IF p_date_from > p_date_to THEN
    RETURN;
  END IF;

  -- Consulta agrupada directamente extraída del JSONB con normalización
  RETURN QUERY
  SELECT 
    LOWER(COALESCE(event_data->>'type', 'uncategorized')) AS insight_type,
    COUNT(*) AS total
  FROM public.analytics_events
  WHERE event_name = 'insight_generated'
    AND created_at >= p_date_from 
    AND created_at <= p_date_to
  GROUP BY LOWER(COALESCE(event_data->>'type', 'uncategorized'))
  ORDER BY total DESC;
END;
$$;
