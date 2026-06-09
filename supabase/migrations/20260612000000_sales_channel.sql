-- =============================================================================
-- MIGRATION: 20260612000000_sales_channel.sql
-- Fase B del change dashboard-kpi-summary-block — canal de venta.
-- GOVERNANCE HIGH: toca el modelo de datos financiero (sales).
-- Aprobación humana explícita: 2026-06-09 ("aprobado Fase B").
--
-- 1. Columna sales.canal (nullable, sin backfill: las ventas previas se
--    agrupan como "Sin canal") + índice (account_id, canal).
-- 2. rpc_create_sale_operation: nuevo parámetro p_canal text DEFAULT NULL,
--    sellado en cada INSERT (canal por operación, no por ítem). Se dropea la
--    firma de 6 args para evitar ambigüedad de overloads; el DEFAULT mantiene
--    compatibilidad con los callers existentes (backend llama posicional con
--    5 args; PostgREST por nombre).
--    Body basado en la versión vigente (20260607000003, fix ON CONFLICT 3-col).
-- 3. rpc_dashboard_channel_margin: margen neto por canal del período + canal
--    líder + margen total actual y anterior (tone del badge). COGS =
--    products.cost * sales.quantity (decisión usuario: COGS). NULL → 'sin_canal'.
--
-- Rollback: DROP FUNCTION rpc_dashboard_channel_margin; recrear RPC de venta
-- sin p_canal; ALTER TABLE sales DROP COLUMN canal (nullable, sin pérdida).
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Columna + índice
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS canal text;

CREATE INDEX IF NOT EXISTS idx_sales_account_canal
  ON public.sales(account_id, canal);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. rpc_create_sale_operation + p_canal
-- ─────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid);

CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(
  p_idempotency_key text,
  p_client_id       uuid,
  p_date            date,
  p_currency        text,
  p_items           jsonb,
  p_branch_id       uuid DEFAULT NULL,
  p_canal           text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_new_op_id    uuid;
  v_existing_op  uuid;
  v_item         RECORD;
  v_product      RECORD;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_unit_factor  numeric(20,10);
  v_qty_norm     numeric(15,4);
  v_inserted     integer;
  v_canal        text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
      USING ERRCODE = 'P403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P400';
  END IF;

  -- Canal: normalizar vacío → NULL; cap defensivo de longitud.
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
  IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
    RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P400';
  END IF;

  -- Verify branch_id belongs to this account (if provided)
  IF p_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
    ) THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P404';
    END IF;
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;  -- 3-col constraint (fixed)

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'sale'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.sales s
    WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, stock, user_id, is_variant, name INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id <> v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      IF v_product.stock < v_qty_norm THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
      END IF;

      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal)
      RETURNING id INTO v_new_sale_id;

      UPDATE public.products
      SET    stock = stock - v_qty_norm
      WHERE  id = v_item.product_id
      RETURNING stock + v_qty_norm, stock
      INTO   v_qty_before, v_qty_after;

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, p_branch_id
      );

    ELSE
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_sale_operation(text, uuid, date, text, jsonb, uuid, text) TO authenticated;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. rpc_dashboard_channel_margin — margen neto por canal del período
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.rpc_dashboard_channel_margin(
  p_from       timestamptz,
  p_to         timestamptz,
  p_prev_from  timestamptz,
  p_prev_to    timestamptz,
  p_branch_id  uuid DEFAULT NULL
)
RETURNS TABLE (
  -- [{canal, revenue, margin_pct}] ordenado por margin_pct desc (solo período actual)
  channels        jsonb,
  -- canal con mejor margen del período (NULL si no hay ventas)
  leader          text,
  -- margen total del período y del anterior (para el tone del badge, up_good)
  margin_pct      numeric,
  prev_margin_pct numeric
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_account_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  RETURN QUERY
  WITH per_channel AS (
    SELECT
      COALESCE(NULLIF(trim(s.canal), ''), 'sin_canal')              AS canal,
      SUM(COALESCE(s.total, s.amount))                               AS revenue,
      SUM(COALESCE(pr.cost, 0) * s.quantity)                         AS cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
    GROUP BY 1
  ),
  channel_rows AS (
    SELECT
      pc.canal,
      pc.revenue,
      ROUND((pc.revenue - pc.cogs) / NULLIF(pc.revenue, 0) * 100, 1) AS margin_pct
    FROM per_channel pc
    WHERE pc.revenue > 0
  ),
  totals_curr AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(pr.cost, 0) * s.quantity))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_from AND p_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  totals_prev AS (
    SELECT
      ROUND(
        (SUM(COALESCE(s.total, s.amount)) - SUM(COALESCE(pr.cost, 0) * s.quantity))
        / NULLIF(SUM(COALESCE(s.total, s.amount)), 0) * 100, 1
      ) AS pct
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN p_prev_from AND p_prev_to
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  )
  SELECT
    COALESCE(
      (SELECT jsonb_agg(
                jsonb_build_object('canal', cr.canal, 'revenue', cr.revenue, 'margin_pct', cr.margin_pct)
                ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
              )
       FROM channel_rows cr),
      '[]'::jsonb
    )                                                                AS channels,
    (SELECT cr.canal FROM channel_rows cr
     ORDER BY cr.margin_pct DESC NULLS LAST, cr.revenue DESC
     LIMIT 1)                                                        AS leader,
    tc.pct                                                           AS margin_pct,
    tp.pct                                                           AS prev_margin_pct
  FROM totals_curr tc
  CROSS JOIN totals_prev tp;
END;
$$;

REVOKE ALL     ON FUNCTION public.rpc_dashboard_channel_margin(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_dashboard_channel_margin(timestamptz, timestamptz, timestamptz, timestamptz, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_dashboard_channel_margin(timestamptz, timestamptz, timestamptz, timestamptz, uuid) TO authenticated;
