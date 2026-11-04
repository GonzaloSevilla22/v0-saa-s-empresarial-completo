-- =============================================================================
-- edicion-operaciones-con-dinero — TANDA A: cimientos, sin cambio de comportamiento visible
-- (governance ALTA: escribe dinero real en cuatro libros desde RPCs SECURITY DEFINER)
-- =============================================================================
-- Qué hace esta migración (design.md §Migration Plan, "Tanda A"):
--   1. op_money_footprint / op_money_footprint_flags: la HUELLA NETA de una operación (D3), una sola definición.
--   2. Las tres RPCs de BORRADO compensan la huella neta (una compensación por fila de huella, misma referencia).
--   3. Emparejamiento de la reversión de un cargo con SU cargo en el aging FIFO (D9), en una única función por parte
--      (_customer_open_items / _supplier_open_items) que consumen los reportes de cobranzas y pagos, el aviso diario
--      y las dos RPCs de cambio de vencimiento.
--   4. Consumidor contable (_journal_post_from_event): el asiento VIGENTE se busca con reversal_of IS NULL, las dos
--      convenciones de referencia en SaleOperationAdjusted / CreditNoteIssued, y la rama nueva PurchaseAdjusted.
--      El conjunto canónico pasa de 14 a 15 tipos en los DOS filtros (este helper y el despachador).
--   5. rpc_atomic_update_purchase_operation: lock de filas ascendente + recuento (P0404) y emite PurchaseAdjusted.
--      rpc_update_expense: toma la fila del gasto FOR UPDATE.
--
-- Regla de este archivo (CLAUDE.md / tasks.md): cada función se reescribe desde su pg_get_functiondef VIVO de prod
-- (md5 sin \r verificado el 2026-11-04; los cuerpos previos están en
-- openspec/changes/edicion-operaciones-con-dinero/evidence/tanda-a/ para el rollback), conservando su COMMENT y
-- re-asertando su ACL. Ninguna firma cambia en esta tanda: CREATE OR REPLACE es seguro (sin overloads, sin 42725).
-- Idempotente: reaplicable dos veces (el final lo verifica y lo exige la cadena de KPI_Validation.yml).

-- =============================================================================
-- 1. op_money_footprint — la HUELLA NETA de una operación (D3)
-- =============================================================================
-- Una sola definición de "qué dinero tiene registrado hoy esta operación, neto, en cada libro".
-- Por libro y por referencia devuelve el neto distinto de cero:
--   account : cuenta corriente de la parte (venta: sale + credit_note; compra: purchase + debit_note);
--             ledger_id = la cuenta corriente del cliente / proveedor.
--   cash    : caja (venta: sale + sale_reversal; compra: purchase_payment + purchase_payment_reversal;
--             gasto: expense + expense_reversal); AGRUPADA POR CAJA (no por sesión); ledger_id = la caja.
--   bank    : banco, todos los tipos del documento (source_doc_type = p_kind); agrupado por cuenta bancaria
--             y por FAMILIA (transfer = transfer_in/transfer_out; el resto, su propio tipo);
--             ledger_id = la cuenta bancaria; mirror_type = el tipo del espejo que anula el neto.
-- Neto 0 significa "ya compensado": la fila no se devuelve (el disparo es por existencia del NETO, nunca por signo).
-- SECURITY INVOKER: la usan las proyecciones de lectura (con la RLS del que consulta) y las RPC SECURITY DEFINER de
-- escritura, que pasan SU cuenta y filtran por ella de forma explícita. No lleva "_" inicial a propósito: es la variante
-- legible por la aplicación (chequeos (3) y (4) de test_function_acl_gate.sql).
CREATE OR REPLACE FUNCTION public.op_money_footprint(p_account_id uuid, p_kind text, p_reference_ids uuid[])
 RETURNS TABLE(book text, ledger_id uuid, family text, reference_id uuid, net numeric, mirror_type text, branch_id uuid)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_cash_types text[];
BEGIN
  IF p_kind NOT IN ('sale', 'purchase', 'expense') THEN
    RAISE EXCEPTION 'op_money_footprint: tipo de operación inválido: % (esperado sale|purchase|expense)', p_kind
      USING ERRCODE = 'P0400';
  END IF;

  IF p_account_id IS NULL OR p_reference_ids IS NULL OR cardinality(p_reference_ids) = 0 THEN
    RETURN;
  END IF;

  v_cash_types := CASE p_kind
    WHEN 'sale'     THEN ARRAY['sale', 'sale_reversal']
    WHEN 'purchase' THEN ARRAY['purchase_payment', 'purchase_payment_reversal']
    ELSE                 ARRAY['expense', 'expense_reversal']
  END;

  -- Cuenta corriente de la parte.
  IF p_kind = 'sale' THEN
    RETURN QUERY
    SELECT 'account'::text, m.customer_account_id, NULL::text, m.reference_id, SUM(m.amount), NULL::text, NULL::uuid
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
      AND m.reference_id = ANY (p_reference_ids)
      AND m.movement_type IN ('sale', 'credit_note')
    GROUP BY m.customer_account_id, m.reference_id
    HAVING SUM(m.amount) <> 0
    ORDER BY 2, 4;
  ELSIF p_kind = 'purchase' THEN
    RETURN QUERY
    SELECT 'account'::text, m.supplier_account_id, NULL::text, m.reference_id, SUM(m.amount), NULL::text, NULL::uuid
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
      AND m.reference_id = ANY (p_reference_ids)
      AND m.movement_type IN ('purchase', 'debit_note')
    GROUP BY m.supplier_account_id, m.reference_id
    HAVING SUM(m.amount) <> 0
    ORDER BY 2, 4;
  END IF;

  -- Caja, agrupada por caja. La cuenta se resuelve por sesión -> caja -> sucursal (cash_movements no la lleva).
  RETURN QUERY
  SELECT 'cash'::text, cs.cashbox_id, NULL::text, cm.reference_id, SUM(cm.amount), NULL::text, NULL::uuid
  FROM public.cash_movements cm
  JOIN public.cash_sessions cs ON cs.id = cm.session_id
  JOIN public.cashboxes cb     ON cb.id = cs.cashbox_id
  JOIN public.branches b       ON b.id  = cb.branch_id
  WHERE b.account_id = p_account_id
    AND cm.reference_id = ANY (p_reference_ids)
    AND cm.movement_type = ANY (v_cash_types)
  GROUP BY cs.cashbox_id, cm.reference_id
  HAVING SUM(cm.amount) <> 0
  ORDER BY 2, 4;

  -- Banco, por cuenta bancaria y familia de tipo. El espejo que anula el neto: para una transferencia, el sentido
  -- contrario; para el resto, el mismo tipo con el importe opuesto.
  RETURN QUERY
  SELECT 'bank'::text, g.bank_account_id, g.fam, g.ref, g.total,
         CASE WHEN g.fam = 'transfer' THEN (CASE WHEN g.total > 0 THEN 'transfer_out' ELSE 'transfer_in' END) ELSE g.fam END,
         g.branch
  FROM (
    SELECT bm.bank_account_id,
           CASE WHEN bm.movement_type IN ('transfer_in', 'transfer_out') THEN 'transfer' ELSE bm.movement_type END AS fam,
           bm.source_doc_ref AS ref,
           SUM(bm.amount) AS total,
           (array_agg(bm.branch_id ORDER BY bm.created_at DESC, bm.id DESC))[1] AS branch
    FROM public.bank_movements bm
    WHERE bm.account_id = p_account_id
      AND bm.source_doc_type = p_kind
      AND bm.source_doc_ref = ANY (p_reference_ids)
    GROUP BY bm.bank_account_id, 2, bm.source_doc_ref
    HAVING SUM(bm.amount) <> 0
  ) g
  ORDER BY 2, 3, 4;
END;
$function$;

