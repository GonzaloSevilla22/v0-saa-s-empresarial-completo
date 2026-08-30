-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = e452c30331368d3bdbc0c24bc305dda2 - length = 3370.
-- Rol en el change: SE REESCRIBE (D14): suma total_spent -> cambia el RETURNS TABLE -> DROP + CREATE + re-emision de ACLs.
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

CREATE OR REPLACE FUNCTION public.rpc_payment_method_report(p_account_id uuid, p_start date, p_end date)
 RETURNS TABLE(payment_method_id uuid, payment_method_name text, payment_method_kind text, is_active boolean, total_sold numeric, total_purchased numeric, operation_count bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  -- Verify caller belongs to this account (espejo de rpc_cost_center_report).
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH
    pm_sales AS (
      SELECT
        s.payment_method_id                                       AS pm_id,
        -- RN-D: importe de línea COALESCE(total, amount).
        COALESCE(SUM(COALESCE(s.total, s.amount)), 0)             AS sold_total,
        -- RN-D: conteo de operaciones COUNT(DISTINCT COALESCE(operation_id, id)).
        COUNT(DISTINCT COALESCE(s.operation_id, s.id))::BIGINT    AS sold_ops
      FROM public.sales s
      WHERE s.account_id = p_account_id
        -- RN-D5: borde superior inclusivo hasta fin de día local.
        AND s.date >= p_start::timestamptz
        AND s.date <  (p_end + 1)::timestamptz
      GROUP BY s.payment_method_id
    ),
    pm_purchases AS (
      SELECT
        p.payment_method_id                                       AS pm_id,
        COALESCE(SUM(COALESCE(p.total, p.amount)), 0)             AS purchased_total,
        COUNT(DISTINCT COALESCE(p.operation_id, p.id))::BIGINT    AS purchased_ops
      FROM public.purchases p
      WHERE p.account_id = p_account_id
        AND p.date >= p_start::timestamptz
        AND p.date <  (p_end + 1)::timestamptz
      GROUP BY p.payment_method_id
    ),
    all_pm_ids AS (
      -- UNION (no UNION ALL) dedupe incluyendo la clave NULL: lo no imputado
      -- colapsa en una sola fila "Sin especificar".
      SELECT pm_id FROM pm_sales
      UNION
      SELECT pm_id FROM pm_purchases
    )
  SELECT
    api.pm_id                                                            AS payment_method_id,
    COALESCE(pm.name, 'Sin especificar')                                 AS payment_method_name,
    pm.kind                                                              AS payment_method_kind,
    -- Las formas de pago desactivadas siguen apareciendo con su nombre
    -- histórico; la bandera deja que la UI las distinga sin consulta extra.
    COALESCE(pm.is_active, true)                                         AS is_active,
    COALESCE(ps.sold_total, 0)                                           AS total_sold,
    COALESCE(pp.purchased_total, 0)                                      AS total_purchased,
    (COALESCE(ps.sold_ops, 0) + COALESCE(pp.purchased_ops, 0))::BIGINT   AS operation_count
  FROM all_pm_ids api
  LEFT JOIN public.payment_methods pm ON pm.id     = api.pm_id
  LEFT JOIN pm_sales               ps ON ps.pm_id  IS NOT DISTINCT FROM api.pm_id
  LEFT JOIN pm_purchases           pp ON pp.pm_id  IS NOT DISTINCT FROM api.pm_id
  -- ORDER BY por expresión y no por el nombre de la columna OUT: evita la
  -- ambigüedad columna-vs-variable de plpgsql en RETURN QUERY.
  ORDER BY (COALESCE(ps.sold_total, 0) + COALESCE(pp.purchased_total, 0)) DESC;
END;
$function$
