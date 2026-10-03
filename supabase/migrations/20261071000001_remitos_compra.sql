-- =============================================================================
-- 20261071000001_remitos_compra.sql
-- remitos-compra, TANDA A (governance MEDIA con tramo ALTO: escribe el ledger
-- de stock en tres caminos nuevos —recepción, edición y anulación— y reescribe
-- helpers y RPCs que remitos-venta acaba de mergear). Sign-off del PO
-- 2026-09-29: «no necesito el remito legal. Andá con todo lo recomendado» y
-- «quiero que tanto el remito como los presupuestos se puedan modificar»
-- (R1-R8); OQ-RC1..RC11 por su recomendación. Ver
-- openspec/changes/remitos-compra/design.md (D1-D16).
--
-- Qué hace (sin dinero: la conversión a compra es la tanda B):
--   1. CHECK ampliados POR AGREGADO al vivo (D16): un bloque DO lee
--      pg_get_constraintdef y sólo hace DROP + ADD si falta el valor, con la
--      lista viva más delivery_note_purchase. Nunca una lista fija: reaplicar
--      esta migración después de otro change que sume valores no los borra.
--      internal_document_sequences, document_status_history,
--      document_status_transitions y operation_idempotency.operation_kind.
--   2. FSM y numeración (D2, D3): filas NULL -> issued {stock,admin,owner} e
--      issued -> canceled {admin,owner} (motivo, terminal) de
--      delivery_note_purchase; disparadores gemelos de número (RC, genérico),
--      creación y enforcement con WHEN (direction = 'purchase'). Los de venta
--      no se tocan.
--   3. Helpers por sentido desde el cuerpo VIVO, con la MISMA firma (D4, D7):
--      _delivery_note_apply_stock y _delivery_note_reverse_held leen direction
--      de la fila del remito (compra: la aplicación suma sin gate con
--      type = purchase; la reversa resta con gate P0409
--      delivery_note_stock_consumed y type = purchase_return);
--      _delivery_note_assert_role_dir(uuid, text, text) NUEVA con nombre propio
--      (sin overload) y _delivery_note_assert_role(uuid, text) delega con
--      'sale'; _delivery_note_payload (desde el cuerpo vivo de 20261070000001)
--      suma supplier_name, supplier_phone, supplier_deleted y
--      missing_price_count.
--   4. Núcleo de edición _delivery_note_replace_content extraído del cuerpo
--      vivo de rpc_update_delivery_note (D5), en el orden vivo: la sucursal
--      nueva se fija ANTES de recalcular lo retenido nuevo; en compra, chequeo
--      del neto por par antes de cualquier pata; patas que suman primero.
--      rpc_update_delivery_note (venta) pasa a llamarlo: el único cambio de
--      forma es su UPDATE partido en dos.
--   5. RPCs SECURITY DEFINER rpc_create_purchase_delivery_note (idempotente,
--      molde DEC-06), rpc_update_purchase_delivery_note y
--      rpc_cancel_delivery_note para los dos sentidos.
--   6. Bloque DO de introspección al final.
--
-- El guard de baja de sucursal NO se toca: _branch_pending_delivery_notes ya
-- cuenta los remitos issued sin filtrar direction (verificado en el gate).
--
-- Idempotente (auto-apply de Supabase GitHub y reaplicación de
-- KPI_Validation.yml): CHECK por agregado, catálogo con ON CONFLICT DO
-- NOTHING, DROP TRIGGER IF EXISTS + CREATE, CREATE OR REPLACE con firmas
-- nuevas o idénticas (sin overload, sin 42725), REVOKE/GRANT y COMMENT
-- re-ejecutables.
--
-- Gates: supabase/tests/test_remitos_compra.sql (EJECUTA las RPCs, los helpers
-- por sentido y la regresión de venta), supabase/tests/test_remitos_compra_race.sh,
-- supabase/tests/test_internal_document_numbering_race.sh
-- (DOC_TYPE=delivery_note_purchase) y, sin tocarlos salvo el bloque (n),
-- test_remitos_venta.sql / test_remitos_venta_race.sh.
-- =============================================================================


-- =============================================================================
-- 1. CHECK ampliados POR AGREGADO al vivo (D16)
-- =============================================================================
DO $$
DECLARE
  v_spec    record;
  v_def     text;
  v_values  text[];
  v_comment text;
BEGIN
  FOR v_spec IN
    SELECT * FROM (VALUES
      ('internal_document_sequences', 'internal_document_sequences_document_type_check', 'document_type'),
      ('document_status_history',     'document_status_history_document_type_check',     'document_type'),
      ('document_status_transitions', 'document_status_transitions_document_type_check', 'document_type'),
      ('operation_idempotency',       'operation_idempotency_operation_kind_check',      'operation_kind')
    ) AS t(tbl, con, col)
  LOOP
    SELECT pg_get_constraintdef(c.oid), obj_description(c.oid, 'pg_constraint')
    INTO   v_def, v_comment
    FROM   pg_constraint c
    WHERE  c.conname = v_spec.con
      AND  c.conrelid = format('public.%I', v_spec.tbl)::regclass;
    IF v_def IS NULL THEN
      RAISE EXCEPTION 'remitos-compra: falta la constraint viva %.%', v_spec.tbl, v_spec.con;
    END IF;

    SELECT array_agg(m[1] ORDER BY o) INTO v_values
    FROM   regexp_matches(v_def, '''([^'']+)''', 'g') WITH ORDINALITY AS r(m, o);

    IF NOT ('delivery_note_purchase' = ANY (v_values)) THEN
      v_values := v_values || 'delivery_note_purchase'::text;
      EXECUTE format('ALTER TABLE public.%I DROP CONSTRAINT %I', v_spec.tbl, v_spec.con);
      -- ARRAY[...] literal (no '{...}'::text[]): pg_get_constraintdef lo devuelve
      -- con un literal por valor, que es lo que la regexp de arriba vuelve a leer.
      EXECUTE format('ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%I = ANY (ARRAY[%s]::text[]))',
                     v_spec.tbl, v_spec.con, v_spec.col,
                     (SELECT string_agg(quote_literal(v), ', ' ORDER BY o) FROM unnest(v_values) WITH ORDINALITY AS u(v, o)));
      IF v_comment IS NOT NULL THEN
        EXECUTE format('COMMENT ON CONSTRAINT %I ON public.%I IS %L', v_spec.con, v_spec.tbl,
                       v_comment || ' remitos-compra (D16): suma delivery_note_purchase por agregado al vivo.');
      END IF;
    END IF;
  END LOOP;
END $$;


-- =============================================================================
-- 2. FSM y numeración (D2, D3)
-- =============================================================================
-- Sólo las filas de la tanda A (regla del seed: ninguna transición sin productor).
INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_purchase', NULL, 'issued', false, false, ARRAY['stock', 'admin', 'owner'])
ON CONFLICT (document_type, to_status) WHERE from_status IS NULL DO NOTHING;

INSERT INTO public.document_status_transitions
  (document_type, from_status, to_status, is_terminal_to, requires_reason, allowed_role)
VALUES
  ('delivery_note_purchase', 'issued', 'canceled', true, true, ARRAY['admin', 'owner'])
ON CONFLICT (document_type, from_status, to_status) WHERE from_status IS NOT NULL DO NOTHING;

-- Número RC: la función genérica, sin cambios; el WHEN separa las secuencias.
DROP TRIGGER IF EXISTS delivery_notes_assign_number_purchase ON public.delivery_notes;
CREATE TRIGGER delivery_notes_assign_number_purchase
  BEFORE INSERT ON public.delivery_notes
  FOR EACH ROW WHEN (NEW.direction = 'purchase')
  EXECUTE FUNCTION public.trg_assign_internal_document_number('delivery_note_purchase');