REVOKE ALL ON FUNCTION public.op_money_footprint(uuid, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.op_money_footprint(uuid, text, uuid[]) TO authenticated, service_role;
COMMENT ON FUNCTION public.op_money_footprint(uuid, text, uuid[]) IS
  $c$edicion-operaciones-con-dinero (D3): huella NETA de una operación por libro (cuenta corriente, caja por caja, banco por cuenta y familia) y por referencia; sólo filas con neto distinto de cero. La usan el borrado, la edición, la vista previa y las proyecciones de lectura (has_account_charge / has_cash_movement / has_bank_movement / is_delete_blocked). SECURITY INVOKER.$c$;


-- Indicadores de lectura derivados de la huella neta (una sola evaluación por operación). Los consumen las
-- proyecciones de /sales, /purchases y /expenses; el borrado y la edición usan op_money_footprint directamente.
--   has_account_charge / has_cash_movement / has_bank_movement : hay neto distinto de cero en ese libro.
--   is_delete_blocked : hay neto de caja y NO hay sesión abierta en ESA caja donde compensar (el mismo par de
--                       condiciones que precede al P0426 de los borrados).
CREATE OR REPLACE FUNCTION public.op_money_footprint_flags(p_account_id uuid, p_kind text, p_reference_ids uuid[])
 RETURNS TABLE(has_account_charge boolean, has_cash_movement boolean, has_bank_movement boolean, is_delete_blocked boolean)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(bool_or(f.book = 'account'), FALSE),
         COALESCE(bool_or(f.book = 'cash'), FALSE),
         COALESCE(bool_or(f.book = 'bank'), FALSE),
         COALESCE(bool_or(f.book = 'cash' AND NOT EXISTS (
                    SELECT 1 FROM public.cash_sessions os WHERE os.cashbox_id = f.ledger_id AND os.status = 'open')), FALSE)
  FROM public.op_money_footprint(p_account_id, p_kind, p_reference_ids) f;
$function$;

REVOKE ALL ON FUNCTION public.op_money_footprint_flags(uuid, text, uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.op_money_footprint_flags(uuid, text, uuid[]) TO authenticated, service_role;
COMMENT ON FUNCTION public.op_money_footprint_flags(uuid, text, uuid[]) IS
  $c$edicion-operaciones-con-dinero (D3): los cuatro indicadores de lectura (has_account_charge, has_cash_movement, has_bank_movement, is_delete_blocked) derivados de op_money_footprint. Siempre devuelve una fila. SECURITY INVOKER.$c$;

-- =============================================================================
-- 2. rpc_delete_sale_operation — compensa la huella neta (D3). Partida: md5 f320b1cd… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_sale_operation(p_sale_id uuid DEFAULT NULL::uuid, p_operation_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_sale_ids             uuid[];
  v_sales_order_id       uuid;
  v_so_status             text;
  v_reference_ids        uuid[];
  v_row                  RECORD;
  v_customer_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_cash_session_id      uuid;
  v_cash_amount          numeric(12,2);
  v_cashbox_id           uuid;
  v_open_session_id      uuid;
  v_bank_row             RECORD;
  v_fp                   RECORD;   -- edicion-operaciones-con-dinero: fila de huella neta
  v_reversed_type        text;
  v_voided_doc           jsonb;   -- venta-editable-sin-cae
  -- remitos-venta (D9): venta nacida de un remito.
  v_source_dn            uuid;
  v_so_branch_id         uuid;
  v_dn_label             text;
  v_dn_status            text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite eliminar ventas (requiere vendedor, cajero, administrador o dueño)');

  IF p_sale_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_sale_operation: se requiere p_sale_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── Resolver el conjunto de filas + la clave de operación (D2) ───────────
  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_sale_ids
    FROM public.sales
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.sales
    WHERE id = p_sale_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_sale_ids
      FROM public.sales
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      -- Legacy: sin operation_id — la fila es su propia operación.
      v_operation_key := p_sale_id;
      v_sale_ids := ARRAY[p_sale_id];
    END IF;
  END IF;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción,
  -- mismo ancla y mismo orden que la edición (sales → sales_orders →
  -- fiscal_documents). Las filas se toman ANTES de resolver la orden: si una
  -- promoción las tiene, se espera a que commitee y la orden que creó se ve
  -- (y se cancela) más abajo; si otra edición o borrado ganó, el conjunto
  -- se recalcula bajo el lock y, vacío, no hay nada que borrar.
  SELECT array_agg(l.id ORDER BY l.id) INTO v_sale_ids
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(v_sale_ids)
      AND  s.account_id = v_account_id
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_sale_ids IS NULL OR array_length(v_sale_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): borrar la venta de OTRO miembro es del dueño o de un administrador; el
  -- resto borra lo propio (P0403). Va sobre las filas YA tomadas con FOR UPDATE (la autoría no cambia) y antes de cualquier
  -- compensación o escritura. Una venta de otra cuenta nunca llega acá: las filas se resuelven por la cuenta activa.
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT s.user_id) FROM public.sales s WHERE s.id = ANY(v_sale_ids)),
    'solo el dueño o un administrador modifican las ventas que cargó otro miembro');

  -- sales_order asociada (camino POS) — misma convención que el guard P0423.
  SELECT id, status INTO v_sales_order_id, v_so_status
  FROM public.sales_orders
  WHERE sale_operation_id = v_operation_key;

  v_reference_ids := ARRAY[v_operation_key];
  IF v_sales_order_id IS NOT NULL THEN
    v_reference_ids := v_reference_ids || v_sales_order_id;
  END IF;

  -- ── remitos-venta (D9): venta nacida de un remito ─────────────────────────
  -- La sucursal del remito (= la de la orden) tiene que estar activa y no
  -- cerrada ANTES de cualquier efecto: el guard de baja de sucursal no cuenta
  -- los remitos converted, así que una sucursal se puede vaciar y desactivar
  -- con un remito convertido; sin este guard, borrar la venta devolvería el
  -- remito a issued en una sucursal muerta (la conversión lo rechazaría y la
  -- anulación devolvería stock a una sucursal que no opera). FOR SHARE: una
  -- desactivación concurrente espera a este commit.
  IF v_sales_order_id IS NOT NULL THEN
    SELECT so.source_delivery_note_id, so.branch_id INTO v_source_dn, v_so_branch_id
    FROM public.sales_orders so
    WHERE so.id = v_sales_order_id;
  END IF;

  IF v_source_dn IS NOT NULL THEN
    SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'del remito') INTO v_dn_label
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn;

    PERFORM 1
    FROM public.branches b
    WHERE b.id = v_so_branch_id
      AND b.account_id = v_account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
    FOR SHARE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito % está desactivada o cerrada — reactivala antes de eliminar la venta', v_dn_label
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- ── Guard fiscal (P0423) — MISMO helper que rpc_atomic_update_sale_operation ──
  -- venta-editable-sin-cae (D2): un comprobante pendiente que NO salió hacia
  -- ARCA se ANULA acá mismo (misma transacción que el borrado), para que el
  -- relay no lo facture después. authorized, marcado y congelado siguen
  -- bloqueando con P0423. Sigue siendo el PRIMER guard, antes de compensar
  -- cuenta corriente (P0425), caja (P0426), banco y de revertir stock — si
  -- levanta, no se tocó ningún libro.
  -- Una sola definición de la regla, compartida con la edición: dos copias
  -- divergirían y una de las dos terminaría anulando un comprobante enviado.
  v_voided_doc := public._fiscal_void_pending_for_sale_edit(
    v_sales_order_id, v_account_id, v_uid,
    format('Anulado por borrado de la venta (operación %s)', v_operation_key)
  );

  -- ── edicion-operaciones-con-dinero (D3/D4): se compensa la HUELLA NETA de cada libro ──
  -- Una compensación por cada fila de huella con neto <> 0, por el importe EXACTAMENTE opuesto y con LA MISMA
  -- referencia que esa fila. Ya no se suma sólo el tipo original ('sale'): con referencias que acumulan el
  -- movimiento original, su compensación y el movimiento nuevo (lo que deja una edición) eso compensaría dos veces
  -- lo ya compensado; y la caja se agrupa por CAJA, no por sesión. Neto 0 = ya compensado: no se escribe nada y no se
  -- exige sesión abierta. Orden de libros sin cambios: cuenta corriente -> caja -> banco.

  -- ── Cuenta corriente de cliente: reversión del cargo (credit_note, P0425 si negativo) ──
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'sale', v_reference_ids) f WHERE f.book = 'account'
  LOOP
    IF v_fp.net > 0 THEN
      PERFORM public._pay_reverse_party_charge(
        v_account_id, 'customer', v_fp.ledger_id, v_fp.net,
        v_fp.reference_id, v_operation_key
      );
    END IF;
  END LOOP;

  -- ── Caja: contra-movimiento en la sesión abierta actual de LA MISMA caja (P0426 si no hay) ─
  -- Por EXISTENCIA del neto, nunca por su signo: el opuesto exacto de lo que quedó posteado.
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'sale', v_reference_ids) f WHERE f.book = 'cash'
  LOOP
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_fp.ledger_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder anular esta venta'
        USING ERRCODE = 'P0426';
    END IF;

    PERFORM public.c28_register_cash_movement(
      v_open_session_id, -v_fp.net, 'sale_reversal', v_fp.reference_id
    );
  END LOOP;

  -- ── Banco: espejo del neto con dirección invertida, siempre unreconciled (D6) ─────
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'sale', v_reference_ids) f WHERE f.book = 'bank'
  LOOP
    PERFORM public._register_bank_movement(
      v_fp.ledger_id, -v_fp.net, v_fp.mirror_type,
      'sale', v_fp.reference_id, CURRENT_DATE, v_fp.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  -- remitos-venta (D9): una venta nacida de un remito NO repone stock: la
  -- mercadería quedó entregada con el remito, que vuelve a pendiente más
  -- abajo (para devolverla al stock se anula el remito). El salto es
  -- explícito: no depende de que esas filas sales no tengan movimientos.
  IF v_source_dn IS NULL THEN
    FOR v_row IN SELECT unnest(v_sale_ids) AS id LOOP
      PERFORM public.rpc_reverse_stock_movement(v_row.id, 'sale', COALESCE(p_reason, 'Venta eliminada'));
    END LOOP;
  END IF;

  -- ── Contable: emitir SaleOperationDeleted (async, vía outbox) ────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationDeleted', 'SaleOperation', v_operation_key,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_operation_key,
      'sales_order_id', v_sales_order_id,
      'occurred_at',    now()
    ),
    now()
  );

  -- ── POS: cancelar la sales_order en la misma transacción (D8) ────────────
  IF v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    UPDATE public.sales_orders
    SET status = 'canceled', sale_operation_id = NULL
    WHERE id = v_sales_order_id;

    PERFORM public.record_status_transition(
      v_account_id, 'sales_order', v_sales_order_id, 'confirmed', 'canceled',
      v_uid, COALESCE(p_reason, 'Venta eliminada')
    );
  END IF;

  -- ── remitos-venta (D9, R5): el remito vuelve a pendiente ─────────────────
  -- Lock del remito AL FINAL (sales -> sales_orders -> fiscal_documents ->
  -- delivery_notes). La orden ya pasó a canceled, así que el índice único
  -- parcial queda libre y el remito se puede volver a convertir. La
  -- transición converted -> issued no tiene rol propio: este borrado ya
  -- registró sales_order confirmed -> canceled, que exige admin/owner.
  IF v_source_dn IS NOT NULL AND v_sales_order_id IS NOT NULL AND v_so_status = 'confirmed' THEN
    SELECT dn.status INTO v_dn_status
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn
    FOR UPDATE;

    IF v_dn_status = 'converted' THEN
      PERFORM public.record_status_transition(
        v_account_id, 'delivery_note_sale', v_source_dn, 'converted', 'issued',
        v_uid, format('Venta eliminada (operación %s)', v_operation_key)
      );

      UPDATE public.delivery_notes
      SET status = 'issued', updated_at = now(), updated_by = v_uid
      WHERE id = v_source_dn;
    END IF;
  END IF;

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(v_sale_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  RETURN true;
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_delete_sale_operation(uuid, uuid, text) IS
  $c$delete-guard-ledgers: RPC atómica de borrado de venta — guard fiscal (P0423), compensa cuenta corriente (P0425), caja (P0426) y banco, revierte stock (#417), emite SaleOperationDeleted, cancela la sales_order del POS. Acepta p_sale_id (delete_by_id) o p_operation_id (delete_by_operation).
  edicion-operaciones-con-dinero (D3): compensa la HUELLA NETA de cada libro (op_money_footprint), una compensación por fila de huella y con la misma referencia que esa fila; neto 0 = ya compensado, sin sesión abierta ni escritura.
  edicion-operaciones-con-dinero (D3): compensa la HUELLA NETA de cada libro (op_money_footprint), una compensación por fila de huella y con la misma referencia que esa fila; neto 0 = ya compensado, sin sesión abierta ni escritura.$c$;


-- =============================================================================
-- 3. rpc_delete_purchase_operation — compensa la huella neta (D3). Partida: md5 272c822c… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_purchase_operation(p_purchase_id uuid DEFAULT NULL::uuid, p_operation_id uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                  uuid;
  v_account_id           uuid;
  v_operation_key        uuid;
  v_purchase_ids         uuid[];
  v_row                  RECORD;
  v_supplier_account_id  uuid;
  v_charge_amount        numeric(15,2);
  v_bank_row             RECORD;
  v_fp                   RECORD;   -- edicion-operaciones-con-dinero: fila de huella neta
  v_reversed_type        text;
  -- caja-compras-cobranzas (D7):
  v_cashbox_id           uuid;
  v_cash_amount          numeric(12,2);
  v_open_session_id      uuid;
  v_cash_reversal_id     uuid;
  -- remitos-compra (D9): compra nacida de un remito.
  v_origins              uuid[];
  v_direct_rows          integer;
  v_source_dn            uuid;
  v_dn                   public.delivery_notes%ROWTYPE;
  v_dn_label             text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite eliminar compras (requiere compras, administrador o dueño)');

  IF p_purchase_id IS NULL AND p_operation_id IS NULL THEN
    RAISE EXCEPTION 'rpc_delete_purchase_operation: se requiere p_purchase_id o p_operation_id'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_operation_id IS NOT NULL THEN
    v_operation_key := p_operation_id;
    SELECT array_agg(id) INTO v_purchase_ids
    FROM public.purchases
    WHERE operation_id = p_operation_id AND account_id = v_account_id;
  ELSE
    SELECT operation_id INTO v_operation_key
    FROM public.purchases
    WHERE id = p_purchase_id AND account_id = v_account_id;

    IF NOT FOUND THEN
      RETURN false;
    END IF;

    IF v_operation_key IS NOT NULL THEN
      SELECT array_agg(id) INTO v_purchase_ids
      FROM public.purchases
      WHERE operation_id = v_operation_key AND account_id = v_account_id;
    ELSE
      v_operation_key := p_purchase_id;
      v_purchase_ids := ARRAY[p_purchase_id];
    END IF;
  END IF;

  IF v_purchase_ids IS NULL OR array_length(v_purchase_ids, 1) IS NULL THEN
    RETURN false;
  END IF;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): borrar la compra de OTRO miembro es del dueño o de un administrador; el
  -- resto borra lo propio (P0403). Antes de tomar el remito de origen y de cualquier compensación. Una compra de otra
  -- cuenta nunca llega acá: las filas se resuelven por la cuenta activa.
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT p.user_id) FROM public.purchases p WHERE p.id = ANY(v_purchase_ids)),
    'solo el dueño o un administrador modifican las compras que cargó otro miembro');

  -- ── remitos-compra (D9): compra nacida de un remito ─────────────────────────
  -- ANTES de cualquier compensación: lock del remito de origen (leído con la cuenta del usuario y
  -- el sentido compra). Es el mismo orden que la conversión (remito -> dinero), así que no hay
  -- ciclo; tomarlo al final no serializaría dos borrados de la misma compra ni un borrado viejo
  -- contra una reconversión, y a crédito invertiría el orden (cuenta corriente -> remito contra
  -- remito -> cuenta corriente: interbloqueo). Un origen de otra cuenta o de venta NUNCA se reabre.
  SELECT array_agg(DISTINCT p.source_delivery_note_id) FILTER (WHERE p.source_delivery_note_id IS NOT NULL),
         count(*) FILTER (WHERE p.source_delivery_note_id IS NULL)
    INTO v_origins, v_direct_rows
  FROM public.purchases p
  WHERE p.id = ANY(v_purchase_ids);

  IF v_origins IS NOT NULL THEN
    -- Los caminos legítimos nunca mezclan orígenes; el disparador del puente cierra los dos
    -- caminos por PostgREST que sí podrían (partir y mezclar operation_id). Defensa en
    -- profundidad frente a una escritura como postgres.
    IF array_length(v_origins, 1) <> 1 OR v_direct_rows > 0 THEN
      RAISE EXCEPTION 'delivery_note_purchase_mismatch: la operación mezcla filas con y sin remito de origen, o de orígenes distintos'
        USING ERRCODE = 'P0409';
    END IF;
    v_source_dn := v_origins[1];

    SELECT * INTO v_dn
    FROM public.delivery_notes dn
    WHERE dn.id = v_source_dn
      AND dn.account_id = v_account_id
      AND dn.direction = 'purchase'
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_purchase_mismatch: el origen % no es un remito de compra de esta cuenta', v_source_dn
        USING ERRCODE = 'P0409';
    END IF;

    -- Bajo el lock del remito se vuelven a leer las filas de la operación: si otro borrado ganó,
    -- ya no existen y éste termina sin efectos, con el mismo resultado que hoy para una
    -- operación inexistente.
    SELECT array_agg(s.id) INTO v_purchase_ids
    FROM (
      SELECT p.id
      FROM public.purchases p
      WHERE p.id = ANY(v_purchase_ids) AND p.account_id = v_account_id
      ORDER BY p.id
      FOR UPDATE
    ) s;
    IF v_purchase_ids IS NULL OR array_length(v_purchase_ids, 1) IS NULL THEN
      RETURN false;
    END IF;

    IF v_dn.status <> 'converted' THEN
      RAISE EXCEPTION 'delivery_note_purchase_mismatch: el remito % está % y no convertido: la compra no se puede reabrir', v_source_dn, v_dn.status
        USING ERRCODE = 'P0409';
    END IF;

    v_dn_label := 'RC-' || lpad(v_dn.number::text, 8, '0');

    -- Borrar la compra reabre el remito y lo deja anulable: tan sensible como anularlo, así que
    -- exige el mismo rol (administrador o dueño). Literal propio para que la UI lo traduzca.
    BEGIN
      PERFORM public._delivery_note_assert_role_dir(v_account_id, 'void', 'purchase');
    EXCEPTION WHEN SQLSTATE 'P0401' OR SQLSTATE 'P0403' THEN
      RAISE EXCEPTION 'delivery_note_purchase_delete_forbidden: borrar esta compra reabre el remito % y lo deja anulable: requiere administrador o dueño', v_dn_label
        USING ERRCODE = 'P0403';
    END;

    -- La sucursal del remito, activa y no cerrada (FOR SHARE: una desactivación concurrente espera
    -- a este commit). El guard de baja no cuenta los remitos converted: sin esto, borrar la compra
    -- reabriría el remito en una sucursal muerta.
    PERFORM 1
    FROM public.branches b
    WHERE b.id = v_dn.branch_id
      AND b.account_id = v_account_id
      AND b.is_active = TRUE
      AND b.status IS DISTINCT FROM 'closed'
    FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'delivery_note_branch_inactive: la sucursal del remito % está desactivada o cerrada — reactivala antes de eliminar la compra', v_dn_label
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- ── edicion-operaciones-con-dinero (D3/D4): se compensa la HUELLA NETA de cada libro ──
  -- Misma regla que rpc_delete_sale_operation: una compensación por fila de huella con neto <> 0, por el opuesto
  -- exacto del neto y con la misma referencia que esa fila; neto 0 = ya compensado. Orden: cuenta corriente ->
  -- caja -> banco.

  -- ── Cuenta corriente de proveedor: reversión del cargo (debit_note, P0425 si negativo) ──
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'purchase', ARRAY[v_operation_key]) f WHERE f.book = 'account'
  LOOP
    IF v_fp.net > 0 THEN
      PERFORM public._pay_reverse_party_charge(
        v_account_id, 'supplier', v_fp.ledger_id, v_fp.net,
        v_fp.reference_id, v_operation_key
      );
    END IF;
  END LOOP;

  -- ── caja-compras-cobranzas (D7) — CAJA: contra-movimiento por EXISTENCIA del NETO ──
  -- ⚠️ Nunca por el signo: existe neto de caja de la compra ⇒ SIEMPRE se compensa, cualquiera sea el signo (el
  -- movimiento de la compra es un egreso, así que el opuesto es el ingreso que repone la plata en el cajón). La sesión
  -- ORIGINAL nunca se toca — append-only (RN-99); el contra-movimiento va SIEMPRE a la sesión abierta ACTUAL de la
  -- MISMA caja, y si no hay ninguna, P0426.
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'purchase', ARRAY[v_operation_key]) f WHERE f.book = 'cash'
  LOOP
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_fp.ledger_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar esta compra'
        USING ERRCODE = 'P0426';
    END IF;

    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_fp.net, 'purchase_payment_reversal', v_fp.reference_id, 'Reversión por borrado de compra'
    );
  END LOOP;

  -- ── Banco: espejo del neto con dirección invertida ─────────────────────────────
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'purchase', ARRAY[v_operation_key]) f WHERE f.book = 'bank'
  LOOP
    PERFORM public._register_bank_movement(
      v_fp.ledger_id, -v_fp.net, v_fp.mirror_type,
      'purchase', v_fp.reference_id, CURRENT_DATE, v_fp.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  -- remitos-compra (D9): una compra nacida de un remito NO revierte stock: la mercadería quedó
  -- recibida con el remito, que vuelve a pendiente más abajo (para sacarla del stock se anula el
  -- remito). El salto es explícito: no depende de que esas filas no tengan movimientos propios.
  IF v_source_dn IS NULL THEN
    FOR v_row IN SELECT unnest(v_purchase_ids) AS id LOOP
      PERFORM public.rpc_reverse_stock_movement(v_row.id, 'purchase', COALESCE(p_reason, 'Compra eliminada'));
    END LOOP;
  END IF;

  -- ── Contable: emitir PurchaseDeleted (async, vía outbox) ──────────────────
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'PurchaseDeleted', 'Purchase', v_operation_key,
    jsonb_build_object(
      'account_id',   v_account_id,
      'operation_id', v_operation_key,
      'occurred_at',  now()
    ),
    now()
  );

  -- ── DELETE + limpieza de idempotencia ─────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(v_purchase_ids);

  DELETE FROM public.operation_idempotency WHERE operation_id = v_operation_key;

  -- ── remitos-compra (D9, R5): el remito vuelve a pendiente ────────────────
  -- Con el remito bloqueado desde el principio. Sin filas con ese origen, se puede volver a
  -- convertir. La transición converted -> issued no tiene rol propio: este borrado ya exigió
  -- administrador o dueño ANTES de cualquier efecto.
  IF v_source_dn IS NOT NULL THEN
    PERFORM public.record_status_transition(
      v_account_id, 'delivery_note_purchase', v_source_dn, 'converted', 'issued',
      v_uid, format('Compra eliminada (operación %s)', v_operation_key)
    );
    UPDATE public.delivery_notes
    SET status = 'issued', updated_at = now(), updated_by = v_uid
    WHERE id = v_source_dn;
  END IF;

  RETURN true;
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) IS
  $c$caja-compras-cobranzas (D7): suma la pata de caja como segunda compensación
  (después de cuenta corriente, antes de banco) — contra-movimiento
  purchase_payment_reversal por existencia (no por signo), P0426 si no hay
  sesión abierta en esa caja. Orden final: cta cte → caja → banco → stock →
  evento → DELETE.
  remitos-compra (D9): con filas de origen de remito, ANTES de cualquier compensación bloquea el remito (cuenta + sentido compra, FOR UPDATE), relee las filas bajo ese lock (si ya no existen termina sin efectos), exige status converted, el rol de anular remitos de compra (admin/owner: P0403 delivery_note_purchase_delete_forbidden) y la sucursal del remito activa y no cerrada (FOR SHARE, P0422 delivery_note_branch_inactive); salta la reversa de stock (el remito ya lo sumó) y devuelve el remito a issued con historial y motivo. Un origen de otra cuenta, de venta o mezclado da P0409 delivery_note_purchase_mismatch.
  edicion-operaciones-con-dinero (D3): compensa la HUELLA NETA de cada libro (op_money_footprint), una compensación por fila de huella y con la misma referencia que esa fila; neto 0 = ya compensado.
  edicion-operaciones-con-dinero (D3): compensa la HUELLA NETA de cada libro (op_money_footprint), una compensación por fila de huella y con la misma referencia que esa fila; neto 0 = ya compensado.$c$;


