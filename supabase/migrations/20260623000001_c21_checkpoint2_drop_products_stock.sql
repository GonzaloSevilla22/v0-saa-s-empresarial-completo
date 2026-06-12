-- =============================================================================
-- MIGRATION: 20260623000001_c21_checkpoint2_drop_products_stock.sql
-- CHANGE:    C-21 v20-inventory-unification — CHECKPOINT PO #2 (DESTRUCTIVO)
--
-- Ejecuta el plan documentado en 20260620000004_c21_products_stock_drop_guard.sql
-- (aprobado por el PO 2026-06-12): branch_stock pasa a ser el ÚNICO ledger.
--
-- CONTENIDO (orden de aplicación):
--   0. Gate: divergencia products.stock vs Σ branch_stock debe ser 0 (aborta).
--   1. DROP trigger on_product_stock_update + check_low_stock (usa NEW.stock —
--      rompería todo INSERT/UPDATE de products tras el DROP; el reemplazo
--      per-branch check_branch_low_stock existe desde C-08).
--   2. get_dashboard_critical_stock (2 overloads) → v_products_with_stock.
--   3. rpc_dashboard_kpi_summary → v_products_with_stock (CTEs stagnant).
--   4. NUEVO rpc_apply_product_stock_delta: punto de entrada del backend Python
--      para stock inicial (create), edición de stock (update) y reversa de
--      compras borradas. Valida cuenta, reusa c21_apply_branch_stock_delta.
--   5. Los 7 RPCs operativos → SINGLE-WRITE branch_stock (se quita la pata
--      products.stock del hotfix 20260622000001; el gate de venta pasa a
--      Σ branch_stock — equivalente exacto del gate global actual).
--   6. rpc_bulk_upsert_products → single-write + cuenta vía current_account_ids()
--      con guard (residuo task_29345f9d: miembros no-dueños generaban NULL).
--   7. ALTER TABLE products DROP COLUMN stock.
--
-- DECISIONES (surfaced al PO):
--   - El chequeo de stock de ventas sigue siendo GLOBAL (Σ branch_stock), no
--     per-branch: paridad exacta con el comportamiento vigente. Pasar a gate
--     per-branch es decisión de producto para un change futuro.
--   - La alerta global de stock bajo (check_low_stock, umbral fijo 5) se retira;
--     queda la per-branch (check_branch_low_stock, umbral branch_stock.min_stock).
--   - FOR UPDATE sobre la fila de products se mantiene como mutex por producto
--     para serializar operaciones concurrentes.
--
-- GOVERNANCE: MEDIUM (stock) — checkpoint destructivo aprobado por el PO.
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
--
-- ROLLBACK (del DROP, según guard 9.4):
--   ALTER TABLE products ADD COLUMN IF NOT EXISTS stock numeric NOT NULL DEFAULT 0;
--   UPDATE products p SET stock = COALESCE(
--     (SELECT SUM(quantity) FROM branch_stock bs WHERE bs.product_id = p.id), 0);
--   y restaurar los RPCs desde 20260622000001 (dual-write).
-- =============================================================================


-- ============================================================
-- 0. GATE — divergencia debe ser 0 o la migración aborta
-- ============================================================
DO $$
DECLARE
  v_div integer;
BEGIN
  SELECT count(*) INTO v_div
  FROM public.products p
  WHERE p.deleted_at IS NULL
    AND COALESCE(p.stock, 0) <> COALESCE(
      (SELECT SUM(bs.quantity) FROM public.branch_stock bs WHERE bs.product_id = p.id), 0);

  IF v_div <> 0 THEN
    RAISE EXCEPTION 'C-21 checkpoint #2 ABORTADO: % productos con divergencia products.stock vs Σ branch_stock. Reconciliar antes del DROP.', v_div;
  END IF;
END $$;


-- ============================================================
-- 1. Retirar alerta global de stock bajo (usa NEW.stock)
-- ============================================================
DROP TRIGGER IF EXISTS on_product_stock_update ON public.products;
DROP FUNCTION IF EXISTS public.check_low_stock();


