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
$function$

