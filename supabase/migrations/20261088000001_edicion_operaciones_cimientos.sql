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

-- =============================================================================
-- 11. _journal_purchase_lines — la resolución de cuentas de una compra, UNA sola vez
-- =============================================================================
-- PurchaseCreated (asiento de alta) y PurchaseAdjusted (asiento de reemplazo de una edición) postean las líneas con
-- ESTA función: así las dos ramas no pueden divergir. Débito: 5100 CMV (con el centro de costo) + 5200 IVA crédito
-- fiscal, o 5100 único por el total si no hay desglose. Crédito: 1100 Caja si la compra fue en efectivo; todo lo
-- demás (crédito, transferencia, billetera, ...) a 2100 Proveedores — el mapeo vigente de PurchaseCreated, sin cambios.
-- Devuelve las sumas de débito y crédito para el ASSERT de balance del llamador (P0450). SECURITY INVOKER: la llama
-- sólo _journal_post_from_event (SECURITY DEFINER), nunca la aplicación.
CREATE OR REPLACE FUNCTION public._journal_purchase_lines(p_entry_id uuid, p_account_id uuid, p_total numeric, p_payment_method text, p_neto numeric, p_iva numeric, p_cost_center_id uuid, OUT o_debit numeric, OUT o_credit numeric)
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
    v_line_no int := 1;
BEGIN
    o_debit  := 0;
    o_credit := 0;

    -- Debit: 5100 CMV [neto + cost_center] + 5200 IVA CF [iva, cc=NULL] o bien 5100 único [total] si no hay desglose
    IF p_neto IS NOT NULL AND p_iva IS NOT NULL THEN
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (p_entry_id, p_account_id, '5100', 'debit', p_neto, v_line_no, p_cost_center_id);
        o_debit := o_debit + p_neto;

        v_line_no := v_line_no + 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (p_entry_id, p_account_id, '5200', 'debit', p_iva, v_line_no, NULL);
        o_debit := o_debit + p_iva;
    ELSE
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (p_entry_id, p_account_id, '5100', 'debit', p_total, v_line_no, p_cost_center_id);
        o_debit := o_debit + p_total;
    END IF;

    -- Credit: 2100 Proveedores (credit) o 1100 Caja (cash)
    v_line_no := v_line_no + 1;
    IF p_payment_method = 'cash' THEN
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (p_entry_id, p_account_id, '1100', 'credit', p_total, v_line_no, NULL);
    ELSE
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (p_entry_id, p_account_id, '2100', 'credit', p_total, v_line_no, NULL);
    END IF;
    o_credit := o_credit + p_total;
END;
$function$;

REVOKE ALL ON FUNCTION public._journal_purchase_lines(uuid, uuid, numeric, text, numeric, numeric, uuid) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._journal_purchase_lines(uuid, uuid, numeric, text, numeric, numeric, uuid) IS
  $c$edicion-operaciones-con-dinero (D10): líneas del asiento de una compra (5100 [+5200] / 1100 o 2100), compartidas por PurchaseCreated y PurchaseAdjusted. Interna: sólo la llama _journal_post_from_event.$c$;


-- =============================================================================
-- 12. _journal_post_from_event — asiento vigente (reversal_of IS NULL), dos convenciones y PurchaseAdjusted (15 tipos).
--     Partida: md5 d7bfbb92… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public._journal_post_from_event(p_event events)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  journal-entry-outbox Consumer 3 — Helper de posting de asientos de partida doble.
  bank-payment-routing C2: agrega ruteo 1110 Banco (bancario) vs 1100 Caja (cash/other)
  en SaleConfirmed/PaymentReceived/PaymentMade, leído del payment_method del payload.
  pagos-cableados-restantes (D7/OQ-1): 'wallet' se suma al vocabulario
  bancario en esas tres ramas — antes caía en 1100 Caja por omisión, ahora
  rutea a 1110 Banco como transfer/card/check (recomendación fundada, OQ-1
  del design.md — reversible con un one-liner si el PO decide otra cosa).

  asiento-venta-formulario (2026-08-20): agrega DOS ramas operation-level,
  moldeadas sobre PurchaseCreated: SaleOperationCreated / SaleOperationAdjusted.

  delete-guard-ledgers (2026-08-22): agrega DOS ramas de contra-asiento por
  borrado, calcadas de la PRIMERA MITAD de SaleOperationAdjusted (localizar +
  revertir, SIN la segunda mitad de asiento-de-reemplazo — el borrado no
  reemplaza, solo revierte):
    - SaleOperationDeleted: resuelve el asiento vigente probando las DOS
      convenciones en orden — (SaleOperation, operation_id) primero
      (formulario), luego (SalesOrder, sales_order_id) (POS) — mismo
      predicado de dos convenciones que gobierna todo el change
      (operation-delete-compensation D2).
    - PurchaseDeleted: única convención (Purchase, operation_id) — las
      compras no tienen el concepto de doble referencia de la venta.
    Ambas ramas: la contra-entry es la ÚNICA entry del evento (a diferencia
    de SaleOperationAdjusted) → SÍ lleva su propio source_event_id —
    trazabilidad evento→asiento completa (ventaja documentada en design §D7).
    El ASSERT de balance común del final de la función las cubre sin código
    adicional (mismo mecanismo que ya usan las 7 ramas preexistentes).

  cobranzas-reverso (2026-09-02): agrega DOS ramas de contra-asiento por
  ANULACIÓN de un cobro/pago, mismo molde que SaleOperationDeleted/
  PurchaseDeleted (localizar + revertir, la contra-entry es la única entry
  del evento). Única convención de referencia en los dos casos — el cobro y
  el pago, a diferencia de la venta, tienen un solo camino de alta:
    - PaymentReceivedReversed: localiza por (CustomerAccount, payment_id).
    - PaymentMadeReversed: localiza por (SupplierAccount, payment_id).
  D5: diferir esta reversión NO era una opción — a diferencia del gasto y la
  compra en efectivo (cuyos asientos no existían cuando se cablearon sus
  libros de dinero), las ramas PaymentReceived/PaymentMade YA estaban vivas y
  el 100% de los pagos históricos tenía asiento posted.

  asiento-contable-gastos (2026-09-10): agrega TRES ramas de gasto — el
  último documento operativo que movía dinero sin dejar rastro contable
  (D10 de gastos-forma-pago). Débito único a 5300 Gastos con el
  cost_center_id de la línea (mismo trato que 5100 en PurchaseCreated);
  crédito por _journal_expense_credit_account(kind), espejo de
  _journal_sale_debit_account menos el caso credit (D4):
    - ExpenseCreated: asiento nuevo, fechado por la fecha de negocio del
      gasto (D5, mismo idioma que SaleOperationCreated).
    - ExpenseAdjusted: molde BYTE A BYTE de SaleOperationAdjusted — localizar
      + revertir + volver a postear con los valores editados.
    - ExpenseDeleted: molde de SaleOperationDeleted/PurchaseDeleted — SOLO
      revertir, la contra-entry es la única entry del evento. La
      localización NO lee public.expenses: el borrado del gasto es físico y
      la fila ya no existe cuando el relay corre.
  D7 (en las tres RPC de gasto, no acá): el productor de ExpenseAdjusted y
  ExpenseDeleted sólo emite si existe un ExpenseCreated previo — evita el
  evento envenenado de un gasto histórico sin backfill (OQ-3).
  El conjunto canónico pasa de 11 a 14 tipos (D8) — invariante verificado por
  supabase/tests/test_cobranzas_reverso.sql bloque (11), cableado a CI en
  este mismo PR.

  edicion-operaciones-con-dinero (tanda A, D2/D10): con el identificador de operación ESTABLE una misma referencia
  acumula el asiento original (reversed), su contra-asiento (posted, reversal_of <> NULL) y el asiento nuevo (posted):
  toda búsqueda del asiento VIGENTE excluye los contra-asientos (`reversal_of IS NULL`, la más reciente primero), el
  patrón que ExpenseAdjusted ya usaba. Cambia sólo la localización del asiento a revertir:
    - SaleOperationAdjusted: resuelve las DOS convenciones (SaleOperation por old_operation_id; SalesOrder por el
      sales_order_id del payload) y su contra-asiento conserva el tipo y la referencia del asiento que revierte.
    - SaleOperationDeleted y PurchaseDeleted: asiento vigente, no cualquiera 'posted'.
    - CreditNoteIssued: SalesOrder primero y, si no hay, (SaleOperation, sales_orders.sale_operation_id): una venta
      del POS editada y facturada tiene su asiento vigente como SaleOperation.
    - PurchaseAdjusted (15° tipo): revierte el asiento vigente de la compra (old_operation_id, como PurchaseDeleted) y
      postea el de reemplazo con las mismas líneas que PurchaseCreated (_journal_purchase_lines, resolución única).
  El conjunto canónico pasa de 14 a 15 tipos (este filtro y el del Consumer 3 de rpc_process_outbox_dispatch).

  Responsabilidades:
    1. Filtrar por event_type (15 tipos en-scope; no-op para el resto).
    2. Reclamar slot de idempotencia (event_id, 'JournalEntry') en operation_idempotency.
    3. Calcular las líneas de débito/crédito según el mapeo hardcodeado (D1, D4 del
       change journal-entry-outbox) + ruteo bancario (C2 D3, extendido por
       pagos-cableados-restantes D7) + mapeo de gasto (asiento-contable-gastos D4).
    4. Validar Σdébito = Σcrédito (ASSERT — D5, ERRCODE P0450).
    5. INSERT journal_entries + journal_lines.

  Codigos de cuenta hardcodeados (D1 journal-entry-outbox — plan mínimo PYME AR):
    1100 Caja / 1110 Banco (C2: wireado — antes reservado) / 1300 Deudores por Ventas
    2100 Proveedores / 4100 Ventas / 4200 IVA Débito Fiscal
    5100 CMV/Compras / 5200 IVA Crédito Fiscal / 5300 Gastos (asiento-contable-gastos: EN USO)

  Ruteo bancario (C2 D3, extendido pagos-cableados-restantes D7): "es método
  bancario" = payment_method IN ('transfer','card','check','wallet').
  SaleConfirmed:    credit→1300; bancario→1110; cash/other/NULL→1100 (débito).
  PaymentReceived:  bancario→1110; cash/NULL→1100 (débito).
  PaymentMade:      bancario→1110; cash/NULL→1100 (crédito).
  PurchaseCreated:  SIN CAMBIOS — cash→1100; todo lo demás (incl. wallet)→2100
                     Proveedores (no tiene predicado v_is_bank — D8 original).
  SaleOperationCreated / SaleOperationAdjusted (nuevo entry): mismo mapeo
                     que SaleConfirmed pero vía _journal_sale_debit_account(kind),
                     y el sin-imputar (NULL) rutea a 1100 (D3, deliberadamente
                     distinto del default 'credit' de PurchaseCreated).
  ExpenseCreated / ExpenseAdjusted (nuevo entry): _journal_expense_credit_account(kind)
                     — bancario→1110; cash/other/sin-imputar→1100; SIN rama credit.

  Notas de diseño:
    - El balance falla → RAISE EXCEPTION USING ERRCODE = 'P0450' → el event queda
      pending para retry; el batch NO aborta (BEGIN/EXCEPTION en rpc_process_outbox_dispatch).
    - account_id denormalizado en journal_lines (D7 — RLS sin subquery por fila).
    - SaleConfirmed: lookup JOIN sales_orders → fiscal_documents para neto/iva (D3/D9).
    - PurchaseCreated: neto/iva del payload (productor enriquecido en migración 2) — SIN CAMBIOS.
    - CreditNoteIssued: reversión del asiento original (D10) — SIN CAMBIOS.
    - SECURITY DEFINER + SET search_path: patrón C-25.

  ERRCODE custom:
    P0450 — balance falla (libre en espacio P04xx del proyecto).
    P0451 — asiento original no encontrado para NC / SaleOperationAdjusted /
            SaleOperationDeleted / PurchaseDeleted / PurchaseAdjusted / PaymentReceivedReversed /
            PaymentMadeReversed / ExpenseAdjusted / ExpenseDeleted (retry).