-- ============================================================
-- 2. get_dashboard_critical_stock → v_products_with_stock
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock()
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid   uuid := auth.uid();
  v_count bigint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- C-21 checkpoint #2: stock = Σ branch_stock (vía vista)
  SELECT COUNT(id) INTO v_count
  FROM public.v_products_with_stock
  WHERE user_id = v_uid
    AND stock <= min_stock;

  RETURN COALESCE(v_count, 0);
END;
$function$;

CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock(p_user_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_count bigint;
BEGIN
  -- Regla 3.6 y Seguridad: Única fuente de verdad en tabla operativa y aislamiento por tenant
  -- C-21 checkpoint #2: stock = Σ branch_stock (vía vista)
  SELECT COUNT(id) INTO v_count
  FROM public.v_products_with_stock
  WHERE user_id = p_user_id
    AND stock <= min_stock;

  RETURN v_count;
END;
$function$;


-- ============================================================
-- 3. rpc_dashboard_kpi_summary → v_products_with_stock
--    (solo cambian los CTEs stagnant_curr / stagnant_prev)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_dashboard_kpi_summary(p_from timestamp with time zone, p_to timestamp with time zone, p_prev_from timestamp with time zone, p_prev_to timestamp with time zone, p_branch_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(net_profit numeric, prev_net_profit numeric, avg_ticket numeric, prev_avg_ticket numeric, cost_per_sale numeric, prev_cost_per_sale numeric, stagnant_stock_value numeric, stagnant_stock_count integer, prev_stagnant_stock_value numeric, prev_stagnant_stock_count integer, sales_count integer, prev_sales_count integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

  IF p_from > p_to OR p_prev_from > p_prev_to THEN
    RAISE EXCEPTION 'Invalid date range' USING ERRCODE = 'P400';
  END IF;

  RETURN QUERY
  WITH sales_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS revenue,
      COALESCE(SUM(COALESCE(s.total, s.amount)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_revenue,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_from      AND p_to)     AS ops,
      COUNT(DISTINCT COALESCE(s.operation_id, s.id)) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to) AS prev_ops,
      COALESCE(SUM(COALESCE(pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_from      AND p_to),      0) AS cogs,
      COALESCE(SUM(COALESCE(pr.cost, 0) * s.quantity) FILTER (WHERE s.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_cogs
    FROM public.sales s
    LEFT JOIN public.products pr ON pr.id = s.product_id
    WHERE s.account_id = v_account_id
      AND s.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR s.branch_id = p_branch_id)
  ),
  expenses_agg AS (
    SELECT
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_from      AND p_to),      0) AS expenses,
      COALESCE(SUM(e.amount) FILTER (WHERE e.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_expenses
    FROM public.expenses e
    WHERE e.account_id = v_account_id
      AND e.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR e.branch_id = p_branch_id)
  ),
  purchases_agg AS (
    SELECT
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_from      AND p_to),      0) AS purchases,
      COALESCE(SUM(COALESCE(pu.total, pu.amount)) FILTER (WHERE pu.date BETWEEN p_prev_from AND p_prev_to), 0) AS prev_purchases
    FROM public.purchases pu
    WHERE pu.account_id = v_account_id
      AND pu.date BETWEEN LEAST(p_prev_from, p_from) AND GREATEST(p_prev_to, p_to)
      AND (p_branch_id IS NULL OR pu.branch_id = p_branch_id)
  ),
  -- Stock sin rotación: productos vendibles con stock, sin líneas de venta en la ventana.
  -- C-21 checkpoint #2: stock = Σ branch_stock (vía vista, products.stock no existe).
  stagnant_curr AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.v_products_with_stock p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_from AND p_to
      )
  ),
  stagnant_prev AS (
    SELECT
      COALESCE(SUM(p.stock * COALESCE(p.cost, 0)), 0) AS value,
      COUNT(*)::integer                               AS cnt
    FROM public.v_products_with_stock p
    WHERE p.account_id = v_account_id
      AND p.stock > 0
      AND COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')
      AND NOT EXISTS (
        SELECT 1 FROM public.sales sx
        WHERE sx.account_id = v_account_id
          AND sx.product_id = p.id
          AND sx.date BETWEEN p_prev_from AND p_prev_to
      )
  )
  SELECT
    sa.revenue      - (ea.expenses      + pa.purchases)       AS net_profit,
    sa.prev_revenue - (ea.prev_expenses + pa.prev_purchases)  AS prev_net_profit,
    ROUND(sa.revenue      / NULLIF(sa.ops, 0), 2)             AS avg_ticket,
    ROUND(sa.prev_revenue / NULLIF(sa.prev_ops, 0), 2)        AS prev_avg_ticket,
    ROUND(sa.cogs         / NULLIF(sa.ops, 0), 2)             AS cost_per_sale,
    ROUND(sa.prev_cogs    / NULLIF(sa.prev_ops, 0), 2)        AS prev_cost_per_sale,
    sc.value                                                  AS stagnant_stock_value,
    sc.cnt                                                    AS stagnant_stock_count,
    sp.value                                                  AS prev_stagnant_stock_value,
    sp.cnt                                                    AS prev_stagnant_stock_count,
    sa.ops::integer                                           AS sales_count,
    sa.prev_ops::integer                                      AS prev_sales_count
  FROM sales_agg sa
  CROSS JOIN expenses_agg  ea
  CROSS JOIN purchases_agg pa
  CROSS JOIN stagnant_curr sc
  CROSS JOIN stagnant_prev sp;