-- Creación: la función parametrizada por TG_ARGV[0] de remitos-venta, sin cambios.
DROP TRIGGER IF EXISTS delivery_notes_record_status_creation_purchase ON public.delivery_notes;
CREATE TRIGGER delivery_notes_record_status_creation_purchase
  AFTER INSERT ON public.delivery_notes
  FOR EACH ROW WHEN (NEW.direction = 'purchase')
  EXECUTE FUNCTION public.trg_delivery_note_record_creation('delivery_note_purchase');

DROP TRIGGER IF EXISTS delivery_notes_enforce_status_transition_purchase ON public.delivery_notes;
CREATE TRIGGER delivery_notes_enforce_status_transition_purchase
  BEFORE UPDATE ON public.delivery_notes
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status AND OLD.direction = 'purchase' AND NEW.direction = 'purchase')
  EXECUTE FUNCTION public.trg_enforce_status_transition('delivery_note_purchase');


-- =============================================================================
-- 3. Rol por sentido (D7): núcleo con nombre propio + el de venta delega
-- =============================================================================
CREATE OR REPLACE FUNCTION public._delivery_note_assert_role_dir(p_account_id uuid, p_mode text, p_direction text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_from  text;
  v_to    text;
  v_roles text[];
  v_label text;
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN ('sale', 'purchase') THEN
    RAISE EXCEPTION 'delivery_note_direction_invalid: %', p_direction USING ERRCODE = 'P0400';
  END IF;

  CASE p_mode
    WHEN 'issue' THEN
      v_from := NULL; v_to := 'issued';
      v_label := CASE p_direction
                   WHEN 'sale' THEN 'emitir o editar remitos (requiere vendedor, stock, administrador o dueño)'
                   ELSE 'emitir o editar remitos de compra (requiere depósito, administrador o dueño)' END;
    WHEN 'void' THEN
      v_from := 'issued'; v_to := 'canceled';
      v_label := CASE p_direction
                   WHEN 'sale' THEN 'anular remitos (requiere administrador o dueño)'
                   ELSE 'anular remitos de compra (requiere administrador o dueño)' END;
    WHEN 'convert' THEN
      v_from := 'issued'; v_to := 'converted';
      v_label := CASE p_direction
                   WHEN 'sale' THEN 'convertir remitos en venta (requiere vendedor, cajero, administrador o dueño)'
                   ELSE 'convertir remitos en compra (requiere compras, depósito, administrador o dueño)' END;
    ELSE
      RAISE EXCEPTION 'delivery_note_role_mode_invalid: %', p_mode USING ERRCODE = 'P0400';
  END CASE;

  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT t.allowed_role INTO v_roles
  FROM   public.document_status_transitions t
  WHERE  t.document_type = 'delivery_note_' || p_direction
    AND  t.from_status IS NOT DISTINCT FROM v_from
    AND  t.to_status = v_to;
  IF v_roles IS NULL THEN
    RAISE EXCEPTION 'delivery_note_role_mode_unavailable: la operación % no está catalogada', p_mode
      USING ERRCODE = 'P0409';
  END IF;

  IF NOT (public.account_user_active_roles(p_account_id, auth.uid()) && v_roles) THEN
    RAISE EXCEPTION 'insufficient_role: tu rol no permite %', v_label USING ERRCODE = 'P0403';
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_assert_role_dir(uuid, text, text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_assert_role_dir(uuid, text, text) IS
  'remitos-compra (D7): is_account_writer (P0401) y roles activos del usuario ∩ allowed_role de la transición del '
  'catálogo delivery_note_<p_direction> que corresponde al modo (issue: NULL->issued, void: issued->canceled, '
  'convert: issued->converted) — P0403 insufficient_role con el rótulo del sentido. Nombre propio (no un overload '
  'de _delivery_note_assert_role): ninguna introspección de una definición por proname queda ambigua. Se evalúa '
  'ANTES de escribir. Interna.';

-- Desde el cuerpo vivo (20261069000001): misma firma, delega con 'sale'.
CREATE OR REPLACE FUNCTION public._delivery_note_assert_role(p_account_id uuid, p_mode text)
RETURNS void
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
BEGIN
  PERFORM public._delivery_note_assert_role_dir(p_account_id, p_mode, 'sale');
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_assert_role(uuid, text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_assert_role(uuid, text) IS
  'remitos-venta (D3/D4/D13): is_account_writer (P0401) y roles activos del usuario ∩ allowed_role de la transición del '
  'catálogo delivery_note_sale que corresponde al modo (issue: NULL->issued, void: issued->canceled, convert: '
  'issued->converted) — P0403 insufficient_role. Se evalúa ANTES de escribir. Interna. remitos-compra (D7): delega en '
  '_delivery_note_assert_role_dir(p_account_id, p_mode, ''sale'').';


-- =============================================================================
-- 4. Helpers de stock por sentido (D4), desde el cuerpo vivo, misma firma
-- =============================================================================
-- El "efecto del remito" sobre el stock es -held en venta y +held en compra.
-- El sentido sale de la fila persistida del remito (el caller ya la tiene
-- bloqueada o recién insertada), nunca de un parámetro.
CREATE OR REPLACE FUNCTION public._delivery_note_apply_stock(p_account_id uuid, p_dn_id uuid, p_op_group uuid, p_pairs jsonb)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_pair   jsonb;
  v_pid    uuid;
  v_bid    uuid;
  v_qty    numeric;
  v_before numeric;
  v_uid    uuid := auth.uid();
  v_dir    text;
BEGIN
  SELECT dn.direction INTO v_dir FROM public.delivery_notes dn WHERE dn.id = p_dn_id;
  IF v_dir IS NULL THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_dn_id USING ERRCODE = 'P0404';
  END IF;

  FOR v_pair IN SELECT e FROM jsonb_array_elements(COALESCE(p_pairs, '[]'::jsonb)) AS e LOOP
    v_pid := (v_pair->>'product_id')::uuid;
    v_bid := (v_pair->>'branch_id')::uuid;
    v_qty := (v_pair->>'quantity')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(bs.quantity, 0) INTO v_before
    FROM   public.branch_stock bs
    WHERE  bs.product_id = v_pid AND bs.branch_id = v_bid
    FOR UPDATE;
    v_before := COALESCE(v_before, 0);

    IF v_dir = 'sale' THEN
      -- Mismo literal que el núcleo de la venta (la UI ya lo traduce).
      IF v_before < v_qty THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_pid, v_before, v_qty
          USING ERRCODE = 'P0409';
      END IF;

      PERFORM public.c21_apply_branch_stock_delta(p_account_id, v_pid, v_bid, -v_qty);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot, metadata
      ) VALUES (
        v_uid, p_account_id, v_pid, v_pair->>'product_name', 'sale',
        -v_qty, v_before, v_before - v_qty,
        p_dn_id, 'delivery_note', v_uid,
        p_op_group, v_bid, (v_pair->>'unit_cost')::numeric,
        jsonb_build_object('delivery_note_item_ids', COALESCE(v_pair->'item_ids', '[]'::jsonb))
      );
    ELSE
      -- Compra: entra mercadería, no hay faltante que controlar.
      PERFORM public.c21_apply_branch_stock_delta(p_account_id, v_pid, v_bid, v_qty);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot, metadata
      ) VALUES (
        v_uid, p_account_id, v_pid, v_pair->>'product_name', 'purchase',
        v_qty, v_before, v_before + v_qty,
        p_dn_id, 'delivery_note', v_uid,
        p_op_group, v_bid, (v_pair->>'unit_cost')::numeric,
        jsonb_build_object('delivery_note_item_ids', COALESCE(v_pair->'item_ids', '[]'::jsonb))
      );
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb) IS
  'remitos-venta (D4/D5): ÚNICO lugar donde el remito descuenta stock. Por cada par recibido (la emisión pasa todos; la edición, sólo los que cambian): gate branch_stock >= requerido (P0409 stock_insuficiente, mismo literal que el núcleo de la venta), c21_apply_branch_stock_delta(-requerido) y movimiento type = sale, reference_type = delivery_note con quantity_before/after, costo congelado y metadata.delivery_note_item_ids. No lee las líneas ni el ledger. Interna. '
  'remitos-compra (D4): pone el efecto del remito según delivery_notes.direction (leído de la fila, nunca de un parámetro): en compra SUMA sin gate (c21_apply_branch_stock_delta(+aportado), type = purchase, reference_type = delivery_note).';

