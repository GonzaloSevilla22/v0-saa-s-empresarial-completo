CREATE OR REPLACE FUNCTION public._delivery_note_payload(p_dn_id uuid)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT to_jsonb(dn)
         || jsonb_build_object(
              'document_type', 'delivery_note_' || dn.direction,
              'client_name',   (SELECT c.name FROM public.clients c WHERE c.id = dn.client_id),
              'client_phone',  (SELECT c.phone FROM public.clients c WHERE c.id = dn.client_id),
              'client_deleted', (SELECT c.deleted_at IS NOT NULL FROM public.clients c WHERE c.id = dn.client_id),
              -- remitos-compra (D7/D11): contraparte del sentido compra y
              -- cuántas líneas siguen con precio 0 (no se puede convertir).
              'supplier_name',  (SELECT s.name FROM public.suppliers s WHERE s.id = dn.supplier_id AND s.account_id = dn.account_id),
              'supplier_phone', (SELECT s.phone FROM public.suppliers s WHERE s.id = dn.supplier_id AND s.account_id = dn.account_id),
              'supplier_deleted', (SELECT s.deleted_at IS NOT NULL FROM public.suppliers s WHERE s.id = dn.supplier_id AND s.account_id = dn.account_id),
              'missing_price_count', (SELECT count(*) FROM public.delivery_note_items mi
                                      WHERE mi.delivery_note_id = dn.id AND mi.price = 0),
              'branch_name',   (SELECT b.name FROM public.branches b WHERE b.id = dn.branch_id),
              -- remitos-venta tanda B: la orden VIVA nacida del remito (a lo
              -- sumo una, índice único parcial); NULL si no está convertido.
              'converted_sales_order_id', (SELECT so.id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
              'converted_operation_id',   (SELECT so.sale_operation_id FROM public.sales_orders so
                                           WHERE so.source_delivery_note_id = dn.id
                                             AND so.account_id = dn.account_id
                                             AND so.status <> 'canceled'),
              'items', COALESCE((
                SELECT jsonb_agg(to_jsonb(i)
                                 || jsonb_build_object(
                                      'unit_symbol', (SELECT u.symbol FROM public.units_of_measure u WHERE u.id = i.unit_id),
                                      'product_deleted', (SELECT p.deleted_at IS NOT NULL FROM public.products p WHERE p.id = i.product_id))
                                 ORDER BY i.line_no, i.id)
                FROM public.delivery_note_items i
                WHERE i.delivery_note_id = dn.id), '[]'::jsonb),
              'history', COALESCE((
                SELECT jsonb_agg(jsonb_build_object(
                         'from_status', h.from_status, 'to_status', h.to_status,
                         'performed_by', h.performed_by, 'reason', h.reason, 'occurred_at', h.occurred_at)
                       ORDER BY h.occurred_at, h.id)
                FROM public.document_status_history h
                WHERE h.document_type = 'delivery_note_' || dn.direction
                  AND h.document_id = dn.id
                  AND h.account_id = dn.account_id), '[]'::jsonb))
  FROM public.delivery_notes dn
  WHERE dn.id = p_dn_id;
$function$