*/
DECLARE
    v_account_id      uuid;
    v_entry_id        uuid;
    v_payload         jsonb;
    v_event_type      text;

    -- Lookup fields
    v_total           numeric(14,2);
    v_payment_method  text;
    v_is_bank         boolean;
    v_neto            numeric(14,2);
    v_iva             numeric(14,2);
    v_comp_type       text;
    v_cost_center_id  uuid;
    v_operation_id    uuid;
    -- cobranzas-reverso: identificador del cobro/pago anulado, source_doc_ref
    -- de las dos ramas nuevas.
    v_payment_id      uuid;
    -- asiento-contable-gastos: identificador del gasto, source_doc_ref de
    -- las tres ramas nuevas.
    v_expense_id      uuid;

    -- Reversal
    v_original_id     uuid;
    v_orig_entry_id   uuid;
    v_sales_order_id  uuid;   -- edicion-operaciones-con-dinero: orden del POS (segunda convención)
    v_sums            record;  -- edicion-operaciones-con-dinero: sumas de _journal_purchase_lines

    -- Balance tracking
    v_sum_debit       numeric(14,2) := 0;
    v_sum_credit      numeric(14,2) := 0;
    v_line_no         int := 0;

    -- Idempotency
    v_claimed         bool;

    -- asiento-venta-formulario: posted_at por D5 (fecha de la venta, no el
    -- instante del relay) para SaleOperationCreated / la mitad "nueva" de
    -- SaleOperationAdjusted. asiento-contable-gastos reutiliza la misma
    -- variable para el mismo propósito en las ramas de gasto.
    v_posted_at       timestamptz;