END;
$function$;


-- ============================================================
-- 4. NUEVO: rpc_apply_product_stock_delta
--    Punto de entrada del backend Python (JWT-passthrough) para:
--    - stock inicial al crear producto (delta = stock inicial)
--    - edición de stock (delta = target − Σ actual)
--    - reversa de stock al borrar compras (delta negativo, allow_negative,
--      sin movement — paridad con el comportamiento previo)
--    Seguridad: solo productos de la cuenta del caller; el helper interno
--    sigue REVOKEado (no expone upsert arbitrario de branch_stock).
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_apply_product_stock_delta(
  p_product_id     uuid,
  p_delta          numeric,
  p_branch_id      uuid    DEFAULT NULL,
  p_reason         text    DEFAULT NULL,
  p_log_movement   boolean DEFAULT TRUE,
  p_allow_negative boolean DEFAULT FALSE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_product    RECORD;
  v_before     numeric(15,4);
  v_after      numeric(15,4);
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  IF p_delta IS NULL OR p_delta = 0 THEN
    RAISE EXCEPTION 'p_delta must be non-zero' USING ERRCODE = 'P400';
  END IF;

  -- Lock de la fila del producto = mutex por producto (serializa con ventas/compras)
  SELECT id, name, account_id INTO v_product
  FROM   public.products
  WHERE  id = p_product_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Product not found: %', p_product_id USING ERRCODE = 'P404';
  END IF;

  IF v_product.account_id IS DISTINCT FROM v_account_id THEN
    RAISE EXCEPTION 'Permission denied to product: %', p_product_id USING ERRCODE = 'P403';
  END IF;

  IF p_branch_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'branch_not_found for this account' USING ERRCODE = 'P404';
    END IF;
  END IF;

  SELECT COALESCE(SUM(quantity), 0) INTO v_before
  FROM   public.branch_stock
  WHERE  product_id = p_product_id;

  v_after := v_before + p_delta;

  IF v_after < 0 AND NOT p_allow_negative THEN
    RAISE EXCEPTION 'Stock insuficiente. Disponible: %, delta: %', v_before, p_delta
      USING ERRCODE = 'P409';
  END IF;

  PERFORM public.c21_apply_branch_stock_delta(
    v_account_id, p_product_id, p_branch_id, p_delta);

  IF p_log_movement THEN
    INSERT INTO public.stock_movements (
      user_id, account_id, product_id, product_name, type,
      quantity_delta, quantity_before, quantity_after,
      reason, performed_by, branch_id
    ) VALUES (
      v_uid, v_account_id, p_product_id, v_product.name, 'adjustment',
      p_delta, v_before, v_after,
      p_reason, v_uid, p_branch_id
    );
  END IF;

  RETURN jsonb_build_object(
    'product_id',      p_product_id,
    'quantity_before', v_before,
    'quantity_after',  v_after,
    'quantity_delta',  p_delta
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_apply_product_stock_delta(uuid, numeric, uuid, text, boolean, boolean) TO authenticated;

COMMENT ON FUNCTION public.rpc_apply_product_stock_delta IS
  'C-21 checkpoint #2: aplica un delta de stock sobre branch_stock (branch indicada '
  'o default de la cuenta). Usado por el backend Python para stock inicial, edición '
  'de stock y reversa de compras borradas. Solo productos de la cuenta del caller.';


-- ============================================================
-- 5a. rpc_create_sale_operation (wrapper + legacy) — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_flag_on    boolean := false;
  v_uid        uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  SELECT COALESCE(enabled, false) INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;

  IF v_flag_on THEN
    RETURN public.rpc_create_sale_operation_v2(
      p_idempotency_key, p_client_id, p_date, p_currency, p_items,
      p_branch_id, p_canal
    );
  ELSE
    DECLARE
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
      v_stock_sum    numeric(15,4);
      v_inserted     integer;
      v_canal        text;
    BEGIN
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

      v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
      IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
        RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P400';
      END IF;

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
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

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
          -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
          SELECT id, user_id, is_variant, name INTO v_product
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

          -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
          SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
          FROM   public.branch_stock
          WHERE  product_id = v_item.product_id;

          IF v_stock_sum < v_qty_norm THEN
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

          v_qty_before := v_stock_sum;
          v_qty_after  := v_stock_sum - v_qty_norm;

          -- C-21 checkpoint #2: single-write branch_stock (branch de la op o default)
          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, p_branch_id, -v_qty_norm);

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
  END IF;
END;
$function$;


-- ============================================================
-- 5b. rpc_create_sale_operation_v2 — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation_v2(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  v_stock_sum    numeric(15,4);
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

  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
  IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
    RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P400';
  END IF;

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
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

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
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
      SELECT id, user_id, is_variant, name INTO v_product
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

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_qty_norm THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
      END IF;

      -- OQ2: doble escritura — inserta header flat Y sale_items en la misma transacción
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         p_branch_id, v_canal)
      RETURNING id INTO v_new_sale_id;

      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity
      );

      v_qty_before := v_stock_sum;
      v_qty_after  := v_stock_sum - v_qty_norm;

      -- C-21 checkpoint #2: single-write branch_stock (branch de la op o default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, p_branch_id, -v_qty_norm);

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
$function$;