CREATE OR REPLACE FUNCTION public._delivery_note_reverse_held(p_account_id uuid, p_dn_id uuid, p_op_group uuid, p_pairs jsonb, p_reference_type text, p_reverses text)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_pair   jsonb;
  v_pid    uuid;
  v_bid    uuid;
  v_qty    numeric;
  v_before numeric;
  v_uid    uuid := auth.uid();
  v_dir    text;
BEGIN
  IF p_reference_type NOT IN ('delivery_note_update', 'delivery_note_reversal') THEN
    RAISE EXCEPTION 'delivery_note_reverse_invalid_reference: %', p_reference_type USING ERRCODE = 'P0400';
  END IF;

  SELECT dn.direction INTO v_dir FROM public.delivery_notes dn WHERE dn.id = p_dn_id;
  IF v_dir IS NULL THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_dn_id USING ERRCODE = 'P0404';
  END IF;

  FOR v_pair IN SELECT e FROM jsonb_array_elements(COALESCE(p_pairs, '[]'::jsonb)) AS e LOOP
    v_pid := (v_pair->>'product_id')::uuid;
    v_bid := (v_pair->>'branch_id')::uuid;
    v_qty := (v_pair->>'quantity')::numeric;
    IF v_qty IS NULL OR v_qty <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(bs.quantity, 0) INTO v_before
    FROM   public.branch_stock bs
    WHERE  bs.product_id = v_pid AND bs.branch_id = v_bid
    FOR UPDATE;
    v_before := COALESCE(v_before, 0);

    IF v_dir = 'sale' THEN
      PERFORM public.c21_apply_branch_stock_delta(p_account_id, v_pid, v_bid, v_qty);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot, metadata
      ) VALUES (
        v_uid, p_account_id, v_pid, v_pair->>'product_name', 'sale_return',
        v_qty, v_before, v_before + v_qty,
        p_dn_id, p_reference_type, v_uid,
        p_op_group, v_bid, (v_pair->>'unit_cost')::numeric,
        jsonb_build_object('reverses', p_reverses,
                           'delivery_note_item_ids', COALESCE(v_pair->'item_ids', '[]'::jsonb))
      );
    ELSE
      -- Compra: la pata RESTA. Gate explícito antes del delta: sin él, el
      -- CHECK (quantity >= 0) de branch_stock abortaría con 23514. El texto
      -- no atribuye origen (el stock de la sucursal mezcla otras entradas).
      IF v_before < v_qty THEN
        RAISE EXCEPTION 'delivery_note_stock_consumed: de % en la sucursal quedan %, el remito necesita restar %',
          COALESCE(v_pair->>'product_name', v_pid::text), trim_scale(v_before), trim_scale(v_qty)
          USING ERRCODE = 'P0409';
      END IF;

      PERFORM public.c21_apply_branch_stock_delta(p_account_id, v_pid, v_bid, -v_qty);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot, metadata
      ) VALUES (
        v_uid, p_account_id, v_pid, v_pair->>'product_name', 'purchase_return',
        -v_qty, v_before, v_before - v_qty,
        p_dn_id, p_reference_type, v_uid,
        p_op_group, v_bid, (v_pair->>'unit_cost')::numeric,
        jsonb_build_object('reverses', p_reverses,
                           'delivery_note_item_ids', COALESCE(v_pair->'item_ids', '[]'::jsonb))
      );
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text) IS
  'remitos-venta (D4/D5/D16): devuelve al stock lo retenido sobre los pares recibidos (de _delivery_note_held_pairs): c21_apply_branch_stock_delta(+retenido) y movimiento type = sale_return con reference_type delivery_note_update (edición) o delivery_note_reversal (anulación) y metadata.reverses. No lee el ledger. Interna. '
  'remitos-compra (D4): quita el efecto del remito según delivery_notes.direction: en compra RESTA lo aportado con gate previo (P0409 delivery_note_stock_consumed: de <producto> en la sucursal quedan <stock>, el remito necesita restar <cantidad>; nunca 23514) y type = purchase_return.';


