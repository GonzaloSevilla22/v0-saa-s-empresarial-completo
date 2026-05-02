-- Función para obtener la cantidad de productos en estado crítico de stock (Multi-tenant)
-- Reemplaza la lógica previa que dependía incorrectamente de events o lógica de cliente.

CREATE OR REPLACE FUNCTION get_dashboard_critical_stock(
  p_user_id uuid
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_count bigint;
BEGIN
  -- Regla 3.6 y Seguridad: Única fuente de verdad en tabla operativa y aislamiento por tenant
  -- NOTA: Se ignora analytics_events. Se usa el estado real sincrónico.
  SELECT COUNT(id) INTO v_count
  FROM public.products
  WHERE user_id = p_user_id
    AND stock <= min_stock;
    
  RETURN v_count;
END;
$$;
