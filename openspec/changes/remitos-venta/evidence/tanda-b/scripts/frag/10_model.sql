

-- =============================================================================
-- 1. Puente remito -> venta (D1) y catálogo de la tanda B (D3)
-- =============================================================================
ALTER TABLE public.sales_orders ADD COLUMN IF NOT EXISTS source_delivery_note_id uuid;

-- NO ACTION (no RESTRICT): se verifica al final de la sentencia, así que no
-- traba un borrado de cuenta que cascadea a la vez sobre delivery_notes y
-- sales_orders. En la práctica equivale a RESTRICT: el remito nunca se borra.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'sales_orders_source_delivery_note_id_fkey'
      AND conrelid = 'public.sales_orders'::regclass
  ) THEN
    ALTER TABLE public.sales_orders
      ADD CONSTRAINT sales_orders_source_delivery_note_id_fkey
      FOREIGN KEY (source_delivery_note_id) REFERENCES public.delivery_notes (id) ON DELETE NO ACTION;
  END IF;
END $$;

-- A lo sumo una orden VIVA por remito (1 remito -> 1 venta, R8). Una orden
-- cancelada (venta borrada) no impide reconvertir (R5).
CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_source_delivery_note_id_uq
  ON public.sales_orders (source_delivery_note_id)
  WHERE source_delivery_note_id IS NOT NULL AND status <> 'canceled';

COMMENT ON COLUMN public.sales_orders.source_delivery_note_id IS
  'remitos-venta (D1/D7): remito de venta del que nació la orden. Lo escribe sólo rpc_convert_delivery_note_to_sale. '
  'Con valor, _c29_confirm_order_core NO mueve stock (el remito ya lo descontó) y revalida el remito y sus líneas; '
  'rpc_delete_sale_operation no repone stock y devuelve el remito a issued; rpc_atomic_update_sale_operation '
  'rechaza la edición (P0423 delivery_note_sale_locked).';

-- Filas de la tanda B (regla del seed: cada una con su productor en esta migración).
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_sale', 'issued', 'converted', false, false, ARRAY['seller', 'cashier', 'admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

-- Sin rol (tercera exención de record_status_transition): la dispara sólo el
-- borrado de la venta, que ya exige admin/owner por sales_order
-- confirmed -> canceled, registrada antes en la misma transacción.
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_sale', 'converted', 'issued', false, false, NULL)
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;