BEGIN
    v_account_id := p_event.account_id;
    v_payload     := p_event.payload;
    v_event_type  := p_event.event_type;

    -- ── Filtro: solo los 15 tipos en-scope ───────────────────────────────────
    -- asiento-contable-gastos: suma ExpenseCreated / ExpenseAdjusted /
    -- ExpenseDeleted (11→14). Este filtro y el de rpc_process_outbox_dispatch
    -- DEBEN listar el mismo conjunto (invariante documentado desde
    -- journal-entry-outbox, verificado por gate desde cobranzas-reverso — D13,
    -- ampliado a 14 por D8 de este change; edicion-operaciones-con-dinero suma PurchaseAdjusted: 15).
    IF v_event_type NOT IN (
        'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
        'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
        'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted',
        'PaymentReceivedReversed', 'PaymentMadeReversed',
        'ExpenseCreated', 'ExpenseAdjusted', 'ExpenseDeleted',
        'PurchaseAdjusted'
    ) THEN
        RETURN;  -- no-op para eventos fuera de alcance
    END IF;

    -- ── Idempotencia: reclamar slot (event_id, 'JournalEntry') ───────────────
    INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
    VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        p_event.id::text || ':JournalEntry',
        'event_consumer',
        p_event.id,
        'JournalEntry'
    )
    ON CONFLICT (event_id, consumer_type)
    WHERE event_id IS NOT NULL
    DO NOTHING;

    GET DIAGNOSTICS v_claimed = ROW_COUNT;

    IF NOT v_claimed THEN
        -- Slot ya existía → skip idempotente (el asiento ya fue posteado)
        RETURN;
    END IF;

    -- ── Dispatch por event_type ───────────────────────────────────────────────

    IF v_event_type = 'SaleConfirmed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- SaleConfirmed: 1100/1110/1300 → 4100 + 4200 (D3, D4 journal-entry-outbox;
        -- C2 D3: ruteo bancario del débito por payment_method; D7
        -- pagos-cableados-restantes: wallet se suma al vocabulario bancario)
        -- Lookup JOIN para comprobante_type/neto/iva_amount (D9 — no modificamos C-29)
        -- SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check', 'wallet');

        -- Lookup fiscal_documents via sales_orders.fiscal_document_id
        SELECT
            fd.comprobante_type,
            fd.neto,
            fd.iva_amount
        INTO
            v_comp_type,
            v_neto,
            v_iva
        FROM public.sales_orders so
        LEFT JOIN public.fiscal_documents fd ON fd.id = so.fiscal_document_id
        WHERE so.id = (v_payload->>'sales_order_id')::uuid;

        -- INSERT entry header
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'SalesOrder',
            (v_payload->>'sales_order_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        -- Debit: 1300 Deudores (credit) o 1110 Banco (bancario) o 1100 Caja (cash/other)
        v_line_no := 1;
        IF v_payment_method = 'credit' THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1300', 'debit', v_total, v_line_no, NULL);
        ELSIF v_is_bank THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1110', 'debit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'debit', v_total, v_line_no, NULL);
        END IF;
        v_sum_debit := v_sum_debit + v_total;

        -- Credit: 4100 + 4200 (Factura A/B con desglose) o 4100 solo (C/sin doc) — SIN CAMBIOS
        IF v_comp_type IN ('factura_a', 'factura_b')
           AND v_neto IS NOT NULL
           AND v_iva IS NOT NULL
        THEN
            -- Factura A/B: crédito 4100 Ventas [neto] + 4200 IVA DF [iva]
            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4100', 'credit', v_neto, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_neto;

            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4200', 'credit', v_iva, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_iva;
        ELSE
            -- Factura C / sin comprobante / sin desglose: crédito único 4100 [total]
            v_line_no := v_line_no + 1;
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
            v_sum_credit := v_sum_credit + v_total;
        END IF;

    ELSIF v_event_type = 'PurchaseCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PurchaseCreated: 5100 + 5200 → 2100/1100 (D4, D8 journal-entry-outbox) — SIN CAMBIOS
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := COALESCE(v_payload->>'payment_method', 'credit');
        v_neto           := (v_payload->>'neto')::numeric(14,2);
        v_iva            := (v_payload->>'iva_amount')::numeric(14,2);
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;
        v_operation_id   := (v_payload->>'operation_id')::uuid;

        -- Si no hay cost_center_id en el payload, intentar lookup a purchases
        IF v_cost_center_id IS NULL AND v_operation_id IS NOT NULL THEN
            SELECT cost_center_id INTO v_cost_center_id
            FROM public.purchases
            WHERE operation_id = v_operation_id
            LIMIT 1;
        END IF;

        -- INSERT entry header
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'Purchase',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        -- Líneas (débito 5100 [+5200] / crédito 1100 o 2100): resolución ÚNICA compartida con PurchaseAdjusted
        -- (edicion-operaciones-con-dinero, D10) — mismo mapeo de siempre.
        SELECT * INTO v_sums FROM public._journal_purchase_lines(
            v_entry_id, v_account_id, v_total, v_payment_method, v_neto, v_iva, v_cost_center_id);
        v_sum_debit  := v_sum_debit  + v_sums.o_debit;
        v_sum_credit := v_sum_credit + v_sums.o_credit;

    ELSIF v_event_type = 'SaleOperationCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-venta-formulario (D1-D6): molde operation-level de
        -- PurchaseCreated. SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';  -- crudo, puede ser NULL (D6 productor)
        v_operation_id   := (v_payload->>'operation_id')::uuid;

        IF v_payload->>'sale_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'sale_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'SaleOperation',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_sale_debit_account(v_payment_method),
                'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'SaleOperationAdjusted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-venta-formulario (D7, override del PO): edición sobre una
        -- operación cuyo asiento ya fue posteado. SIN CAMBIOS (delete-guard-
        -- ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_original_id := (v_payload->>'old_operation_id')::uuid;

        -- edicion-operaciones-con-dinero (D2/D10): asiento VIGENTE (sin contra-asientos, el más reciente) y las
        -- DOS convenciones: (SaleOperation, old_operation_id) primero; (SalesOrder, sales_order_id) si el payload
        -- la trae (venta del POS o presupuestada).
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_original_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL AND v_payload->>'sales_order_id' IS NOT NULL THEN
            SELECT id INTO v_orig_entry_id
            FROM public.journal_entries
            WHERE source_doc_type = 'SalesOrder'
              AND source_doc_ref  = (v_payload->>'sales_order_id')::uuid
              AND status          = 'posted'
              AND reversal_of     IS NULL
              AND account_id      = v_account_id
            ORDER BY posted_at DESC, created_at DESC
            LIMIT 1;
        END IF;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para SaleOperation % (SaleOperationAdjusted %). El evento quedará pending for retry.',
                v_original_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: reversión exacta (mismo patrón de copia con lados
        -- invertidos que ya usa CreditNoteIssued). posted_at=now(): la
        -- reversión data la corrección, no la venta original.
        -- El contra-asiento conserva el tipo y la referencia del asiento que revierte (cualquiera de las dos
        -- convenciones): para la convención de formulario es 'SaleOperation' + old_operation_id, como siempre.
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), NULL, source_doc_type,
            source_doc_ref, 'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        -- Balance de la contra-entry, validado individualmente (además del
        -- ASSERT común al final, que valida el asiento NUEVO).
        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: la contra-entry de SaleOperationAdjusted % no balancea (ERRCODE P0450).',
                p_event.id
                USING ERRCODE = 'P0450';
        END IF;

        -- El asiento vigente queda revertido.
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

        -- Asiento nuevo: valores editados, mismo ruteo por kind que
        -- SaleOperationCreated vía el helper compartido (D3/D4).
        v_sum_debit  := 0;
        v_sum_credit := 0;

        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_operation_id   := (v_payload->>'new_operation_id')::uuid;

        IF v_payload->>'sale_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'sale_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'SaleOperation',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_sale_debit_account(v_payment_method),
                'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '4100', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentReceived' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentReceived: SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check', 'wallet');

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'CustomerAccount',
            (v_payload->>'payment_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        IF v_is_bank THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1110', 'debit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'debit', v_total, v_line_no, NULL);
        END IF;
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '1300', 'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'PaymentMade' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- PaymentMade: SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'payment_method';
        v_is_bank        := v_payment_method IN ('transfer', 'card', 'check', 'wallet');

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'SupplierAccount',
            (v_payload->>'payment_id')::uuid, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '2100', 'debit', v_total, v_line_no, NULL);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        IF v_is_bank THEN
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1110', 'credit', v_total, v_line_no, NULL);
        ELSE
            INSERT INTO public.journal_lines
                (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
            VALUES (v_entry_id, v_account_id, '1100', 'credit', v_total, v_line_no, NULL);
        END IF;
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'CreditNoteIssued' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- CreditNoteIssued: SIN CAMBIOS (delete-guard-ledgers): byte a byte.
        -- ──────────────────────────────────────────────────────────────────────
        v_original_id := (v_payload->>'source_sales_order_id')::uuid;

        -- Buscar el asiento original posteado (edicion-operaciones-con-dinero: el VIGENTE, sin contra-asientos).
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SalesOrder'
          AND source_doc_ref  = v_original_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        -- Segunda convención: la venta del POS editada o promovida tiene su asiento vigente como SaleOperation, por
        -- el operation_id de la orden. Sin esto la nota de crédito reintentaba P0451 para siempre.
        IF v_orig_entry_id IS NULL THEN
            SELECT je.id INTO v_orig_entry_id
            FROM public.journal_entries je
            JOIN public.sales_orders so ON so.sale_operation_id = je.source_doc_ref
            WHERE so.id             = v_original_id
              AND so.account_id     = v_account_id
              AND je.source_doc_type = 'SaleOperation'
              AND je.status          = 'posted'
              AND je.reversal_of     IS NULL
              AND je.account_id      = v_account_id
            ORDER BY je.posted_at DESC, je.created_at DESC
            LIMIT 1;
        END IF;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento original '
                'para SalesOrder % (CreditNoteIssued %). El evento quedará pending for retry.',
                v_original_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- INSERT asiento espejo (reversal)
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        VALUES (
            v_account_id, now(), p_event.id, 'CreditNote',
            (v_payload->>'source_fiscal_document_id')::uuid, 'posted', v_orig_entry_id
        )
        RETURNING id INTO v_entry_id;

        -- Copiar líneas del original con lados invertidos (debit↔credit)
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        -- Sumar balance del asiento espejo para validación
        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        -- Marcar el original como reversed
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'SaleOperationDeleted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- delete-guard-ledgers (operation-delete-compensation / journal-entry):
        -- contra-asiento por borrado — SOLO la mitad "revertir" de
        -- SaleOperationAdjusted, sin asiento de reemplazo. Resuelve el asiento
        -- vigente probando las DOS convenciones en orden: (SaleOperation,
        -- operation_id) primero (formulario), luego (SalesOrder,
        -- sales_order_id) (POS, D2). La contra-entry es la ÚNICA entry del
        -- evento → lleva su propio source_event_id (ventaja sobre Adjusted,
        -- §D7). El ASSERT de balance común del final la valida — sin código
        -- adicional (misma mecánica que las 7 ramas preexistentes).
        -- ──────────────────────────────────────────────────────────────────────
        v_operation_id := (v_payload->>'operation_id')::uuid;

        -- edicion-operaciones-con-dinero (D2): el asiento VIGENTE (sin contra-asientos, el más reciente) en las dos
        -- convenciones.
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_operation_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL AND v_payload->>'sales_order_id' IS NOT NULL THEN
            SELECT id INTO v_orig_entry_id
            FROM public.journal_entries
            WHERE source_doc_type = 'SalesOrder'
              AND source_doc_ref  = (v_payload->>'sales_order_id')::uuid
              AND status          = 'posted'
              AND reversal_of     IS NULL
              AND account_id      = v_account_id
            ORDER BY posted_at DESC, created_at DESC
            LIMIT 1;
        END IF;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para la venta borrada (SaleOperationDeleted %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: copia source_doc_type/source_doc_ref del asiento
        -- original (cualquiera de las dos convenciones que haya resuelto) —
        -- es una REVERSIÓN, no un documento fiscal nuevo (a diferencia de
        -- CreditNoteIssued, que sí es su propio 'CreditNote').
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'PurchaseDeleted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- delete-guard-ledgers: mismo molde que SaleOperationDeleted, única
        -- convención (Purchase, operation_id) — las compras no tienen el
        -- concepto de doble referencia de la venta. cost_center_id por línea
        -- se preserva automáticamente: se copia igual que el resto de la fila.
        -- ──────────────────────────────────────────────────────────────────────
        v_operation_id := (v_payload->>'operation_id')::uuid;

        -- edicion-operaciones-con-dinero (D2): el asiento VIGENTE (sin contra-asientos, el más reciente).
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Purchase'
          AND source_doc_ref  = v_operation_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para la compra borrada (PurchaseDeleted %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'PurchaseAdjusted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- edicion-operaciones-con-dinero (D10): edición de una compra. Mitad "revertir" de PurchaseDeleted (asiento
        -- vigente de old_operation_id) + mitad "postear" de PurchaseCreated (mismas líneas, vía
        -- _journal_purchase_lines). El productor sólo lo emite si existe PurchaseCreated para la operación (evita el
        -- evento envenenado de una compra histórica sin asiento). Con el id estable (tanda B) old = new.
        -- P0451 si el asiento vigente todavía no existe (PurchaseAdjusted procesado antes que el alta: reintenta);
        -- P0450 si el asiento nuevo no balancea.
        -- ──────────────────────────────────────────────────────────────────────
        v_original_id := (v_payload->>'old_operation_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Purchase'
          AND source_doc_ref  = v_original_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para la compra % (PurchaseAdjusted %). El evento quedará pending for retry.',
                v_original_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: reversión exacta del asiento vigente, conservando su tipo y referencia. La entry del
        -- evento es el asiento NUEVO (lleva el source_event_id), como en SaleOperationAdjusted.
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), NULL, source_doc_type,
            source_doc_ref, 'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: la contra-entry de PurchaseAdjusted % no balancea (ERRCODE P0450).',
                p_event.id
                USING ERRCODE = 'P0450';
        END IF;

        -- El asiento vigente queda revertido.
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

        -- Asiento nuevo: valores editados, mismas líneas que PurchaseCreated.
        v_sum_debit  := 0;
        v_sum_credit := 0;

        v_total          := (v_payload->>'total')::numeric(14,2);
        v_payment_method := COALESCE(v_payload->>'payment_method', 'credit');
        v_neto           := (v_payload->>'neto')::numeric(14,2);
        v_iva            := (v_payload->>'iva_amount')::numeric(14,2);
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;
        v_operation_id   := COALESCE((v_payload->>'new_operation_id')::uuid, v_original_id);

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, now(), p_event.id, 'Purchase',
            v_operation_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        SELECT * INTO v_sums FROM public._journal_purchase_lines(
            v_entry_id, v_account_id, v_total, v_payment_method, v_neto, v_iva, v_cost_center_id);
        v_sum_debit  := v_sum_debit  + v_sums.o_debit;
        v_sum_credit := v_sum_credit + v_sums.o_credit;

    ELSIF v_event_type = 'PaymentReceivedReversed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- cobranzas-reverso (D5/D13): contra-asiento por anulación de un
        -- cobro. Mismo molde que PurchaseDeleted — única convención de
        -- referencia (CustomerAccount, payment_id): el cobro tiene un solo
        -- camino de alta, no dos como la venta.
        -- ──────────────────────────────────────────────────────────────────────
        v_payment_id := (v_payload->>'payment_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'CustomerAccount'
          AND source_doc_ref  = v_payment_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el cobro anulado (PaymentReceivedReversed %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'PaymentMadeReversed' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- cobranzas-reverso: espejo exacto para el pago a proveedor —
        -- (SupplierAccount, payment_id).
        -- ──────────────────────────────────────────────────────────────────────
        v_payment_id := (v_payload->>'payment_id')::uuid;

        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'SupplierAccount'
          AND source_doc_ref  = v_payment_id
          AND status          = 'posted'
          AND account_id      = v_account_id
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el pago anulado (PaymentMadeReversed %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    ELSIF v_event_type = 'ExpenseCreated' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-contable-gastos (D3/D4/D5): asiento nuevo — débito único a
        -- 5300 Gastos con el cost_center_id del gasto (mismo trato que 5100
        -- en PurchaseCreated), crédito por _journal_expense_credit_account
        -- (espejo de _journal_sale_debit_account, sin la rama credit).
        -- Fechado por la fecha de negocio del gasto (D5, mismo idioma que
        -- SaleOperationCreated) — NUNCA por el instante del relay.
        -- ──────────────────────────────────────────────────────────────────────
        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'kind';  -- crudo, puede ser NULL (sin imputar)
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;
        v_expense_id     := (v_payload->>'expense_id')::uuid;

        IF v_payload->>'expense_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'expense_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'Expense',
            v_expense_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '5300', 'debit', v_total, v_line_no, v_cost_center_id);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_expense_credit_account(v_payment_method),
                'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'ExpenseAdjusted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-contable-gastos (D6): molde BYTE A BYTE de
        -- SaleOperationAdjusted — localizar + revertir + volver a postear con
        -- los valores editados. El asiento posteado NO vuelve inmutable al
        -- gasto (D6): este productor sólo se emite si existe ExpenseCreated
        -- (D7, garantizado por el caller, no acá).
        -- ──────────────────────────────────────────────────────────────────────
        v_expense_id := (v_payload->>'expense_id')::uuid;

        -- Corrección de findings (revisor, ronda 1, blocker): excluir
        -- contra-asientos (reversal_of IS NOT NULL) del lookup del "vigente".
        -- Sin este filtro, a partir de la SEGUNDA edición hay DOS filas
        -- status='posted' para el mismo source_doc_ref (el asiento nuevo Y el
        -- contra-asiento de la edición anterior) y LIMIT 1 elige una
        -- arbitraria — revirtiendo el contra-asiento en vez del vigente.
        -- ORDER BY por robustez: aun con el filtro, si alguna vez hubiera más
        -- de una fila válida, quedarse con la más reciente.
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Expense'
          AND source_doc_ref  = v_expense_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el gasto % (ExpenseAdjusted %). El evento quedará pending for retry.',
                v_expense_id, p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        -- Contra-entry: reversión exacta, lados invertidos. posted_at=now():
        -- la corrección data la corrección, no el gasto original.
        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        VALUES (
            v_account_id, now(), NULL, 'Expense',
            v_expense_id, 'posted', v_orig_entry_id
        )
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        -- Balance de la contra-entry, validado individualmente (además del
        -- ASSERT común al final, que valida el asiento NUEVO).
        SELECT
            COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
            COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
        INTO v_sum_debit, v_sum_credit
        FROM public.journal_lines
        WHERE entry_id = v_entry_id;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: la contra-entry de ExpenseAdjusted % no balancea (ERRCODE P0450).',
                p_event.id
                USING ERRCODE = 'P0450';
        END IF;

        -- El asiento vigente queda revertido.
        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

        -- Asiento nuevo: valores editados, mismo mapeo que ExpenseCreated.
        v_sum_debit  := 0;
        v_sum_credit := 0;

        v_total          := (v_payload->>'amount')::numeric(14,2);
        v_payment_method := v_payload->>'kind';
        v_cost_center_id := (v_payload->>'cost_center_id')::uuid;

        IF v_payload->>'expense_date' IS NOT NULL THEN
            v_posted_at := ((v_payload->>'expense_date')::date + TIME '12:00:00')
                           AT TIME ZONE 'America/Argentina/Mendoza';
        ELSE
            v_posted_at := now();
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status)
        VALUES (
            v_account_id, v_posted_at, p_event.id, 'Expense',
            v_expense_id, 'posted'
        )
        RETURNING id INTO v_entry_id;

        v_line_no := 1;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id, '5300', 'debit', v_total, v_line_no, v_cost_center_id);
        v_sum_debit := v_sum_debit + v_total;

        v_line_no := 2;
        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        VALUES (v_entry_id, v_account_id,
                public._journal_expense_credit_account(v_payment_method),
                'credit', v_total, v_line_no, NULL);
        v_sum_credit := v_sum_credit + v_total;

    ELSIF v_event_type = 'ExpenseDeleted' THEN
        -- ──────────────────────────────────────────────────────────────────────
        -- asiento-contable-gastos: molde de SaleOperationDeleted/PurchaseDeleted
        -- — SOLO revertir, la contra-entry es la ÚNICA entry del evento → lleva
        -- su propio source_event_id. La localización NO lee public.expenses:
        -- el borrado del gasto es físico y la fila ya no existe cuando el
        -- relay corre — el evento ya trae todo lo necesario (D7, emitido sólo
        -- si existe ExpenseCreated, garantizado por el caller).
        -- ──────────────────────────────────────────────────────────────────────
        v_expense_id := (v_payload->>'expense_id')::uuid;

        -- Corrección de findings (revisor, ronda 1, blocker): mismo fix que
        -- ExpenseAdjusted arriba — excluir contra-asientos del lookup del
        -- "vigente" para no revertir el contra-asiento de una edición previa
        -- en vez del asiento que refleja el estado real del gasto.
        SELECT id INTO v_orig_entry_id
        FROM public.journal_entries
        WHERE source_doc_type = 'Expense'
          AND source_doc_ref  = v_expense_id
          AND status          = 'posted'
          AND reversal_of     IS NULL
          AND account_id      = v_account_id
        ORDER BY posted_at DESC, created_at DESC
        LIMIT 1;

        IF v_orig_entry_id IS NULL THEN
            RAISE EXCEPTION
                'journal_entry_original_not_found: no se encontró el asiento vigente '
                'para el gasto borrado (ExpenseDeleted %). El evento quedará pending for retry.',
                p_event.id
                USING ERRCODE = 'P0451';
        END IF;

        INSERT INTO public.journal_entries
            (account_id, posted_at, source_event_id, source_doc_type,
             source_doc_ref, status, reversal_of)
        SELECT
            v_account_id, now(), p_event.id, source_doc_type, source_doc_ref,
            'posted', v_orig_entry_id
        FROM public.journal_entries
        WHERE id = v_orig_entry_id
        RETURNING id INTO v_entry_id;

        INSERT INTO public.journal_lines
            (entry_id, account_id, account_code, side, amount, line_no, cost_center_id)
        SELECT
            v_entry_id,
            v_account_id,
            account_code,
            CASE side WHEN 'debit' THEN 'credit' ELSE 'debit' END,
            amount,
            line_no,
            cost_center_id
        FROM public.journal_lines
        WHERE entry_id = v_orig_entry_id;

        UPDATE public.journal_entries
        SET status = 'reversed'
        WHERE id = v_orig_entry_id;

    END IF;

    -- ── ASSERT de balance: Σdébito = Σcrédito (D5 journal-entry-outbox) — SIN CAMBIOS ──
    -- Solo validar para eventos que crean líneas directamente (no para no-op)
    IF v_entry_id IS NOT NULL THEN
        -- Para los tipos que no son reversal puro (CreditNoteIssued ya
        -- calculó su propio balance del espejo arriba), recalcular de la
        -- tabla contra v_entry_id — que en SaleOperationAdjusted/ExpenseAdjusted
        -- apunta al asiento NUEVO (la contra-entry ya se validó individualmente
        -- más arriba, antes de marcarse reversed el original). SaleOperationDeleted
        -- / PurchaseDeleted / PaymentReceivedReversed / PaymentMadeReversed /
        -- ExpenseDeleted quedan cubiertas por esta misma rama genérica:
        -- v_entry_id apunta a SU contra-entry (única entry del evento).
        IF v_event_type != 'CreditNoteIssued' THEN
            SELECT
                COALESCE(SUM(CASE WHEN side = 'debit'  THEN amount END), 0),
                COALESCE(SUM(CASE WHEN side = 'credit' THEN amount END), 0)
            INTO v_sum_debit, v_sum_credit
            FROM public.journal_lines
            WHERE entry_id = v_entry_id;
        END IF;

        IF v_sum_debit <> v_sum_credit THEN
            RAISE EXCEPTION
                'journal_balance_assertion_failed: Σdébito=% ≠ Σcrédito=% para evento % (ERRCODE P0450). '
                'El asiento no balancea — evento quedará pending for retry.',
                v_sum_debit, v_sum_credit, p_event.id
                USING ERRCODE = 'P0450';
        END IF;
    END IF;

END;
$function$;


REVOKE ALL ON FUNCTION public._journal_post_from_event(events) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public._journal_post_from_event(events) IS
  $c$journal-entry-outbox (journal-entry): Consumer 3 — postea la partida doble de un evento del outbox. SIN GRANT — NO AGREGAR UNO. Recibe una fila de events COMPLETA (composite; PostgREST acepta un objeto JSON), así que expuesta a `authenticated` permite forjar un evento con cualquier account_id y postear un asiento arbitrario en otro tenant (verificado en local). Único caller: rpc_process_outbox_dispatch (SECURITY DEFINER), disparado por el job de pg_cron `relay-process-outbox`. Perdió su REVOKE original en 20261001000001 L1914; lo restauró el hotfix 20261010000001_revoke_internal_money_helpers.sql (PR #454) y los chequeos (3) y (4) de supabase/tests/test_function_acl_gate.sql impiden que vuelva a perderse.
  edicion-operaciones-con-dinero (tanda A): el asiento vigente se busca con reversal_of IS NULL; SaleOperationAdjusted y CreditNoteIssued resuelven las dos convenciones; rama nueva PurchaseAdjusted (15 tipos).$c$;


-- =============================================================================
-- 13. rpc_process_outbox_dispatch — el Consumer 3 lista los mismos 15 tipos. Partida: md5 fd8392d1… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_process_outbox_dispatch(p_batch_limit integer DEFAULT 100)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  C-25 + journal-entry-outbox + v3-notifications-realtime pure-SQL relay dispatch.

  Consumer order (per-event):
    1. AuditLog  (mandatory first — audit domain invariant)
    2. EmailNotification (sale_created/stock_adjusted/plan_changed)
    3. JournalEntry (SaleConfirmed/PurchaseCreated/SaleOperationCreated/
       SaleOperationAdjusted/PaymentReceived/PaymentMade/CreditNoteIssued/
       SaleOperationDeleted/PurchaseDeleted/PaymentReceivedReversed/
       PaymentMadeReversed/ExpenseCreated/ExpenseAdjusted/ExpenseDeleted/
       PurchaseAdjusted)
    4. Notification (CashSessionClosed/StockBelowMinimum/FiscalDocumentRejected/
       QuoteAccepted/TransferDispatched) — v3-notifications-realtime.

  processed_at se escribe SOLO si todos los consumers activos del evento tienen
  éxito. Un consumer fallido deja processed_at NULL → retry en el próximo tick.
  Cada consumer está idempotency-guarded por (event_id, consumer_type).

  Per-event isolation: BEGIN/EXCEPTION/END por evento.
  SECURITY DEFINER: cross-account sin debilitar RLS. REVOCADO de anon/PUBLIC.

  delete-guard-ledgers (2026-08-22): agrega SaleOperationDeleted y
  PurchaseDeleted al filtro del Consumer 3 — mismo invariante ya documentado
  por asiento-venta-formulario: el filtro del dispatcher y el de
  _journal_post_from_event deben listar el mismo conjunto.

  cobranzas-reverso (2026-09-02, D13): agrega PaymentReceivedReversed y
  PaymentMadeReversed (9→11) — mismo invariante, ahora sostenido además por
  un gate automático (supabase/tests/test_cobranzas_reverso.sql) que compara
  los dos conjuntos extraídos de los cuerpos vivos, no sólo por este
  comentario.

  asiento-contable-gastos (2026-09-10, D8): agrega ExpenseCreated,
  ExpenseAdjusted y ExpenseDeleted (11→14) — mismo invariante; el gate de
  test_cobranzas_reverso.sql bloque (11) pasa a esperar los 14 tipos y se
  cablea a KPI_Validation.yml en este mismo PR (nunca había corrido en CI).

  edicion-operaciones-con-dinero (2026-11-04, tanda A, 3.4): agrega PurchaseAdjusted (14->15) al filtro de este
  consumidor — mismo invariante; el gate de test_cobranzas_reverso.sql bloque (11) pasa a esperar los 15 tipos y a
  detectar PurchaseAdjusted ausente de uno solo de los dos filtros.
*/
DECLARE
  v_event           public.events%ROWTYPE;
  v_processed_count int := 0;
  v_audit_claimed   bool;
  v_email_claimed   bool;
  v_subject         text;
  v_recipient       text;
BEGIN
  FOR v_event IN
    SELECT *
    FROM public.events
    WHERE processed_at IS NULL
    ORDER BY occurred_at
    LIMIT p_batch_limit
    FOR UPDATE SKIP LOCKED
  LOOP
    BEGIN

      -- ── Consumer 1: AuditLog (mandatory first) ────────────────────────────
      INSERT INTO public.operation_idempotency
        (user_id, idempotency_key, operation_kind, event_id, consumer_type)
      VALUES (
        '00000000-0000-0000-0000-000000000000'::uuid,
        v_event.id::text || ':AuditLog',
        'event_consumer',
        v_event.id,
        'AuditLog'
      )
      ON CONFLICT (event_id, consumer_type)
      WHERE event_id IS NOT NULL
      DO NOTHING;

      GET DIAGNOSTICS v_audit_claimed = ROW_COUNT;

      IF v_audit_claimed THEN
        INSERT INTO public.audit_logs (account_id, action, created_at)
        VALUES (v_event.account_id, v_event.event_type, now());
      END IF;

      -- ── Consumer 2: EmailNotification ─────────────────────────────────────
      IF v_event.event_type IN ('sale_created', 'stock_adjusted', 'plan_changed') THEN

        INSERT INTO public.operation_idempotency
          (user_id, idempotency_key, operation_kind, event_id, consumer_type)
        VALUES (
          '00000000-0000-0000-0000-000000000000'::uuid,
          v_event.id::text || ':EmailNotification',
          'event_consumer',
          v_event.id,
          'EmailNotification'
        )
        ON CONFLICT (event_id, consumer_type)
        WHERE event_id IS NOT NULL
        DO NOTHING;

        GET DIAGNOSTICS v_email_claimed = ROW_COUNT;

        IF v_email_claimed THEN
          v_subject := CASE v_event.event_type
            WHEN 'sale_created'    THEN 'Nueva venta registrada'
            WHEN 'stock_adjusted'  THEN 'Ajuste de stock realizado'
            WHEN 'plan_changed'    THEN 'Tu plan ha sido actualizado'
            ELSE 'Evento: ' || v_event.event_type
          END;

          v_recipient := COALESCE(
            v_event.payload->>'email',
            'account:' || v_event.account_id::text
          );

          INSERT INTO public.email_logs
            (event_type, recipient, subject, status, metadata)
          VALUES (
            v_event.event_type,
            v_recipient,
            v_subject,
            'pending',
            jsonb_build_object(
              'event_id',   v_event.id::text,
              'account_id', v_event.account_id::text
            )
          )
          ON CONFLICT DO NOTHING;
        END IF;

      END IF;

      -- ── Consumer 3: JournalEntry (journal-entry-outbox) ───────────────────
      -- Solo para los 15 tipos en-scope; _journal_post_from_event hace no-op
      -- para el resto. La idempotencia (event_id, 'JournalEntry') se gestiona
      -- dentro del helper. Un fallo en el posting (balance, NC sin original,
      -- reverso sin original) deja el evento pending para retry — el
      -- EXCEPTION del sub-bloque lo captura sin abortar el batch.
      IF v_event.event_type IN (
          'SaleConfirmed', 'PurchaseCreated', 'SaleOperationCreated',
          'SaleOperationAdjusted', 'PaymentReceived', 'PaymentMade',
          'CreditNoteIssued', 'SaleOperationDeleted', 'PurchaseDeleted',
          'PaymentReceivedReversed', 'PaymentMadeReversed',
          'ExpenseCreated', 'ExpenseAdjusted', 'ExpenseDeleted',
          'PurchaseAdjusted'
      ) THEN
        PERFORM public._journal_post_from_event(v_event);
      END IF;

      -- ── Consumer 4: Notification (v3-notifications-realtime) ─────────────
      -- Solo para los 5 tipos en-scope; _notification_from_event hace no-op
      -- para el resto (incluyendo CashSessionClosed con difference=0 y
      -- audiencia vacía). La idempotencia (event_id, 'Notification') se
      -- gestiona dentro del helper, igual que el Consumer 3.
      IF v_event.event_type IN (
          'CashSessionClosed', 'StockBelowMinimum', 'FiscalDocumentRejected',
          'QuoteAccepted', 'TransferDispatched'
      ) THEN
        PERFORM public._notification_from_event(v_event);
      END IF;

      -- ── Mark processed (todos los consumers activos tuvieron éxito) ─────────
      UPDATE public.events
      SET processed_at = now()
      WHERE id = v_event.id;

      v_processed_count := v_processed_count + 1;

    EXCEPTION
      WHEN OTHERS THEN
        RAISE WARNING
          'rpc_process_outbox_dispatch: fallo en evento % (type=%): %',
          v_event.id, v_event.event_type, SQLERRM;
    END;

  END LOOP;

  RETURN v_processed_count;
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_process_outbox_dispatch(integer) FROM PUBLIC, anon, authenticated;
COMMENT ON FUNCTION public.rpc_process_outbox_dispatch(integer) IS
  $c$C-25 + journal-entry-outbox + v3-notifications-realtime: dispatch in-DB del outbox transaccional. Consumer 1: AuditLog (mandatory first). Consumer 2: EmailNotification (sale_created/stock_adjusted/plan_changed). Consumer 3: JournalEntry (SaleConfirmed/PurchaseCreated/PaymentReceived/PaymentMade/CreditNoteIssued) — llama a _journal_post_from_event (SECURITY DEFINER). Consumer 4: Notification (CashSessionClosed/StockBelowMinimum/FiscalDocumentRejected/QuoteAccepted/TransferDispatched) — llama a _notification_from_event (SECURITY DEFINER). processed_at SOLO tras éxito de todos los consumers activos. Per-event isolation: BEGIN/EXCEPTION/END. REVOCADO de anon/PUBLIC.
  edicion-operaciones-con-dinero (tanda A): el Consumer 3 lista los 15 tipos (suma PurchaseAdjusted), el mismo conjunto que _journal_post_from_event.$c$;

-- =============================================================================
-- 14. rpc_atomic_update_purchase_operation — lock de filas ascendente + recuento y PurchaseAdjusted.
--     Partida: md5 28fd6790… (vivo, sin \r; incluye remitos-compra, multiusuario y stock-edicion-sucursal-piso).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_supplier_id uuid DEFAULT NULL::uuid, p_supplier_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_author          uuid;   -- multiusuario-operativo (tanda B): autor de la operación que se edita
  v_account_id      uuid;
  v_old_purchase    RECORD;
  v_item            RECORD;
  v_product         RECORD;
  v_new_op_id       uuid;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_flag_on         boolean;
  v_old_snapshots   jsonb;
  v_prev_snap       jsonb;
  v_line_snap       jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_reverse_delta     numeric;         -- ventas-unidades-conversion (D6)
  v_apply_qty_norm    numeric(15,4);   -- ventas-unidades-conversion (D1)
  v_old_payment_method_id   uuid;
  v_final_payment_method_id uuid;
  v_old_branch_id      uuid;
  v_old_supplier_id    uuid;
  v_old_cost_center_id uuid;
  v_final_branch_id    uuid;
  v_branch             RECORD;
  v_final_supplier_id    uuid;
  v_final_cost_center_id uuid;
  v_old_kind             text;
  v_final_kind           text;
  v_dn_label             text;   -- remitos-compra (D9): remito de origen de la compra
  -- stock-edicion-sucursal-piso (D2): chequeo previo de la pata REVERSE.
  v_rev_qty              numeric;
  v_rev_branch           uuid;
  v_rev_branch_qty       numeric(15,4);
  -- edicion-operaciones-con-dinero (tanda A, D12/D10): lock de filas + evento contable.
  v_locked_ids           uuid[];
  v_old_op_id            uuid;
  v_total_new            numeric;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede actualizar la operación'
      USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite editar compras (requiere compras, administrador o dueño)');

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P0400';
  END IF;

  -- multiusuario-operativo (tanda B, D8): el documento tiene que ser de la CUENTA ACTIVA, no del caller. Una compra de
  -- otra cuenta es indistinguible de una inexistente (P0404, mismo texto).
  --
  -- edicion-operaciones-con-dinero (tanda A, D12): las filas se toman FOR UPDATE en orden ASCENDENTE de id y se
  -- RECUENTA bajo el lock (la venta ya lo hacía; la compra no tomaba ningún lock). Con dos "Guardar" a la vez la
  -- segunda espera a la primera, vuelve a contar —las filas ya no existen— y levanta P0404 en vez de revertir el
  -- stock por segunda vez y duplicar la operación. Orden global de locks de CLAUDE.md: la compra es su propia ancla.
  SELECT array_agg(l.id ORDER BY l.id) INTO v_locked_ids
  FROM (
    SELECT p.id
    FROM   public.purchases p
    WHERE  p.id = ANY(p_purchase_ids)
      AND  p.account_id = v_account_id
    ORDER  BY p.id
    FOR UPDATE
  ) l;

  IF COALESCE(array_length(v_locked_ids, 1), 0) != array_length(p_purchase_ids, 1) THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- Identificador de operación vigente (para el evento contable PurchaseAdjusted): bajo el lock, antes del DELETE.
  SELECT p.operation_id INTO v_old_op_id FROM public.purchases p WHERE p.id = ANY(v_locked_ids) ORDER BY p.id LIMIT 1;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): sobre una compra de OTRO miembro sólo puede el dueño o un administrador;
  -- el resto corrige lo propio (P0403). La autoría se CONSERVA en las filas nuevas (v_author).
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT p.user_id) FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)),
    'solo el dueño o un administrador modifican las compras que cargó otro miembro');
  SELECT p.user_id INTO v_author FROM public.purchases p WHERE p.id = ANY(p_purchase_ids) ORDER BY p.id LIMIT 1;

  -- remitos-compra (D9): una compra nacida de un remito NO se edita. El editor siempre reemplaza
  -- líneas (REVERSE + APPLY) y la REVERSE, sin movimiento propio de esas filas, cae a la
  -- normalización de la línea y RESTARÍA stock que el remito sigue aportando (la APPLY lo sumaría
  -- de nuevo; una reducción dejaría stock restado de más, y la anulación del remito lo restaría
  -- otra vez). Va ANTES de los tres P0423 de dinero —es el motivo más específico: una compra de
  -- remito a crédito recibiría si no el de cuenta corriente, que manda a "borrar y volver a
  -- cargar" sin explicar el remito— y bloquea la operación ENTERA, también la cabecera.
  SELECT COALESCE('RC-' || lpad(dn.number::text, 8, '0'), 'de origen') INTO v_dn_label
  FROM   public.purchases p
  JOIN   public.delivery_notes dn ON dn.id = p.source_delivery_note_id
  WHERE  p.id = ANY(p_purchase_ids)
    AND  p.account_id = v_account_id
  LIMIT  1;

  IF FOUND THEN
    RAISE EXCEPTION 'delivery_note_purchase_locked: la compra nació del remito %: para corregirla, eliminá la compra, editá el remito y volvé a convertirlo', v_dn_label
      USING ERRCODE = 'P0423';
  END IF;

  -- pagos-cableados-restantes (D6, task 9.3): inmutabilidad por cargo de
  -- cuenta corriente posteado.
  IF EXISTS (
    SELECT 1
    FROM public.supplier_account_movements sam
    WHERE sam.reference_id IN (
      SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
    )
  ) THEN
    RAISE EXCEPTION 'operation_has_account_charge_immutable: compra con cargo en cuenta corriente del proveedor posteado — borrá esta compra (revierte el cargo y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.2): inmutabilidad por movimiento
  -- bancario posteado.
  IF EXISTS (
    SELECT 1
    FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'purchase'
      AND bm.source_doc_ref IN (
        SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_bank_movement_immutable: la operación tiene un movimiento bancario posteado y no puede editarse — registrá el ajuste en el ledger bancario y una compra nueva'
      USING ERRCODE = 'P0423';
  END IF;

  -- caja-compras-cobranzas (D8): tercer término del guard P0423 — la compra
  -- que ya descontó de la caja también pasa a ser inmutable. Antes de este
  -- change este caso era INALCANZABLE (ningún camino de alta producía un
  -- movimiento de caja de compra), así que agregarlo no cambia el
  -- comportamiento de ninguna compra existente.
  IF EXISTS (
    SELECT 1
    FROM public.cash_movements cm
    WHERE cm.movement_type = 'purchase_payment'
      AND cm.reference_id IN (
        SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
      )
  ) THEN
    RAISE EXCEPTION 'operation_has_cash_movement_immutable: la compra descontó de la caja y no puede editarse — borrá esta compra (revierte la caja y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (p.product_id)
           p.product_id,
           jsonb_build_object(
             'name_snapshot',       COALESCE(pi.name_snapshot, p.name_snapshot),
             'sku_snapshot',        COALESCE(pi.sku_snapshot, p.sku_snapshot),
             'unit_cost_snapshot',  COALESCE(pi.unit_cost_snapshot, p.unit_cost_snapshot),
             'iva_rate_snapshot',   COALESCE(pi.iva_rate_snapshot, p.iva_rate_snapshot),
             'snapshot_backfilled', COALESCE(pi.snapshot_backfilled, p.snapshot_backfilled, false)
           ) AS snap
    FROM   public.purchases p
    LEFT JOIN public.purchase_items pi
           ON pi.purchase_id = p.id AND pi.product_id = p.product_id
    WHERE  p.id = ANY(p_purchase_ids)
      AND  p.product_id IS NOT NULL
      AND  (COALESCE(pi.unit_cost_snapshot, p.unit_cost_snapshot) IS NOT NULL
            OR COALESCE(pi.name_snapshot, p.name_snapshot) IS NOT NULL)
    ORDER BY p.product_id, p.id
  ) t;

  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
  LIMIT  1;

  IF p_payment_method_provided THEN
    IF p_payment_method_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old_payment_method_id;
  END IF;

  SELECT branch_id, supplier_id, cost_center_id
  INTO   v_old_branch_id, v_old_supplier_id, v_old_cost_center_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
  LIMIT  1;

  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM   public.branches
      WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old_branch_id;
  END IF;

  -- compras-gastos-sucursal-por-defecto (D2/D5): para la COMPRA, NULL significa "la
  -- principal". Ni la intención de desimputar (p_branch_provided con NULL) ni una fila
  -- vigente sin sucursal (compra histórica) se preservan: se resuelve a la principal
  -- operativa ANTES del REVERSE, igual que la validación de arriba (gate 2.9 de
  -- edicion-preserva-contexto: una edición inválida no revierte ni reaplica stock).
  -- Una sucursal vigente no nula se preserva sin revalidar, como hoy; una explícita
  -- inválida sigue dando P0422 branch_invalid. El REVERSE de una fila NULL ya caía en la
  -- principal vigente (op_stock_movement) y el APPLY suma en esa misma sucursal: el neto
  -- es cero. El gasto aplica la misma regla en rpc_update_expense.
  IF v_final_branch_id IS NULL THEN
    v_final_branch_id := public.c26_default_branch(v_account_id);
    IF v_final_branch_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id
        AND is_active = TRUE AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  IF p_supplier_provided THEN
    IF p_supplier_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.suppliers
        WHERE id = p_supplier_id AND account_id = v_account_id AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'supplier_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_supplier_id := p_supplier_id;
  ELSE
    v_final_supplier_id := v_old_supplier_id;
  END IF;

  IF p_cost_center_provided THEN
    IF p_cost_center_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cost_centers
        WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
      ) THEN
        RAISE EXCEPTION 'cost_center_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_cost_center_id := p_cost_center_id;
  ELSE
    v_final_cost_center_id := v_old_cost_center_id;
  END IF;

  SELECT kind INTO v_final_kind
  FROM   public.payment_methods
  WHERE  id = v_final_payment_method_id;

  SELECT kind INTO v_old_kind
  FROM   public.payment_methods
  WHERE  id = v_old_payment_method_id;

  IF (p_payment_method_provided OR p_supplier_provided)
     AND v_final_kind = 'credit'
     AND v_final_supplier_id IS NULL
  THEN
    RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method_provided
     AND v_final_kind = 'credit'
     AND v_old_kind IS DISTINCT FROM 'credit'
  THEN
    RAISE EXCEPTION 'credit_transition_not_allowed: la edición no postea cargos en cuenta corriente — borrá esta compra y volvé a cargarla como compra a crédito'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  FOR v_old_purchase IN
    SELECT id, product_id, quantity, unit_id, branch_id, operation_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_purchase.product_id;

      -- ventas-unidades-conversion (D6): la pata REVERSE devuelve EXACTAMENTE
      -- lo que el movimiento original sumó (quantity_delta, ya en unidad base
      -- del producto). Sin movimiento cae a la definición única.
      SELECT unit_cost_snapshot, -quantity_delta INTO v_reverse_unit_cost, v_reverse_delta
      FROM   public.stock_movements
      WHERE  reference_id = v_old_purchase.id AND reference_type = 'purchase'
      ORDER  BY created_at DESC
      LIMIT  1;

      v_rev_qty := COALESCE(v_reverse_delta,
                 -public._uom_normalize_quantity(v_old_purchase.product_id, v_old_purchase.unit_id, v_old_purchase.quantity));

      -- stock-edicion-sucursal-piso (D2): la pata REVERSE RESTA del stock lo que la compra
      -- había sumado. Si esa mercadería ya se vendió, la sucursal no alcanza y la resta
      -- violaba el CHECK branch_stock_quantity_non_negative (23514), que el backend
      -- devolvía como un 422 genérico («Los datos no cumplen las restricciones»). Se
      -- rechaza ANTES con un P0409 legible que dice cuánto queda y cuánto habría que
      -- restar. No cambia qué ediciones prosperan (las que fallaban con 23514 fallan con
      -- este mensaje): el borrado de la compra, que sí aplica el piso en cero, queda como
      -- la salida. La transacción entera se revierte: ninguna línea previa queda reversada.
      v_rev_branch := COALESCE(v_old_purchase.branch_id, public.c26_default_branch(v_account_id));
      SELECT COALESCE(quantity, 0) INTO v_rev_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_old_purchase.product_id AND branch_id = v_rev_branch;
      v_rev_branch_qty := COALESCE(v_rev_branch_qty, 0);
      IF v_rev_branch_qty + v_rev_qty < 0 THEN
        RAISE EXCEPTION 'purchase_edit_stock_consumed: de % en la sucursal quedan % y la edición necesita restar %',
          COALESCE(v_old_product_name, v_old_purchase.product_id::text), v_rev_branch_qty, -v_rev_qty
          USING ERRCODE = 'P0409';
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_purchase.product_id, v_old_product_name,
        v_old_purchase.branch_id,
        v_rev_qty,
        'purchase_return',
        v_old_purchase.id, 'purchase_update', v_old_purchase.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1): cantidad de la línea nueva en unidad
      -- base del producto para la pata APPLY.
      v_apply_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (COALESCE(v_author, v_uid), v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id,
         v_line_snap->>'name_snapshot',
         v_line_snap->>'sku_snapshot',
         (v_line_snap->>'unit_cost_snapshot')::numeric,
         (v_line_snap->>'iva_rate_snapshot')::numeric)
      RETURNING id INTO v_new_purchase_id;

      IF v_flag_on THEN
        INSERT INTO public.purchase_items (
          purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_purchase_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, v_apply_qty_norm, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id)
      VALUES
        (COALESCE(v_author, v_uid), v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  -- ── edicion-operaciones-con-dinero (tanda A, D10): rastro contable de la edición ─────────────────────────────────
  -- PurchaseAdjusted si la operación vigente TIENE asiento (o lo tendrá): existe su PurchaseCreated, o un
  -- PurchaseAdjusted anterior que dejó el id actual. Es la regla de ExpenseAdjusted: evita el evento envenenado de una
  -- compra histórica sin asiento. En esta tanda el id de la compra todavía se regenera, así que el payload lleva el
  -- id viejo y el nuevo y el consumidor resuelve el asiento por el viejo; la tanda B vuelve el id estable (old = new).
  -- Antes de este evento la edición de una compra con asiento dejaba el asiento viejo vivo y un PurchaseDeleted
  -- posterior del id nuevo reintentaba P0451 para siempre.
  IF v_old_op_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM public.events ev
    WHERE ev.event_type IN ('PurchaseCreated', 'PurchaseAdjusted')
      AND ev.aggregate_type = 'Purchase'
      AND ev.aggregate_id   = v_old_op_id
      AND ev.account_id     = v_account_id
  ) THEN
    SELECT COALESCE(SUM(p.total), 0) INTO v_total_new FROM public.purchases p WHERE p.operation_id = v_new_op_id AND p.account_id = v_account_id;

    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id, 'PurchaseAdjusted', 'Purchase', v_new_op_id,
      jsonb_build_object(
        'account_id',       v_account_id,
        'old_operation_id', v_old_op_id,
        'new_operation_id', v_new_op_id,
        'total',            v_total_new,
        'cost_center_id',   v_final_cost_center_id,
        'neto',             NULL,
        'iva_amount',       NULL,
        'payment_method',   COALESCE(v_final_kind, 'credit'),
        'occurred_at',      now()
      ),
      now()
    );
  END IF;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated;
COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) IS
  $c$caja-compras-cobranzas (D8): el guard P0423 suma un tercer EXISTS contra
  cash_movements (movement_type=purchase_payment) — una compra con caja
  posteada también pasa a ser inmutable. Mismo predicado en el derivado de
  lectura del listado (backend/repositories/purchase_repository.py).
  remitos-compra (D9): una compra con origen de remito no se edita: P0423 delivery_note_purchase_locked, después de la comprobación de existencia y ANTES de los tres P0423 de dinero (sin tocar stock ni nada).
  stock-edicion-sucursal-piso (D2): chequeo previo de la pata REVERSE — si la mercadería de la compra ya se vendió, rechaza con P0409 purchase_edit_stock_consumed (cuánto queda y cuánto habría que restar) en vez de 23514.
  edicion-operaciones-con-dinero (tanda A, D12/D10): toma las filas FOR UPDATE en orden ascendente y recuenta (P0404, como la venta) y emite PurchaseAdjusted (payload con el id viejo y el nuevo) cuando la operación tiene asiento.$c$;


-- =============================================================================
-- 15. rpc_update_expense — toma la fila del gasto FOR UPDATE. Partida: md5 809a1799… (vivo, sin \r).
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_update_expense(p_expense_id uuid, p_category text DEFAULT NULL::text, p_amount numeric DEFAULT NULL::numeric, p_date date DEFAULT NULL::date, p_description text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_old                 RECORD;
  v_branch              RECORD;
  v_final_payment_method_id uuid;
  v_final_branch_id     uuid;
  v_final_cost_center_id    uuid;
  -- asiento-contable-gastos (D7): valores finales resultantes de la edición,
  -- para la carga de ExpenseAdjusted — mismo mapeo que ExpenseCreated.
  v_final_amount        numeric;
  v_final_date          date;
  v_final_kind          text;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede editar el gasto'
      USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  -- Localización POR TENANT: si el gasto no aparece, P0404 — sin distinguir
  -- "no existe" de "es de otra cuenta" (D4).
  SELECT * INTO v_old
  FROM public.expenses
  WHERE id = p_expense_id AND account_id = v_account_id
  FOR UPDATE;   -- edicion-operaciones-con-dinero (tanda A, D12): sin el lock, dos ediciones a la vez pierden una (lost update)

  IF NOT FOUND THEN
    RAISE EXCEPTION 'expense_not_found: el gasto no existe o no pertenece a esta cuenta'
      USING ERRCODE = 'P0404';
  END IF;

  -- ── D11: los dos guards de inmutabilidad, ANTES DE CUALQUIER ESCRITURA ────
  -- Mismos predicados y mismo ERRCODE que rpc_atomic_update_sale_operation
  -- (baseline). Los mensajes son distinguibles a propósito: el usuario tiene
  -- que saber cuál de los dos libros produjo el bloqueo.
  --
  -- asiento-contable-gastos (D6): la existencia de un ASIENTO contable NO se
  -- suma a estos guards. Un gasto sin movimiento de caja ni bancario sigue
  -- siendo plenamente editable aunque ya tenga su asiento posteado; la
  -- edición lo corrige por el par contra-asiento/asiento nuevo más abajo.
  IF EXISTS (
    SELECT 1 FROM public.cash_movements cm
    WHERE cm.reference_id = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_cash_movement_immutable: el gasto tiene un movimiento de caja posteado y no puede editarse — borralo y volvé a cargarlo (el borrado compensa la caja)'
      USING ERRCODE = 'P0423';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.bank_movements bm
    WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
  ) THEN
    RAISE EXCEPTION 'expense_has_bank_movement_immutable: el gasto tiene un movimiento bancario posteado y no puede editarse — borralo y volvé a cargarlo (el borrado registra el movimiento espejo)'
      USING ERRCODE = 'P0423';
  END IF;

  -- ── Importe positivo, espejo del alta ─────────────────────────────────────
  -- Sin esto la edición sería el bypass del guard del alta: un gasto legítimo
  -- pasaría a importe negativo con un solo PUT. `NULL` conserva la semántica
  -- COALESCE heredada del UPDATE que este RPC reemplaza ("no cambia"), y por
  -- eso el predicado es IS NOT NULL AND <= 0 y no el del alta.
  IF p_amount IS NOT NULL AND p_amount <= 0 THEN
    RAISE EXCEPTION 'Amount must be greater than zero'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── D12: tri-estado, campo por campo, con validación ANTES del UPDATE ─────
  IF p_payment_method_provided THEN
    -- ⚠️ La validación de reimputación se aplica SÓLO cuando el valor cambia.
    -- El formulario manda `paymentMethodId` SIEMPRE (está en el literal del
    -- payload) y en edición ofrece a propósito las formas dadas de baja
    -- (`includeInactive={isEdit}`, para que un gasto histórico siga nombrando
    -- la suya). Con el predicado aplicado sin excepción, desactivar una forma
    -- de pago volvía INOPERABLE todo gasto que la usara: cualquier edición
    -- —aunque sólo tocara el importe— rebotaba con P0404 hasta reactivarla.
    -- Reenviar el valor vigente es PRESERVAR, no reimputar. La TENENCIA sí se
    -- verifica siempre: lo que se relaja es `is_active`/`deleted_at`, nunca el
    -- `account_id`. Gate: sección 8.7, con control negativo (cambiar a OTRA
    -- forma inactiva sigue siendo P0404).
    IF p_payment_method_id IS NOT NULL
       AND p_payment_method_id IS DISTINCT FROM v_old.payment_method_id THEN
      -- Mismo predicado que el alta: cuenta + activa + no borrada.
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
      -- D3 también en la edición: la API no puede ser un bypass del selector.
      IF (SELECT kind FROM public.payment_methods WHERE id = p_payment_method_id) = 'credit' THEN
        RAISE EXCEPTION 'credit_not_supported_for_expense: un gasto no tiene contraparte con cuenta corriente — para un egreso que vas a pagar después, cargalo como compra a proveedor'
          USING ERRCODE = 'P0400';
      END IF;
    ELSIF p_payment_method_id IS NOT NULL THEN
      -- Reenvío del valor vigente: sólo tenencia (el gasto ya es del tenant,
      -- pero la FK de payment_methods no está scopeada por cuenta y el guard
      -- de tenencia no se relaja nunca — lección de cuenta-corriente-party-guard).
      IF NOT EXISTS (
        SELECT 1 FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
      ) THEN
        RAISE EXCEPTION 'payment_method_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_payment_method_id := p_payment_method_id;
  ELSE
    v_final_payment_method_id := v_old.payment_method_id;
  END IF;

  IF p_branch_provided THEN
    IF p_branch_id IS NOT NULL THEN
      SELECT id, status INTO v_branch
      FROM public.branches
      WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
      IF NOT FOUND OR v_branch.status = 'closed' THEN
        RAISE EXCEPTION 'branch_invalid: la sucursal no pertenece a la cuenta o no está operativa'
          USING ERRCODE = 'P0422';
      END IF;
    END IF;
    v_final_branch_id := p_branch_id;
  ELSE
    v_final_branch_id := v_old.branch_id;
  END IF;

  -- compras-gastos-sucursal-por-defecto (D4/D5): un nulo de sucursal, informado o vigente
  -- (gasto histórico), se resuelve con la MISMA regla que el alta del gasto
  -- (rpc_create_expense): COALESCE con la principal. Sin guard de sucursal operativa
  -- (OQ-3 (a)): el gasto no mueve mercadería y el alta persiste el fallback. La
  -- intención de desimputar la sucursal desaparece del contrato tri-estado; forma de
  -- pago y centro de costo conservan las tres intenciones.
  v_final_branch_id := COALESCE(v_final_branch_id, public.c26_default_branch(v_account_id));

  IF p_cost_center_provided THEN
    IF p_cost_center_id IS NOT NULL THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.cost_centers
        WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
      ) THEN
        RAISE EXCEPTION 'cost_center_not_found or not active for this account'
          USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_final_cost_center_id := p_cost_center_id;
  ELSE
    v_final_cost_center_id := v_old.cost_center_id;
  END IF;

  UPDATE public.expenses
  SET category          = COALESCE(p_category, v_old.category),
      amount            = COALESCE(p_amount, v_old.amount),
      date              = COALESCE(p_date::timestamptz, v_old.date),
      description       = COALESCE(p_description, v_old.description),
      payment_method_id = v_final_payment_method_id,
      branch_id         = v_final_branch_id,
      cost_center_id    = v_final_cost_center_id
  WHERE id = p_expense_id AND account_id = v_account_id;

  -- ── asiento-contable-gastos (D7): ExpenseAdjusted, SÓLO si existe el alta ──
  -- El predicado evalúa la EXISTENCIA DEL EVENTO de alta, nunca la del
  -- asiento: un gasto creado y editado/borrado dentro de la misma ventana de
  -- relay tiene su ExpenseCreated sin procesar y todavía no tiene asiento, y
  -- tiene que emitir igual — el relay procesa en orden de ocurrencia y el
  -- fallo recuperable (P0451) del consumidor resuelve si quedan en corridas
  -- distintas. Un gasto histórico (sin ExpenseCreated) no emite nada: si
  -- emitiera, el consumidor jamás encontraría el asiento original y
  -- reintentaría con P0451 cada minuto, para siempre (evento envenenado).
  IF EXISTS (
    SELECT 1 FROM public.events
    WHERE event_type = 'ExpenseCreated' AND aggregate_type = 'Expense' AND aggregate_id = p_expense_id AND account_id = v_account_id
  ) THEN
    v_final_amount := COALESCE(p_amount, v_old.amount);
    v_final_date   := COALESCE(p_date, v_old.date::date);

    -- Corrección de findings (revisor, ronda 1, major): el `kind` que decide
    -- la CONTRAPARTIDA del asiento se deriva de lo que REALMENTE ocurrió en
    -- los libros de dinero (design.md D4: "el asiento nombra la cuenta del
    -- libro que efectivamente se movió"), NUNCA de la forma de pago
    -- declarada en el edit. rpc_update_expense jamás llama a
    -- _pay_register_operation_bank_movement ni a c28_register_cash_movement
    -- (la edición no mueve dinero, D6) — y el guard de inmutabilidad de
    -- arriba ya garantiza que, si llegamos hasta acá, el gasto NO tiene
    -- ningún bank_movement posteado. Sin este fix, cambiar la forma de pago
    -- a un kind bancario en la edición acreditaría 1110 Banco sin que exista
    -- ningún movimiento bancario real que lo respalde — un descuadre de
    -- conciliación esperando a pasar. La rama IS NULL (verdadera 100% del
    -- tiempo, por el guard de arriba) queda declarada por robustez, no por
    -- necesidad: si alguna vez cambia el guard, este derivado sigue siendo
    -- correcto sin tocarlo.
    IF EXISTS (
      SELECT 1 FROM public.bank_movements bm
      WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = p_expense_id
    ) THEN
      -- Los cuatro kind bancarios son equivalentes para
      -- _journal_expense_credit_account (todos → 1110): cualquiera sirve.
      v_final_kind := 'transfer';
    ELSE
      v_final_kind := NULL;
    END IF;

    INSERT INTO public.events (account_id, event_type, aggregate_type, aggregate_id, payload)
    VALUES (
      v_account_id, 'ExpenseAdjusted', 'Expense', p_expense_id,
      jsonb_build_object(
        'account_id', v_account_id,
        'expense_id', p_expense_id,
        'amount', v_final_amount,
        'expense_date', v_final_date,
        'cost_center_id', v_final_cost_center_id,
        'kind', v_final_kind
      )
    );
  END IF;

  RETURN jsonb_build_object(
    'expense_id',        p_expense_id,
    'payment_method_id', v_final_payment_method_id,
    'branch_id',         v_final_branch_id,
    'cost_center_id',    v_final_cost_center_id
  );
END;
$function$;


REVOKE ALL ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) TO authenticated;
COMMENT ON FUNCTION public.rpc_update_expense(uuid, text, numeric, date, text, uuid, boolean, uuid, boolean, uuid, boolean) IS
  $c$gastos-forma-pago: edición atómica del gasto. Bloquea con P0423 el gasto con
  movimiento de caja o bancario posteado, con mensajes distinguibles y ANTES de
  cualquier escritura (D11), y aplica el contrato tri-estado
  (p_<campo>, p_<campo>_provided) a forma de pago, sucursal y centro de costo
  (D12). NO postea movimientos: imputar una forma de pago por edición es sólo
  una etiqueta (D13). compras-gastos-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la sucursal por defecto, como en el alta.
  edicion-operaciones-con-dinero (tanda A, D12): lee y toma la fila del gasto FOR UPDATE antes de resolver los valores vigentes.$c$;

