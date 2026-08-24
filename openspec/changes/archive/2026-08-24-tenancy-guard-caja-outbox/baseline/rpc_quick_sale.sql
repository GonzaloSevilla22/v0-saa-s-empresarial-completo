-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-24, vía
-- pg_get_functiondef(oid) — task 1.5 de tenancy-guard-caja-outbox (tramo h1).
-- MAX(version) al momento de la captura: 20261012000001 (261 migraciones).
-- md5(pg_get_functiondef) = ccb8afa0730195cb3df65807eb0a05ed · length = 4046.
-- REFERENCIA — no se toca: wrapper del POS, hereda el guard del core.
-- prosecdef = true · anon=false · authenticated=true · service_role=true.

CREATE OR REPLACE FUNCTION public.rpc_quick_sale(p_idempotency_key text, p_client_id uuid DEFAULT NULL::uuid, p_items jsonb DEFAULT '[]'::jsonb, p_payment_method text DEFAULT 'other'::text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_account_id     uuid;
  v_branch_id      uuid;
  v_sales_order_id uuid;
  v_item           RECORD;
  v_total          numeric(15,2) := 0;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Resolver account_id
  SELECT cai INTO v_account_id
  FROM current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar items
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch
  v_branch_id := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  IF v_branch_id IS NULL THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene sucursal activa'
      USING ERRCODE = 'P0422';
  END IF;

  -- Calcular total inicial
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'quantity debe ser > 0' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.price IS NULL OR v_item.price < 0 THEN
      RAISE EXCEPTION 'price debe ser >= 0' USING ERRCODE = 'P0400';
    END IF;
    v_total := v_total + COALESCE(v_item.subtotal, v_item.price * v_item.quantity);
  END LOOP;

  -- Crear SalesOrder en draft
  -- limpiezas-pagos-admin (D7 extendido, hallazgo del gate 4.1): ya no
  -- escribe el texto crudo p_payment_method en la columna retirada — el
  -- draft nace sin imputar (payment_method_id NULL); _c29_confirm_order_core
  -- (abajo, misma transacción) resuelve/valida la imputación real.
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, status, total, created_by)
  VALUES
    (v_account_id, v_branch_id, p_client_id, 'draft', v_total, v_uid)
  RETURNING id INTO v_sales_order_id;

  -- v3-document-status-history (RN-A2): creación de la SalesOrder → historial
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', v_sales_order_id, NULL, 'draft', v_uid, NULL);

  -- Crear sales_order_items
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
           AS x(product_id uuid, quantity numeric, price numeric, subtotal numeric, unit_id uuid)
  LOOP
    INSERT INTO public.sales_order_items
      (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal)
    VALUES
      (v_sales_order_id, v_account_id,
       v_item.product_id, v_item.unit_id,
       v_item.quantity, v_item.price,
       COALESCE(v_item.subtotal, v_item.price * v_item.quantity));
  END LOOP;

  -- Confirmar inline (hot path transaccional). pos-catalogo-pagos: pasa
  -- p_payment_method_id — la RPC interna resuelve y valida el kind (D2).
  -- pos-banco-movimientos: pasa p_bank_account_id — passthrough (D6).
  RETURN public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order_id,
    p_payment_method,
    p_cash_session_id,
    p_comprobante_type,
    p_point_of_sale_id,
    p_canal,
    p_payment_method_id,
    p_bank_account_id
  );
END;
$function$
