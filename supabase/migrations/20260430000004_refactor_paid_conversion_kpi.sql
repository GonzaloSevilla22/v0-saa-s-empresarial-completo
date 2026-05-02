-- Función para obtener la Tasa de Conversión a Pago (Admin KPI Snapshot)
-- Mide el porcentaje actual del total de cuentas que están en plan 'pro'

CREATE OR REPLACE FUNCTION get_admin_paid_conversion_rate()
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rate numeric;
BEGIN
  -- Cálculo 100% en SQL usando un solo escaneo a la tabla profiles
  -- Numerador: conteo condicional (FILTER WHERE plan = 'pro')
  -- Denominador: conteo total absoluto
  SELECT 
    COALESCE(
      ROUND(
        ( COUNT(*) FILTER (WHERE plan = 'pro')::numeric / NULLIF(COUNT(*), 0)::numeric ) * 100, 
        2
      ), 
      0::numeric
    ) INTO v_rate
  FROM public.profiles;

  RETURN v_rate;
END;
$$;