-- ============================================================
-- 5c. rpc_create_purchase_operation (wrapper + legacy) — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid        uuid;
  v_account_id uuid;
  v_flag_on    boolean := false;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  SELECT COALESCE(enabled, false) INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;

  IF v_flag_on THEN
    RETURN public.rpc_create_purchase_operation_v2(
      p_idempotency_key, p_date, p_description, p_items
    );
  ELSE
    DECLARE
      v_new_op_id       uuid;
      v_existing_op     uuid;
      v_item            RECORD;
      v_product         RECORD;
      v_new_purchase_id uuid;
      v_result_items    jsonb := '[]'::jsonb;
      v_qty_before      numeric;
      v_qty_after       numeric;
      v_unit_factor     numeric(20,10);
      v_qty_norm        numeric(15,4);
      v_stock_sum       numeric(15,4);
      v_inserted        integer;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
      END IF;

      IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
      END IF;

      IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
      END IF;

      v_new_op_id := gen_random_uuid();

      INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
      VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;

      IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'purchase'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                 jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                 '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

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
          -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
          SELECT id, user_id, is_variant, name INTO v_product
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
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                USING ERRCODE = 'P422';
            END IF;
          END IF;

          INSERT INTO public.purchases
            (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
          VALUES
            (v_uid, v_account_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
          RETURNING id INTO v_new_purchase_id;

          -- C-21 checkpoint #2: before/after desde Σ branch_stock
          SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
          FROM   public.branch_stock
          WHERE  product_id = v_item.product_id;

          v_qty_before := v_stock_sum;
          v_qty_after  := v_stock_sum + v_qty_norm;

          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, NULL, v_qty_norm);

          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
            v_qty_norm, v_qty_before, v_qty_after,
            v_new_purchase_id, 'purchase', v_uid,
            v_new_op_id
          );

        ELSE
          INSERT INTO public.purchases
            (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
          VALUES
            (v_uid, v_account_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
          RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
      END LOOP;

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$function$;


-- ============================================================
-- 5d. rpc_create_purchase_operation_v2 — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation_v2(p_idempotency_key text, p_date date, p_description text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_new_op_id       uuid;
  v_existing_op     uuid;
  v_item            RECORD;
  v_product         RECORD;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;
  v_qty_after       numeric;
  v_unit_factor     numeric(20,10);
  v_qty_norm        numeric(15,4);
  v_stock_sum       numeric(15,4);
  v_inserted        integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P403';
  END IF;

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'purchase'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.purchases p
    WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

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
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
      SELECT id, user_id, is_variant, name INTO v_product
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
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      -- OQ2: doble escritura — header flat + purchase_items
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      INSERT INTO public.purchase_items (
        purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_purchase_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity
      );

      -- C-21 checkpoint #2: before/after desde Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      v_qty_before := v_stock_sum;
      v_qty_after  := v_stock_sum + v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, v_qty_norm);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
        v_qty_norm, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase', v_uid,
        v_new_op_id
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;


-- ============================================================
-- 5e. rpc_stock_adjustment — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(p_product_id uuid, p_quantity_delta numeric DEFAULT NULL::numeric, p_type text DEFAULT 'adjustment'::text, p_reason text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_reference_id uuid DEFAULT NULL::uuid, p_target_quantity numeric DEFAULT NULL::numeric)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid         uuid;
  v_product     RECORD;
  v_account_id  uuid;
  v_stock_sum   numeric(15,4);
  v_qty_before  numeric;
  v_qty_after   numeric;
  v_delta       numeric;
  v_movement_id uuid;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF p_type NOT IN (
    'adjustment', 'physical_count', 'loss', 'damage',
    'expiry', 'transfer_in', 'transfer_out'
  ) THEN
    RAISE EXCEPTION
      'Tipo de movimiento no válido para ajuste manual: %. '
      'Permitidos: adjustment, physical_count, loss, damage, expiry, transfer_in, transfer_out',
      p_type
      USING ERRCODE = 'check_violation';
  END IF;

  IF p_quantity_delta IS NULL AND p_target_quantity IS NULL THEN
    RAISE EXCEPTION 'Se requiere p_quantity_delta o p_target_quantity'
      USING ERRCODE = 'check_violation';
  END IF;

  -- Lock row BEFORE computing delta (critical for physical_count).
  -- C-21 checkpoint #2: la fila se lockea como mutex; el stock se lee de Σ branch_stock.
  SELECT id, name, stock_control_type, account_id
  INTO   v_product
  FROM   public.products
  WHERE  id = p_product_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado o acceso denegado'
      USING ERRCODE = 'no_data_found';
  END IF;

  IF v_product.stock_control_type IN ('variant_only', 'untracked') THEN
    RAISE EXCEPTION
      'Este producto no permite ajuste manual de stock (stock_control_type = %). '
      'Los productos "variant_only" se gestionan a través de sus variantes; '
      'los "untracked" no tienen stock físico.',
      v_product.stock_control_type
      USING ERRCODE = 'check_violation';
  END IF;

  v_account_id := COALESCE(
    v_product.account_id,
    (SELECT cai FROM current_account_ids() AS cai LIMIT 1)
  );

  SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
  FROM   public.branch_stock
  WHERE  product_id = p_product_id;

  IF p_type = 'physical_count' AND p_target_quantity IS NOT NULL THEN
    v_delta := p_target_quantity - v_stock_sum;
  ELSE
    v_delta := p_quantity_delta;
    IF v_delta = 0 THEN
      RAISE EXCEPTION 'quantity_delta no puede ser cero para tipo %', p_type
        USING ERRCODE = 'check_violation';
    END IF;
  END IF;

  v_qty_before := v_stock_sum;
  v_qty_after  := v_stock_sum + v_delta;

  IF v_qty_after < 0 THEN
    RAISE EXCEPTION
      'Stock insuficiente. Disponible: %, solicitado quitar: %',
      v_qty_before, ABS(v_delta)
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  IF v_delta != 0 THEN
    -- C-21 checkpoint #2: single-write branch_stock (ajuste global → default branch)
    PERFORM public.c21_apply_branch_stock_delta(
      v_account_id, p_product_id, NULL, v_delta);
  END IF;

  INSERT INTO public.stock_movements (
    user_id, product_id, product_name, type,
    quantity_delta, quantity_before, quantity_after,
    reason, notes, performed_by,
    reference_id, reference_type
    -- operation_group_id intentionally NULL: single-movement operation
  ) VALUES (
    v_uid, p_product_id, v_product.name, p_type,
    v_delta, v_qty_before, v_qty_after,
    p_reason, p_notes, v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',     v_movement_id,
    'product_id',      p_product_id,
    'product_name',    v_product.name,
    'quantity_before', v_qty_before,
    'quantity_after',  v_qty_after,
    'quantity_delta',  v_delta,
    'type',            p_type
  );
END;
$function$;


-- ============================================================
-- 5f. rpc_atomic_update_sale_operation — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_old_sale     RECORD;
  v_item         RECORD;
  v_product      RECORD;
  v_new_op_id    uuid;
  v_new_sale_id  uuid;
  v_stock_sum    numeric(15,4);
  v_result_items jsonb := '[]'::jsonb;
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Account scoping (C-05 D7) ────────────────────────────────────────────
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P403';
  END IF;

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.sales
    WHERE id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P403';
  END IF;

  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  FOR v_old_sale IN
    SELECT product_id, quantity, branch_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: devolver a la branch original de la venta (o default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_old_sale.product_id, v_old_sale.branch_id, v_old_sale.quantity);
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
      SELECT id, user_id, is_variant INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      -- C-21 checkpoint #2: gate global de stock = Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      IF v_stock_sum < v_item.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, -v_item.quantity);

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;


-- ============================================================
-- 5g. rpc_atomic_update_purchase_operation — SINGLE-WRITE
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_old_purchase    RECORD;
  v_item            RECORD;
  v_product         RECORD;
  v_new_op_id       uuid;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Account scoping (C-05 D7) ────────────────────────────────────────────
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P403';
  END IF;

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.purchases
    WHERE id = ANY(p_purchase_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: purchase belongs to another user' USING ERRCODE = 'P403';
  END IF;

  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids))
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  FOR v_old_purchase IN
    SELECT product_id, quantity, branch_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: revertir de la branch original de la compra (o default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_old_purchase.product_id, v_old_purchase.branch_id, -v_old_purchase.quantity);
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
      SELECT id, user_id, is_variant INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      -- C-21 checkpoint #2: single-write branch_stock (sin branch en la firma → default)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, v_item.quantity);

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;


-- ============================================================
-- 6. rpc_bulk_upsert_products — SINGLE-WRITE + cuenta vía
--    current_account_ids() con guard (residuo task_29345f9d)
-- ============================================================
CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(p_rows jsonb, p_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_row            jsonb;
  v_product_id     uuid;
  v_existing_id    uuid;
  v_resolved_pid   uuid;
  v_attr           jsonb;
  v_inserted       int := 0;
  v_updated        int := 0;
  v_errors         jsonb := '[]'::jsonb;
  v_error_detail   jsonb;
  v_account_id     uuid;
  v_default_branch uuid;
  v_stock_qty      numeric;
BEGIN
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'Unauthorized: caller does not own user_id';
  END IF;

  -- C-21 checkpoint #2 (residuo task_29345f9d): la cuenta se resuelve vía
  -- current_account_ids() — funciona para dueños Y miembros. El método anterior
  -- (accounts.user_id) devolvía NULL para miembros no-dueños y generaba
  -- products huérfanos. Guard duro: sin cuenta no se importa.
  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede importar productos'
      USING ERRCODE = 'P403';
  END IF;

  -- Default branch de la cuenta (la más antigua); lazy-create si no existe.
  SELECT b.id INTO v_default_branch
    FROM branches b
   WHERE b.account_id = v_account_id
   ORDER BY b.created_at ASC
   LIMIT 1;

  IF v_default_branch IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active)
    VALUES (v_account_id, 'Casa Central', TRUE)
    ON CONFLICT (account_id, name) DO NOTHING;

    SELECT b.id INTO v_default_branch
      FROM branches b
     WHERE b.account_id = v_account_id
     ORDER BY b.created_at ASC
     LIMIT 1;
  END IF;

  FOR v_row IN SELECT * FROM jsonb_array_elements(p_rows)
  LOOP
    BEGIN
      v_existing_id := NULL;
      IF v_row->>'sku' IS NOT NULL AND v_row->>'sku' <> '' THEN
        SELECT id INTO v_existing_id
          FROM public.products
         WHERE user_id = p_user_id
           AND sku = v_row->>'sku'
         LIMIT 1;
      END IF;

      v_resolved_pid := NULL;

      IF v_row->>'parent_id' IS NOT NULL AND v_row->>'parent_id' <> '' THEN
        v_resolved_pid := (v_row->>'parent_id')::uuid;

      ELSIF v_row->>'sku_parent' IS NOT NULL AND v_row->>'sku_parent' <> '' THEN
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE user_id = p_user_id
           AND sku = v_row->>'sku_parent'
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'SKU Padre "%" no encontrado para la variante "%"',
            v_row->>'sku_parent', v_row->>'name';
        END IF;

      ELSIF v_row->>'parent_name' IS NOT NULL AND v_row->>'parent_name' <> '' THEN
        SELECT id INTO v_resolved_pid
          FROM public.products
         WHERE user_id = p_user_id
           AND name = v_row->>'parent_name'
           AND (is_variant = false OR is_variant IS NULL)
           AND parent_id IS NULL
         ORDER BY created_at DESC
         LIMIT 1;
        IF v_resolved_pid IS NULL THEN
          RAISE EXCEPTION 'Producto Padre "%" no encontrado para la variante "%"',
            v_row->>'parent_name', v_row->>'name';
        END IF;
      END IF;

      v_stock_qty := COALESCE((v_row->>'stock')::numeric, 0);

      IF v_existing_id IS NOT NULL THEN
        -- C-21 checkpoint #2: products.stock no existe — el stock va solo a branch_stock.
        UPDATE public.products SET
          name               = COALESCE(NULLIF(v_row->>'name',''),       name),
          category           = COALESCE(NULLIF(v_row->>'category',''),   category),
          price              = COALESCE((v_row->>'price')::numeric,      price),
          cost               = COALESCE((v_row->>'cost')::numeric,       cost),
          min_stock          = COALESCE((v_row->>'min_stock')::integer,  min_stock),
          barcode            = COALESCE(NULLIF(v_row->>'barcode',''),    barcode),
          parent_id          = COALESCE(v_resolved_pid,                  parent_id),
          is_variant         = COALESCE((v_row->>'is_variant')::boolean, is_variant),
          stock_control_type = COALESCE(NULLIF(v_row->>'stock_control_type',''), stock_control_type),
          account_id         = COALESCE(account_id, v_account_id)
        WHERE id = v_existing_id AND user_id = p_user_id;

        v_product_id := v_existing_id;
        v_updated    := v_updated + 1;

      ELSE
        INSERT INTO public.products (
          user_id, account_id, name, category, price, cost, min_stock,
          barcode, sku, parent_id, is_variant, stock_control_type
        ) VALUES (
          p_user_id,
          v_account_id,
          v_row->>'name',
          COALESCE(NULLIF(v_row->>'category',''), 'Otros'),
          COALESCE((v_row->>'price')::numeric,    0),
          COALESCE((v_row->>'cost')::numeric,     0),
          COALESCE((v_row->>'min_stock')::integer, 0),
          NULLIF(v_row->>'barcode', ''),
          NULLIF(v_row->>'sku',     ''),
          v_resolved_pid,
          COALESCE((v_row->>'is_variant')::boolean, false),
          COALESCE(NULLIF(v_row->>'stock_control_type',''), 'tracked')
        )
        RETURNING id INTO v_product_id;

        v_inserted := v_inserted + 1;
      END IF;

      -- Stock del CSV → branch_stock (default branch), set absoluto.
      -- Sólo para filas no-Padre (stock > 0 o stock explícito en el CSV).
      IF v_default_branch IS NOT NULL
         AND v_product_id IS NOT NULL
         AND (v_row->>'stock' IS NOT NULL OR v_stock_qty > 0)
      THEN
        INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity, min_stock)
        VALUES (
          v_account_id,
          v_product_id,
          v_default_branch,
          v_stock_qty,
          COALESCE((v_row->>'min_stock')::integer, 0)
        )
        ON CONFLICT (product_id, branch_id)
          DO UPDATE SET
            quantity  = EXCLUDED.quantity,
            min_stock = EXCLUDED.min_stock;
      END IF;

      IF v_row->'attributes' IS NOT NULL AND jsonb_array_length(v_row->'attributes') > 0 THEN
        FOR v_attr IN SELECT * FROM jsonb_array_elements(v_row->'attributes')
        LOOP
          INSERT INTO public.product_attributes (product_id, user_id, key, value, sort_order)
          VALUES (
            v_product_id,
            p_user_id,
            v_attr->>'key',
            v_attr->>'value',
            COALESCE((v_attr->>'sort_order')::integer, 0)
          )
          ON CONFLICT (product_id, key) DO UPDATE
            SET value      = EXCLUDED.value,
                sort_order = EXCLUDED.sort_order;
        END LOOP;
      END IF;

    EXCEPTION WHEN OTHERS THEN
      v_error_detail := jsonb_build_object(
        'sku',     v_row->>'sku',
        'name',    v_row->>'name',
        'message', SQLERRM
      );
      v_errors := v_errors || jsonb_build_array(v_error_detail);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'inserted', v_inserted,
    'updated',  v_updated,
    'errors',   v_errors
  );
