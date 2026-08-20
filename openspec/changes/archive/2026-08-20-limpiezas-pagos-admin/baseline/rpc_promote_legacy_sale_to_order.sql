CREATE OR REPLACE FUNCTION public.rpc_promote_legacy_sale_to_order(p_operation_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_client_id      uuid;
  v_total          numeric(15,2) := 0;
  v_sales_order_id uuid;
  v_existing_id    uuid;
  v_item           RECORD;
BEGIN
  -- ── Autenticación ───────────────────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Tenencia: existe la operación legacy y pertenece al usuario ─────────────
  -- Tomamos account_id, branch_id y client_id de la primera fila de la operación.
  -- MIN() para evitar ambigüedad si hay varias filas (operaciones multi-ítem).
  SELECT
    MIN(s.account_id),
    MIN(s.branch_id),
    MIN(s.client_id)
  INTO v_account_id, v_branch_id, v_client_id
  FROM public.sales s
  JOIN public.account_members am
    ON am.account_id = s.account_id
   AND am.user_id    = v_uid
  WHERE s.operation_id = p_operation_id;

  IF v_account_id IS NULL THEN
    -- La operación no existe o pertenece a otro usuario/cuenta
    RAISE EXCEPTION 'operation_not_found: operación % no encontrada o ajena', p_operation_id
      USING ERRCODE = 'P0404';
  END IF;

  -- ── Permiso de escritura ────────────────────────────────────────────────────
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: sin permiso de escritura sobre la cuenta'
      USING ERRCODE = 'P0401';
  END IF;

  -- ── Idempotencia: short-circuit si la SalesOrder ya existe (D2) ─────────────
  SELECT id INTO v_existing_id
  FROM public.sales_orders
  WHERE sale_operation_id = p_operation_id;

  IF v_existing_id IS NOT NULL THEN
    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END IF;

  -- ── Resolver branch efectiva (D4) ────────────────────────────────────────────
  -- Preferir branch de la venta legacy; sino, default de la cuenta (C-26).
  v_branch_id := COALESCE(v_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- ── Reconstruir ítems desde sale_items con fallback al header plano (D3) ─────
  -- Calculamos total = Σ subtotales.
  -- Líneas de servicio (product_id NULL) se incluyen sin error.
  SELECT COALESCE(SUM(COALESCE(si.subtotal, s.total)), 0)
  INTO v_total
  FROM public.sales s
  LEFT JOIN public.sale_items si ON si.sale_id = s.id
  WHERE s.operation_id = p_operation_id
    AND s.account_id   = v_account_id;

  -- ── INSERT sales_orders (status='confirmed', side-effect-free) ──────────────
  -- Carrera de concurrencia (D2): si otra promoción de la MISMA operación ganó
  -- entre el short-circuit de arriba y este INSERT, el índice único parcial dispara
  -- unique_violation. La capturamos y devolvemos la orden existente como replay,
  -- haciendo honor a la idempotencia que el diseño promete (en vez de un 500).
  BEGIN
    INSERT INTO public.sales_orders
      (account_id, branch_id, client_id, status, payment_method,
       sale_operation_id, total, fiscal_document_id, created_by)
    VALUES
      (v_account_id, v_branch_id, v_client_id, 'confirmed', 'other',
       p_operation_id, v_total, NULL, v_uid)
    RETURNING id INTO v_sales_order_id;
  EXCEPTION WHEN unique_violation THEN
    -- La transacción concurrente ya commiteó su sales_orders → es visible.
    SELECT id INTO v_existing_id
    FROM public.sales_orders
    WHERE sale_operation_id = p_operation_id;

    RETURN jsonb_build_object(
      'sales_order_id',    v_existing_id,
      'sale_operation_id', p_operation_id,
      'replayed',          true
    );
  END;

  -- ── INSERT sales_order_items (D3: sale_items con fallback header plano) ──────
  FOR v_item IN
    SELECT
      COALESCE(si.product_id, s.product_id)   AS product_id,
      s.unit_id                                AS unit_id,
      COALESCE(si.quantity,   s.quantity)      AS quantity,
      COALESCE(si.price,      s.amount)        AS price,
      COALESCE(si.subtotal,   s.total)         AS subtotal
    FROM public.sales s
    LEFT JOIN public.sale_items si ON si.sale_id = s.id
    WHERE s.operation_id = p_operation_id
      AND s.account_id   = v_account_id
    ORDER BY s.id
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price, v_item.subtotal);
  END LOOP;

  -- D1 verificación: NO se toca branch_stock, NO se inserta cash_movement,
  -- NO se inserta SaleConfirmed en events, NO se llama _c29_confirm_order_core.

  RETURN jsonb_build_object(
    'sales_order_id',    v_sales_order_id,
    'sale_operation_id', p_operation_id,
    'replayed',          false
  );
END;
$function$
;