-- =============================================================================
-- 5. Payload (D7), desde el cuerpo vivo de 20261070000001
-- =============================================================================
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
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_payload(uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_payload(uuid) IS
  'remitos-venta: fila de delivery_notes + document_type, nombres de cliente y sucursal, líneas en orden de carga (con símbolo de unidad y si el producto fue dado de baja) e historial de estados. converted_sales_order_id/converted_operation_id: la orden VIVA (no cancelada) nacida del remito (tanda B), NULL si no está convertido. Interna. '
  'remitos-compra (D7): suma supplier_name, supplier_phone y supplier_deleted (proveedor filtrado por la cuenta del remito) y missing_price_count (líneas con price = 0).';


-- =============================================================================
-- 6. Núcleo de edición (D5), extraído del cuerpo vivo de rpc_update_delivery_note
-- =============================================================================
CREATE OR REPLACE FUNCTION public._delivery_note_replace_content(p_dn_id uuid, p_branch_id uuid, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  v_dn       RECORD;
  v_products uuid[];
  v_old      jsonb;
  v_new      jsonb;
  v_valid    jsonb;
  v_carry    jsonb;
  v_rev      jsonb;
  v_app      jsonb;
  v_op_group uuid;
  v_short    RECORD;
  v_stock    numeric;
BEGIN
  -- El caller ya tiene el remito bloqueado (FOR UPDATE) y validada la cabecera.
  SELECT dn.id, dn.account_id, dn.direction INTO v_dn
  FROM   public.delivery_notes dn
  WHERE  dn.id = p_dn_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_dn_id USING ERRCODE = 'P0404';
  END IF;

  -- Lock de la unión de productos (vigentes + nuevos) ANTES de validar.
  SELECT array_agg(DISTINCT x.pid) INTO v_products
  FROM (
    SELECT i.product_id AS pid FROM public.delivery_note_items i WHERE i.delivery_note_id = v_dn.id
    UNION
    SELECT NULLIF(e->>'product_id', '')::uuid FROM jsonb_array_elements(p_items) AS e WHERE jsonb_typeof(e) = 'object'
  ) x
  WHERE x.pid IS NOT NULL;
  PERFORM public._delivery_note_lock_products(v_dn.account_id, v_products);

  -- Lo retenido / aportado por las líneas VIGENTES, antes de tocarlas (con la
  -- sucursal vieja todavía en la cabecera).
  v_old := public._delivery_note_held_pairs(v_dn.id);

  v_valid := public._delivery_note_validate_items(v_dn.account_id, p_branch_id, p_items, v_old);

  -- Política canónica de operaciones (D6 de venta): el producto que sigue
  -- acarrea sus cuatro snapshots (ante varias líneas, la de menor line_no).
  SELECT COALESCE(jsonb_object_agg(s.product_id::text, jsonb_build_object(
           'name_snapshot', s.name_snapshot, 'sku_snapshot', s.sku_snapshot,
           'unit_cost_snapshot', s.unit_cost_snapshot, 'iva_rate_snapshot', s.iva_rate_snapshot)), '{}'::jsonb)
  INTO   v_carry
  FROM  (SELECT DISTINCT ON (i.product_id) i.product_id, i.name_snapshot, i.sku_snapshot,
                i.unit_cost_snapshot, i.iva_rate_snapshot
         FROM   public.delivery_note_items i
         WHERE  i.delivery_note_id = v_dn.id
         ORDER BY i.product_id, i.line_no, i.id) s;

  DELETE FROM public.delivery_note_items WHERE delivery_note_id = v_dn.id;

  -- _delivery_note_held_pairs lee la sucursal de la cabecera: se fija ANTES de
  -- recalcular lo retenido nuevo, así un cambio de sucursal mueve el stock
  -- aunque las cantidades no cambien. El resto de la cabecera lo escribe cada RPC.
  UPDATE public.delivery_notes SET branch_id = p_branch_id WHERE id = v_dn.id;

  PERFORM public._delivery_note_insert_items(v_dn.account_id, v_dn.id, v_valid->'lines', v_carry);

  v_new := public._delivery_note_held_pairs(v_dn.id);

  -- Pares que cambian: retenido <> requerido por (producto, sucursal). Los
  -- demás no escriben nada (una edición de precio no ensucia el kardex).
  WITH o AS (
    SELECT e, (e->>'product_id')::uuid AS pid, (e->>'branch_id')::uuid AS bid, (e->>'quantity')::numeric AS qty
    FROM jsonb_array_elements(v_old) e
  ), n AS (
    SELECT e, (e->>'product_id')::uuid AS pid, (e->>'branch_id')::uuid AS bid, (e->>'quantity')::numeric AS qty
    FROM jsonb_array_elements(v_new) e
  ), changed AS (
    SELECT o.e AS old_e, n.e AS new_e
    FROM o FULL JOIN n ON n.pid = o.pid AND n.bid = o.bid
    WHERE COALESCE(o.qty, 0) <> COALESCE(n.qty, 0)
  )
  SELECT COALESCE(jsonb_agg(old_e) FILTER (WHERE old_e IS NOT NULL), '[]'::jsonb),
         COALESCE(jsonb_agg(new_e) FILTER (WHERE new_e IS NOT NULL), '[]'::jsonb)
  INTO   v_rev, v_app
  FROM   changed;

  v_op_group := gen_random_uuid();

  IF v_dn.direction = 'purchase' THEN
    -- Compra: faltante sobre el NETO por par, antes de escribir cualquier pata,
    -- con el stock anterior a la edición y lo que el usuario realmente resta.
    FOR v_short IN
      WITH o AS (
        SELECT (e->>'product_id')::uuid AS pid, (e->>'branch_id')::uuid AS bid,
               (e->>'quantity')::numeric AS qty, e->>'product_name' AS pname
        FROM jsonb_array_elements(v_old) e
      ), n AS (
        SELECT (e->>'product_id')::uuid AS pid, (e->>'branch_id')::uuid AS bid,
               (e->>'quantity')::numeric AS qty
        FROM jsonb_array_elements(v_new) e
      )
      SELECT o.pid, o.bid, o.pname, COALESCE(n.qty, 0) - o.qty AS net
      FROM   o LEFT JOIN n ON n.pid = o.pid AND n.bid = o.bid
      WHERE  COALESCE(n.qty, 0) - o.qty < 0
      ORDER BY o.pid, o.bid
    LOOP
      SELECT COALESCE(bs.quantity, 0) INTO v_stock
      FROM   public.branch_stock bs
      WHERE  bs.product_id = v_short.pid AND bs.branch_id = v_short.bid;
      v_stock := COALESCE(v_stock, 0);
      IF v_stock < -v_short.net THEN
        RAISE EXCEPTION 'delivery_note_stock_consumed: de % en la sucursal quedan %, el remito necesita restar %',
          COALESCE(v_short.pname, v_short.pid::text), trim_scale(v_stock), trim_scale(-v_short.net)
          USING ERRCODE = 'P0409';
      END IF;
    END LOOP;

    -- Las patas que SUMAN primero (aplicación), después las que restan: el
    -- gate de la reversa ve el neto.
    PERFORM public._delivery_note_apply_stock(v_dn.account_id, v_dn.id, v_op_group, v_app);
    PERFORM public._delivery_note_reverse_held(v_dn.account_id, v_dn.id, v_op_group, v_rev,
                                               'delivery_note_update', 'delivery_note_edit');
  ELSE
    -- Venta (orden vivo): la reversa suma primero; el control de faltante de la
    -- aplicación es sobre el neto.
    PERFORM public._delivery_note_reverse_held(v_dn.account_id, v_dn.id, v_op_group, v_rev,
                                               'delivery_note_update', 'delivery_note_edit');
    PERFORM public._delivery_note_apply_stock(v_dn.account_id, v_dn.id, v_op_group, v_app);
  END IF;

  RETURN v_valid;
END;
$function$;

REVOKE ALL ON FUNCTION public._delivery_note_replace_content(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._delivery_note_replace_content(uuid, uuid, jsonb) IS
  'remitos-compra (D5): núcleo de edición compartido por los dos sentidos, extraído del cuerpo vivo de '
  'rpc_update_delivery_note y en su mismo orden: lock de la unión de productos por id -> retenido viejo '
  '(_delivery_note_held_pairs) -> _delivery_note_validate_items -> acarreo de los cuatro snapshots -> DELETE de líneas '
  '-> UPDATE delivery_notes.branch_id (ANTES de recalcular lo retenido nuevo) -> INSERT de líneas -> retenido nuevo -> '
  'pares que cambian. En compra, chequeo del neto por par antes de cualquier pata (P0409 delivery_note_stock_consumed con '
  'el stock previo y lo que se resta). Patas que SUMAN primero: venta reversa -> aplicación, compra aplicación -> reversa. '
  'Devuelve el resultado de la validación (lines, total). La cabecera, el total y revision los escribe cada RPC. El caller '
  'tiene el remito bloqueado. Interna.';


-- =============================================================================
-- 7. rpc_update_delivery_note (venta), desde el cuerpo vivo: llama al núcleo.
--    Único cambio de forma: el UPDATE vivo se parte en dos (branch_id lo fija
--    el núcleo; cliente, domicilio, notas, total y revision, esta RPC).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_update_delivery_note(p_delivery_note_id uuid, p_expected_revision integer, p_client_id uuid, p_branch_id uuid, p_delivery_address text, p_notes text, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid      uuid;
  v_dn       RECORD;
  v_branch   RECORD;
  v_address  text;
  v_notes    text;
  v_valid    jsonb;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_dn
  FROM   public.delivery_notes
  WHERE  id = p_delivery_note_id
    AND  account_id IN (SELECT public.current_account_ids())
    AND  direction = 'sale'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role(v_dn.account_id, 'issue');

  IF v_dn.status = 'converted' THEN
    RAISE EXCEPTION 'delivery_note_locked_converted: el remito ya se convirtió en venta: para corregirlo, eliminá la venta y el remito vuelve a quedar pendiente'
      USING ERRCODE = 'P0423';
  END IF;
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede editar', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se editó' USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  IF p_client_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.clients
    WHERE id = p_client_id AND account_id = v_dn.account_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  -- La pata de reversa escribe en la sucursal VIGENTE: autosuficiente, no
  -- delega en el guard de baja de sucursal (D5, D9).
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_dn.branch_id AND is_active = TRUE AND status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada — reactivala para editar el remito'
      USING ERRCODE = 'P0422';
  END IF;

  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_branch_required: el remito necesita la sucursal de la que sale la mercadería'
      USING ERRCODE = 'P0400';
  END IF;
  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_dn.account_id AND is_active = TRUE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
  END IF;
  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Reemplazo completo: NULL significa vacío (la UI manda el valor vigente).
  v_address := NULLIF(btrim(COALESCE(p_delivery_address, '')), '');
  IF v_address IS NOT NULL AND char_length(v_address) > 500 THEN
    RAISE EXCEPTION 'delivery_note_address_too_long: el domicilio admite hasta 500 caracteres' USING ERRCODE = 'P0400';
  END IF;
  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'delivery_note_items_required: el remito necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;

  -- remitos-compra (D5): el reemplazo de líneas y las patas de stock viven en
  -- el núcleo compartido (fija branch_id antes de recalcular lo retenido).
  v_valid := public._delivery_note_replace_content(v_dn.id, p_branch_id, p_items);

  UPDATE public.delivery_notes
  SET    client_id        = p_client_id,
         delivery_address = v_address,
         notes            = v_notes,
         total            = (v_valid->>'total')::numeric,
         updated_at       = now(),
         updated_by       = v_uid,
         revision         = revision + 1
  WHERE  id = v_dn.id;

  RETURN public._delivery_note_payload(v_dn.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) IS
  'remitos-venta (D5/D6): reemplazo atómico de un remito issued bajo FOR UPDATE (P0404 delivery_note_not_found si es ajeno o no existe; P0423 delivery_note_locked_converted; P0409 delivery_note_invalid_state; P0409 delivery_note_changed ante una versión vieja). Rol issue, cliente vivo, sucursal vigente y nueva activas y no cerradas (P0422 delivery_note_branch_inactive / branch_closed). Productos bloqueados antes de validar; retenido de las líneas vigentes (_delivery_note_held_pairs, nunca el ledger) contra requerido normalizado: sólo los pares que cambian reciben reversa (sale_return/delivery_note_update) y después aplicación (sale/delivery_note, faltante sobre el neto). Snapshots acarreados por producto. revision + 1, sin historial de estados. '
  'remitos-compra (D5): el reemplazo lo hace _delivery_note_replace_content (compartido con el sentido compra); esta RPC escribe después cliente, domicilio, notas, total y revision.';


-- =============================================================================
-- 8. rpc_cancel_delivery_note para los dos sentidos (D6), desde el cuerpo vivo
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_cancel_delivery_note(p_delivery_note_id uuid, p_expected_revision integer, p_reason text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid      uuid;
  v_dn       RECORD;
  v_reason   text;
  v_products uuid[];
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- remitos-compra (D6): sin filtro de sentido; rol, historial y textos salen
  -- de la fila del remito.
  SELECT * INTO v_dn
  FROM   public.delivery_notes
  WHERE  id = p_delivery_note_id
    AND  account_id IN (SELECT public.current_account_ids())
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role_dir(v_dn.account_id, 'void', v_dn.direction);

  IF v_dn.status = 'converted' THEN
    IF v_dn.direction = 'purchase' THEN
      RAISE EXCEPTION 'delivery_note_locked_converted: el remito ya se convirtió en compra: para anularlo, primero eliminá la compra'
        USING ERRCODE = 'P0423';
    END IF;
    RAISE EXCEPTION 'delivery_note_locked_converted: el remito ya se convirtió en venta: para anularlo, primero eliminá la venta'
      USING ERRCODE = 'P0423';
  END IF;
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede anular', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se anula' USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  v_reason := NULLIF(btrim(COALESCE(p_reason, '')), '');
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'delivery_note_cancel_reason_required: anular un remito exige un motivo' USING ERRCODE = 'P0400';
  END IF;
  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'delivery_note_cancel_reason_too_long: el motivo admite hasta 500 caracteres' USING ERRCODE = 'P0400';
  END IF;

  -- Autosuficiente (D9/D16): nunca mover stock en una sucursal que no opera.
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_dn.branch_id AND is_active = TRUE AND status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada — reactivala para anular el remito'
      USING ERRCODE = 'P0422';
  END IF;

  -- Lock de los productos ANTES de leer branch_stock (D16 paso 7).
  SELECT array_agg(DISTINCT i.product_id) INTO v_products
  FROM   public.delivery_note_items i WHERE i.delivery_note_id = v_dn.id;
  PERFORM public._delivery_note_lock_products(v_dn.account_id, v_products);

  -- Venta: repone lo retenido. Compra: resta lo aportado, con gate
  -- (P0409 delivery_note_stock_consumed si ya se consumió; el RAISE revierte
  -- todo, ningún par queda restado a medias).
  PERFORM public._delivery_note_reverse_held(v_dn.account_id, v_dn.id, gen_random_uuid(),
                                             public._delivery_note_held_pairs(v_dn.id),
                                             'delivery_note_reversal', 'delivery_note_cancel');

  PERFORM public.record_status_transition(v_dn.account_id, 'delivery_note_' || v_dn.direction, v_dn.id,
                                          'issued', 'canceled', v_uid, v_reason);
  UPDATE public.delivery_notes
  SET    status = 'canceled', updated_at = now(), updated_by = v_uid
  WHERE  id = v_dn.id;

  RETURN public._delivery_note_payload(v_dn.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_cancel_delivery_note(uuid, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_cancel_delivery_note(uuid, integer, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_cancel_delivery_note(uuid, integer, text) IS
  'remitos-venta (D16, R3): anula un remito issued bajo FOR UPDATE. Rol void ({admin,owner}, P0403); converted -> P0423 delivery_note_locked_converted; canceled -> P0409 delivery_note_invalid_state; versión (P0409 delivery_note_changed); motivo obligatorio (P0400 delivery_note_cancel_reason_required); sucursal del remito activa y no cerrada (P0422 delivery_note_branch_inactive, sin efectos). Bloquea los productos antes de leer el stock y repone TODO lo retenido (sale_return/delivery_note_reversal) desde las líneas, nunca desde el ledger. Historial issued -> canceled con el motivo y el actor. '
  'remitos-compra (D6, R3/R6): sirve a los dos sentidos. El rol void, el tipo del historial (delivery_note_<direction>) y el texto de P0423 salen del remito; en compra resta lo aportado (purchase_return/delivery_note_reversal) y rechaza con P0409 delivery_note_stock_consumed, sin efectos, si la mercadería ya se consumió.';


-- =============================================================================
-- 9. rpc_create_purchase_delivery_note (D4)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_delivery_note(
  p_idempotency_key    text,
  p_supplier_id        uuid,
  p_branch_id          uuid,
  p_supplier_reference text,
  p_notes              text,
  p_items              jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid         uuid;
  v_dn_id       uuid;
  v_inserted    integer;
  v_existing_op uuid;
  v_account_id  uuid;
  v_branch      RECORD;
  v_reference   text;
  v_notes       text;
  v_items       jsonb;
  v_products    uuid[];
  v_valid       jsonb;
  v_total       numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_idempotency_key IS NULL OR btrim(p_idempotency_key) = '' THEN
    RAISE EXCEPTION 'idempotency_key_required: la emisión del remito necesita una clave de idempotencia'
      USING ERRCODE = 'P0400';
  END IF;

  -- DEC-06, molde de rpc_create_sale_delivery_note: la fila se inserta ANTES de
  -- escribir y revierte con el remito; un envío concurrente con la misma clave
  -- espera acá al primero y cae en DO NOTHING (nunca un 23505).
  v_dn_id := gen_random_uuid();
  INSERT INTO public.operation_idempotency (user_id, operation_kind, idempotency_key, operation_id)
  VALUES (v_uid, 'delivery_note_purchase', p_idempotency_key, v_dn_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;
  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid AND operation_kind = 'delivery_note_purchase' AND idempotency_key = p_idempotency_key;
    IF v_existing_op IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.delivery_notes dn
      WHERE dn.id = v_existing_op AND dn.direction = 'purchase'
        AND dn.account_id IN (SELECT public.current_account_ids())
    ) THEN
      RETURN public._delivery_note_payload(v_existing_op) || jsonb_build_object('replayed', true);
    END IF;
    RAISE EXCEPTION 'idempotency_key_conflict: la clave ya se usó para otra operación' USING ERRCODE = 'P0409';
  END IF;

  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_supplier_required: el remito de compra necesita un proveedor' USING ERRCODE = 'P0400';
  END IF;

  -- La cuenta es la del proveedor, entre las del usuario: determinista aunque
  -- el usuario tenga varias membresías.
  SELECT s.account_id INTO v_account_id
  FROM   public.suppliers s
  WHERE  s.id = p_supplier_id
    AND  s.account_id IN (SELECT public.current_account_ids());
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role_dir(v_account_id, 'issue', 'purchase');

  IF NOT EXISTS (SELECT 1 FROM public.suppliers WHERE id = p_supplier_id AND deleted_at IS NULL) THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_branch_required: el remito de compra necesita la sucursal a la que entra la mercadería'
      USING ERRCODE = 'P0400';
  END IF;
  -- FOR SHARE antes de sumar stock: serializa contra la baja de una sucursal
  -- VACÍA (el guard de baja sólo ve existencias y remitos ya confirmados). Si
  -- la baja llegó primero, se relee desactivada y se rechaza con P0422; si
  -- llegó la recepción primero, la baja espera y ve el remito (P0428).
  SELECT id, is_active, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id
  FOR SHARE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
  END IF;
  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;
  IF NOT v_branch.is_active THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal a la que entra la mercadería está desactivada — reactivala o elegí otra'
      USING ERRCODE = 'P0422';
  END IF;

  v_reference := NULLIF(btrim(COALESCE(p_supplier_reference, '')), '');
  IF v_reference IS NOT NULL AND char_length(v_reference) > 100 THEN
    RAISE EXCEPTION 'delivery_note_supplier_reference_too_long: el número del remito del proveedor admite hasta 100 caracteres'
      USING ERRCODE = 'P0400';
  END IF;
  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'delivery_note_items_required: el remito necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;

  -- D1: el subtotal de cada línea lo calcula el servidor (precio x cantidad,
  -- redondeado a 2), ignorando el que mande el cliente.
  SELECT jsonb_agg(CASE
           WHEN jsonb_typeof(e) = 'object'
            AND (e->>'price')    ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
            AND (e->>'quantity') ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
           THEN e || jsonb_build_object('subtotal', round((e->>'price')::numeric * (e->>'quantity')::numeric, 2))
           ELSE e END ORDER BY o)
  INTO   v_items
  FROM   jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o);

  -- Lock de los productos ANTES de validarlos (TOCTOU).
  SELECT array_agg(DISTINCT NULLIF(e->>'product_id', '')::uuid) INTO v_products
  FROM   jsonb_array_elements(v_items) AS e
  WHERE  jsonb_typeof(e) = 'object';
  PERFORM public._delivery_note_lock_products(v_account_id, v_products);

  v_valid := public._delivery_note_validate_items(v_account_id, p_branch_id, v_items, NULL);

  -- D1: total = round(Σ precio x cantidad, 2), la misma regla que el núcleo de
  -- la compra: la compra nacida de este remito tiene el mismo total.
  SELECT round(COALESCE(sum((l->>'price')::numeric * (l->>'quantity')::numeric), 0), 2)
  INTO   v_total
  FROM   jsonb_array_elements(v_valid->'lines') AS l;

  -- delivery_notes_assign_number_purchase numera (RC) y
  -- delivery_notes_record_status_creation_purchase registra NULL -> issued.
  INSERT INTO public.delivery_notes
    (id, account_id, direction, branch_id, supplier_id, supplier_reference, status, issued_on,
     notes, total, created_by)
  VALUES
    (v_dn_id, v_account_id, 'purchase', p_branch_id, p_supplier_id, v_reference, 'issued', public.reporting_local_today(),
     v_notes, v_total, v_uid);

  PERFORM public._delivery_note_insert_items(v_account_id, v_dn_id, v_valid->'lines', NULL);

  PERFORM public._delivery_note_apply_stock(v_account_id, v_dn_id, gen_random_uuid(),
                                            public._delivery_note_held_pairs(v_dn_id));

  RETURN public._delivery_note_payload(v_dn_id) || jsonb_build_object('replayed', false);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_purchase_delivery_note(text, uuid, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_delivery_note(text, uuid, uuid, text, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_create_purchase_delivery_note(text, uuid, uuid, text, text, jsonb) IS
  'remitos-compra (D4): emite un remito de compra y SUMA el stock de la sucursal de destino en la misma transacción. '
  'Idempotente por (usuario, delivery_note_purchase, clave), molde DEC-06 (replay -> mismo remito con replayed = true; clave '
  'de otra operación -> P0409 idempotency_key_conflict). Proveedor obligatorio (P0400 delivery_note_supplier_required), vivo y '
  'de las cuentas del usuario (P0404 supplier_not_found; la cuenta es la del proveedor), rol issue de compra antes de escribir '
  '({stock,admin,owner}, P0401/P0403), sucursal obligatoria, de la cuenta (P0404), no cerrada (P0422 branch_closed) y activa '
  '(P0422 delivery_note_branch_inactive), leída FOR SHARE; número del proveedor <= 100 y notas <= 2.000; productos bloqueados '
  'en orden de id ANTES de validar; subtotales y total del servidor (round(Σ precio x cantidad, 2)); precio 0 admitido; costo '
  'congelado = costo de catálogo. Movimiento purchase/delivery_note por par. No toca caja, banco, cuenta corriente, outbox ni '
  'products.cost.';


-- =============================================================================
-- 10. rpc_update_purchase_delivery_note (D5)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_update_purchase_delivery_note(
  p_delivery_note_id   uuid,
  p_expected_revision  integer,
  p_supplier_id        uuid,
  p_branch_id          uuid,
  p_supplier_reference text,
  p_notes              text,
  p_items              jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid       uuid;
  v_dn        RECORD;
  v_branch    RECORD;
  v_reference text;
  v_notes     text;
  v_items     jsonb;
  v_valid     jsonb;
  v_total     numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT * INTO v_dn
  FROM   public.delivery_notes
  WHERE  id = p_delivery_note_id
    AND  account_id IN (SELECT public.current_account_ids())
    AND  direction = 'purchase'
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'delivery_note_not_found: %', p_delivery_note_id USING ERRCODE = 'P0404';
  END IF;

  PERFORM public._delivery_note_assert_role_dir(v_dn.account_id, 'issue', 'purchase');

  IF v_dn.status = 'converted' THEN
    RAISE EXCEPTION 'delivery_note_locked_converted: el remito ya se convirtió en compra: para corregirlo, eliminá la compra y el remito vuelve a quedar pendiente'
      USING ERRCODE = 'P0423';
  END IF;
  IF v_dn.status <> 'issued' THEN
    RAISE EXCEPTION 'delivery_note_invalid_state: el remito está % y no se puede editar', v_dn.status
      USING ERRCODE = 'P0409';
  END IF;
  IF p_expected_revision IS NULL THEN
    RAISE EXCEPTION 'delivery_note_revision_required: falta la versión del remito que se editó' USING ERRCODE = 'P0400';
  END IF;
  IF p_expected_revision <> v_dn.revision THEN
    RAISE EXCEPTION 'delivery_note_changed: el remito cambió desde que lo abriste (versión % vs %) — recargalo',
      p_expected_revision, v_dn.revision
      USING ERRCODE = 'P0409';
  END IF;

  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_supplier_required: el remito de compra necesita un proveedor' USING ERRCODE = 'P0400';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.suppliers
    WHERE id = p_supplier_id AND account_id = v_dn.account_id AND deleted_at IS NULL
  ) THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  -- La pata que resta escribe en la sucursal VIGENTE: autosuficiente.
  IF NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_dn.branch_id AND is_active = TRUE AND status IS DISTINCT FROM 'closed'
  ) THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito está desactivada o cerrada — reactivala para editar el remito'
      USING ERRCODE = 'P0422';
  END IF;

  IF p_branch_id IS NULL THEN
    RAISE EXCEPTION 'delivery_note_branch_required: el remito de compra necesita la sucursal a la que entra la mercadería'
      USING ERRCODE = 'P0400';
  END IF;
  -- La sucursal nueva, FOR SHARE si cambia (misma carrera contra la baja de una
  -- sucursal vacía que la emisión, D4).
  IF p_branch_id IS DISTINCT FROM v_dn.branch_id THEN
    SELECT id, is_active, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_dn.account_id
    FOR SHARE;
  ELSE
    SELECT id, is_active, status INTO v_branch
    FROM   public.branches
    WHERE  id = p_branch_id AND account_id = v_dn.account_id;
  END IF;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found or not active for this account' USING ERRCODE = 'P0404';
  END IF;
  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;
  IF NOT v_branch.is_active THEN
    RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal a la que entra la mercadería está desactivada — reactivala o elegí otra'
      USING ERRCODE = 'P0422';
  END IF;

  -- Reemplazo completo: NULL significa vacío (la UI manda el valor vigente).
  v_reference := NULLIF(btrim(COALESCE(p_supplier_reference, '')), '');
  IF v_reference IS NOT NULL AND char_length(v_reference) > 100 THEN
    RAISE EXCEPTION 'delivery_note_supplier_reference_too_long: el número del remito del proveedor admite hasta 100 caracteres'
      USING ERRCODE = 'P0400';
  END IF;
  v_notes := NULLIF(btrim(COALESCE(p_notes, '')), '');
  IF v_notes IS NOT NULL AND char_length(v_notes) > 2000 THEN
    RAISE EXCEPTION 'delivery_note_notes_too_long: las notas admiten hasta 2.000 caracteres' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'delivery_note_items_required: el remito necesita al menos una línea' USING ERRCODE = 'P0400';
  END IF;

  -- D1: subtotales del servidor.
  SELECT jsonb_agg(CASE
           WHEN jsonb_typeof(e) = 'object'
            AND (e->>'price')    ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
            AND (e->>'quantity') ~ '^\s*-?[0-9]+(\.[0-9]+)?\s*$'
           THEN e || jsonb_build_object('subtotal', round((e->>'price')::numeric * (e->>'quantity')::numeric, 2))
           ELSE e END ORDER BY o)
  INTO   v_items
  FROM   jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o);

  -- Núcleo compartido (D5): fija branch_id antes de recalcular lo aportado,
  -- chequea el neto por par y aplica las patas que suman primero.
  v_valid := public._delivery_note_replace_content(v_dn.id, p_branch_id, v_items);

  SELECT round(COALESCE(sum((l->>'price')::numeric * (l->>'quantity')::numeric), 0), 2)
  INTO   v_total
  FROM   jsonb_array_elements(v_valid->'lines') AS l;

  UPDATE public.delivery_notes
  SET    supplier_id        = p_supplier_id,
         supplier_reference = v_reference,
         notes              = v_notes,
         total              = v_total,
         updated_at         = now(),
         updated_by         = v_uid,
         revision           = revision + 1
  WHERE  id = v_dn.id;

  RETURN public._delivery_note_payload(v_dn.id);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_update_purchase_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_purchase_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_purchase_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb) IS
  'remitos-compra (D5, R4): reemplazo atómico de un remito de compra issued bajo FOR UPDATE (un remito de venta o ajeno -> '
  'P0404 delivery_note_not_found; converted -> P0423 delivery_note_locked_converted; canceled -> P0409 '
  'delivery_note_invalid_state; versión vieja -> P0409 delivery_note_changed). Rol issue de compra, proveedor vivo de la cuenta, '
  'sucursal vigente activa y no cerrada (P0422 delivery_note_branch_inactive) y nueva de la cuenta, activa y no cerrada (FOR SHARE '
  'si cambia). Subtotales y total del servidor. El reemplazo lo hace _delivery_note_replace_content: sólo los pares que cambian '
  'escriben movimientos, la aplicación (purchase/delivery_note) antes que la reversa (purchase_return/delivery_note_update) y, '
  'antes de cualquier pata, el faltante sobre el neto por par (P0409 delivery_note_stock_consumed, sin efectos). revision + 1, '
  'sin historial de estados.';


-- =============================================================================
-- 11. Introspección (D16). Falla la migración si algo no quedó como se diseñó.
-- =============================================================================
DO $$
DECLARE
  v_bad  text[] := '{}';
  v_fn   text;
  v_src  text;
  v_def  text;
  v_c    text;
  v_v    text;
  v_spec record;
  v_rpcs text[] := ARRAY[
    'public.rpc_create_purchase_delivery_note(text, uuid, uuid, text, text, jsonb)',
    'public.rpc_update_purchase_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)',
    'public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)',
    'public.rpc_cancel_delivery_note(uuid, integer, text)'
  ];
  v_internal text[] := ARRAY[
    'public._delivery_note_assert_role_dir(uuid, text, text)',
    'public._delivery_note_assert_role(uuid, text)',
    'public._delivery_note_replace_content(uuid, uuid, jsonb)',
    'public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb)',
    'public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text)',
    'public._delivery_note_payload(uuid)'
  ];
BEGIN
  -- CHECK: el valor nuevo Y los previos (nunca una lista que pierda valores).
  FOR v_spec IN
    SELECT * FROM (VALUES
      ('internal_document_sequences_document_type_check', ARRAY['quote', 'delivery_note_sale']),
      ('document_status_history_document_type_check',     ARRAY['quote', 'sales_order', 'fiscal_document', 'cash_session',
                                                               'reconciliation_session', 'stock_transfer', 'delivery_note_sale']),
      ('document_status_transitions_document_type_check', ARRAY['quote', 'sales_order', 'fiscal_document', 'cash_session',
                                                               'reconciliation_session', 'stock_transfer', 'delivery_note_sale']),
      ('operation_idempotency_operation_kind_check',      ARRAY['sale', 'purchase', 'payment_received', 'payment_made',
                                                               'supplier_charge', 'bank_movement', 'event_consumer',
                                                               'bank_statement_import', 'cash_session_close',
                                                               'subscription_webhook', 'credit_note', 'expense_import',
                                                               'product_import', 'delivery_note_sale'])
    ) AS t(con, prev)
  LOOP
    SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint WHERE conname = v_spec.con;
    IF v_def IS NULL OR v_def NOT LIKE '%''delivery_note_purchase''%' THEN
      v_bad := v_bad || format('%s no admite delivery_note_purchase', v_spec.con);
    END IF;
    FOREACH v_v IN ARRAY v_spec.prev LOOP
      IF v_def IS NULL OR v_def NOT LIKE '%''' || v_v || '''%' THEN
        v_bad := v_bad || format('%s perdió el valor previo %s', v_spec.con, v_v);
      END IF;
    END LOOP;
  END LOOP;

  -- Disparadores gemelos de compra y los de venta intactos.
  FOR v_spec IN
    SELECT * FROM (VALUES
      ('delivery_notes_assign_number_purchase',             'trg_assign_internal_document_number', 'purchase', 'delivery_note_purchase'),
      ('delivery_notes_record_status_creation_purchase',    'trg_delivery_note_record_creation',   'purchase', 'delivery_note_purchase'),
      ('delivery_notes_enforce_status_transition_purchase', 'trg_enforce_status_transition',       'purchase', 'delivery_note_purchase'),
      ('delivery_notes_assign_number_sale',                 'trg_assign_internal_document_number', 'sale',     'delivery_note_sale'),
      ('delivery_notes_record_status_creation_sale',        'trg_delivery_note_record_creation',   'sale',     'delivery_note_sale'),
      ('delivery_notes_enforce_status_transition_sale',     'trg_enforce_status_transition',       'sale',     'delivery_note_sale')
    ) AS t(tg, fn, dir, arg)
  LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                   WHERE t.tgrelid = 'public.delivery_notes'::regclass AND t.tgname = v_spec.tg
                     AND p.proname = v_spec.fn
                     AND pg_get_triggerdef(t.oid) LIKE '%direction = ''' || v_spec.dir || '''%'
                     AND pg_get_triggerdef(t.oid) LIKE '%''' || v_spec.arg || '''%') THEN
      v_bad := v_bad || format('falta o está mal el disparador %s', v_spec.tg);
    END IF;
  END LOOP;

  -- Catálogo de la tanda A: presencia por clave y atributos, NO conteo (CI la
  -- reaplica cuando la tanda B ya sumó sus dos filas).
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status IS NULL AND to_status = 'issued'
                   AND NOT is_terminal_to AND NOT requires_reason
                   AND cardinality(allowed_role) = 3 AND allowed_role @> ARRAY['stock', 'admin', 'owner']) THEN
    v_bad := v_bad || 'catálogo delivery_note_purchase sin la fila NULL -> issued {stock,admin,owner}'::text;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.document_status_transitions
                 WHERE document_type = 'delivery_note_purchase' AND from_status = 'issued' AND to_status = 'canceled'
                   AND is_terminal_to AND requires_reason
                   AND cardinality(allowed_role) = 2 AND allowed_role @> ARRAY['admin', 'owner']) THEN
    v_bad := v_bad || 'catálogo delivery_note_purchase sin la fila issued -> canceled {admin,owner}'::text;
  END IF;

  -- Una sola definición de cada función reescrita o nueva (sin overload).
  FOREACH v_c IN ARRAY ARRAY['_delivery_note_assert_role', '_delivery_note_assert_role_dir',
                             '_delivery_note_apply_stock', '_delivery_note_reverse_held', '_delivery_note_payload',
                             '_delivery_note_replace_content', '_delivery_note_held_pairs', '_branch_pending_delivery_notes',
                             'rpc_update_delivery_note', 'rpc_cancel_delivery_note',
                             'rpc_create_purchase_delivery_note', 'rpc_update_purchase_delivery_note'] LOOP
    IF (SELECT count(*) FROM pg_proc WHERE proname = v_c AND pronamespace = 'public'::regnamespace) <> 1 THEN
      v_bad := v_bad || format('%s no tiene exactamente una definición', v_c);
    END IF;
  END LOOP;

  -- ACLs.
  FOREACH v_fn IN ARRAY v_rpcs LOOP
    IF to_regprocedure(v_fn) IS NULL
       OR has_function_privilege('anon', v_fn, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = to_regprocedure(v_fn))
       OR obj_description(to_regprocedure(v_fn), 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('ACL/definer/COMMENT inesperado en %s', v_fn);
    END IF;
  END LOOP;
  FOREACH v_fn IN ARRAY v_internal LOOP
    IF to_regprocedure(v_fn) IS NULL
       OR has_function_privilege('anon', v_fn, 'EXECUTE')
       OR has_function_privilege('authenticated', v_fn, 'EXECUTE')
       OR obj_description(to_regprocedure(v_fn), 'pg_proc') IS NULL THEN
      v_bad := v_bad || format('helper %s ausente, ejecutable por anon/authenticated o sin COMMENT', v_fn);
    END IF;
  END LOOP;

  -- Cuerpos: los helpers de stock leen direction del remito; el de compra suma
  -- (purchase) y la reversa resta con gate (purchase_return).
  FOREACH v_fn IN ARRAY ARRAY['public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb)',
                              'public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text)'] LOOP
    SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc WHERE oid = v_fn::regprocedure;
    IF position('SELECT dn.direction INTO v_dir FROM public.delivery_notes dn WHERE dn.id = p_dn_id' IN v_src) = 0 THEN
      v_bad := v_bad || format('%s no lee direction de la fila del remito', v_fn);
    END IF;
  END LOOP;
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb)'::regprocedure;
  IF position('''purchase'',' IN v_src) = 0 OR position('stock_insuficiente' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_apply_stock sin la rama de compra (purchase) o sin el gate de venta'::text;
  END IF;
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text)'::regprocedure;
  IF position('''purchase_return''' IN v_src) = 0 OR position('delivery_note_stock_consumed' IN v_src) = 0
     OR position('''sale_return''' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_reverse_held sin la rama de compra con gate o sin la de venta'::text;
  END IF;

  -- Payload: proveedor y precios faltantes, y conserva la derivación de venta.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc WHERE oid = 'public._delivery_note_payload(uuid)'::regprocedure;
  IF position('''supplier_name''' IN v_src) = 0 OR position('''supplier_phone''' IN v_src) = 0
     OR position('''supplier_deleted''' IN v_src) = 0 OR position('''missing_price_count''' IN v_src) = 0
     OR position('so.source_delivery_note_id = dn.id' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_payload sin supplier_name/supplier_phone/supplier_deleted/missing_price_count o sin la venta generada'::text;
  END IF;

  -- Núcleo de edición: fija branch_id ANTES de recalcular, neto en compra,
  -- patas que suman primero.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._delivery_note_replace_content(uuid, uuid, jsonb)'::regprocedure;
  IF NOT (position('UPDATE public.delivery_notes SET branch_id = p_branch_id' IN v_src) > 0
          AND position('UPDATE public.delivery_notes SET branch_id = p_branch_id' IN v_src)
              < position('v_new := public._delivery_note_held_pairs' IN v_src))
     OR position('delivery_note_stock_consumed' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_replace_content no fija branch_id antes de recalcular lo retenido nuevo o no chequea el neto'::text;
  END IF;

  -- rpc_update_delivery_note llama al núcleo y ya no lleva el reemplazo embebido.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)'::regprocedure;
  IF position('public._delivery_note_replace_content(v_dn.id, p_branch_id, p_items)' IN v_src) = 0
     OR position('_delivery_note_held_pairs' IN v_src) > 0 THEN
    v_bad := v_bad || 'rpc_update_delivery_note no delega en _delivery_note_replace_content'::text;
  END IF;

  -- rpc_cancel_delivery_note sin el filtro de venta, con rol e historial por sentido.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public.rpc_cancel_delivery_note(uuid, integer, text)'::regprocedure;
  IF position('direction = ''sale''' IN v_src) > 0
     OR position('public._delivery_note_assert_role_dir(v_dn.account_id, ''void'', v_dn.direction)' IN v_src) = 0
     OR position('''delivery_note_'' || v_dn.direction' IN v_src) = 0 THEN
    v_bad := v_bad || 'rpc_cancel_delivery_note sigue filtrando venta o no resuelve rol/historial por sentido'::text;
  END IF;

  -- El rol de venta delega en el núcleo con nombre propio.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._delivery_note_assert_role(uuid, text)'::regprocedure;
  IF position('public._delivery_note_assert_role_dir(p_account_id, p_mode, ''sale'')' IN v_src) = 0 THEN
    v_bad := v_bad || '_delivery_note_assert_role no delega en _delivery_note_assert_role_dir'::text;
  END IF;

  -- El guard de baja de sucursal sigue contando remitos de los dos sentidos.
  SELECT replace(prosrc, E'\r', '') INTO v_src FROM pg_proc
  WHERE oid = 'public._branch_pending_delivery_notes(uuid)'::regprocedure;
  IF position('direction' IN v_src) > 0 OR position('status = ''issued''' IN v_src) = 0 THEN
    v_bad := v_bad || '_branch_pending_delivery_notes dejó de contar los remitos issued de los dos sentidos'::text;
  END IF;

  -- COMMENT vivos conservados en las funciones reescritas.
  FOREACH v_fn IN ARRAY ARRAY['public._delivery_note_assert_role(uuid, text)',
                              'public._delivery_note_apply_stock(uuid, uuid, uuid, jsonb)',
                              'public._delivery_note_reverse_held(uuid, uuid, uuid, jsonb, text, text)',
                              'public._delivery_note_payload(uuid)',
                              'public.rpc_update_delivery_note(uuid, integer, uuid, uuid, text, text, jsonb)',
                              'public.rpc_cancel_delivery_note(uuid, integer, text)'] LOOP
    IF obj_description(v_fn::regprocedure, 'pg_proc') NOT LIKE 'remitos-venta%'
       OR obj_description(v_fn::regprocedure, 'pg_proc') NOT LIKE '%remitos-compra%' THEN
      v_bad := v_bad || format('%s perdió su COMMENT vivo o no declara el cambio de remitos-compra', v_fn);
    END IF;
  END LOOP;

  IF array_length(v_bad, 1) > 0 THEN
    RAISE EXCEPTION E'remitos-compra tanda A (introspección FAILED):\n  %', array_to_string(v_bad, E'\n  ');
  END IF;
  RAISE NOTICE 'remitos-compra tanda A (introspección OK): CHECK con delivery_note_purchase y todos los previos, disparadores gemelos (y los de venta intactos), las dos filas de la tanda A del catálogo delivery_note_purchase, una definición por función, ACLs, helpers de stock por sentido leyendo direction, payload con proveedor y missing_price_count, núcleo de edición, rpc_update_delivery_note delegando, rpc_cancel_delivery_note de los dos sentidos, rol de venta delegando, guard de baja de sucursal sin filtro de sentido y COMMENT vivos.';
END $$;