-- =============================================================================
-- 16. Introspección: lo que esta migración promete, verificado en la base viva
-- =============================================================================
-- Falla la migración (y la reaplicación de CI) si alguna función quedó con más de una definición viva, con la ACL
-- cambiada, sin la huella neta / el emparejamiento / el asiento vigente, o si los dos filtros del conjunto canónico no
-- listan los mismos 15 tipos.
DO $$
DECLARE
  v_fn     text;
  v_n      integer;
  v_src    text;
  v_oid    oid;
  v_set_j  text[];
  v_set_d  text[];
BEGIN
  -- (a) una sola firma viva por función
  FOR v_fn IN SELECT unnest(ARRAY[
      'op_money_footprint', 'op_money_footprint_flags', '_customer_open_items', '_supplier_open_items',
      '_journal_purchase_lines', '_journal_post_from_event', 'rpc_process_outbox_dispatch',
      'rpc_delete_sale_operation', 'rpc_delete_purchase_operation', 'rpc_delete_expense',
      'rpc_receivables_report', 'rpc_payables_report', '_produce_receivables_overdue_digest',
      'rpc_update_customer_charge_due_date', 'rpc_update_supplier_charge_due_date',
      'rpc_atomic_update_purchase_operation', 'rpc_update_expense'])
  LOOP
    SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): % tiene % definiciones vivas', v_fn, v_n;
    END IF;
  END LOOP;

  -- (b) ACL: ejecutables por authenticated (nunca por anon) las de API; internas sin authenticated ni anon
  FOR v_fn IN SELECT unnest(ARRAY[
      'op_money_footprint', 'op_money_footprint_flags', 'rpc_delete_sale_operation', 'rpc_delete_purchase_operation',
      'rpc_delete_expense', 'rpc_receivables_report', 'rpc_payables_report', 'rpc_update_customer_charge_due_date',
      'rpc_update_supplier_charge_due_date', 'rpc_atomic_update_purchase_operation', 'rpc_update_expense'])
  LOOP
    SELECT oid INTO v_oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): la ACL de % cambió (authenticated sí, anon nunca)', v_fn;
    END IF;
  END LOOP;
  FOR v_fn IN SELECT unnest(ARRAY[
      '_customer_open_items', '_supplier_open_items', '_journal_purchase_lines', '_journal_post_from_event',
      'rpc_process_outbox_dispatch', '_produce_receivables_overdue_digest'])
  LOOP
    SELECT oid INTO v_oid FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF has_function_privilege('authenticated', v_oid, 'EXECUTE') OR has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): % es interna y quedó ejecutable por authenticated o anon', v_fn;
    END IF;
  END LOOP;

  -- (c) el borrado consume la huella neta (y ya no suma por tipo original)
  FOR v_fn IN SELECT unnest(ARRAY['rpc_delete_sale_operation', 'rpc_delete_purchase_operation', 'rpc_delete_expense'])
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src NOT LIKE '%op_money_footprint(%' THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): % no consume op_money_footprint', v_fn;
    END IF;
    IF v_src ~* 'GROUP BY session_id' THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): % todavía agrupa la caja por sesión', v_fn;
    END IF;
  END LOOP;

  -- (d) el aging sale de la derivación única, en los cinco lugares SQL
  FOR v_fn IN SELECT unnest(ARRAY['rpc_receivables_report', '_produce_receivables_overdue_digest', 'rpc_update_customer_charge_due_date'])
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src NOT LIKE '%_customer_open_items(%' OR v_src ~* 'WITH pool AS|\mcum_amount\M' THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): % no usa _customer_open_items o conserva su propio FIFO', v_fn;
    END IF;
  END LOOP;
  FOR v_fn IN SELECT unnest(ARRAY['rpc_payables_report', '_produce_receivables_overdue_digest', 'rpc_update_supplier_charge_due_date'])
  LOOP
    SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = v_fn;
    IF v_src NOT LIKE '%_supplier_open_items(%' OR v_src ~* 'WITH pool AS|\mcum_amount\M' THEN
      RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): % no usa _supplier_open_items o conserva su propio FIFO', v_fn;
    END IF;
  END LOOP;

  -- (e) el consumidor contable: asiento vigente (reversal_of IS NULL) en las cinco búsquedas con riesgo de contra-asiento,
  --     rama PurchaseAdjusted y los dos filtros con LOS MISMOS 15 tipos
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = '_journal_post_from_event';
  SELECT count(*) INTO v_n FROM regexp_matches(regexp_replace(regexp_replace(v_src, '/\*.*?\*/', '', 'gs'), '--[^\n]*', '', 'g'), 'reversal_of\s+IS NULL', 'g');
  IF v_n < 10 THEN
    RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): _journal_post_from_event tiene % búsquedas con reversal_of IS NULL y se esperaban al menos 10', v_n;
  END IF;
  IF v_src NOT LIKE '%v_event_type = ''PurchaseAdjusted''%' OR v_src NOT LIKE '%_journal_purchase_lines(%' THEN
    RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): _journal_post_from_event no tiene la rama PurchaseAdjusted';
  END IF;
  SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_set_j
  FROM regexp_matches(substring(pg_get_functiondef('public._journal_post_from_event(events)'::regprocedure) from 'v_event_type NOT IN \(([^)]*)\)'), '''([A-Za-z]+)''', 'g') AS m;
  SELECT array_agg(DISTINCT m[1] ORDER BY m[1]) INTO v_set_d
  FROM regexp_matches(substring(pg_get_functiondef('public.rpc_process_outbox_dispatch(integer)'::regprocedure) from 'Consumer 3: JournalEntry.*?IN \(([^)]*)\)'), '''([A-Za-z]+)''', 'g') AS m;
  IF v_set_j IS DISTINCT FROM v_set_d OR array_length(v_set_j, 1) <> 15 OR NOT ('PurchaseAdjusted' = ANY (v_set_j)) THEN
    RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): los dos filtros de event_type deben listar los mismos 15 tipos (con PurchaseAdjusted): helper=% despachador=%', v_set_j, v_set_d;
  END IF;

  -- (f) la edición de compra bloquea las filas y emite PurchaseAdjusted; la de gasto lee FOR UPDATE
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_atomic_update_purchase_operation';
  IF v_src !~* 'ORDER\s+BY\s+p\.id\s+FOR UPDATE' OR v_src NOT LIKE '%''PurchaseAdjusted''%' THEN
    RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): rpc_atomic_update_purchase_operation sin lock de filas ascendente o sin PurchaseAdjusted';
  END IF;
  SELECT prosrc INTO v_src FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'rpc_update_expense';
  IF regexp_replace(v_src, '--[^\n]*', '', 'g') !~* 'account_id = v_account_id\s+FOR UPDATE' THEN
    RAISE EXCEPTION 'edicion-operaciones-con-dinero tanda A (introspección): rpc_update_expense no lee la fila del gasto FOR UPDATE';
  END IF;

  RAISE NOTICE 'edicion-operaciones-con-dinero tanda A (introspección) OK: una firma por función, ACLs, huella neta, aging único, asiento vigente, 15 tipos en los dos filtros y locks de edición';
END $$;
