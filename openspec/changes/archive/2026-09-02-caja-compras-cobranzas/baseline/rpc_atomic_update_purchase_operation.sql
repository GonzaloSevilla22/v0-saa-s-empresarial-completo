-- Procedencia: pg_get_functiondef(oid) VIVO en producción (gxdhpxvdjjkmxhdkkwyb),
-- capturado 2026-09-01 vía mcp__supabase__execute_sql (SELECT, read-only).
-- md5:    0dc8bcf0902710ecb126a9edb9bc3e5f
-- length: 23205
-- Coincide EXACTO con design.md — checkpoint 1.2 PASA.
-- SE REESCRIBE (grupo 6): el guard P0423 (operation_has_account_charge_immutable /
-- operation_has_bank_movement_immutable) suma un tercer EXISTS contra
-- cash_movements.reference_id = p.operation_id (compra con caja posteada
-- también pasa a ser inmutable).

CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_supplier_id uuid DEFAULT NULL::uuid, p_supplier_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false)
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
  v_flag_on         boolean;
  v_old_snapshots   jsonb;
  v_prev_snap       jsonb;
  v_line_snap       jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_old_payment_method_id   uuid;  -- metodos-pago-operaciones (D5)
  v_final_payment_method_id uuid;  -- metodos-pago-operaciones (D5)
  -- edicion-preserva-contexto (F1):
  v_old_branch_id      uuid;       -- §D1/§D3
  -- valor vigente capturado antes del DELETE — base del tri-estado
  -- (compras-proveedor-cuenta-corriente D7/OQ-5)
  v_old_supplier_id    uuid;
  -- valor vigente capturado antes del DELETE — base del tri-estado
  -- (compras-proveedor-cuenta-corriente D7/OQ-5)
  v_old_cost_center_id uuid;
  v_final_branch_id    uuid;       -- §D3/§D8: sucursal EFECTIVA
  v_branch             RECORD;
  -- compras-proveedor-cuenta-corriente (D7 + OQ-5): proveedor y centro de
  -- costo EFECTIVOS — cierran la OQ-1 que edicion-preserva-contexto dejó
  -- abierta ("preservados pero no parámetro, porque el form no los expone").
  v_final_supplier_id    uuid;
  v_final_cost_center_id uuid;
  -- compras-proveedor-cuenta-corriente (review A, SQL-1/BE-2/SEC-1): kind
  -- EFECTIVO de la forma de pago — el vigente antes de la edición y el que
  -- queda después. Base del guard de transición a crédito.
  v_old_kind             text;
  v_final_kind           text;
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
      USING ERRCODE = 'P0403';
  END IF;

  IF array_length(p_purchase_ids, 1) IS NULL OR array_length(p_purchase_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No purchase IDs provided' USING ERRCODE = 'P0400';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.purchases
    WHERE id = ANY(p_purchase_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: purchase belongs to another user' USING ERRCODE = 'P0403';
  END IF;

  IF (SELECT COUNT(*) FROM public.purchases WHERE id = ANY(p_purchase_ids))
      != array_length(p_purchase_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more purchase IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- pagos-cableados-restantes (D6, task 9.3): espejo del guard de venta —
  -- inmutabilidad de operaciones con cargo de cuenta corriente posteado.
  -- Purchases no tiene el concepto de "purchase_orders" análogo a
  -- sales_orders: reference_id del cargo (cuando exista, vía el helper
  -- compartido _pay_register_party_charge con party_kind='supplier') apunta
  -- directo a purchases.operation_id, sin la complejidad de doble referencia
  -- de la venta. Sin guard de caja: las compras no tienen opt-in de caja en
  -- este change (OQ-E recortado — ver design.md Non-Goals).
  IF EXISTS (
    SELECT 1
    FROM public.supplier_account_movements sam
    WHERE sam.reference_id IN (
      SELECT p.operation_id FROM public.purchases p WHERE p.id = ANY(p_purchase_ids)
    )
  ) THEN
    -- compras-proveedor-cuenta-corriente (review A, SPEC-05): el texto venía
    -- copiado del lado VENTA y ofrecía un camino de corrección que en compras
    -- NO existe (el listado de compras ya lo dice en la UI). El camino real es
    -- borrar + recargar: rpc_delete_purchase_operation compensa el cargo, el
    -- banco y el stock de forma atómica.
    -- (El gate de STEP 4 verifica que la copia de venta no vuelva a colarse.)
    RAISE EXCEPTION 'operation_has_account_charge_immutable: compra con cargo en cuenta corriente del proveedor posteado — borrá esta compra (revierte el cargo y repone el stock) y volvé a cargarla'
      USING ERRCODE = 'P0423';
  END IF;

  -- pos-banco-movimientos (D8, task 6.2): tercer EXISTS — bank_movements
  -- entra al mismo bloqueo P0423 que el cargo de cuenta corriente. Egreso de
  -- compra: reference siempre purchases.operation_id (sin la doble
  -- convención de la venta).
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

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón que venta.
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2/D5): acarreo de snapshot keyed por
  -- product_id. Para compra el snapshot puede vivir en purchase_items, en el
  -- header purchases, o en ambos — se acarrea desde purchase_items cuando
  -- hay fila y, si no, cae al header (COALESCE(pi.*, p.*)).
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

  -- metodos-pago-operaciones (D5): capturar el payment_method_id vigente de
  -- la operación ANTES del DELETE — mismo momento que v_old_snapshots.
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

  -- edicion-preserva-contexto (F1, design §D1/§D2): capturar el contexto
  -- vigente del header ANTES del DELETE (el DELETE de más abajo borra las
  -- filas viejas: sin esta captura previa no habría de dónde preservar).
  --
  -- compras-proveedor-cuenta-corriente (D7 + OQ-5): los tres son ahora
  -- editables por contrato TRI-ESTADO — se cierra la OQ-1 de
  -- edicion-preserva-contexto, que los dejó "preservados sin exponerse"
  -- porque el form de compra no tenía selector. Ahora lo tiene para
  -- proveedor, y el CostCenterSelect ya estaba montado en el form de edición
  -- sin ningún efecto (UI que mentía en producción).
  SELECT branch_id, supplier_id, cost_center_id
  INTO   v_old_branch_id, v_old_supplier_id, v_old_cost_center_id
  FROM   public.purchases
  WHERE  id = ANY(p_purchase_ids)
  LIMIT  1;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para branch_id —
  -- espejo del de venta. Validación antes del REVERSE (gate 2.9).
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

  -- compras-proveedor-cuenta-corriente (D7): tri-estado para supplier_id —
  -- mismo contrato que payment_method_id y branch_id. El router lo resuelve
  -- con `"supplier_id" in payload.model_fields_set`, NUNCA con
  -- `payload.supplier_id is None`:
  --   provided=false            -> preservar el vigente (v_old_supplier_id)
  --   provided=true, valor uuid -> reimputar
  --   provided=true, valor NULL -> desimputar
  --
  -- Validación ANTES del REVERSE (mismo gate que branch_id): un proveedor
  -- ajeno o borrado rechaza sin reversa ni reaplicación de stock.
  --
  -- La edición NO postea ni revierte cargos de cuenta corriente: una compra
  -- con cargo posteado ya es inmutable (P0423, guard de más arriba), así que
  -- el único caso editable es el de una compra SIN cargo — y ahí reimputar el
  -- proveedor es sólo cambiar una FK. Invariante asertada por test, no
  -- asumida.
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

  -- compras-proveedor-cuenta-corriente (OQ-5 opción A): mismo tri-estado para
  -- cost_center_id. Cierra la OQ-1 de edicion-preserva-contexto COMPLETA — el
  -- CostCenterSelect ya está montado en el form de edición de compra y hasta
  -- hoy no tenía parámetro en la RPC: el usuario cambiaba el centro de costo,
  -- guardaba, y no pasaba nada.
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

  -- compras-proveedor-cuenta-corriente (review A — SQL-1/BE-2/SEC-1): guard de
  -- transición a crédito en la EDICIÓN.
  --
  -- D7 es explícito: la edición NO postea ni revierte cargos de cuenta
  -- corriente. Sin este guard, el camino de edición podía mover una compra a
  -- una forma de pago de kind='credit' —con o sin proveedor— y dejarla
  -- registrada como "a crédito" SIN cargo posteado: exactamente el defecto que
  -- la spec `supplier-account` declara ("Una compra imputada a kind='credit'
  -- que quede registrada sin su cargo correspondiente SHALL considerarse un
  -- defecto, no una configuración válida"). Y como el guard P0423 de más
  -- arriba mira supplier_account_movements, la compra resultante quedaba
  -- además indefinidamente editable — deuda invisible y mutable.
  --
  -- Se resuelven los DOS kinds efectivos: el que queda tras la edición
  -- (v_final_payment_method_id, ya validado por el tri-estado de arriba) y el
  -- que la operación tenía antes (v_old_payment_method_id). SELECT INTO sobre
  -- un id NULL deja la variable en NULL — "sin forma de pago imputada".
  SELECT kind INTO v_final_kind
  FROM   public.payment_methods
  WHERE  id = v_final_payment_method_id;

  SELECT kind INTO v_old_kind
  FROM   public.payment_methods
  WHERE  id = v_old_payment_method_id;

  -- (a) Simetría con el alta (D6): no hay deuda sin acreedor, tampoco por
  --     edición. MISMO mensaje y MISMO ERRCODE que el camino de creación —
  --     el mapeo backend/frontend es uno solo. Cubre el caso "compra a crédito
  --     legacy a la que se le desimputa el proveedor".
  --
  --     review C (S1): la regla sólo alcanza a la edición que TOCA el contrato
  --     de crédito — es decir, la que informa la forma de pago o el proveedor.
  --     Sin ese condicionante, una compra legacy que YA estaba imputada a un
  --     kind='credit' y NO tiene proveedor (el estado de las 38 operaciones
  --     vivas en prod, donde hasta este change había 0 proveedores) quedaba
  --     INEDITABLE: cambiarle una cantidad rebotaba con P0400 sin que el
  --     usuario hubiera tocado ni la forma de pago ni el proveedor. Eso
  --     contradice tanto la spec operation-edit-context ("una compra que YA
  --     estaba imputada a kind='credit' y no tiene cargo SHALL seguir siendo
  --     editable") como el comentario de (b) acá abajo. Con el condicionante:
  --       - desimputar el proveedor (p_supplier_provided)            -> rechaza
  --       - reimputar la forma de pago, aunque siga en credit
  --         (p_payment_method_provided)                              -> rechaza
  --       - editar cantidades/fecha/descripción sin tocar ninguno    -> pasa
  IF (p_payment_method_provided OR p_supplier_provided)
     AND v_final_kind = 'credit'
     AND v_final_supplier_id IS NULL
  THEN
    RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
      USING ERRCODE = 'P0400';
  END IF;

  -- (b) Transición HACIA crédito: sólo se rechaza cuando la edición informa
  --     explícitamente la forma de pago (p_payment_method_provided) y el kind
  --     pasa de "no crédito" (incluido NULL, sin forma de pago) a 'credit'.
  --     El camino de corrección es borrar + recargar, que sí postea el cargo.
  --
  --     Las compras a crédito YA existentes sin cargo posteado (las históricas
  --     de antes de este change) siguen siendo editables: v_old_kind ya es
  --     'credit', así que este IF no se dispara y sólo aplica (a). Sin ese
  --     matiz, el change habría vuelto inmutables en silencio a las 38
  --     operaciones de compra vivas en prod.
  --
  --     No se acuña un ERRCODE nuevo: P0400 (ya mapeado a 400) con el prefijo
  --     de mensaje distinguiendo el caso, mismo criterio que D6.
  IF p_payment_method_provided
     AND v_final_kind = 'credit'
     AND v_old_kind IS DISTINCT FROM 'credit'
  THEN
    RAISE EXCEPTION 'credit_transition_not_allowed: la edición no postea cargos en cuenta corriente — borrá esta compra y volvé a cargarla como compra a crédito'
      USING ERRCODE = 'P0400';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — espejo de
  -- la venta, signos invertidos. REVERSE sigue sobre la sucursal VIEJA de
  -- cada fila (§D8 — no cambia con F1).
  FOR v_old_purchase IN
    SELECT id, product_id, quantity, branch_id, operation_id
    FROM public.purchases
    WHERE id = ANY(p_purchase_ids)
  LOOP
    IF v_old_purchase.product_id IS NOT NULL THEN
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_purchase.product_id;

      SELECT unit_cost_snapshot INTO v_reverse_unit_cost
      FROM   public.stock_movements
      WHERE  reference_id = v_old_purchase.id AND reference_type = 'purchase'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: revertir de la branch original de la compra (o default).
      -- stock-movements-edicion (D2/D3): pata REVERSE — type='purchase_return',
      -- reference_id=id VIEJO, reference_type='purchase_update', delta
      -- NEGATIVO (revierte la entrada de stock que aplicó la compra original).
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_purchase.product_id, v_old_product_name,
        v_old_purchase.branch_id, -v_old_purchase.quantity, 'purchase_return',
        v_old_purchase.id, 'purchase_update', v_old_purchase.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', NULL
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.purchases WHERE id = ANY(p_purchase_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  -- edicion-preserva-contexto (F3, design §D7): quantity integer→numeric,
  -- unit_id sumado al recordset (misma forma que rpc_create_purchase_operation).
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
      END IF;

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- edicion-operaciones-lineas (D2/D4/D5): misma decisión de snapshot que
      -- la venta, aplicada AL HEADER siempre (D5 — el write path real).
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id = v_final_branch_id (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7).
      -- compras-proveedor-cuenta-corriente (D7/OQ-5): supplier_id y
      -- cost_center_id pasan de acarreados a EFECTIVOS (tri-estado).
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id,
         name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id,
         v_line_snap->>'name_snapshot',
         v_line_snap->>'sku_snapshot',
         (v_line_snap->>'unit_cost_snapshot')::numeric,
         (v_line_snap->>'iva_rate_snapshot')::numeric)
      RETURNING id INTO v_new_purchase_id;

      -- edicion-operaciones-lineas (D3): purchase_items condicionado por el
      -- mismo flag que la venta y que la creación de compra.
      -- edicion-preserva-contexto: unit_id = v_item.unit_id en vez de NULL.
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

      -- C-21 checkpoint #2: single-write branch_stock.
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='purchase',
      -- reference_id=id NUEVO, reference_type='purchase' (indistinguible de
      -- la creación). unit_cost_snapshot reusa v_line_snap.
      -- edicion-preserva-contexto (F1 §D8): sucursal EFECTIVA en vez de NULL.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, v_item.quantity, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/unit_id igual.
      -- compras-proveedor-cuenta-corriente (D7/OQ-5): supplier_id y
      -- cost_center_id EFECTIVOS también en la rama sin producto.
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id,
         branch_id, supplier_id, cost_center_id, payment_method_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_description, p_date, v_new_op_id,
         v_final_branch_id, v_final_supplier_id, v_final_cost_center_id, v_final_payment_method_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$function$
;