-- =============================================================================
-- 4. rpc_delete_expense — compensa la huella neta (D3). Partida: md5 eae2e6c6… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_delete_expense(p_expense_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_expense          RECORD;
  v_cashbox_id       uuid;
  v_cash_amount      numeric(12,2);
  v_open_session_id  uuid;
  v_cash_reversal_id uuid;
  v_bank_row         RECORD;
  v_fp               RECORD;   -- edicion-operaciones-con-dinero: fila de huella neta
  v_reversed_type    text;
  v_bank_reversals   integer := 0;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede borrar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_expense
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id
  FOR UPDATE;   -- edicion-operaciones-con-dinero (D12): mismo lock de fila que la edición

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── edicion-operaciones-con-dinero (D3/D4): se compensa la HUELLA NETA de cada libro ──
  -- Antes se sumaba sólo el tipo original ('expense'): un gasto editado (500 -> 300) acumula expense -500,
  -- expense_reversal +500 y expense -300 con la MISMA referencia, y borrarlo reponía 800 en vez de 300. Ahora se
  -- compensa el neto de cada caja y de cada cuenta bancaria, con la misma referencia que esa fila de huella.
  --
  -- ⚠️ El disparo es por EXISTENCIA del neto, NUNCA por su signo (el guard de signo del original es lo que dejaba
  -- pasar el borrado sin compensar y SIN levantar P0426 — el modo de falla que motivó delete-guard-ledgers). El
  -- movimiento del gasto es NEGATIVO; si por cualquier camino el neto fuera positivo, la contra-partida sale
  -- negativa y compensa igual: la reversa es siempre el opuesto exacto de lo posteado. Neto 0 = ya compensado.
  --
  -- La sesión ORIGINAL nunca se toca: el ledger de caja es append-only. El contra-movimiento va SIEMPRE a la sesión
  -- abierta actual de la MISMA caja (P0426 si no hay). Banco: se usa _register_bank_movement (el escritor crudo) y
  -- NO _pay_register_operation_bank_movement: la reversa no vuelve a resolver la cuenta ni a evaluar el guard de
  -- período conciliado — va contra la MISMA cuenta del movimiento original (D2 de gastos-forma-pago).
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'expense', ARRAY[p_expense_id]) f WHERE f.book = 'cash'
  LOOP
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_fp.ledger_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar este gasto'
        USING ERRCODE = 'P0426';
    END IF;

    v_cash_reversal_id := public.c28_register_cash_movement(
      -- qa-integral-modulos (G16/H11): la reversa lleva el motivo del gasto
      -- borrado (mismo criterio que el alta y que el backfill de la seccion 3).
      v_open_session_id, -v_fp.net, 'expense_reversal', v_fp.reference_id,
      v_expense.description
    );
  END LOOP;

  -- ── Banco: espejo del neto con dirección invertida, siempre unreconciled ───────────
  FOR v_fp IN
    SELECT * FROM public.op_money_footprint(v_account_id, 'expense', ARRAY[p_expense_id]) f WHERE f.book = 'bank'
  LOOP
    PERFORM public._register_bank_movement(
      v_fp.ledger_id, -v_fp.net, v_fp.mirror_type,
      'expense', v_fp.reference_id, CURRENT_DATE, v_fp.branch_id,
      -- qa-integral-modulos (G16/H11): el espejo nombra al gasto borrado.
      -- El marcador 'Reversión por borrado de gasto' se CONSERVA: el gate
      -- test_gastos_forma_pago (5.5/5.7) lo exige como ancla del contrato.
      'Reversión por borrado de gasto' || COALESCE(': ' || v_expense.description, '')
    );
    v_bank_reversals := v_bank_reversals + 1;
  END LOOP;

  -- ── asiento-contable-gastos (D7): ExpenseDeleted, SÓLO si existe el alta,
  -- ANTES del borrado físico ─────────────────────────────────────────────────
  -- El account_id ya no se podría leer de public.expenses después del DELETE
  -- de más abajo, así que el evento se emite ANTES. Carga mínima: cuenta +
  -- id del gasto — es todo lo que el consumidor necesita para localizar el
  -- asiento vigente por su source_doc_ref y revertirlo (la lookup NO lee
  -- public.expenses).
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = p_expense_id AND account_id = v_account_id
  ) THEN
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
    VALUES (
      v_account_id, 'ExpenseDeleted', 'Expense', p_expense_id,
      jsonb_build_object('account_id', v_account_id, 'expense_id', p_expense_id)
    );
  END IF;

  -- ── El borrado, DESPUÉS de las dos compensaciones y del evento contable ──
  DELETE FROM public.expenses WHERE id = p_expense_id AND account_id = v_account_id;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'deleted',           true,
    'cash_reversal_id',  v_cash_reversal_id,
    'bank_reversals',    v_bank_reversals
  );
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_delete_expense(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_delete_expense(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_delete_expense(uuid) IS
  $c$gastos-forma-pago: borrado atómico del gasto con compensación de las DOS
  patas —caja (expense_reversal positivo en la sesión abierta actual de la
  misma caja, P0426 si no hay ninguna) y banco (espejo invertido)— antes del
  DELETE. ⚠️ El guard de signo NO es el de rpc_delete_sale_operation
  (v_cash_amount > 0): los movimientos de gasto son negativos y el guard
  positivo del original sería falso para todo gasto (D8). Es `<> 0` y no
  `< 0` para que la compensación no dependa de una invariante que vive en
  otra función: existe movimiento de caja del gasto => siempre se compensa.
  edicion-operaciones-con-dinero (D3): compensa la HUELLA NETA de caja y banco (op_money_footprint), con la misma referencia que cada fila de huella; toma la fila del gasto FOR UPDATE.
  edicion-operaciones-con-dinero (D3): compensa la HUELLA NETA de caja y banco (op_money_footprint), con la misma referencia que cada fila de huella; toma la fila del gasto FOR UPDATE.$c$;

-- =============================================================================
-- 5. Emparejamiento de la reversión de un cargo en el aging FIFO (D9)
-- =============================================================================


-- =============================================================================
-- _customer_open_items: el importe ABIERTO de cada cargo, por línea de flotación, con la reversión emparejada (D9)
-- =============================================================================
-- Una sola definición de la derivación FIFO del lado cliente, que consumen rpc_receivables_report, el aviso
-- diario y la RPC de cambio de vencimiento. Cargo = 'sale' + 'adjustment' positivo. Todo otro movimiento aporta crédito
-- con su propio signo (un cobro, una anulación de cobro lo RESTA — nunca es un cargo), SALVO la reversión de un cargo
-- ('credit_note' con referencia): ésta cancela PRIMERO los cargos de su misma referencia y de la misma cuenta corriente, en el
-- orden de la línea de flotación de esos cargos; sólo el remanente (si lo hubiera) va al pozo general. El invariante
-- de cierre (suma de lo abierto = saldo) se conserva: el emparejamiento sólo mueve importe entre "cargo neto" y "pozo".
--   p_account_id : la cuenta (tenant), SIEMPRE filtra por ella; NULL = todas (el aviso diario recorre todas).
--   p_*_account_id : opcional, acota a UNA cuenta corriente (la RPC de cambio de vencimiento).
-- Interna (prefijo "_"): sin EXECUTE para anon ni authenticated; la llaman las RPC SECURITY DEFINER.
CREATE OR REPLACE FUNCTION public._customer_open_items(p_account_id uuid, p_customer_account_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(party_account_id uuid, account_id uuid, id uuid, amount numeric, due_date date, open_amount numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH mv AS (
    SELECT m.customer_account_id AS party, m.account_id, m.id, m.amount, m.due_date, m.created_at, m.movement_type, m.reference_id,
           (m.movement_type = 'sale' OR (m.movement_type = 'adjustment' AND m.amount > 0)) AS is_charge
    FROM public.customer_account_movements m
    WHERE (p_account_id IS NULL OR m.account_id = p_account_id)
      AND (p_customer_account_id IS NULL OR m.customer_account_id = p_customer_account_id)
  ),
  rev AS (
    SELECT mv.party, mv.reference_id, SUM(-mv.amount) AS credit
    FROM mv
    WHERE mv.movement_type = 'credit_note' AND mv.reference_id IS NOT NULL
    GROUP BY mv.party, mv.reference_id
  ),
  pool AS (
    SELECT mv.party, COALESCE(SUM(-mv.amount), 0) AS credit
    FROM mv
    WHERE NOT mv.is_charge
      AND NOT (mv.movement_type = 'credit_note' AND mv.reference_id IS NOT NULL)
    GROUP BY mv.party
  ),
  chg AS (
    SELECT mv.party, mv.account_id, mv.id, mv.amount, mv.due_date, mv.created_at, mv.reference_id,
           SUM(mv.amount) OVER (
             PARTITION BY mv.party, mv.reference_id
             ORDER BY COALESCE(mv.due_date, (mv.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      mv.created_at, mv.id
           ) AS cum_ref
    FROM mv
    WHERE mv.is_charge
  ),
  net AS (
    SELECT c.party, c.account_id, c.id, c.amount, c.due_date, c.created_at,
           LEAST(c.amount, GREATEST(0::numeric, c.cum_ref - COALESCE(r.credit, 0))) AS net_amount
    FROM chg c
    LEFT JOIN rev r ON r.party = c.party AND r.reference_id = c.reference_id
  ),
  remainder AS (
    SELECT r.party, SUM(GREATEST(0::numeric, r.credit - COALESCE(t.total, 0))) AS rem
    FROM rev r
    LEFT JOIN (SELECT chg.party, chg.reference_id, SUM(chg.amount) AS total FROM chg GROUP BY chg.party, chg.reference_id) t
           ON t.party = r.party AND t.reference_id = r.reference_id
    GROUP BY r.party
  )
  SELECT n.party, n.account_id, n.id, n.amount, n.due_date,
         LEAST(n.net_amount, GREATEST(0::numeric,
           SUM(n.net_amount) OVER (
             PARTITION BY n.party
             ORDER BY COALESCE(n.due_date, (n.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      n.created_at, n.id
           ) - COALESCE(p.credit, 0) - COALESCE(rm.rem, 0)
         )) AS open_amount
  FROM net n
  LEFT JOIN pool p ON p.party = n.party
  LEFT JOIN remainder rm ON rm.party = n.party;
$function$;

REVOKE ALL ON FUNCTION public._customer_open_items(uuid, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._customer_open_items(uuid, uuid) IS
  $c$edicion-operaciones-con-dinero (D9): importe abierto de cada cargo del lado cliente por línea de flotación, con la reversión de un cargo emparejada con los cargos de su misma referencia. Única definición para el reporte, el aviso diario y el cambio de vencimiento. Interna.$c$;


-- =============================================================================
-- _supplier_open_items: el importe ABIERTO de cada cargo, por línea de flotación, con la reversión emparejada (D9)
-- =============================================================================
-- Una sola definición de la derivación FIFO del lado proveedor, que consumen rpc_payables_report, el aviso
-- diario y la RPC de cambio de vencimiento. Cargo = 'purchase' + 'adjustment' positivo. Todo otro movimiento aporta crédito
-- con su propio signo (un cobro, una anulación de cobro lo RESTA — nunca es un cargo), SALVO la reversión de un cargo
-- ('debit_note' con referencia): ésta cancela PRIMERO los cargos de su misma referencia y de la misma cuenta corriente, en el
-- orden de la línea de flotación de esos cargos; sólo el remanente (si lo hubiera) va al pozo general. El invariante
-- de cierre (suma de lo abierto = saldo) se conserva: el emparejamiento sólo mueve importe entre "cargo neto" y "pozo".
--   p_account_id : la cuenta (tenant), SIEMPRE filtra por ella; NULL = todas (el aviso diario recorre todas).
--   p_*_account_id : opcional, acota a UNA cuenta corriente (la RPC de cambio de vencimiento).
-- Interna (prefijo "_"): sin EXECUTE para anon ni authenticated; la llaman las RPC SECURITY DEFINER.
CREATE OR REPLACE FUNCTION public._supplier_open_items(p_account_id uuid, p_supplier_account_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(party_account_id uuid, account_id uuid, id uuid, amount numeric, due_date date, open_amount numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  WITH mv AS (
    SELECT m.supplier_account_id AS party, m.account_id, m.id, m.amount, m.due_date, m.created_at, m.movement_type, m.reference_id,
           (m.movement_type = 'purchase' OR (m.movement_type = 'adjustment' AND m.amount > 0)) AS is_charge
    FROM public.supplier_account_movements m
    WHERE (p_account_id IS NULL OR m.account_id = p_account_id)
      AND (p_supplier_account_id IS NULL OR m.supplier_account_id = p_supplier_account_id)
  ),
  rev AS (
    SELECT mv.party, mv.reference_id, SUM(-mv.amount) AS credit
    FROM mv
    WHERE mv.movement_type = 'debit_note' AND mv.reference_id IS NOT NULL
    GROUP BY mv.party, mv.reference_id
  ),
  pool AS (
    SELECT mv.party, COALESCE(SUM(-mv.amount), 0) AS credit
    FROM mv
    WHERE NOT mv.is_charge
      AND NOT (mv.movement_type = 'debit_note' AND mv.reference_id IS NOT NULL)
    GROUP BY mv.party
  ),
  chg AS (
    SELECT mv.party, mv.account_id, mv.id, mv.amount, mv.due_date, mv.created_at, mv.reference_id,
           SUM(mv.amount) OVER (
             PARTITION BY mv.party, mv.reference_id
             ORDER BY COALESCE(mv.due_date, (mv.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      mv.created_at, mv.id
           ) AS cum_ref
    FROM mv
    WHERE mv.is_charge
  ),
  net AS (
    SELECT c.party, c.account_id, c.id, c.amount, c.due_date, c.created_at,
           LEAST(c.amount, GREATEST(0::numeric, c.cum_ref - COALESCE(r.credit, 0))) AS net_amount
    FROM chg c
    LEFT JOIN rev r ON r.party = c.party AND r.reference_id = c.reference_id
  ),
  remainder AS (
    SELECT r.party, SUM(GREATEST(0::numeric, r.credit - COALESCE(t.total, 0))) AS rem
    FROM rev r
    LEFT JOIN (SELECT chg.party, chg.reference_id, SUM(chg.amount) AS total FROM chg GROUP BY chg.party, chg.reference_id) t
           ON t.party = r.party AND t.reference_id = r.reference_id
    GROUP BY r.party
  )
  SELECT n.party, n.account_id, n.id, n.amount, n.due_date,
         LEAST(n.net_amount, GREATEST(0::numeric,
           SUM(n.net_amount) OVER (
             PARTITION BY n.party
             ORDER BY COALESCE(n.due_date, (n.created_at AT TIME ZONE 'America/Argentina/Mendoza')::date),
                      n.created_at, n.id
           ) - COALESCE(p.credit, 0) - COALESCE(rm.rem, 0)
         )) AS open_amount
  FROM net n
  LEFT JOIN pool p ON p.party = n.party
  LEFT JOIN remainder rm ON rm.party = n.party;
$function$;

REVOKE ALL ON FUNCTION public._supplier_open_items(uuid, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._supplier_open_items(uuid, uuid) IS
  $c$edicion-operaciones-con-dinero (D9): importe abierto de cada cargo del lado proveedor por línea de flotación, con la reversión de un cargo emparejada con los cargos de su misma referencia. Única definición para el reporte, el aviso diario y el cambio de vencimiento. Interna.$c$;


-- =============================================================================
-- 6. rpc_receivables_report — abierto por cargo desde _customer_open_items. Partida: md5 fbeb101d… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_receivables_report(p_account_id uuid)
 RETURNS TABLE(client_id uuid, client_name text, client_phone text, balance numeric, days_since_last_charge integer, days_since_last_payment integer, last_payment_date date, overdue_total numeric, amount_current numeric, amount_overdue_1_30 numeric, amount_overdue_31_60 numeric, amount_overdue_60_plus numeric, amount_no_due_date numeric, oldest_due_date date, days_overdue_max integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-panel (Etapa A) + cobranzas-vencimientos (Etapa B, D4/D5/D6):
  una fila por cliente deudor con el reparto de su saldo en cinco tramos,
  derivado FIFO por línea de flotación SIN materializar imputaciones
  (edicion-operaciones-con-dinero D9: con la reversión de un cargo emparejada, ver _customer_open_items):
    - cargos = movement_type 'sale' + 'adjustment' positivo, ordenados por
      (vencimiento o fecha local del posteo, created_at, id);
    - crédito disponible = suma NEGADA, con su propio signo, de todo lo demás
      (un cobro/nota suma crédito; una anulación de cobro lo RESTA — jamás es
      un cargo: rejuvenecería la mora);
    - abierto del cargo i = clamp(acumulado_i - crédito, 0, importe_i).
  Invariante de cierre: la suma de los 5 tramos = balance materializado.
  Clasificación (regla SEPARADA de la imputación, D5): sólo un cargo con
  vencimiento puede estar vencido; sin vencimiento = tramo propio, NUNCA se
  pliega a "al día". Día calendario argentino vía reporting_local_today().
*/
BEGIN
  -- Guard de membresía (D1 Etapa A): primera sentencia, antes de leer dato alguno.
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH today AS (
    SELECT public.reporting_local_today() AS d
  ),
  last_moves AS (
    -- D4 Etapa A: el cargo es EXCLUSIVAMENTE movement_type = 'sale' para las
    -- antigüedades; el cobro es EXCLUSIVAMENTE 'payment_received'.
    SELECT
      m.customer_account_id                                                 AS ca_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'sale')             AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_received') AS last_payment_at
    FROM public.customer_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.customer_account_id
  ),
  open_items AS (
    -- edicion-operaciones-con-dinero (D9): el abierto de cada cargo sale de la derivación ÚNICA
    -- (_customer_open_items), con la reversión de un cargo emparejada con los cargos de su referencia.
    SELECT oi.party_account_id AS ca_id, oi.due_date, oi.open_amount
    FROM public._customer_open_items(p_account_id) oi
  ),
  aging AS (
    SELECT oi.ca_id,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date <  t.d), 0) AS agg_overdue_total,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date >= t.d), 0) AS agg_current,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 1 AND 30), 0)  AS agg_1_30,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 31 AND 60), 0) AS agg_31_60,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) > 60), 0)              AS agg_60_plus,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NULL), 0)                                               AS agg_no_due,
      MIN(oi.due_date) FILTER (WHERE oi.open_amount > 0)                                    AS agg_oldest_due,
      MAX(t.d - oi.due_date) FILTER (WHERE oi.open_amount > 0 AND oi.due_date < t.d)        AS agg_days_max
    FROM open_items oi
    CROSS JOIN today t
    GROUP BY oi.ca_id
  )
  SELECT
    c.id       AS client_id,
    c.name     AS client_name,
    -- cobranzas-vencimientos (D12): el recordatorio de WhatsApp de /cobranzas
    -- necesita el telefono del deudor — mismo dato que ya expone /clientes.
    c.phone    AS client_phone,
    ca.balance AS balance,
    (t.d - (lm.last_charge_at  AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_charge,
    (t.d - (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_payment,
    (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date                  AS last_payment_date,
    COALESCE(ag.agg_overdue_total, 0) AS overdue_total,
    COALESCE(ag.agg_current, 0)       AS amount_current,
    COALESCE(ag.agg_1_30, 0)          AS amount_overdue_1_30,
    COALESCE(ag.agg_31_60, 0)         AS amount_overdue_31_60,
    COALESCE(ag.agg_60_plus, 0)       AS amount_overdue_60_plus,
    COALESCE(ag.agg_no_due, 0)        AS amount_no_due_date,
    ag.agg_oldest_due                 AS oldest_due_date,
    ag.agg_days_max::integer          AS days_overdue_max
  FROM public.customer_accounts ca
  JOIN public.clients c ON c.id = ca.client_id
  LEFT JOIN last_moves lm ON lm.ca_id = ca.id
  LEFT JOIN aging ag ON ag.ca_id = ca.id
  CROSS JOIN today t
  -- D5 Etapa A: sólo deuda viva y clientes vigentes (mismo criterio que /clientes).
  WHERE ca.account_id = p_account_id
    AND ca.balance > 0
    AND c.deleted_at IS NULL
  ORDER BY ca.balance DESC;
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_receivables_report(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_receivables_report(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_receivables_report(uuid) IS
  $c$cobranzas-panel + cobranzas-vencimientos: read-model agregado de cuentas por cobrar con aging FIFO por línea de flotación (D4) — 5 tramos que suman el balance (invariante de cierre), sin materializar imputaciones. Sólo cargos con vencimiento pueden estar vencidos (D5); sin vencimiento es tramo propio. Día argentino via reporting_local_today(). Excluye balance = 0 y clientes con deleted_at. Guard P0401 primera sentencia. edicion-operaciones-con-dinero (D9): el abierto por cargo sale de _customer_open_items (la reversión de un cargo cancela primero los cargos de su misma referencia).$c$;


-- =============================================================================
-- 7. rpc_payables_report — abierto por cargo desde _supplier_open_items. Partida: md5 30404ab9… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_payables_report(p_account_id uuid)
 RETURNS TABLE(supplier_id uuid, supplier_name text, balance numeric, days_since_last_charge integer, days_since_last_payment integer, last_payment_date date, overdue_total numeric, amount_current numeric, amount_overdue_1_30 numeric, amount_overdue_31_60 numeric, amount_overdue_60_plus numeric, amount_no_due_date numeric, oldest_due_date date, days_overdue_max integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-vencimientos (D6): espejo TEXTUAL de rpc_receivables_report sobre
  supplier_accounts/suppliers — cargo = 'purchase' + 'adjustment' positivo;
  crédito = pagos/notas de débito/anulaciones con su signo. Mismas garantías:
  guard P0401 primera sentencia, invariante de cierre, día argentino,
  exclusión de balance = 0 y proveedores con deleted_at.
*/
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  RETURN QUERY
  WITH today AS (
    SELECT public.reporting_local_today() AS d
  ),
  last_moves AS (
    SELECT
      m.supplier_account_id                                             AS sa_id,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'purchase')     AS last_charge_at,
      MAX(m.created_at) FILTER (WHERE m.movement_type = 'payment_made') AS last_payment_at
    FROM public.supplier_account_movements m
    WHERE m.account_id = p_account_id
    GROUP BY m.supplier_account_id
  ),
  open_items AS (
    -- edicion-operaciones-con-dinero (D9): el abierto de cada cargo sale de la derivación ÚNICA
    -- (_supplier_open_items), con la reversión de un cargo emparejada con los cargos de su referencia.
    SELECT oi.party_account_id AS sa_id, oi.due_date, oi.open_amount
    FROM public._supplier_open_items(p_account_id) oi
  ),
  aging AS (
    SELECT oi.sa_id,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date <  t.d), 0) AS agg_overdue_total,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND oi.due_date >= t.d), 0) AS agg_current,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 1 AND 30), 0)  AS agg_1_30,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) BETWEEN 31 AND 60), 0) AS agg_31_60,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NOT NULL AND (t.d - oi.due_date) > 60), 0)              AS agg_60_plus,
      COALESCE(SUM(oi.open_amount) FILTER (WHERE oi.due_date IS NULL), 0)                                               AS agg_no_due,
      MIN(oi.due_date) FILTER (WHERE oi.open_amount > 0)                                    AS agg_oldest_due,
      MAX(t.d - oi.due_date) FILTER (WHERE oi.open_amount > 0 AND oi.due_date < t.d)        AS agg_days_max
    FROM open_items oi
    CROSS JOIN today t
    GROUP BY oi.sa_id
  )
  SELECT
    s.id       AS supplier_id,
    s.name     AS supplier_name,
    sa.balance AS balance,
    (t.d - (lm.last_charge_at  AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_charge,
    (t.d - (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date)::integer AS days_since_last_payment,
    (lm.last_payment_at AT TIME ZONE 'America/Argentina/Mendoza')::date                  AS last_payment_date,
    COALESCE(ag.agg_overdue_total, 0) AS overdue_total,
    COALESCE(ag.agg_current, 0)       AS amount_current,
    COALESCE(ag.agg_1_30, 0)          AS amount_overdue_1_30,
    COALESCE(ag.agg_31_60, 0)         AS amount_overdue_31_60,
    COALESCE(ag.agg_60_plus, 0)       AS amount_overdue_60_plus,
    COALESCE(ag.agg_no_due, 0)        AS amount_no_due_date,
    ag.agg_oldest_due                 AS oldest_due_date,
    ag.agg_days_max::integer          AS days_overdue_max
  FROM public.supplier_accounts sa
  JOIN public.suppliers s ON s.id = sa.supplier_id
  LEFT JOIN last_moves lm ON lm.sa_id = sa.id
  LEFT JOIN aging ag ON ag.sa_id = sa.id
  CROSS JOIN today t
  WHERE sa.account_id = p_account_id
    AND sa.balance > 0
    AND s.deleted_at IS NULL
  ORDER BY sa.balance DESC;
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_payables_report(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_payables_report(uuid) TO authenticated;
COMMENT ON FUNCTION public.rpc_payables_report(uuid) IS
  $c$cobranzas-vencimientos (D6): read-model de cuentas por pagar — espejo textual de rpc_receivables_report sobre supplier_accounts. Mismos tramos, mismo invariante de cierre, mismas garantías de tenencia. edicion-operaciones-con-dinero (D9): el abierto por cargo sale de _supplier_open_items.$c$;


-- =============================================================================
-- 8. _produce_receivables_overdue_digest — abierto por cargo desde las funciones únicas. Partida: md5 1e30cc2d… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public._produce_receivables_overdue_digest()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  cobranzas-vencimientos (D8/D9): UN aviso resumido por cuenta, por lado y
  por día calendario argentino, SOLO sobre lo VENCIDO (overdue_total > 0).
  La derivación FIFO es la misma línea de flotación de los read-models (D4);
  OQ-2 firmada: clientes/proveedores dados de baja EXCLUIDOS (mismo D5 de la
  Etapa A — el aviso no nombra partes que la aplicación no lista).
  Destinatario: el propietario de la cuenta (precedente PlanLimitExceeded).
  Solo lectura sobre los libros: no toca saldos, movimientos ni asientos.
*/
DECLARE
  n_recv  integer := 0;
  n_pay   integer := 0;
  v_today date := public.reporting_local_today();
BEGIN
  -- ── Lado POR COBRAR ────────────────────────────────────────────────────────
  WITH open_overdue AS (
    -- edicion-operaciones-con-dinero (D9): abierto por cargo desde la derivación ÚNICA (_customer_open_items,
    -- todas las cuentas: p_account_id NULL), con la reversión de un cargo emparejada con los de su referencia.
    SELECT oi.account_id, oi.party_account_id AS ca_id, oi.open_amount
    FROM public._customer_open_items(NULL) oi
    WHERE oi.due_date IS NOT NULL AND oi.due_date < v_today
  ),
  per_account AS (
    SELECT oo.account_id,
           COUNT(DISTINCT ca.client_id) FILTER (WHERE oo.open_amount > 0) AS party_count,
           SUM(oo.open_amount) AS overdue_total
    FROM open_overdue oo
    JOIN public.customer_accounts ca ON ca.id = oo.ca_id
    JOIN public.clients c ON c.id = ca.client_id
    WHERE ca.balance > 0 AND c.deleted_at IS NULL
    GROUP BY oo.account_id
    HAVING SUM(oo.open_amount) > 0
  ),
  candidates AS (
    SELECT pa.account_id, a.owner_user_id AS user_id, au.email AS recipient,
           pa.party_count, pa.overdue_total
    FROM per_account pa
    JOIN public.accounts a ON a.id = pa.account_id
    JOIN auth.users au ON au.id = a.owner_user_id
    WHERE NOT EXISTS (  -- D8 capa 2: dedup por día argentino, aunque cambien los importes
      SELECT 1 FROM public.email_logs el
      WHERE el.user_id = a.owner_user_id
        AND el.event_type = 'receivables_overdue_digest'
        AND el.metadata->>'as_of' = v_today::text
        AND (el.metadata->>'account_id')::uuid = pa.account_id
    )
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'receivables_overdue_digest', recipient,
           'Tenés deuda vencida por cobrar — ALIADATA',
           jsonb_build_object('account_id', account_id, 'as_of', v_today::text,
                              'party_count', party_count, 'overdue_total', overdue_total)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING (metadata->>'account_id')::uuid AS account_id
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'ReceivablesOverdueDigest', 'ReceivablesDigest', c.account_id,
           jsonb_build_object('account_id', c.account_id, 'as_of', v_today::text,
                              'party_count', c.party_count, 'overdue_total', c.overdue_total),
           now()
    FROM candidates c
    JOIN ins_email e ON e.account_id = c.account_id
    RETURNING 1
  )
  SELECT count(*) INTO n_recv FROM ins_email;

  -- ── Lado POR PAGAR (espejo) ────────────────────────────────────────────────
  WITH open_overdue AS (
    -- edicion-operaciones-con-dinero (D9): espejo — _supplier_open_items.
    SELECT oi.account_id, oi.party_account_id AS sa_id, oi.open_amount
    FROM public._supplier_open_items(NULL) oi
    WHERE oi.due_date IS NOT NULL AND oi.due_date < v_today
  ),
  per_account AS (
    SELECT oo.account_id,
           COUNT(DISTINCT sa.supplier_id) FILTER (WHERE oo.open_amount > 0) AS party_count,
           SUM(oo.open_amount) AS overdue_total
    FROM open_overdue oo
    JOIN public.supplier_accounts sa ON sa.id = oo.sa_id
    JOIN public.suppliers s ON s.id = sa.supplier_id
    WHERE sa.balance > 0 AND s.deleted_at IS NULL
    GROUP BY oo.account_id
    HAVING SUM(oo.open_amount) > 0
  ),
  candidates AS (
    SELECT pa.account_id, a.owner_user_id AS user_id, au.email AS recipient,
           pa.party_count, pa.overdue_total
    FROM per_account pa
    JOIN public.accounts a ON a.id = pa.account_id
    JOIN auth.users au ON au.id = a.owner_user_id
    WHERE NOT EXISTS (
      SELECT 1 FROM public.email_logs el
      WHERE el.user_id = a.owner_user_id
        AND el.event_type = 'payables_overdue_digest'
        AND el.metadata->>'as_of' = v_today::text
        AND (el.metadata->>'account_id')::uuid = pa.account_id
    )
  ),
  ins_email AS (
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    SELECT user_id, 'payables_overdue_digest', recipient,
           'Tenés deuda vencida con proveedores — ALIADATA',
           jsonb_build_object('account_id', account_id, 'as_of', v_today::text,
                              'party_count', party_count, 'overdue_total', overdue_total)
    FROM candidates
    ON CONFLICT (user_id, event_type, metadata) DO NOTHING
    RETURNING (metadata->>'account_id')::uuid AS account_id
  ),
  ins_event AS (
    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    SELECT c.account_id, 'PayablesOverdueDigest', 'PayablesDigest', c.account_id,
           jsonb_build_object('account_id', c.account_id, 'as_of', v_today::text,
                              'party_count', c.party_count, 'overdue_total', c.overdue_total),
           now()
    FROM candidates c
    JOIN ins_email e ON e.account_id = c.account_id
    RETURNING 1
  )
  SELECT count(*) INTO n_pay FROM ins_email;

  RETURN n_recv + n_pay;
END;
$function$;


REVOKE ALL ON FUNCTION public._produce_receivables_overdue_digest() FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._produce_receivables_overdue_digest() IS
  $c$cobranzas-vencimientos (D8/D9): barrido diario — UN resumen de deuda vencida por cuenta, por lado (cobrar/pagar) y por día argentino, por los dos canales (email_logs + evento al outbox para la campana) con UN solo dedup: el evento se crea SOLO para las filas que el INSERT de email realmente insertó. Capa 2 de dedup por metadata->as_of (los importes viajan en metadata y cambiarían el conflicto de la capa 1). Excluye partes dadas de baja (OQ-2) y solo cuenta lo vencido (D9). edicion-operaciones-con-dinero (D9): el abierto por cargo sale de _customer_open_items / _supplier_open_items.$c$;


-- =============================================================================
-- 9. rpc_update_customer_charge_due_date — abierto desde _customer_open_items. Partida: md5 3caedef0… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_update_customer_charge_due_date(p_movement_id uuid, p_due_date date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_movement         public.customer_account_movements%ROWTYPE;
  v_open_amount       numeric(15,2);
  v_due_date_before   date;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Tenencia: id + account_id — nunca revela si el cargo existe en OTRA cuenta.
  SELECT * INTO v_movement
  FROM public.customer_account_movements
  WHERE id = p_movement_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'charge_not_found: %', p_movement_id USING ERRCODE = 'P0404';
  END IF;

  -- Mismo vocabulario FIFO que rpc_receivables_report: sólo sale + adjustment
  -- positivo son CARGO. Un cobro/nota/reversa no tiene vencimiento propio que
  -- editar (D7 de cobranzas-vencimientos: due_date sólo existe en la fila del
  -- cargo — un no-cargo con due_date sería un estado nunca producido).
  IF NOT (v_movement.movement_type = 'sale'
          OR (v_movement.movement_type = 'adjustment' AND v_movement.amount > 0)) THEN
    RAISE EXCEPTION 'not_a_charge: movement_type=%, amount=%', v_movement.movement_type, v_movement.amount
      USING ERRCODE = 'P0400';
  END IF;

  -- open_amount del cargo (ANTES del cambio) — misma derivación FIFO que
  -- rpc_receivables_report, acotada al customer_account_id de este cargo.
  -- edicion-operaciones-con-dinero (D9): MISMA derivación que los reportes (_customer_open_items, con la reversión
  -- de un cargo emparejada con los cargos de su referencia), acotada a la cuenta corriente de este cargo.
  SELECT oi.open_amount
  INTO v_open_amount
  FROM public._customer_open_items(v_account_id, v_movement.customer_account_id) oi
  WHERE oi.id = p_movement_id;

  IF COALESCE(v_open_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'charge_fully_settled: el cargo % no tiene saldo abierto', p_movement_id
      USING ERRCODE = 'P0400';
  END IF;

  v_due_date_before := v_movement.due_date;

  -- ÚNICA mutación de este ledger append-only: SOLO due_date, scoped por
  -- id + account_id (defensa en profundidad, ya validado arriba).
  UPDATE public.customer_account_movements
  SET due_date = p_due_date
  WHERE id = p_movement_id AND account_id = v_account_id;

  INSERT INTO public.audit_logs
    (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    v_account_id, v_uid, 'customer_charge.due_date_changed', 'customer_account_movement', p_movement_id,
    jsonb_build_object(
      'due_date_before', v_due_date_before,
      'due_date_after',  p_due_date,
      'reason',          p_reason,
      'movement_type',   v_movement.movement_type,
      'amount',          v_movement.amount
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',       p_movement_id,
    'due_date',          p_due_date,
    'previous_due_date', v_due_date_before
  );
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_customer_charge_due_date(uuid, date, text) IS
  $c$cobranzas-vencimientos OQ-1: corrige el vencimiento de un cargo (sale/adjustment>0) abierto de customer_account_movements. Guard is_account_writer (owner/admin, P0401); P0403 sin cuenta activa; P0404 cargo de otra cuenta; P0400 no-cargo o cargo saldado. p_due_date NULL limpia el vencimiento. Única mutación permitida sobre este ledger append-only — auditada en audit_logs (customer_charge.due_date_changed) con before/after. edicion-operaciones-con-dinero (D9): el abierto del cargo sale de _customer_open_items.$c$;


-- =============================================================================
-- 10. rpc_update_supplier_charge_due_date — abierto desde _supplier_open_items. Partida: md5 6e00eaf7… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_update_supplier_charge_due_date(p_movement_id uuid, p_due_date date, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_movement         public.supplier_account_movements%ROWTYPE;
  v_open_amount       numeric(15,2);
  v_due_date_before   date;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM public.current_account_ids() AS cai
  LIMIT 1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'sin_cuenta_activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  SELECT * INTO v_movement
  FROM public.supplier_account_movements
  WHERE id = p_movement_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'charge_not_found: %', p_movement_id USING ERRCODE = 'P0404';
  END IF;

  IF NOT (v_movement.movement_type = 'purchase'
          OR (v_movement.movement_type = 'adjustment' AND v_movement.amount > 0)) THEN
    RAISE EXCEPTION 'not_a_charge: movement_type=%, amount=%', v_movement.movement_type, v_movement.amount
      USING ERRCODE = 'P0400';
  END IF;

  -- edicion-operaciones-con-dinero (D9): espejo — _supplier_open_items, acotada a la cuenta corriente de este cargo.
  SELECT oi.open_amount
  INTO v_open_amount
  FROM public._supplier_open_items(v_account_id, v_movement.supplier_account_id) oi
  WHERE oi.id = p_movement_id;

  IF COALESCE(v_open_amount, 0) <= 0 THEN
    RAISE EXCEPTION 'charge_fully_settled: el cargo % no tiene saldo abierto', p_movement_id
      USING ERRCODE = 'P0400';
  END IF;

  v_due_date_before := v_movement.due_date;

  UPDATE public.supplier_account_movements
  SET due_date = p_due_date
  WHERE id = p_movement_id AND account_id = v_account_id;

  INSERT INTO public.audit_logs
    (account_id, user_id, action, entity_type, entity_id, metadata, created_at)
  VALUES (
    v_account_id, v_uid, 'supplier_charge.due_date_changed', 'supplier_account_movement', p_movement_id,
    jsonb_build_object(
      'due_date_before', v_due_date_before,
      'due_date_after',  p_due_date,
      'reason',          p_reason,
      'movement_type',   v_movement.movement_type,
      'amount',          v_movement.amount
    ),
    now()
  );

  RETURN jsonb_build_object(
    'movement_id',       p_movement_id,
    'due_date',          p_due_date,
    'previous_due_date', v_due_date_before
  );
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_supplier_charge_due_date(uuid, date, text) IS
  $c$cobranzas-vencimientos OQ-1: espejo de rpc_update_customer_charge_due_date sobre supplier_account_movements (purchase/adjustment>0 es cargo). Guard is_account_writer (owner/admin, P0401); P0403 sin cuenta activa; P0404 cargo de otra cuenta; P0400 no-cargo o cargo saldado. p_due_date NULL limpia el vencimiento. Auditado en audit_logs (supplier_charge.due_date_changed). edicion-operaciones-con-dinero (D9): el abierto del cargo sale de _supplier_open_items.$c$;
