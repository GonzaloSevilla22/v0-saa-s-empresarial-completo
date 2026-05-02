-- Función para obtener el volumen de Interacciones Comunitarias (Admin KPI)
-- Mide el total de posts + replies reales en el período, reemplazando la dependencia de analytics_events

CREATE OR REPLACE FUNCTION get_admin_community_interactions(
  p_date_from timestamptz,
  p_date_to timestamptz
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_total bigint;
BEGIN
  -- Regla 3.6: Validar fechas invertidas devolviendo 0
  IF p_date_from > p_date_to THEN
    RETURN 0::bigint;
  END IF;

  -- Regla 3.6: Única Fuente de Verdad. Leer de tablas transaccionales, no eventos.
  WITH posts_count AS (
    SELECT COUNT(*) as total
    FROM public.posts
    WHERE created_at >= p_date_from 
      AND created_at <= p_date_to
  ),
  replies_count AS (
    SELECT COUNT(*) as total
    FROM public.replies
    WHERE created_at >= p_date_from 
      AND created_at <= p_date_to
  )
  -- Sumatoria segura
  SELECT 
    COALESCE((SELECT total FROM posts_count), 0) + 
    COALESCE((SELECT total FROM replies_count), 0) 
  INTO v_total;

  RETURN v_total;
END;
$$;
