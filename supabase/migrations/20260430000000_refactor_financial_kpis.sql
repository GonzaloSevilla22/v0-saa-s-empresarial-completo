-- Función unificada para KPIs financieros del Dashboard (Multi-tenant)
-- Reemplaza RPCs individuales que usaban COUNT y no recibían fechas dinámicas.
-- Usa la columna 'date' como fecha operativa.

CREATE OR REPLACE FUNCTION get_dashboard_financials(
  p_user_id uuid,
  p_date_from timestamptz,
  p_date_to timestamptz
)
RETURNS TABLE (
  total_income numeric,
  total_expenses numeric,
  total_purchases numeric,
  net_profit numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  -- Regla 3.6: Si date_from > date_to, manejar de forma controlada evitando errores
  IF p_date_from > p_date_to THEN
    RETURN QUERY SELECT 0::numeric, 0::numeric, 0::numeric, 0::numeric;
    RETURN;
  END IF;

  -- Regla 3.6 y Seguridad: Única fuente de verdad, SUM, COALESCE y aislamiento por tenant
  -- Se utiliza la columna 'date' (tipo timestamptz) como fecha operativa
  RETURN QUERY
  WITH ingresos AS (
    SELECT COALESCE(SUM(amount), 0) as total 
    FROM public.sales 
    WHERE user_id = p_user_id
      AND date >= p_date_from 
      AND date <= p_date_to
  ),
  gastos AS (
    SELECT COALESCE(SUM(amount), 0) as total 
    FROM public.expenses 
    WHERE user_id = p_user_id
      AND date >= p_date_from 
      AND date <= p_date_to
  ),
  compras AS (
    SELECT COALESCE(SUM(amount), 0) as total 
    FROM public.purchases 
    WHERE user_id = p_user_id
      AND date >= p_date_from 
      AND date <= p_date_to
  )
  SELECT 
    i.total AS total_income,
    g.total AS total_expenses,
    c.total AS total_purchases,
    (i.total - (g.total + c.total)) AS net_profit
  FROM ingresos i
  CROSS JOIN gastos g
  CROSS JOIN compras c;
END;
$$;
