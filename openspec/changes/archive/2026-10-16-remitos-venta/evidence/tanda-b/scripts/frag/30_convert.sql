CREATE OR REPLACE FUNCTION public.rpc_convert_delivery_note_to_sale(
  p_idempotency_key   text,
  p_delivery_note_id  uuid,
  p_expected_revision integer,
  p_payment_method_id uuid,
  p_cash_session_id   uuid DEFAULT NULL,
  p_bank_account_id   uuid DEFAULT NULL,
  p_canal             text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_dn           public.delivery_notes%ROWTYPE;
  v_existing_op  uuid;
  v_order        RECORD;
  v_sales_order  uuid;
  v_sale         jsonb;
BEGIN
  -- 1. Entrada
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_idempotency_key IS NULL OR length(btrim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;
  IF p_payment_method_id IS NULL THEN
    RAISE EXCEPTION 'payment_method_required: la conversión exige una forma de pago del catálogo'
      USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se convierte'
      USING ERRCODE = 'P0400';
  END IF;

  -- 2. Lock del documento de origen primero (ajeno = inexistente), después el
  -- rol de la transición issued -> converted del catálogo.
  SELECT * INTO v_dn
  FROM public.delivery_notes
  WHERE id = p_delivery_note_id
    AND account_id IN (SELECT public.current_account_ids())
    AND direction = 'sale'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role(v_dn.account_id, 'convert');

  -- 3. Idempotencia, leída bajo el lock: el doble clic sobre el mismo remito
  -- espera el lock de arriba y hace replay (ya converted: responde antes de
  -- mirar el estado).
  SELECT operation_id INTO v_existing_op
  FROM public.operation_idempotency
  WHERE user_id = v_uid
    AND operation_kind = 'sale'
    AND idempotency_key = p_idempotency_key;

  IF FOUND THEN
    SELECT so.id, so.total INTO v_order
    FROM public.sales_orders so
    WHERE so.sale_operation_id = v_existing_op
      AND so.source_delivery_note_id = p_delivery_note_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
        USING ERRCODE = 'P0409';
    END IF;
    RETURN jsonb_build_object(
      'delivery_note_id',     p_delivery_note_id,
      'delivery_note_number', v_dn.number,
      'sales_order_id',       v_order.id,
      'operation_id',         v_existing_op,
      'total',                v_order.total,
      'replayed',             true
    );
  END IF;

  -- 4. Estado y versión, sobre la fila bloqueada.
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede convertir', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  -- 5. Guards autosuficientes (no delegan en el guard de baja de sucursal).
  -- Cliente vivo: una venta a crédito postearía deuda contra un cliente que
  -- cobranzas excluye. Los productos dados de baja después de emitir SE
  -- CONVIERTEN (OQ-RV3): la mercadería ya se entregó.
  IF NOT EXISTS (
    SELECT 1 FROM public.clients c
    WHERE c.id = v_dn.client_id
      AND c.account_id = v_dn.account_id
      AND c.deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'delivery_note_client_unavailable: el cliente del remito fue dado de baja: editá el remito y elegí un cliente vigente'
      USING ERRCODE = 'P0404';
  END IF;
  -- Sucursal del remito activa y no cerrada (el núcleo sólo rechaza 'closed').
  IF NOT EXISTS (
    SELECT 1 FROM public.branches b
    WHERE b.id = v_dn.branch_id
      AND b.account_id = v_dn.account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'branch_closed: la sucursal del remito está desactivada o cerrada — reactivala para convertir el remito'
      USING ERRCODE = 'P0422';
  END IF;

  -- 6. Orden draft con origen de remito, en la sucursal del remito (de donde
  -- salió el stock), y sus líneas copiadas del remito con precios y snapshots
  -- (sin re-leer el maestro, OQ-RV13).
  INSERT INTO public.sales_orders
    (account_id, branch_id, client_id, source_delivery_note_id, status, total, created_by)
  VALUES
    (v_dn.account_id, v_dn.branch_id, v_dn.client_id, v_dn.id, 'draft', v_dn.total, v_uid)
  RETURNING id INTO v_sales_order;

  PERFORM public.record_status_transition(
    v_dn.account_id, 'sales_order', v_sales_order, NULL, 'draft', v_uid, NULL);

  INSERT INTO public.sales_order_items
    (sales_order_id, account_id, product_id, unit_id, quantity, price, subtotal,
     name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
  SELECT v_sales_order, v_dn.account_id, i.product_id, i.unit_id, i.quantity, i.price, i.subtotal,
         i.name_snapshot, i.sku_snapshot, i.unit_cost_snapshot, i.iva_rate_snapshot
  FROM public.delivery_note_items i
  WHERE i.delivery_note_id = v_dn.id
  ORDER BY i.line_no, i.id;

  -- 7. Confirmación con el núcleo del POS, sin tipo de comprobante (facturar
  -- es una acción posterior explícita). El núcleo ve source_delivery_note_id,
  -- revalida el remito y NO mueve stock.
  v_sale := public._c29_confirm_order_core(
    p_idempotency_key,
    v_sales_order,
    NULL,
    p_cash_session_id,
    NULL,
    NULL,
    p_canal,
    p_payment_method_id,
    p_bank_account_id
  );

  -- La misma clave usada en paralelo sobre OTRO documento: el núcleo esperó el
  -- ON CONFLICT y devolvió la operación ajena sin confirmar esta orden.
  IF COALESCE((v_sale->>'replayed')::boolean, false) THEN
    RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación'
      USING ERRCODE = 'P0409';
  END IF;

  -- 8. Transición del remito (no sube la revisión: no cambia el contenido).
  PERFORM public.record_status_transition(
    v_dn.account_id, 'delivery_note_sale', v_dn.id, 'issued', 'converted', v_uid, NULL);
  UPDATE public.delivery_notes
  SET status = 'converted', updated_at = now(), updated_by = v_uid
  WHERE id = v_dn.id;

  -- 9. Resultado
  RETURN jsonb_build_object(
    'delivery_note_id',     v_dn.id,
    'delivery_note_number', v_dn.number,
    'sales_order_id',       v_sales_order,
    'operation_id',         (v_sale->>'operation_id')::uuid,
    'total',                (v_sale->>'total')::numeric,
    'replayed',             false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_convert_delivery_note_to_sale(text, uuid, integer, uuid, uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_convert_delivery_note_to_sale(text, uuid, integer, uuid, uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_convert_delivery_note_to_sale(text, uuid, integer, uuid, uuid, uuid, text) IS
  'remitos-venta (D7, R8): convierte un remito de venta issued en una venta con un toque, SIN doble descuento. '
  'Lock del remito (ajeno = P0404 delivery_note_not_found) -> rol issued->converted del catálogo '
  '({seller,cashier,admin,owner}, P0401/P0403) -> idempotencia bajo el lock (replay; otra operación -> P0409 '
  'idempotency_key_conflict) -> estado (P0409 delivery_note_invalid_state) y versión (P0409 delivery_note_changed) '
  '-> cliente vivo (P0404 delivery_note_client_unavailable) -> sucursal del remito activa y no cerrada (P0422 '
  'branch_closed) -> orden draft con source_delivery_note_id en la sucursal del remito y líneas copiadas con sus '
  'precios y snapshots -> _c29_confirm_order_core (que con ese origen no mueve stock) -> transición issued->converted. '
  'No bloquea productos. Devuelve {delivery_note_id, delivery_note_number, sales_order_id, operation_id, total, replayed}.';