END;
$function$;

COMMENT ON FUNCTION public.rpc_bulk_upsert_products IS
    'C-21 checkpoint #2: single-write — el stock del CSV va solo a branch_stock '
    '(default branch, set absoluto). Cuenta resuelta vía current_account_ids() '
    '(dueños y miembros) con guard: sin cuenta activa no se importa.';


-- ============================================================
-- 7. DROP destructivo — products.stock (guard 9.4)
-- ============================================================
ALTER TABLE public.products DROP COLUMN IF EXISTS stock;

COMMENT ON FUNCTION public.c21_apply_branch_stock_delta IS
  'C-21: única vía de escritura de stock (branch_stock es el único ledger desde '
  'el checkpoint #2). Upsert acumulativo en la branch indicada o la default '
  '(más antigua) de la cuenta, con lazy-create de "Casa Central".';


-- =============================================================================
-- VERIFICATION (post-push):
--   -- Ninguna función debe referenciar la columna eliminada:
--   SELECT proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--   WHERE n.nspname = 'public' AND p.prosrc ~* '(products\s+SET\s+stock|p\.stock|NEW\.stock)';
--   -- La columna no existe:
--   SELECT count(*) FROM information_schema.columns
--   WHERE table_name = 'products' AND column_name = 'stock';  -- → 0
-- =============================================================================
