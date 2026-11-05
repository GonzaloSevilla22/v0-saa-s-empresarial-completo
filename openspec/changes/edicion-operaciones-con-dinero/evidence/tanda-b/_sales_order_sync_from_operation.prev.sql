CREATE OR REPLACE FUNCTION public._sales_order_sync_from_operation(p_sales_order_id uuid, p_operation_id uuid, p_account_id uuid)
 RETURNS numeric
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_order  RECORD;
  v_fd_ok  boolean;
  v_hdr    RECORD;
BEGIN
  IF p_sales_order_id IS NULL OR p_operation_id IS NULL OR p_account_id IS NULL THEN
    RAISE EXCEPTION 'sales_order_sync_invalid_args: la orden, la operación y la cuenta son obligatorias'
      USING ERRCODE = 'P0400';
  END IF;

  SELECT so.id, so.account_id, so.fiscal_document_id
  INTO   v_order
  FROM   public.sales_orders so
  WHERE  so.id = p_sales_order_id
  FOR UPDATE;

  IF NOT FOUND OR v_order.account_id IS DISTINCT FROM p_account_id THEN
    RAISE EXCEPTION 'sales_order_not_found: la orden de venta % no pertenece a la cuenta', p_sales_order_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_order.fiscal_document_id IS NOT NULL THEN
    SELECT (fd.status IN ('rejected', 'voided'))
    INTO   v_fd_ok
    FROM   public.fiscal_documents fd
    WHERE  fd.id = v_order.fiscal_document_id;

    IF v_fd_ok IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'sales_order_has_live_invoice: la orden % tiene un comprobante vigente — no se recalcula', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;
  END IF;

  SELECT count(*)                                                     AS n_rows,
         bool_and(s.account_id IS NOT DISTINCT FROM p_account_id)     AS all_mine,
         count(DISTINCT s.client_id)                                  AS n_clients,
         count(*) FILTER (WHERE s.client_id IS NULL)                  AS n_client_null,
         count(DISTINCT s.branch_id)                                  AS n_branches,
         count(*) FILTER (WHERE s.branch_id IS NULL)                  AS n_branch_null,
         (array_agg(s.client_id ORDER BY s.id))[1]                    AS client_id,
         (array_agg(s.branch_id ORDER BY s.id))[1]                    AS branch_id,
         round(COALESCE(sum(COALESCE(s.total, s.amount * s.quantity)), 0), 2) AS total
  INTO   v_hdr
  FROM   public.sales s
  WHERE  s.operation_id = p_operation_id;

  IF v_hdr.n_rows = 0 THEN
    RAISE EXCEPTION 'operation_empty: la operación % no tiene líneas — no hay nada que facturar', p_operation_id
      USING ERRCODE = 'P0400';
  END IF;

  IF v_hdr.all_mine IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
      USING ERRCODE = 'P0404';
  END IF;

  IF v_hdr.n_clients > 1 OR (v_hdr.n_clients = 1 AND v_hdr.n_client_null > 0) THEN
    RAISE EXCEPTION 'operation_inconsistent: las líneas de la operación % tienen distinto cliente — editá la venta para unificarlo antes de facturar', p_operation_id
      USING ERRCODE = 'P0422';
  END IF;

  IF v_hdr.n_branches > 1 OR (v_hdr.n_branches = 1 AND v_hdr.n_branch_null > 0) THEN
    RAISE EXCEPTION 'operation_inconsistent: las líneas de la operación % tienen distinta sucursal — editá la venta para unificarla antes de facturar', p_operation_id
      USING ERRCODE = 'P0422';
  END IF;

  UPDATE public.sales_orders so
  SET    total     = v_hdr.total,
         client_id = v_hdr.client_id,
         branch_id = COALESCE(v_hdr.branch_id, so.branch_id)
  WHERE  so.id = p_sales_order_id;

  DELETE FROM public.sales_order_items WHERE sales_order_id = p_sales_order_id;

  INSERT INTO public.sales_order_items
    (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled)
  SELECT p_sales_order_id,
         p_account_id,
         COALESCE(si.product_id, s.product_id),
         COALESCE(si.unit_id, s.unit_id),
         s.quantity,
         s.amount,
         -- D2: Σ subtotales = total SIEMPRE. Cada línea a 2 decimales; el
         -- residuo del redondeo (±, sólo con filas de más de 2 decimales) va a
         -- la última fila por id.
         s.line_total + CASE WHEN s.rn_desc = 1 THEN v_hdr.total - s.lines_sum ELSE 0 END,
         si.name_snapshot,
         si.sku_snapshot,
         si.unit_cost_snapshot,
         si.iva_rate_snapshot,
         COALESCE(si.snapshot_backfilled, false)
  FROM (
    SELECT x.*,
           round(COALESCE(x.total, x.amount * x.quantity), 2)               AS line_total,
           sum(round(COALESCE(x.total, x.amount * x.quantity), 2)) OVER ()  AS lines_sum,
           row_number() OVER (ORDER BY x.id DESC)                           AS rn_desc
    FROM   public.sales x
    WHERE  x.operation_id = p_operation_id
  ) s
  LEFT JOIN LATERAL (
    SELECT x.product_id, x.unit_id, x.name_snapshot, x.sku_snapshot,
           x.unit_cost_snapshot, x.iva_rate_snapshot, x.snapshot_backfilled
    FROM   public.sale_items x
    WHERE  x.sale_id = s.id
    -- H2: en prod la fila duplicada trae un sale_item del producto (con
    -- snapshots) y OTRO sin producto ni snapshots. Se prefiere el que coincide
    -- con el producto de la fila; el id sólo desempata.
    ORDER  BY (x.product_id IS NOT DISTINCT FROM s.product_id) DESC,
              (x.product_id IS NULL),
              x.id
    LIMIT  1
  ) si ON true
  ORDER  BY s.id;

  RETURN v_hdr.total;
END;
$function$

