-- =============================================================================
-- ROLLBACK de 20261091000001_v31_document_lines_consistency.sql  (design D10)
--
-- Se aplica por CLI, con aprobación del PO. Qué hace:
--   1. DROP NOT NULL de name_snapshot en sale_items y purchase_items.
--   2. Recrea las 7 funciones con el cuerpo VIVO previo (checkpoint 0.2, md5 en la migración).
--   3. Vuelve a insertar las filas del feature flag de líneas (enabled = true) para las cuentas con ventas.
-- NO revierte el backfill: las líneas agregadas y los nombres completados son correctos y quedan
-- marcados con snapshot_backfilled = true.
-- =============================================================================

ALTER TABLE public.sale_items     ALTER COLUMN name_snapshot DROP NOT NULL;
ALTER TABLE public.purchase_items ALTER COLUMN name_snapshot DROP NOT NULL;

-- ── rpc_create_sale_operation_v2 (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation_v2(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_new_op_id    uuid;
  v_existing_op  uuid;
  v_item         RECORD;
  v_product      RECORD;
  v_branch       RECORD;
  v_gate_branch  uuid;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
  v_qty_before   numeric;
  v_qty_after    numeric;
  v_qty_norm     numeric(15,4);
  v_branch_qty   numeric(15,4);
  v_inserted     integer;
  v_canal        text;
  -- pagos-cableados-restantes (D1/D4/D5): kind derivado + total acumulado
  -- para el cargo de crédito y el movimiento de caja opt-in.
  v_kind                  text;
  v_total_sum             numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
      USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite registrar ventas (requiere vendedor, cajero, administrador o dueño)');

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
  END IF;

  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
  IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
    RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
  END IF;

  -- pagos-cableados-restantes (D1 de pos-catalogo-pagos, reaplicado): el
  -- kind se DERIVA del catálogo — nunca se acepta como texto del cliente.
  -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id).
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind
    FROM public.payment_methods
    WHERE id = p_payment_method_id AND account_id = v_account_id
      AND is_active = TRUE AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): el client_id es opcional pero, si viene,
  -- tiene que pertenecer al tenant — ANTES de cualquier escritura (incluida
  -- la fila legacy de `sales`, más abajo). El choke point
  -- c30_get_or_create_customer_account (20261011000001) sólo se ejecuta
  -- para ventas a CRÉDITO (vía _pay_register_party_charge, DESPUÉS del
  -- INSERT en `sales`): una venta al CONTADO (cash/transfer/card/...) con un
  -- client_id ajeno nunca invoca ese choke point y hoy escribe la fila
  -- igual, sin rollback — exactamente la OQ-4 que este fix cierra. Guard
  -- explícito, incondicional al kind. Mismo predicado que el choke point
  -- (sin filtro de deleted_at, a propósito: un cliente dado de baja ya es
  -- aceptado hoy por ese mismo camino para postear un cargo).
  IF p_client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = p_client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- pagos-cableados-restantes (D5): crédito es obligatorio, nunca opcional —
  -- ANTES del descuento de stock (task 5.2). No hay "vender a cuenta
  -- corriente sin anotarlo".
  IF v_kind = 'credit' AND p_client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- C-26: la branch explícita debe existir, estar activa Y operativa
  IF p_branch_id IS NOT NULL THEN
    SELECT id, status INTO v_branch
    FROM public.branches
    WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'branch_not_found or not active for this account'
        USING ERRCODE = 'P0404';
    END IF;
    IF v_branch.status = 'closed' THEN
      RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- C-26: branch del gate y del descuento (explícita o default operativa)
  v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

  -- ventas-sucursal-por-defecto (D2/D3): la sucursal que se GUARDA es la misma con
  -- la que se valida el stock, la caja y el banco. Sin sucursal elegida, si la
  -- cuenta no tiene ninguna sucursal OPERATIVA a la cual resolver (ninguna
  -- sucursal, o todas inactivas o cerradas: c26_default_branch devuelve entonces
  -- su fallback no operativo), se rechaza ANTES de escribir nada. Mismo token y
  -- mismo código que rpc_quick_sale y "Facturar venta manual" cuando la cuenta no
  -- tiene sucursal. Una sucursal ELEGIDA ya se validó arriba (P0404 / P0422
  -- branch_closed). Va antes del INSERT en operation_idempotency: el rechazo no
  -- deja nada persistido.
  IF p_branch_id IS NULL AND NOT EXISTS (
    SELECT 1 FROM public.branches
    WHERE id = v_gate_branch AND account_id = v_account_id
      AND is_active = TRUE AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
      USING ERRCODE = 'P0422';
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'sale'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.sales s
    WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- pagos-cableados-restantes: acumular total para el cargo de crédito y/o
    -- el movimiento de caja opt-in (mismo patrón que rpc_create_purchase_operation).
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    IF v_item.product_id IS NOT NULL THEN
      -- v3-snapshot-pattern: se agrega sku, cost a la lectura ya existente
      -- (name, is_variant) para congelar name/sku/cost sin un SELECT extra.
      SELECT id, user_id, is_variant, name, sku, cost INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1/D2): la conversión por unidad vive en UNA
      -- sola definición, relativa a la unidad base del PRODUCTO (P0404 unidad
      -- inexistente, P0400 unit_type_mismatch / unit_requires_base_unit).
      -- Tercera revisión (TOCTOU): DESPUÉS del FOR UPDATE — con la fila tomada
      -- la unidad base ya no cambia (trg_product_base_unit_guard espera esta
      -- fila) y un cambio que commiteó mientras esperábamos se lee acá.
      v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- C-26 (OQ-A): gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        IF p_branch_id IS NOT NULL THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        ELSE
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        END IF;
      END IF;

      -- ventas-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o la
      -- principal operativa), la MISMA con la que se validó el stock y se descuenta,
      -- no el p_branch_id crudo.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product ya cargado.
      -- iva_rate_snapshot: products no tiene columna de IVA (D3) → NULL.
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

      -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
      -- ventas-sucursal-por-defecto (D1/D2): el movimiento lleva v_gate_branch, la
      -- sucursal de la que SALIÓ el stock: la reversa del borrado lee la sucursal DEL
      -- MOVIMIENTO (se escribe una única vez, en este INSERT: RN-21 intacta).
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );

    ELSE
      -- v3-snapshot-pattern (2.6): línea de servicio — name_snapshot no
      -- disponible en el payload legacy de esta RPC (solo amount/quantity/
      -- unit_id); queda NULL como hoy. La línea de servicio con
      -- name_snapshot desde payload se resuelve en _c29_confirm_order_core
      -- (sales_order_items ya trae el nombre desde el frontend — ver 2.4/2.6).
      -- ventas-unidades-conversion: sin producto no hay stock que mover, pero
      -- la unidad de la línea se sigue validando (P0404) como antes.
      PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
      -- ventas-sucursal-por-defecto (D1/D2): v_gate_branch, no p_branch_id crudo.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
         total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (v_uid, v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
         v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
  -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
  -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
  -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
  -- venta de 665,334 y una factura de round(Σ) = 665,33.
  v_total_sum := round(v_total_sum, 2);

  -- pagos-cableados-restantes (OQ-C, D4): opt-in de caja — las tres
  -- condiciones se validan en el SERVIDOR (kind cash + sesión abierta en la
  -- sucursal EFECTIVA + fecha de hoy en ART), nunca se confía en la UI. La
  -- ausencia de p_cash_session_id es no-op (D5 — compatible hacia atrás con
  -- las 223 operaciones históricas del formulario).
  IF p_cash_session_id IS NOT NULL THEN
    -- edicion-operaciones-con-dinero (tanda B, D16): las tres condiciones del opt-in viven en UN solo helper.
    PERFORM public._cash_optin_assert(v_account_id, p_cash_session_id, v_kind, v_gate_branch, p_date, false, 'sale');

    PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total_sum, 'sale', v_new_op_id);
  END IF;

  -- pagos-cableados-restantes (OQ-D, D2/D5): crédito SIEMPRE postea el
  -- cargo, vía el mismo helper compartido que usa el POS — una sola
  -- definición de "cargar una venta a cuenta corriente" (D1).
  -- cobranzas-vencimientos (D3): transporta la fecha de negocio (p_date) y
  -- el override (p_due_date) — la cascada se resuelve EN el helper, nunca acá.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', p_client_id, v_total_sum, v_new_op_id, v_new_op_id,
      p_date, p_due_date
    );
  END IF;

  -- pos-banco-movimientos (D5, task 5.1): movimiento bancario operativo del
  -- formulario de venta — mismo helper que el POS, mismo punto (después de
  -- caja/crédito). p_value_date = p_date (el form admite fechas pasadas —
  -- D4, guard P0424 dentro del helper).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total_sum, 'in', 'sale', v_new_op_id,
    p_date, v_gate_branch, NULL
  );

  -- asiento-venta-formulario (D6): evento del outbox — INSERT plano, SIN
  -- bloque EXCEPTION. Si esto falla y la venta igual commitea, el
  -- resultado es exactamente el bug que este change arregla (venta sin
  -- asiento) pero silencioso — swallowear el fallo no es aceptable.
  -- payment_method va CRUDO (v_kind), sin COALESCE: el default vive en la
  -- rama del consumidor, no en el payload (D6 — lección de pagos-cableados-
  -- restantes D7 con el 'credit' cableado de compras).
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id, 'SaleOperationCreated', 'SaleOperation', v_new_op_id,
    jsonb_build_object(
      'account_id',     v_account_id,
      'operation_id',   v_new_op_id,
      'total',          v_total_sum,
      'payment_method', v_kind,
      'client_id',      p_client_id,
      'sale_date',      p_date,
      'occurred_at',    now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_operation_v2(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation_v2(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,date) TO authenticated, service_role;
COMMENT ON FUNCTION public.rpc_create_sale_operation_v2(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,date) IS NULL;

-- ── rpc_create_sale_operation (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_sale_operation(p_idempotency_key text, p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id uuid;
  v_flag_on    boolean := false;
  v_uid        uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  -- deudas-menores-agosto (G1/D1): ausencia de fila = v2 (antes: legacy). El
  -- COALESCE va DESPUÉS del SELECT — SELECT ... INTO sin fila deja v_flag_on
  -- en NULL, y el COALESCE de acá lo resuelve a true. Ponerlo DENTRO del
  -- SELECT (como antes) no ejecuta nada cuando no hay fila y v_flag_on queda
  -- NULL (≈ false en el IF), que es exactamente el bug que se corrige.
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  IF v_flag_on THEN
    -- pagos-cableados-restantes: propaga p_cash_session_id a la v2.
    -- pos-banco-movimientos: propaga p_bank_account_id a la v2 (D6).
    -- cobranzas-vencimientos: propaga p_due_date a la v2 (el camino vivo).
    RETURN public.rpc_create_sale_operation_v2(
      p_idempotency_key, p_client_id, p_date, p_currency, p_items,
      p_branch_id, p_canal, p_payment_method_id, p_cash_session_id, p_bank_account_id,
      p_due_date
    );
  ELSE
    DECLARE
      v_new_op_id    uuid;
      v_existing_op  uuid;
      v_item         RECORD;
      v_product      RECORD;
      v_branch       RECORD;
      v_gate_branch  uuid;
      v_new_sale_id  uuid;
      v_result_items jsonb := '[]'::jsonb;
      v_qty_before   numeric;
      v_qty_after    numeric;
      v_qty_norm     numeric(15,4);
      v_branch_qty   numeric(15,4);
      v_inserted     integer;
      v_canal        text;
      -- pagos-cableados-restantes (task 5.3): mismo trío que la rama v2.
      v_kind                  text;
      v_total_sum             numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
      v_cash_session_status   text;
      v_cash_session_branch   uuid;
    BEGIN
      IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
          USING ERRCODE = 'P0403';
      END IF;

      -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
      -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
      PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite registrar ventas (requiere vendedor, cajero, administrador o dueño)');

      IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
      END IF;

      IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
      END IF;

      IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
      END IF;

      v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');
      IF v_canal IS NOT NULL AND length(v_canal) > 40 THEN
        RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
      END IF;

      -- pagos-cableados-restantes: mismo patrón de derivación de kind que la v2.
      -- metodos-pago-operaciones: validar pertenencia opcional (mirror de p_canal/branch_id)
      IF p_payment_method_id IS NOT NULL THEN
        SELECT kind INTO v_kind
        FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL;

        IF NOT FOUND THEN
          RAISE EXCEPTION 'payment_method_not_found or not active for this account'
            USING ERRCODE = 'P0404';
        END IF;
      END IF;

      IF v_kind = 'credit' AND p_client_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id'
          USING ERRCODE = 'P0400';
      END IF;

      -- C-26: la branch explícita debe existir, estar activa Y operativa
      IF p_branch_id IS NOT NULL THEN
        SELECT id, status INTO v_branch
        FROM public.branches
        WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'branch_not_found or not active for this account'
            USING ERRCODE = 'P0404';
        END IF;
        IF v_branch.status = 'closed' THEN
          RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- C-26: branch del gate y del descuento (explícita o default operativa)
      v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));

      -- ventas-sucursal-por-defecto (D2/D3): la sucursal que se GUARDA es la misma con
      -- la que se valida el stock, la caja y el banco. Sin sucursal elegida, si la
      -- cuenta no tiene ninguna sucursal OPERATIVA a la cual resolver (ninguna
      -- sucursal, o todas inactivas o cerradas: c26_default_branch devuelve entonces
      -- su fallback no operativo), se rechaza ANTES de escribir nada. Mismo token y
      -- mismo código que rpc_quick_sale y "Facturar venta manual" cuando la cuenta no
      -- tiene sucursal. Una sucursal ELEGIDA ya se validó arriba (P0404 / P0422
      -- branch_closed). Va antes del INSERT en operation_idempotency: el rechazo no
      -- deja nada persistido.
      IF p_branch_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = v_gate_branch AND account_id = v_account_id
          AND is_active = TRUE AND status = 'active'
      ) THEN
        RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
          USING ERRCODE = 'P0422';
      END IF;

      v_new_op_id := gen_random_uuid();

      INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
      VALUES (v_uid, p_idempotency_key, 'sale', v_new_op_id)
      ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

      GET DIAGNOSTICS v_inserted = ROW_COUNT;

      IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'sale'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                 jsonb_agg(jsonb_build_object('id', s.id, 'product_id', s.product_id) ORDER BY s.id),
                 '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.sales s
        WHERE  s.user_id = v_uid AND s.operation_id = v_existing_op;

        RETURN jsonb_build_object(
          'operation_id', v_existing_op,
          'items',        v_result_items,
          'replayed',     true
        );
      END IF;

      FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                 AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
        ORDER BY product_id
      LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
          RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
          RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        -- pagos-cableados-restantes: acumular total (mismo patrón que la v2).
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
          SELECT id, user_id, is_variant, name, sku, cost INTO v_product
          FROM   public.products
          WHERE  id = v_item.product_id
            AND account_id = v_account_id
          FOR UPDATE;

          IF NOT FOUND THEN
            RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
          END IF;

          -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
          -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

          IF NOT v_product.is_variant THEN
            IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
              RAISE EXCEPTION
                'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
                USING ERRCODE = 'P0422';
            END IF;
          END IF;

          -- ventas-unidades-conversion (auditoría post-apply): la rama legacy del
          -- kill-switch sale_items_rpc_v2=false conservaba la conversión inline
          -- (relativa a la base del TIPO). Misma definición única que la v2.
          -- Tercera revisión (TOCTOU): DESPUÉS del FOR UPDATE, como en la v2.
          v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

          -- C-26 (OQ-A): gate per-branch — el stock debe estar EN la branch
          -- de la operación (explícita o default operativa)
          SELECT COALESCE(quantity, 0) INTO v_branch_qty
          FROM   public.branch_stock
          WHERE  product_id = v_item.product_id AND branch_id = v_gate_branch;
          v_branch_qty := COALESCE(v_branch_qty, 0);

          IF v_branch_qty < v_qty_norm THEN
            IF p_branch_id IS NOT NULL THEN
              RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            ELSE
              RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
            END IF;
          END IF;

          -- ventas-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o la
          -- principal operativa), la MISMA con la que se validó el stock y se descuenta,
          -- no el p_branch_id crudo.
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, v_item.product_id,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             v_gate_branch, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;

          v_qty_before := v_branch_qty;
          v_qty_after  := v_branch_qty - v_qty_norm;

          PERFORM public.c21_apply_branch_stock_delta(
            v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm);

          -- v3-snapshot-pattern: costo congelado en el movimiento de stock.
          -- ventas-sucursal-por-defecto (D1/D2): el movimiento lleva v_gate_branch, la
          -- sucursal de la que SALIÓ el stock: la reversa del borrado lee la sucursal DEL
          -- MOVIMIENTO (se escribe una única vez, en este INSERT: RN-21 intacta).
          INSERT INTO public.stock_movements (
            user_id, account_id, product_id, product_name, type,
            quantity_delta, quantity_before, quantity_after,
            reference_id, reference_type, performed_by,
            operation_group_id, branch_id, unit_cost_snapshot
          ) VALUES (
            v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
            -v_qty_norm, v_qty_before, v_qty_after,
            v_new_sale_id, 'sale', v_uid,
            v_new_op_id, v_gate_branch, v_product.cost
          );

        ELSE
          -- Línea sin producto: no mueve stock; la unidad se sigue validando (P0404).
          PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
          -- ventas-sucursal-por-defecto (D1/D2): v_gate_branch, no p_branch_id crudo.
          INSERT INTO public.sales
            (user_id, account_id, client_id, product_id, amount, quantity, unit_id,
             total, currency, date, operation_id, branch_id, canal, payment_method_id)
          VALUES
            (v_uid, v_account_id, p_client_id, NULL,
             v_item.amount, v_item.quantity, v_item.unit_id,
             v_item.amount * v_item.quantity, p_currency, p_date, v_new_op_id,
             v_gate_branch, v_canal, p_payment_method_id)
          RETURNING id INTO v_new_sale_id;
        END IF;

        v_result_items := v_result_items
          || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
      END LOOP;

      -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
      -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
      -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
      -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
      -- venta de 665,334 y una factura de round(Σ) = 665,33.
      v_total_sum := round(v_total_sum, 2);

      -- pagos-cableados-restantes (task 5.3/6.2): mismo trío opt-in de caja
      -- + cargo de crédito que la rama v2 — la rama legacy queda consistente.
      IF p_cash_session_id IS NOT NULL THEN
        IF v_kind IS DISTINCT FROM 'cash' THEN
          RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
            USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
          RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
            USING ERRCODE = 'P0422';
        END IF;

        IF p_date <> public.reporting_local_today() THEN
          RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una venta fechada hoy (%)', public.reporting_local_today()
            USING ERRCODE = 'P0422';
        END IF;

        PERFORM public.c28_register_cash_movement(p_cash_session_id, v_total_sum, 'sale', v_new_op_id);
      END IF;

      -- cobranzas-vencimientos (D3): la rama legacy transporta la fecha de
      -- negocio y el override al helper — la MISMA llamada que la v2.
      IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
          v_account_id, 'customer', p_client_id, v_total_sum, v_new_op_id, v_new_op_id,
          p_date, p_due_date
        );
      END IF;

      -- pos-banco-movimientos (D5, task 5.1): rama legacy — mismo helper y
      -- mismo punto que la v2, para que ambas ramas del strangler queden
      -- consistentes (regla dura del proyecto: no duplicar la regla).
      PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'in', 'sale', v_new_op_id,
        p_date, v_gate_branch, NULL
      );

      RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
      );
    END;
  END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_sale_operation(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,date) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_create_sale_operation(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,date) TO authenticated, service_role;
COMMENT ON FUNCTION public.rpc_create_sale_operation(text,uuid,date,text,jsonb,uuid,text,uuid,uuid,uuid,date) IS NULL;

-- ── _purchase_operation_core (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public._purchase_operation_core(p_account_id uuid, p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid, p_cost_center_id uuid, p_payment_method_id uuid, p_bank_account_id uuid, p_supplier_id uuid, p_cash_session_id uuid, p_due_date date, p_source_delivery_note_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
/*
  v3-snapshot-pattern: agrega name_snapshot/sku_snapshot/unit_cost_snapshot/
  iva_rate_snapshot al INSERT de purchases (D2 — el write path real de
  compra) y unit_cost_snapshot al stock_movements de compra. Preserva
  íntegro el fix de 20260804000004 (ON CONFLICT 3-col + branch_stock, sin
  products.stock).

  deudas-menores-agosto (G1): agrega la resolución del flag
  'sale_items_rpc_v2' (mismo patrón COALESCE-después-del-SELECT que
  rpc_create_sale_operation) y, condicionado por ella, el INSERT en
  purchase_items que este RPC nunca tuvo en prod.

  metodos-pago-operaciones: agrega p_payment_method_id opcional, validado
  contra el catálogo de la cuenta y persistido en todas las filas de la
  operación (mirror de p_cost_center_id).

  pagos-cableados-restantes (D7/OQ-E): el payload de PurchaseCreated ya no
  hardcodea 'payment_method':'credit' — deriva el kind real de
  p_payment_method_id (mismo SELECT que ya validaba la pertenencia, ahora
  captura también el kind) con COALESCE(..., 'credit') para preservar el
  comportamiento cuando no hay forma de pago imputada.

  pos-banco-movimientos (D5, task 5.2): agrega p_bank_account_id opcional —
  la compra por método bancario debita el ledger operativo (egreso,
  p_direction='out'), simétrico a la venta.

  compras-proveedor-cuenta-corriente (D4/D6/D8): agrega p_supplier_id opcional
  trailing — la compra pasa a saber a quién se le compró, persistido en LAS DOS
  ramas del INSERT a purchases (D4), y cuando la forma de pago imputada es de
  kind='credit' postea el cargo en la cuenta corriente del proveedor vía el
  helper compartido _pay_register_party_charge (D8).

  caja-compras-cobranzas (D2/D3): agrega p_cash_session_id opcional trailing —
  con las tres condiciones verificadas en servidor, descuenta de la caja por
  el total de la compra. Sin SQL nuevo para D3 (sucursal): p_branch_id ya se
  valida y persiste desde 20261009000001 — lo que arregla D3 vive en el
  frontend/backend Python (grupos 9/10), no acá.

  cobranzas-vencimientos (D3): agrega p_due_date opcional trailing — la
  compra a crédito transporta la fecha de negocio (p_date) y el override al
  helper compartido, que resuelve la cascada con el plazo del PROVEEDOR.

  compras-gastos-sucursal-por-defecto (D1-D3): resuelve UNA vez
  v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta)) y la usa en
  los dos INSERT en purchases, el delta de stock, el movimiento de stock, la
  condición de caja y el banco. Sin sucursal operativa a la cual resolver rechaza
  con P0422 no_branch_found antes de escribir nada, y una sucursal elegida cerrada
  con P0422 branch_closed.

  remitos-compra tanda B (D8): extraído como NÚCLEO INTERNO (sin EXECUTE para anon ni
  authenticated) con p_account_id y p_source_delivery_note_id. Con origen (modo remito,
  sólo desde rpc_convert_delivery_note_to_purchase) el núcleo revalida el remito bajo
  bloqueo, LEE las líneas del propio remito (p_items tiene que venir nulo), NO toma el
  lock del producto ni suma stock ni escribe movimientos (el remito ya sumó el stock),
  toma los cuatro snapshots de la línea del remito, persiste el origen en cada fila y,
  al final y en la misma transacción, pasa el remito a converted con su historial. La
  decisión la toma el servidor desde el remito validado: ningún parámetro público la
  pide. rpc_create_purchase_operation queda como wrapper de la misma firma que llama
  al núcleo con origen nulo: la compra directa es idéntica.
*/
DECLARE
    v_uid             uuid;
    v_account_id      uuid;
    v_flag_on         boolean := false;
    v_new_op_id       uuid;
    v_existing_op     uuid;
    v_item            RECORD;
    v_product         RECORD;
    v_new_purchase_id uuid;
    v_result_items    jsonb := '[]'::jsonb;
    v_qty_before      numeric;
    v_qty_after       numeric;
    v_qty_norm        numeric(15,4);
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
    v_total_sum       numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
    v_kind            text;            -- pagos-cableados-restantes (D7)
    -- caja-compras-cobranzas (D2):
    v_cash_movement_id    uuid;
    -- compras-gastos-sucursal-por-defecto (D1/D2/D3):
    v_branch              RECORD;
    v_gate_branch         uuid;
    -- remitos-compra (D8): modo remito.
    v_from_dn             boolean := (p_source_delivery_note_id IS NOT NULL);
    v_dn                  public.delivery_notes%ROWTYPE;
    v_snap_name           text;
    v_snap_sku            text;
    v_snap_cost           numeric;
    v_snap_iva            numeric;
BEGIN
    v_uid := (SELECT auth.uid());
    IF v_uid IS NULL THEN
        RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
    END IF;

    v_account_id := p_account_id;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'Usuario sin cuenta activa — no se puede crear la operación'
            USING ERRCODE = 'P0403';
    END IF;

    -- deudas-menores-agosto (G1/D1): mismo flag_key y mismo patrón que
    -- rpc_create_sale_operation — ausencia de fila = v2 (escribe línea).
    SELECT enabled INTO v_flag_on
    FROM   public.account_feature_flags
    WHERE  account_id = v_account_id
      AND  flag_key   = 'sale_items_rpc_v2'
    LIMIT  1;
    v_flag_on := COALESCE(v_flag_on, true);

    IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
    END IF;

    -- remitos-compra (D8): MODO REMITO, autosuficiente aunque hoy sólo lo use la conversión
    -- (un guard que delega no es guard). Las líneas salen del REMITO, nunca del request.
    IF v_from_dn THEN
        IF p_items IS NOT NULL THEN
            RAISE EXCEPTION 'delivery_note_items_from_source: las líneas de una compra con origen de remito salen del remito, no del request'
                USING ERRCODE = 'P0400';
        END IF;

        SELECT * INTO v_dn
        FROM   public.delivery_notes
        WHERE  id = p_source_delivery_note_id
          AND  account_id = v_account_id
          AND  direction = 'purchase'
        FOR UPDATE;

        IF NOT FOUND
           OR v_dn.status <> 'issued'
           OR p_supplier_id IS DISTINCT FROM v_dn.supplier_id
           OR p_branch_id IS DISTINCT FROM v_dn.branch_id
           OR EXISTS (SELECT 1 FROM public.purchases
                      WHERE source_delivery_note_id = p_source_delivery_note_id) THEN
            RAISE EXCEPTION 'delivery_note_purchase_mismatch: el origen % no es un remito de compra pendiente de esta cuenta, de este proveedor y de esta sucursal, sin otra compra', p_source_delivery_note_id
                USING ERRCODE = 'P0409';
        END IF;

        SELECT jsonb_agg(jsonb_build_object(
                   'product_id', i.product_id, 'amount', i.price, 'quantity', i.quantity, 'unit_id', i.unit_id,
                   'name_snapshot', i.name_snapshot, 'sku_snapshot', i.sku_snapshot,
                   'unit_cost_snapshot', i.unit_cost_snapshot, 'iva_rate_snapshot', i.iva_rate_snapshot)
               ORDER BY i.product_id, i.line_no)
        INTO   p_items
        FROM   public.delivery_note_items i
        WHERE  i.delivery_note_id = p_source_delivery_note_id
          AND  i.account_id = v_account_id;

        IF p_items IS NULL THEN
            RAISE EXCEPTION 'delivery_note_purchase_mismatch: el remito % no tiene líneas', p_source_delivery_note_id
                USING ERRCODE = 'P0409';
        END IF;
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P0400';
    END IF;

    -- Verify branch_id belongs to this account (if provided)
    -- compras-gastos-sucursal-por-defecto (D2/D3, OQ-2 (a)): una sucursal ELEGIDA no
    -- puede estar cerrada — el bloque literal de rpc_create_expense. Hasta este change
    -- sólo se miraba is_active y la mercadería entraba en una sucursal cerrada.
    IF p_branch_id IS NOT NULL THEN
        SELECT id, status INTO v_branch
        FROM   public.branches
        WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
        IF v_branch.status = 'closed' THEN
            RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
        END IF;
    END IF;

    -- cost-center-dimension: Verify cost_center_id belongs to this account (mirror of branch_id)
    IF p_cost_center_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.cost_centers
            WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'cost_center_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- metodos-pago-operaciones: Verify payment_method_id belongs to this account (mirror of cost_center_id).
    -- pagos-cableados-restantes (D7): el mismo SELECT que valida pertenencia
    -- ahora captura también el kind — un solo lookup, no dos.
    IF p_payment_method_id IS NOT NULL THEN
        SELECT kind INTO v_kind
        FROM public.payment_methods
        WHERE id = p_payment_method_id AND account_id = v_account_id
          AND is_active = TRUE AND deleted_at IS NULL;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'payment_method_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- compras-proveedor-cuenta-corriente (D6): pertenencia del proveedor a la
    -- cuenta — mismo molde que branch_id/cost_center_id/payment_method_id.
    IF p_supplier_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.suppliers
            WHERE id = p_supplier_id AND account_id = v_account_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'supplier_not_found or not active for this account'
                USING ERRCODE = 'P0404';
        END IF;
    END IF;

    -- compras-proveedor-cuenta-corriente (D6, OQ-1 opción A): no hay deuda sin
    -- acreedor. Espejo exacto de credit_requires_client del lado venta.
    IF v_kind = 'credit' AND p_supplier_id IS NULL THEN
        RAISE EXCEPTION 'credit_requires_supplier: una compra a crédito necesita un proveedor identificado para cargar su cuenta corriente'
            USING ERRCODE = 'P0400';
    END IF;

    -- compras-gastos-sucursal-por-defecto (D1/D2/D3): la sucursal que se GUARDA es la
    -- misma con la que entra el stock, se escribe el movimiento de stock, se valida la
    -- sesión de caja y se registra el movimiento bancario. Sin sucursal elegida, si la
    -- cuenta no tiene ninguna sucursal OPERATIVA a la cual resolver (ninguna sucursal,
    -- o todas inactivas o cerradas: c26_default_branch devuelve entonces su fallback no
    -- operativo), se rechaza ANTES de escribir nada. Mismo token y mismo código que la
    -- venta. Una sucursal ELEGIDA ya se validó arriba (P0404 / P0422 branch_closed). Va
    -- antes del INSERT en operation_idempotency: el rechazo no deja nada persistido.
    v_gate_branch := COALESCE(p_branch_id, public.c26_default_branch(v_account_id));
    IF p_branch_id IS NULL AND NOT EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = v_gate_branch AND account_id = v_account_id
          AND is_active = TRUE AND status = 'active'
    ) THEN
        RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la compra'
            USING ERRCODE = 'P0422';
    END IF;

    v_new_op_id := gen_random_uuid();

    -- ON CONFLICT: el índice único es (user_id, operation_kind, idempotency_key).
    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
    ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid
          AND  operation_kind = 'purchase'
          AND  idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                   jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                   '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

        -- Idempotency replay: NO emitir evento duplicado (DEC-20). caja-
        -- compras-cobranzas (D12): un replay tampoco vuelve a postear caja —
        -- el RETURN acá corta antes de llegar al bloque de caja de más abajo.
        RETURN jsonb_build_object(
            'operation_id', v_existing_op,
            'items',        v_result_items,
            'replayed',     true
        );
    END IF;

    FOR v_item IN
        SELECT *
        FROM   jsonb_to_recordset(p_items)
                   AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid,
                        name_snapshot text, sku_snapshot text, unit_cost_snapshot numeric, iva_rate_snapshot numeric)
        ORDER BY product_id
    LOOP
        IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
            RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
            RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
        END IF;

        -- journal-entry-outbox: acumular total para el payload del evento
        -- (y ahora también para el egreso de caja).
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
            -- remitos-compra (D8): en modo remito se saltean el FOR UPDATE del producto, el chequeo por
            -- usuario, el de padre con variantes, la normalización y el stock (sin stock que mover, el lock
            -- del producto no protege nada y sólo sumaría superficie de interbloqueo con remitos y ventas).
            -- La existencia del producto la garantiza la FK de delivery_note_items.product_id.
            IF NOT v_from_dn THEN
                SELECT id, user_id, is_variant, name, sku, cost INTO v_product
                FROM   public.products
                WHERE  id = v_item.product_id
                  AND account_id = v_account_id
                FOR UPDATE;

                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
                END IF;

                -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
                -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

                IF NOT v_product.is_variant THEN
                    IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
                        RAISE EXCEPTION
                            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                            USING ERRCODE = 'P0422';
                    END IF;
                END IF;

                -- ventas-unidades-conversion (D1/D2): misma definición única que la venta.
                -- Tercera revisión (TOCTOU, reproducido con dos conexiones): DESPUÉS
                -- del FOR UPDATE. Normalizar antes leía la unidad base COMMITEADA
                -- mientras un cambio kg → u seguía abierto: la compra esperaba la
                -- fila y escribía 2 (kg) que se leían 2 u.
                v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

                v_snap_name := v_product.name;
                v_snap_sku  := v_product.sku;
                v_snap_cost := v_product.cost;
                v_snap_iva  := NULL;
            ELSE
                -- Los cuatro snapshots de la LÍNEA DEL REMITO (un producto renombrado o dado de baja entre la
                -- recepción y la compra conserva el nombre del remito).
                v_snap_name := v_item.name_snapshot;
                v_snap_sku  := v_item.sku_snapshot;
                v_snap_cost := v_item.unit_cost_snapshot;
                v_snap_iva  := v_item.iva_rate_snapshot;
            END IF;

            -- compras-gastos-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o
            -- la principal), la misma con la que entra el stock — no el p_branch_id crudo.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot,
                 source_delivery_note_id)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 v_gate_branch, p_cost_center_id, p_payment_method_id,
                 p_supplier_id,
                 v_snap_name, v_snap_sku, v_snap_cost, v_snap_iva,
                 p_source_delivery_note_id)
            RETURNING id INTO v_new_purchase_id;

            IF v_flag_on THEN
                INSERT INTO public.purchase_items (
                    purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
                    name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
                ) VALUES (
                    v_new_purchase_id, v_item.product_id, v_account_id, NULL,
                    v_item.quantity, v_item.unit_id,
                    v_item.amount, v_item.amount * v_item.quantity,
                    v_snap_name, v_snap_sku, v_snap_cost, v_snap_iva
                );
            END IF;

            -- remitos-compra (D8): el stock ya lo sumó el remito al recibir; en modo remito la compra no
            -- toca branch_stock ni escribe stock_movements.
            IF NOT v_from_dn THEN
                -- stock sobre branch_stock (C-21). before/after = Σ branch_stock.
                SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
                FROM   public.branch_stock
                WHERE  product_id = v_item.product_id;

                v_qty_before := v_stock_sum;
                v_qty_after  := v_stock_sum + v_qty_norm;

                -- compras-gastos-sucursal-por-defecto (D1): v_gate_branch EXPLÍCITA. Con el NULL crudo
                -- c21 resolvía la principal por dentro (otra lectura de c26_default_branch) y, sin
                -- ninguna sucursal, creaba "Casa Central" al vuelo.
                PERFORM public.c21_apply_branch_stock_delta(
                    v_account_id, v_item.product_id, v_gate_branch, v_qty_norm);

                INSERT INTO public.stock_movements (
                    user_id, account_id, product_id, product_name, type,
                    quantity_delta, quantity_before, quantity_after,
                    reference_id, reference_type, performed_by,
                    operation_group_id, branch_id, unit_cost_snapshot
                ) VALUES (
                    v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                    v_qty_norm, v_qty_before, v_qty_after,
                    v_new_purchase_id, 'purchase', v_uid,
                    -- compras-gastos-sucursal-por-defecto (D1): el movimiento lleva v_gate_branch, la
                    -- misma sucursal que el delta de stock y que la fila de la compra.
                    v_new_op_id, v_gate_branch, v_product.cost
                );
            END IF;

        ELSE
            IF v_from_dn THEN
                RAISE EXCEPTION 'delivery_note_purchase_mismatch: el remito % tiene una línea sin producto', p_source_delivery_note_id
                    USING ERRCODE = 'P0409';
            END IF;
            -- Línea sin producto: no mueve stock; la unidad se sigue validando (P0404).
            PERFORM public._uom_normalize_quantity(NULL, v_item.unit_id, v_item.quantity);
            -- compras-gastos-sucursal-por-defecto (D1/D2): también la línea de servicio guarda
            -- v_gate_branch.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 v_gate_branch, p_cost_center_id, p_payment_method_id,
                 p_supplier_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
    -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
    -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
    -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
    -- venta de 665,334 y una factura de round(Σ) = 665,33.
    v_total_sum := round(v_total_sum, 2);

    -- ── caja-compras-cobranzas (D2) — OPT-IN DE CAJA, 3 condiciones ───────────
    -- Copiado LITERAL del molde de rpc_create_expense: mismos tres tokens de
    -- error, mismo orden, y p_date (`date`) comparado DIRECTO contra
    -- reporting_local_today() — PROHIBIDO castear a timestamptz (el ::date
    -- implícito usaría la timezone del servidor/UTC, y una compra cargada
    -- entre las 21:00 y las 23:59 de Mendoza se rechazaría con P0422 justo
    -- cuando el usuario sabe que es hoy).
    --
    -- compras-gastos-sucursal-por-defecto (D1): "Sucursal efectiva de la compra" =
    -- v_gate_branch (la elegida o, sin elegir, la principal operativa), la misma que se
    -- persiste y con la que entra el stock — como el gasto y la venta. Antes de este
    -- change se comparaba contra el valor CRUDO: una compra sin sucursal no satisfacía la
    -- condición para ninguna caja real, y el formulario ofrece la sesión de la principal
    -- PRE-MARCADA, así que toda compra en efectivo sin sucursal elegida se rechazaba.
    IF p_cash_session_id IS NOT NULL THEN
        -- edicion-operaciones-con-dinero (tanda B, D16): las tres condiciones del opt-in viven en UN solo helper.
        PERFORM public._cash_optin_assert(v_account_id, p_cash_session_id, v_kind, v_gate_branch, p_date, false, 'purchase');

        v_cash_movement_id := public.c28_register_cash_movement(
            p_cash_session_id, -v_total_sum, 'purchase_payment', v_new_op_id, p_description
        );
    END IF;
    -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

    -- pos-banco-movimientos (D5, task 5.2): movimiento bancario operativo de
    -- EGRESO — v_kind CRUDO.
    -- compras-gastos-sucursal-por-defecto (D1): lleva v_gate_branch (la sucursal EFECTIVA, la
    -- misma que se persistió en la compra), como el gasto y la venta.
    PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'out', 'purchase', v_new_op_id,
        p_date, v_gate_branch, NULL
    );

    -- compras-proveedor-cuenta-corriente (D8): cargo en la cuenta corriente
    -- del proveedor. cobranzas-vencimientos (D3): transporta la fecha de
    -- negocio y el override — la cascada (plazo del PROVEEDOR) vive en el helper.
    IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
            v_account_id, 'supplier', p_supplier_id, v_total_sum, v_new_op_id, v_new_op_id,
            p_date, p_due_date
        );
    END IF;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    INSERT INTO public.events
        (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
        v_account_id,
        'PurchaseCreated',
        'Purchase',
        v_new_op_id,
        jsonb_build_object(
            'account_id',     v_account_id,
            'operation_id',   v_new_op_id,
            'total',          v_total_sum,
            'cost_center_id', p_cost_center_id,
            'neto',           NULL,
            'iva_amount',     NULL,
            'payment_method', COALESCE(v_kind, 'credit'),
            'occurred_at',    now()
        ),
        now()
    );

    -- remitos-compra (D8, molde de la revisión adversarial RB-02 de remitos-venta): el remito de
    -- origen queda `converted` EN EL NÚCLEO, en la misma transacción que crea la compra y bajo el
    -- mismo lock del remito, y sólo por el camino que crea la compra (un replay de idempotencia
    -- devolvió antes). Si quedara en el caller, uno futuro que lo omitiera dejaría una compra con
    -- origen y el remito issued: editable y anulable, y la anulación restaría stock que esa compra da
    -- por recibido. No sube la revisión (no cambia el contenido). El allowed_role de la fila
    -- issued -> converted se evalúa contra el actor.
    IF v_from_dn THEN
        PERFORM public.record_status_transition(
            v_account_id, 'delivery_note_purchase', p_source_delivery_note_id, 'issued', 'converted', v_uid, NULL);
        UPDATE public.delivery_notes
        SET    status = 'converted', updated_at = now(), updated_by = v_uid
        WHERE  id = p_source_delivery_note_id;
    END IF;

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$function$;

REVOKE ALL ON FUNCTION public._purchase_operation_core(uuid,text,date,text,jsonb,uuid,uuid,uuid,uuid,uuid,uuid,date,uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._purchase_operation_core(uuid,text,date,text,jsonb,uuid,uuid,uuid,uuid,uuid,uuid,date,uuid) TO service_role;
COMMENT ON FUNCTION public._purchase_operation_core(uuid,text,date,text,jsonb,uuid,uuid,uuid,uuid,uuid,uuid,date,uuid) IS
$cmt$remitos-compra (D8): núcleo transaccional de la compra, extraído del cuerpo vivo de rpc_create_purchase_operation (361a1ffc…) con p_account_id y p_source_delivery_note_id. INTERNO: sin EXECUTE para anon ni authenticated (lo llaman sólo rpc_create_purchase_operation —origen nulo: la compra directa, idéntica— y rpc_convert_delivery_note_to_purchase). Con origen (modo remito) revalida el remito bajo bloqueo (cuenta, sentido compra, issued, mismo proveedor y sucursal, sin otra compra con ese origen: P0409 delivery_note_purchase_mismatch), exige p_items nulo (P0400 delivery_note_items_from_source), LEE las líneas del propio remito, NO toma el lock del producto ni suma stock ni escribe movimientos, toma los cuatro snapshots de la línea del remito, persiste purchases.source_delivery_note_id y deja el remito converted con su historial en la misma transacción. Caja, banco, cuenta corriente del proveedor, idempotencia, total y PurchaseCreated: como la compra directa.$cmt$;

-- ── _c29_confirm_order_core (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid DEFAULT NULL::uuid, p_comprobante_type text DEFAULT NULL::text, p_point_of_sale_id uuid DEFAULT NULL::uuid, p_canal text DEFAULT NULL::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid              uuid;
  v_account_id       uuid;
  v_order            public.sales_orders%ROWTYPE;
  v_gate_branch      uuid;
  v_branch           RECORD;
  v_item             RECORD;
  v_product          RECORD;
  v_branch_qty       numeric(15,4);
  v_qty_norm         numeric(15,4);
  v_existing_op      uuid;
  v_new_op_id        uuid;
  v_new_sale_id      uuid;
  v_fiscal_doc_id    uuid;
  v_fiscal_result    jsonb;
  v_inserted         integer;
  v_canal            text;
  v_total            numeric(15,2) := 0;
  v_qty_before       numeric;
  v_qty_after        numeric;
  -- pos-catalogo-pagos (D2/D3): resolución de kind y cuenta corriente.
  v_kind                 text;
  v_pm_is_active         boolean;
  -- tenancy-guard-caja-outbox (h1, capa 1): mismos nombres que en
  -- rpc_create_sale_operation_v2, de donde se copia el predicado.
  v_cash_session_status  text;
  v_cash_session_branch  uuid;
  -- remitos-venta (D7): la orden nació de un remito — lo decide la columna
  -- persistida de la orden (sales_orders.source_delivery_note_id), NUNCA un
  -- parámetro: la firma no cambia.
  v_from_delivery_note   boolean := false;
  v_dn                   RECORD;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- Validar idempotency_key
  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  -- Cargar la orden
  SELECT * INTO v_order
  FROM public.sales_orders
  WHERE id = p_sales_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales_order_not_found' USING ERRCODE = 'P0404';
  END IF;

  v_account_id := v_order.account_id;

  -- Guard: permiso de escritura
  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;

  -- Validar estado de la orden
  IF v_order.status <> 'draft' THEN
    RAISE EXCEPTION 'order_not_in_draft: estado %', v_order.status
      USING ERRCODE = 'P0409';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): mismo guard que
  -- rpc_create_sale_operation_v2 (20261045000001) — cubre POS
  -- (rpc_quick_sale), rpc_confirm_sales_order y rpc_accept_quote una vez
  -- confirmado: v_order.client_id se valida contra el tenant ANTES de
  -- cualquier escritura (idempotencia incluida, más abajo). Si viene de
  -- rpc_quick_sale, el INSERT en sales_orders corre en la MISMA
  -- transacción que esta RPC — el rechazo de acá revierte también esa fila.
  IF v_order.client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = v_order.client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', v_order.client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- ╔═══ remitos-venta (D7): orden nacida de un remito ═════════════════════╗
  -- El remito YA descontó el stock al emitirse: esta orden no lo vuelve a
  -- mover (rama del loop de más abajo). Antes de la primera escritura se
  -- revalida TODO, de forma autosuficiente (un guard que delega no es guard):
  -- una orden fabricada con un source_delivery_note_id válido pero con otro
  -- cliente, otra sucursal u otras líneas, o apuntando a un remito ajeno,
  -- anulado o ya convertido, rebota acá en lugar de regalar mercadería.
  -- El FOR UPDATE es un no-op si la conversión ya tiene el remito.
  IF v_order.source_delivery_note_id IS NOT NULL THEN
    SELECT * INTO v_dn
    FROM public.delivery_notes
    WHERE id = v_order.source_delivery_note_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_dn.account_id <> v_account_id
       OR v_dn.direction <> 'sale'
       OR v_dn.status <> 'issued'
       OR v_dn.client_id IS DISTINCT FROM v_order.client_id
       OR v_dn.branch_id <> v_order.branch_id THEN
      RAISE EXCEPTION 'delivery_note_order_mismatch: la orden % no corresponde a un remito de venta pendiente de la misma cuenta, cliente y sucursal', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;

    -- Multiconjunto de líneas (producto, unidad, cantidad) idéntico al del
    -- remito: dos EXCEPT ALL vacíos.
    IF EXISTS (
         SELECT soi.product_id, soi.unit_id, soi.quantity
         FROM public.sales_order_items soi
         WHERE soi.sales_order_id = p_sales_order_id
         EXCEPT ALL
         SELECT dni.product_id, dni.unit_id, dni.quantity
         FROM public.delivery_note_items dni
         WHERE dni.delivery_note_id = v_dn.id
       )
       OR EXISTS (
         SELECT dni.product_id, dni.unit_id, dni.quantity
         FROM public.delivery_note_items dni
         WHERE dni.delivery_note_id = v_dn.id
         EXCEPT ALL
         SELECT soi.product_id, soi.unit_id, soi.quantity
         FROM public.sales_order_items soi
         WHERE soi.sales_order_id = p_sales_order_id
       ) THEN
      RAISE EXCEPTION 'delivery_note_order_mismatch: las líneas de la orden % no son las del remito', p_sales_order_id
        USING ERRCODE = 'P0409';
    END IF;

    v_from_delivery_note := true;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- ─── pos-catalogo-pagos (D2): resolver el kind — el cliente no elige la
  -- taxonomía, la RPC la deriva del catálogo y no le cree al texto que
  -- venga junto. Va con los demás guards de entrada, antes de tocar stock.
  IF p_payment_method_id IS NOT NULL THEN
    SELECT kind, is_active INTO v_kind, v_pm_is_active
    FROM public.payment_methods
    WHERE id = p_payment_method_id
      AND account_id = v_account_id
      AND deleted_at IS NULL;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'payment_method_not_found: % no pertenece a la cuenta o no existe', p_payment_method_id
        USING ERRCODE = 'P0404';
    END IF;

    IF NOT v_pm_is_active THEN
      RAISE EXCEPTION 'payment_method_inactive: % está desactivada', p_payment_method_id
        USING ERRCODE = 'P0400';
    END IF;

    IF p_payment_method IS NOT NULL AND p_payment_method <> v_kind THEN
      RAISE EXCEPTION 'payment_method_mismatch: el texto % no coincide con el kind % de la forma de pago', p_payment_method, v_kind
        USING ERRCODE = 'P0400';
    END IF;
  ELSE
    -- Camino legacy (D2, limpiezas-pagos-admin): sin payment_method_id, el
    -- kind es el texto recibido (o 'other' si viene NULL). A diferencia del
    -- comportamiento anterior (que dejaba el kind viviendo solo en la
    -- columna de texto sales_orders.payment_method, ahora retirada), se
    -- intenta resolver la forma de pago viva y activa de la cuenta con ese
    -- kind (desempate por sort_order, luego id) para imputar
    -- p_payment_method_id. Si no hay ninguna forma de pago sembrada de ese
    -- kind (p.ej. 'check', ver OQ-1), la orden queda sin imputar — no
    -- aborta, es el mismo criterio "sin especificar" que ya contempla la
    -- capability payment-method.
    v_kind := COALESCE(p_payment_method, 'other');

    SELECT id INTO p_payment_method_id
    FROM public.payment_methods
    WHERE account_id = v_account_id
      AND kind = v_kind
      AND is_active = true
      AND deleted_at IS NULL
    ORDER BY sort_order, id
    LIMIT 1;
  END IF;

  -- D6: validación cash sin session → P0400 (ramifica sobre v_kind, no sobre
  -- el texto crudo — D4).
  IF v_kind = 'cash' AND p_cash_session_id IS NULL THEN
    RAISE EXCEPTION 'cash_requires_session: payment_method=cash exige cash_session_id'
      USING ERRCODE = 'P0400';
  END IF;

  -- ╔═══ tenancy-guard-caja-outbox (h1, CAPA 1 — invariante de SUCURSAL) ════╗
  -- El p_cash_session_id llega del payload y hasta acá NADIE lo validaba: sólo
  -- se chequeaba IS NULL (arriba) y se lo pasaba crudo a
  -- c28_register_cash_movement, que no mira account_id. Una sesión de caja de
  -- OTRO TENANT se confirmaba y le dejaba un ingreso fantasma en el arqueo.
  -- El predicado se COPIA de rpc_create_sale_operation_v2 (el formulario, que
  -- ya lo cumplía): sesión abierta Y de la sucursal efectiva de la venta.
  -- Mismo ERRCODE y MISMO mensaje literal: que dos caminos den errores
  -- distintos para la misma condición es deuda, no feature.
  -- PARIDAD PARCIAL, A PROPÓSITO. Sobre el MISMO parámetro el formulario
  -- aplica tres guards, y acá se replica UNO — el de tenencia. Los otros dos
  -- NO se replican: `cash_optin_requires_cash_kind` (rechaza el id de sesión
  -- si el kind no es cash) y `cash_optin_requires_today`. Son higiene de
  -- input, no tenencia: con kind no-cash el id se descarta sin tocar caja
  -- (el consumo vive dentro de `IF v_kind = 'cash'`), y la fecha de la venta
  -- del POS la fija reporting_local_today() en el propio INSERT, así que la
  -- condición se cumple por construcción. Replicarlos agrandaría el BREAKING
  -- de un change CRÍTICO sobre payloads que ninguna superficie del producto
  -- genera, a cambio de cero seguridad. Queda anotado como candidato en
  -- design.md D2. Lo que sí está cubierto y es lo que importa: el guard de
  -- tenencia es AGNÓSTICO DEL KIND — una sesión ajena rebota igual con
  -- `transfer` (assert 2.6 del gate).
  -- Ubicación (D2): junto a las demás validaciones de payload, inmediatamente
  -- después de cash_requires_session y ANTES de la primera escritura (el
  -- INSERT en operation_idempotency, más abajo). Se compara contra
  -- v_order.branch_id porque `v_gate_branch := v_order.branch_id` se asigna
  -- unas líneas más abajo: es el mismo valor, y mover esa asignación habría
  -- introducido una diferencia contra el baseline vivo que no es el guard.
  -- EL GUARD ES AUTOSUFICIENTE — única diferencia deliberada contra el
  -- predicado copiado del formulario, y está acá por una revisión adversarial
  -- (2026-08-24). En el formulario `v_gate_branch` ya viene validada como
  -- perteneciente al tenant antes del bloque; en el core NO: la sucursal de la
  -- orden la elige el atacante en el camino de rpc_quick_sale
  -- (`COALESCE(p_branch_id, c26_default_branch(...))` va al INSERT en
  -- sales_orders sin chequeo de cuenta) y la validación de tenencia de la
  -- sucursal —el `AND account_id = v_account_id` del `branch_not_found`—
  -- ocurre unas líneas MÁS ABAJO. Con sólo `cb.branch_id = v_order.branch_id`,
  -- mandar la sucursal de la víctima junto con su sesión de caja SATISFACE el
  -- guard, y lo único que frena la escritura pasa a ser un chequeo ajeno a
  -- este change que ningún test congela (medido: ese payload rebotaba con
  -- P0404, no con P0422). Por eso el SELECT JOINea `branches` y exige
  -- `b.account_id = v_account_id`: el guard establece por sí solo los DOS
  -- invariantes —caja de la sucursal de la venta Y del tenant que llama— sin
  -- depender de nada de más abajo. Si la sesión no cumple, el SELECT no
  -- devuelve fila, las dos variables quedan NULL y el IS DISTINCT FROM de
  -- abajo dispara el P0422. Candados: asserts (2.7) y (2.8) del gate.
  IF p_cash_session_id IS NOT NULL THEN
    SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
    FROM public.cash_sessions cs
    JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
    JOIN public.branches   b  ON b.id  = cb.branch_id
    WHERE cs.id = p_cash_session_id
      AND b.account_id = v_account_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_order.branch_id THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la venta'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;
  -- ╚════════════════════════════════════════════════════════════════════════╝

  -- pos-catalogo-pagos (D3): restaurar el guard credit_requires_client del
  -- bloque C-30 (20260720000001), ANTES de tocar stock — junto con los
  -- demás guards de entrada.
  IF v_kind = 'credit' AND v_order.client_id IS NULL THEN
    RAISE EXCEPTION 'credit_requires_client: una venta a crédito exige client_id en la orden'
      USING ERRCODE = 'P0400';
  END IF;

  -- Validar payment_method (D4: vocabulario completo del catálogo, los 7 kind)
  IF v_kind NOT IN ('cash', 'transfer', 'card', 'check', 'wallet', 'credit', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method: %', v_kind
      USING ERRCODE = 'P0400';
  END IF;

  -- Resolver branch del gate (ya está en la orden; usamos la branch de la orden)
  v_gate_branch := v_order.branch_id;

  -- Validar que la branch esté activa
  SELECT id, status INTO v_branch
  FROM public.branches
  WHERE id = v_gate_branch AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RAISE EXCEPTION 'branch_closed: la sucursal está cerrada' USING ERRCODE = 'P0422';
  END IF;

  -- Canal normalizado
  v_canal := NULLIF(trim(COALESCE(p_canal, '')), '');

  -- ─── Idempotencia (DEC-06) ───────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'sale', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver la operación original sin re-ejecutar
    -- (v3-document-status-history: el return temprano garantiza que el replay
    -- NO inserta historial duplicado). La forma de pago del replay se ignora
    -- (pos-catalogo-pagos: mismo criterio, ahora también para payment_method_id).
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'sale'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_existing_op,
      'replayed',        true
    );
  END IF;

  -- ─── Calcular total y descontar stock por línea ──────────────────────────
  FOR v_item IN
    SELECT * FROM public.sales_order_items
    WHERE sales_order_id = p_sales_order_id
    ORDER BY id
  LOOP
    v_total := v_total + v_item.subtotal;

    IF v_item.product_id IS NOT NULL THEN
      -- remitos-venta (D7): con origen de remito se saltean el FOR UPDATE del
      -- producto, la normalización, el gate, el delta y el movimiento — no hay
      -- stock que proteger (el remito ya lo descontó) y un FOR UPDATE sólo
      -- sumaría superficie de interbloqueo contra otros remitos (los locks de
      -- FK de las líneas ya los tomó rpc_convert_delivery_note_to_sale, por id,
      -- antes de insertarlas: acá se vuelven a tomar sin esperar). La existencia del
      -- producto la garantiza la FK de delivery_note_items. Se conservan la
      -- fila legacy sales y sale_items, que toma los CUATRO snapshots de la
      -- línea de la orden (copiados del remito, sin re-leer el maestro:
      -- nombre y SKU del remito aunque el producto se haya renombrado, costo
      -- congelado al salir la mercadería — OQ-RV3/OQ-RV4).
      IF v_from_delivery_note THEN
        INSERT INTO public.sales
          (user_id, account_id, client_id, product_id, amount, quantity,
           unit_id, total, currency, date, operation_id, branch_id, canal,
           payment_method_id)
        VALUES
          (v_uid, v_account_id, v_order.client_id, v_item.product_id,
           v_item.price, v_item.quantity,
           v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
           v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
        RETURNING id INTO v_new_sale_id;

        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
          v_item.name_snapshot, v_item.sku_snapshot, v_item.unit_cost_snapshot, v_item.iva_rate_snapshot
        );

        CONTINUE;
      END IF;

      -- v3-snapshot-pattern: se agrega sku, cost al lock existente.
      SELECT id, user_id, name, sku, cost INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'product_not_found: %', v_item.product_id
          USING ERRCODE = 'P0404';
      END IF;

      -- ventas-unidades-conversion (D1/D2): el POS descontaba la cantidad
      -- CRUDA de la línea; ahora normaliza por la misma definición única que
      -- el formulario (unidad base del producto). sales_order_items.unit_id
      -- viaja con la línea desde rpc_quick_sale / rpc_confirm_sales_order.
      v_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- Gate per-branch
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM public.branch_stock
      WHERE product_id = v_item.product_id AND branch_id = v_gate_branch;

      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_qty_norm THEN
        RAISE EXCEPTION 'stock_insuficiente para producto %: disponible %, solicitado %',
          v_item.product_id, v_branch_qty, v_qty_norm
          USING ERRCODE = 'P0409';
      END IF;

      v_qty_before := v_branch_qty;
      v_qty_after  := v_branch_qty - v_qty_norm;

      -- Descontar stock (C-21 helper)
      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, v_gate_branch, -v_qty_norm
      );

      -- Insertar fila legacy sales (retrocompat D4). app-timezone-argentina
      -- (task 5): día argentino, no CURRENT_DATE (UTC del servidor).
      -- pos-catalogo-pagos: cada fila legacy nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, v_item.product_id,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- v3-snapshot-pattern: congelar name/sku/cost desde v_product (2.4).
      -- iva_rate_snapshot NULL (D3).
      INSERT INTO public.sale_items (
        sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
        name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
      ) VALUES (
        v_new_sale_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal,
        v_product.name, v_product.sku, v_product.cost, NULL
      );

      -- stock_movements (reference_type='sale') — v3-snapshot-pattern: costo congelado.
      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id, branch_id, unit_cost_snapshot
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'sale',
        -v_qty_norm, v_qty_before, v_qty_after,
        v_new_sale_id, 'sale', v_uid,
        v_new_op_id, v_gate_branch, v_product.cost
      );
    ELSE
      -- Línea de servicio sin producto — solo fila legacy (2.6: sin snapshot,
      -- name_snapshot ya vive en sales_order_items.name_snapshot desde su
      -- propia creación en quick_sale/confirm_sales_order — no aplica acá).
      -- app-timezone-argentina (task 5): día argentino, no CURRENT_DATE.
      -- pos-catalogo-pagos: también nace con payment_method_id (D2).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity,
         unit_id, total, currency, date, operation_id, branch_id, canal,
         payment_method_id)
      VALUES
        (v_uid, v_account_id, v_order.client_id, NULL,
         v_item.price, v_item.quantity,
         v_item.unit_id, v_item.subtotal, 'ARS', public.reporting_local_today(),
         v_new_op_id, v_gate_branch, v_canal, p_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;
  END LOOP;

  -- ─── Caja (C-28 helper intra-transacción) ───────────────────────────────
  -- pos-catalogo-pagos (D4): ramifica sobre v_kind, no sobre el texto crudo.
  IF v_kind = 'cash' THEN
    PERFORM public.c28_register_cash_movement(
      p_cash_session_id,
      v_total,
      'sale',
      p_sales_order_id
    );
  END IF;

  -- ─── pagos-cableados-restantes (D2): cuenta corriente del cliente — el
  -- bloque inline restaurado por pos-catalogo-pagos (D3) se REEMPLAZA por
  -- la llamada al helper compartido _pay_register_party_charge (D1), la
  -- misma definición que usa el formulario de venta (rpc_create_sale_
  -- operation_v2). client_id ya validado arriba (credit_requires_client
  -- antes del descuento de stock). El helper posta el cargo C-30 y emite
  -- CustomerAccountCharged en la misma operación atómica — nada de esto
  -- se relaja, sólo deja de estar duplicado.
  IF v_kind = 'credit' THEN
    PERFORM public._pay_register_party_charge(
      v_account_id, 'customer', v_order.client_id, v_total, p_sales_order_id, v_new_op_id
    );
  END IF;

  -- ─── pos-banco-movimientos (D5): movimiento bancario operativo — después
  -- de caja/cuenta corriente, ANTES del bloque fiscal (task 4.1). NULL si no
  -- corresponde escribir (kind no bancario, o bancario sin cuenta resuelta —
  -- D2). value_date = día ART (D4, el POS nunca dispara P0424: opera siempre
  -- sobre hoy).
  PERFORM public._pay_register_operation_bank_movement(
    v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
    v_total, 'in', 'sale', p_sales_order_id,
    public.reporting_local_today(), v_gate_branch, NULL
  );

  -- ─── Numeración fiscal (C-27, opcional) ─────────────────────────────────
  -- GATE OQ-G: bloque fiscal copiado SIN TOCAR NI UNA LÍNEA desde la
  -- definición viva capturada 2026-08-19. No modificar sin sign-off del PO.
  IF p_comprobante_type IS NOT NULL THEN
    SELECT public.rpc_emit_pending_cae(
      p_comprobante_type,
      v_total,
      v_order.client_id,
      p_point_of_sale_id
    ) INTO v_fiscal_result;

    v_fiscal_doc_id := (v_fiscal_result->>'fiscal_document_id')::uuid;
  END IF;

  -- ─── INSERT outbox (DEC-20 — SaleConfirmed) ─────────────────────────────
  -- pos-catalogo-pagos: el payload lleva el kind EFECTIVO (v_kind), no el
  -- texto crudo del cliente — coherente con lo que persiste sales_orders.
  -- limpiezas-pagos-admin (D1 de design.md): esta clave NO cambia — el
  -- consumidor (_journal_post_from_event) lee el PAYLOAD, nunca la columna.
  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'SaleConfirmed',
    'SalesOrder',
    p_sales_order_id,
    jsonb_build_object(
      'account_id',      v_account_id,
      'branch_id',       v_gate_branch,
      'sales_order_id',  p_sales_order_id,
      'operation_id',    v_new_op_id,
      'total',           v_total,
      'payment_method',  v_kind,
      'client_id',       v_order.client_id,
      'occurred_at',     now()
    ),
    now()
  );

  -- v3-document-status-history (RN-A1): transición draft→confirmed en la
  -- misma transacción atómica (junto con stock, caja, fiscal y outbox)
  PERFORM public.record_status_transition(
    v_account_id, 'sales_order', p_sales_order_id, 'draft', 'confirmed', v_uid, NULL);

  -- ─── Transicionar la orden a confirmed ───────────────────────────────────
  -- limpiezas-pagos-admin (G1b): la columna de texto payment_method fue
  -- retirada — la orden persiste únicamente payment_method_id (resuelto
  -- arriba, explícito o vía la resolución legacy D2). El kind efectivo
  -- (v_kind) sigue viajando en el payload del evento SaleConfirmed.
  UPDATE public.sales_orders
  SET
    status              = 'confirmed',
    payment_method_id   = p_payment_method_id,
    total               = v_total,
    sale_operation_id   = v_new_op_id,
    fiscal_document_id  = v_fiscal_doc_id
  WHERE id = p_sales_order_id;

  -- remitos-venta (D7, revisión adversarial 8.5 RB-02): el remito de origen
  -- queda `converted` EN EL NÚCLEO, en la misma transacción que la confirmación,
  -- y no en la RPC de conversión. Una orden idéntica al remito confirmada por
  -- cualquier camino (rpc_confirm_sales_order, llamada directa al núcleo) dejaría
  -- si no el remito `issued` con la venta viva: anulable (reponiendo stock) y,
  -- al borrar la venta, repuesto dos veces. No sube la revisión (no cambia el
  -- contenido). Un replay no llega acá: devolvió antes de confirmar.
  IF v_from_delivery_note THEN
    PERFORM public.record_status_transition(
      v_account_id, 'delivery_note_sale', v_dn.id, 'issued', 'converted', v_uid, NULL);
    UPDATE public.delivery_notes
    SET status = 'converted', updated_at = now(), updated_by = v_uid
    WHERE id = v_dn.id;
  END IF;

  RETURN jsonb_build_object(
    'sales_order_id',  p_sales_order_id,
    'operation_id',    v_new_op_id,
    'total',           v_total,
    'fiscal_doc_id',   v_fiscal_doc_id,
    'replayed',        false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid) TO authenticated, service_role;
COMMENT ON FUNCTION public._c29_confirm_order_core(text,uuid,text,uuid,text,uuid,text,uuid,uuid) IS
$cmt$C-29 (sales-order): core transaccional de la confirmación de una SalesOrder — lo comparten los dos wrappers públicos del POS, rpc_quick_sale y rpc_confirm_sales_order. tenancy-guard-caja-outbox (h1, capa 1): valida la TENENCIA del p_cash_session_id con el mismo predicado de sesión abierta + sucursal efectiva que el formulario de venta (rpc_create_sale_operation_v2) — no con sus otros dos guards sobre ese parámetro (cash_optin_requires_cash_kind y cash_optin_requires_today), que son higiene de input y no se replican a propósito — y falla con P0422 cash_optin_requires_open_session. Antes sólo chequeaba IS NULL y pasaba el id crudo a c28_register_cash_movement, así que una sesión de caja de OTRO TENANT (o de otra sucursal del mismo tenant) se confirmaba y dejaba un ingreso fantasma en el arqueo de la víctima. El guard va entre cash_requires_session y la primera escritura (D2); los dos wrappers lo HEREDAN y por eso no se tocan. Backstop de tenant en c28_register_cash_movement (P0401). Candado: supabase/tests/test_tenancy_guard_caja_outbox.sql.$cmt$;

-- ── rpc_atomic_update_sale_operation (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(p_sale_ids uuid[], p_client_id uuid, p_date date, p_currency text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_canal text DEFAULT NULL::text, p_canal_provided boolean DEFAULT false, p_cash_session_id uuid DEFAULT NULL::uuid, p_cash_provided boolean DEFAULT false, p_bank_account_id uuid DEFAULT NULL::uuid, p_bank_account_provided boolean DEFAULT false, p_due_date date DEFAULT NULL::date, p_due_date_provided boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_dry_run boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid            uuid;
  v_author         uuid;   -- multiusuario-operativo (tanda B): autor de la operación que se edita
  v_account_id     uuid;
  v_old_sale       RECORD;
  v_item           RECORD;
  v_product        RECORD;
  v_new_op_id      uuid;
  v_new_sale_id    uuid;
  v_stock_sum      numeric(15,4);
  v_branch_qty     numeric(15,4);   -- stock-edicion-sucursal-piso (D1): saldo de la sucursal donde se aplica
  v_rev_branch     uuid;            -- stock-edicion-sucursal-piso (D4): sucursal donde se devuelve la pata REVERSE
  v_rev_meta       jsonb;
  v_result_items   jsonb := '[]'::jsonb;
  v_flag_on        boolean;
  v_old_snapshots  jsonb;
  v_prev_snap      jsonb;
  v_line_snap      jsonb;
  v_old_product_name text;
  v_reverse_unit_cost numeric;
  v_reverse_delta     numeric;         -- ventas-unidades-conversion (D6)
  v_apply_qty_norm    numeric(15,4);   -- ventas-unidades-conversion (D1)
  v_old_payment_method_id   uuid;  -- metodos-pago-operaciones (D5)
  v_final_payment_method_id uuid;  -- metodos-pago-operaciones (D5)
  -- edicion-preserva-contexto (F1):
  v_old_operation_id uuid;         -- §D9: para re-apuntar sales_orders
  v_old_branch_id    uuid;         -- §D1/§D3
  v_old_canal        text;         -- §D1/§D3
  v_final_branch_id  uuid;         -- §D3/§D8: sucursal EFECTIVA (reimputada o vieja)
  v_final_canal      text;         -- §D3
  v_canal_clean      text;
  v_branch           RECORD;
  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable de la operación editada en vez de bloquear la edición.
  v_total_sum          numeric := 0;   -- cuarta revisión: sin escala, round(Σ, 2) al cerrar el loop
  v_kind_final          text;
  v_pending_event_id    uuid;
  v_pending_event_type  text;
  v_pending_payload     jsonb;
  v_has_posted_entry    boolean := false;
  -- venta-editable-sin-cae: la anulación del comprobante pendiente NO enviado.
  v_void_rec            RECORD;   -- (sales_order_id, operation_id) a anular
  v_voided_doc          jsonb;    -- descriptor del último comprobante anulado
  -- venta-editable-vs-promocion-legacy (20261061000001):
  v_locked              integer;  -- filas de la operación tomadas con FOR UPDATE
  v_resync_id           uuid;     -- orden re-apuntada que se recalcula (N3)
  v_dn_label            text;     -- remitos-venta (D9): remito de origen de la venta
  -- edicion-operaciones-con-dinero (tanda B): plan de dinero, huella y rastro
  v_old_date       date;
  v_old_client     uuid;
  v_pre_total      numeric;   -- total calculado del payload ANTES de escribir (D12 paso 4)
  v_order_id       uuid;      -- sales_orders.id de la operacion (POS o presupuestada)
  v_refs           uuid[];    -- referencias de la huella: operation_id + orden, o ids de fila (legacy)
  v_plan           jsonb;
  v_dry_fiscal     text;      -- bloqueo fiscal visto en la vista previa (nada se anula en seco)
  v_before         jsonb;
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

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'seller', 'cashier'], 'tu rol no permite editar ventas (requiere vendedor, cajero, administrador o dueño)');

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P0400';
  END IF;

  -- multiusuario-operativo (tanda B, D8): el documento tiene que ser de la CUENTA ACTIVA, no del caller. Una venta de
  -- otra cuenta es indistinguible de una inexistente (P0404, mismo texto): no se revela que existe en otra cuenta.
  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids) AND account_id = v_account_id)
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- multiusuario-operativo (tanda B, D9, OQ-4 b): sobre una venta de OTRO miembro sólo puede el dueño o un administrador;
  -- el resto corrige lo propio (P0403). La autoría se CONSERVA en las filas nuevas (v_author): la edición reemplaza las
  -- líneas, pero quien la cargó sigue siendo su autor.
  PERFORM public._account_assert_document_authority(
    v_account_id,
    (SELECT array_agg(DISTINCT s.user_id) FROM public.sales s WHERE s.id = ANY(p_sale_ids)),
    'solo el dueño o un administrador modifican las ventas que cargó otro miembro');
  SELECT s.user_id INTO v_author FROM public.sales s WHERE s.id = ANY(p_sale_ids) ORDER BY s.id LIMIT 1;

  -- venta-editable-vs-promocion-legacy (N1): EXCLUSIÓN contra la promoción.
  -- Las filas de sales de la operación son lo único que existe ANTES que la
  -- orden, así que son el ancla común: la promoción, la edición y el borrado
  -- las toman PRIMERO, con FOR UPDATE y en orden ascendente de id. Orden
  -- global de locks: sales → sales_orders → fiscal_documents → resto.
  -- Sin este lock, el enumerador de órdenes de más abajo leía SIN lock, no
  -- veía la orden que una promoción concurrente estaba creando, y la venta
  -- quedaba editada con un comprobante pendiente VIVO por importes viejos.
  -- Recuento bajo el lock: si otra edición o un borrado ganó y se llevó
  -- alguna fila mientras se esperaba, se aborta acá, antes de revertir stock
  -- o de tocar cualquier libro (doble "Guardar" incluido).
  SELECT count(*) INTO v_locked
  FROM (
    SELECT s.id
    FROM   public.sales s
    WHERE  s.id = ANY(p_sale_ids)
      AND  s.account_id = v_account_id
    ORDER  BY s.id
    FOR UPDATE
  ) l;

  IF v_locked <> array_length(p_sale_ids, 1) THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P0404';
  END IF;

  -- operacion-party-guard (fix ad-hoc 2026-09-10, cierra OQ-4 de
  -- cuenta-corriente-party-guard): la edición también puede reasignar el
  -- client_id de la operación (p_client_id es obligatorio, sin contrato
  -- tri-estado _provided — el llamador siempre lo reenvía) y hoy lo
  -- escribe sin validar tenencia, igual que rpc_create_sale_operation_v2
  -- antes de este fix. Mismo predicado, mismo ERRCODE, ANTES de cualquier
  -- guard de inmutabilidad/reversa.
  IF p_client_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM public.clients
      WHERE id = p_client_id AND account_id = v_account_id
    ) THEN
      RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
    END IF;
  END IF;

  -- remitos-venta (D9): una venta nacida de un remito NO se edita. El editor
  -- siempre reemplaza líneas (REVERSE + APPLY) y la REVERSE, sin movimiento
  -- propio de esas filas sales, cae a la normalización de la línea y
  -- REPONDRÍA stock que el remito sigue reteniendo (la APPLY lo descontaría
  -- de nuevo; una reducción dejaría reposición de más que la anulación del
  -- remito duplicaría). Va ANTES del bloque fiscal para no anular un
  -- comprobante pendiente por una edición que igual se rechaza, y bloquea la
  -- operación entera (también la cabecera).
  SELECT COALESCE('R-' || lpad(dn.number::text, 8, '0'), 'de origen') INTO v_dn_label
  FROM   public.sales s
  JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
  JOIN   public.delivery_notes dn ON dn.id = so.source_delivery_note_id
  WHERE  s.id = ANY(p_sale_ids)
  LIMIT  1;

  IF FOUND THEN
    RAISE EXCEPTION 'delivery_note_sale_locked: la venta nació del remito %: para corregirla, eliminá la venta, editá el remito y volvé a convertirlo', v_dn_label
      USING ERRCODE = 'P0423';
  END IF;

  -- edicion-preserva-contexto (F2, design §D5) + venta-editable-sin-cae (D2):
  -- guard fiscal — SHALL correr antes de cualquier reversa/eliminación/
  -- reaplicación, de modo que una operación bloqueada quede intacta si el
  -- guard dispara. Resuelto por JOIN (sales.operation_id →
  -- sales_orders.sale_operation_id → sales_orders.fiscal_document_id →
  -- fiscal_documents), nunca por una columna denormalizada de "facturado"
  -- (segunda fuente de verdad).
  --
  -- venta-editable-sin-cae: el predicado deja de ser "¿HAY comprobante?" y
  -- pasa a ser "¿el comprobante YA SALIÓ hacia ARCA?". Un pending_cae SIN
  -- marca de envío ya no bloquea: se ANULA (voided) en ESTA MISMA
  -- transacción, para que el relay no lo facture después con los importes
  -- viejos. authorized, marcado y congelado siguen bloqueando con P0423
  -- (tres tokens distintos — ver _fiscal_void_pending_for_sale_edit, que es
  -- la ÚNICA definición de esta regla y la comparte con el borrado).
  -- rejected y voided no bloquean ni se tocan.
  -- asiento-venta-formulario: el guard fiscal sigue siendo el PRIMERO.
  --
  -- Esta query NO filtra por `so.fiscal_document_id IS NOT NULL` (red team
  -- 2026-09-22, M1): ese filtro se evalúa SIN lock, así que con una emisión
  -- abierta en otra conexión devolvía cero filas, el helper no se llamaba
  -- NUNCA, y la venta se editaba dejando vivo el comprobante que la emisión
  -- estaba por commitear. Quién decide "hay comprobante" es el helper, con la
  -- fila de la orden BLOQUEADA. Acá sólo se enumeran las órdenes de la
  -- operación (a lo sumo una: sale_operation_id tiene índice único parcial).
  FOR v_void_rec IN
    SELECT DISTINCT so.id AS sales_order_id, s.operation_id AS operation_id
    FROM   public.sales s
    JOIN   public.sales_orders so ON so.sale_operation_id = s.operation_id
    WHERE  s.id = ANY(p_sale_ids)
  LOOP
    IF p_dry_run THEN
      -- Vista previa: la anulacion del comprobante pendiente es una ESCRITURA. Se corre en un sub-bloque que se deshace
      -- siempre (P0999); el descriptor queda en la variable y un bloqueo fiscal (P0423) viaja como dato del plan.
      BEGIN
        v_voided_doc := public._fiscal_void_pending_for_sale_edit(
          v_void_rec.sales_order_id, v_account_id, v_uid,
          format('Anulado por edición de la venta (operación %s)', v_void_rec.operation_id)
        );
        RAISE EXCEPTION 'dry_run_rollback' USING ERRCODE = 'P0999';
      EXCEPTION
        WHEN SQLSTATE 'P0423' THEN
          GET STACKED DIAGNOSTICS v_dry_fiscal = MESSAGE_TEXT;
        WHEN SQLSTATE 'P0999' THEN
          NULL;
      END;
    ELSE
      v_voided_doc := public._fiscal_void_pending_for_sale_edit(
        v_void_rec.sales_order_id, v_account_id, v_uid,
        format('Anulado por edición de la venta (operación %s)', v_void_rec.operation_id)
      );
    END IF;
  END LOOP;

  -- edicion-operaciones-con-dinero (tanda B, D1): se RETIRAN los tres P0423 de dinero (cuenta corriente, caja y banco) que
  -- bloqueaban la operacion entera. Ahora la edicion calcula la huella neta y el efecto deseado de cada libro y escribe solo
  -- donde difieren (plan de abajo). Siguen en pie los bloqueos que NO son de dinero: remito y comprobante fiscal.

  -- edicion-operaciones-lineas (D3): mismo flag_key y mismo patrón
  -- COALESCE-después-del-SELECT que rpc_create_sale_operation — ausencia de
  -- fila = v2 (escribe línea).
  SELECT enabled INTO v_flag_on
  FROM   public.account_feature_flags
  WHERE  account_id = v_account_id
    AND  flag_key   = 'sale_items_rpc_v2'
  LIMIT  1;
  v_flag_on := COALESCE(v_flag_on, true);

  -- edicion-operaciones-lineas (D2): acarreo de snapshot keyed por
  -- product_id, capturado ANTES del DELETE — el CASCADE se lleva puesto
  -- sale_items en STEP 2. DISTINCT ON (product_id) ORDER BY product_id, id:
  -- determinístico ante colisión (dos filas viejas de header con el mismo
  -- producto — la forma legacy 1-operación:N-filas, 23 ventas en prod).
  SELECT COALESCE(jsonb_object_agg(t.product_id::text, t.snap), '{}'::jsonb)
  INTO   v_old_snapshots
  FROM (
    SELECT DISTINCT ON (si.product_id)
           si.product_id,
           jsonb_build_object(
             'name_snapshot',       si.name_snapshot,
             'sku_snapshot',        si.sku_snapshot,
             'unit_cost_snapshot',  si.unit_cost_snapshot,
             'iva_rate_snapshot',   si.iva_rate_snapshot,
             'snapshot_backfilled', si.snapshot_backfilled
           ) AS snap
    FROM   public.sale_items si
    WHERE  si.sale_id = ANY(p_sale_ids)
      AND  si.product_id IS NOT NULL
    ORDER BY si.product_id, si.id
  ) t;

  -- metodos-pago-operaciones (D5): capturar el payment_method_id vigente de
  -- la operación ANTES del DELETE — mismo momento que v_old_snapshots. Por
  -- operación (D3): cualquier fila alcanza (todas comparten el valor).
  SELECT payment_method_id INTO v_old_payment_method_id
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
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

  -- edicion-preserva-contexto (F1, design §D1): capturar el contexto vigente
  -- del header ANTES del DELETE, junto al resto de lo que se acarrea.
  -- LIMIT 1 es correcto: branch_id/canal/operation_id son de la operación,
  -- no de la línea — todas las filas del mismo operation_id los comparten
  -- (misma justificación que payment_method_id, D3 de #419).
  SELECT operation_id, branch_id, canal
  INTO   v_old_operation_id, v_old_branch_id, v_old_canal
  FROM   public.sales
  WHERE  id = ANY(p_sale_ids)
  LIMIT  1;

  -- asiento-venta-formulario (D7, override del PO): resolver el rastro
  -- contable de v_old_operation_id ANTES del REVERSE/DELETE — no se
  -- rechaza la edición, se ajusta el rastro más abajo. Caso B: se toma el
  -- lock ACÁ, sobre el evento pendiente (SaleOperationCreated apuntando a
  -- esta operación, o SaleOperationAdjusted cuyo new_operation_id es esta
  -- operación), para no competir con el dispatcher a mitad de camino. Bajo
  -- READ COMMITTED, SELECT ... FOR UPDATE re-evalúa el WHERE contra la
  -- versión más reciente de la fila al tomar el lock: si el dispatcher ya
  -- la marcó processed_at mientras se esperaba el lock, Postgres la excluye
  -- automáticamente del resultado — no hace falta un re-chequeo manual.
  IF v_old_operation_id IS NOT NULL THEN
    -- edicion-operaciones-con-dinero (D10): la orden del POS o presupuestada de la operacion (a lo sumo una: indice unico parcial).
    SELECT so.id INTO v_order_id
    FROM   public.sales_orders so
    WHERE  so.sale_operation_id = v_old_operation_id AND so.account_id = v_account_id;

    SELECT id, event_type, payload
    INTO   v_pending_event_id, v_pending_event_type, v_pending_payload
    FROM   public.events
    WHERE  processed_at IS NULL
      AND  (
             (event_type = 'SaleOperationCreated' AND aggregate_id = v_old_operation_id)
          OR (event_type = 'SaleOperationAdjusted' AND (payload->>'new_operation_id')::uuid = v_old_operation_id)
           )
    ORDER BY occurred_at
    LIMIT 1
    FOR UPDATE;

    -- Caso C: sin evento pendiente reemplazable — ¿hay un asiento ya posteado?
    IF v_pending_event_id IS NULL THEN
      -- edicion-operaciones-con-dinero (D10): ademas del asiento SaleOperation (formulario), una venta del POS o presupuestada
      -- tiene su asiento como SalesOrder, o su SaleConfirmed todavia sin procesar (el ajuste reintenta P0451 hasta que se postee).
      SELECT EXISTS (
        SELECT 1 FROM public.journal_entries
        WHERE source_doc_type = 'SaleOperation'
          AND source_doc_ref  = v_old_operation_id
          AND status = 'posted'
      ) OR (v_order_id IS NOT NULL AND (
        EXISTS (
          SELECT 1 FROM public.journal_entries
          WHERE source_doc_type = 'SalesOrder'
            AND source_doc_ref  = v_order_id
            AND status = 'posted'
        ) OR EXISTS (
          SELECT 1 FROM public.events
          WHERE event_type = 'SaleConfirmed'
            AND aggregate_id = v_order_id
            AND account_id = v_account_id
        )
      )) INTO v_has_posted_entry;
    END IF;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para branch_id —
  -- espejo exacto del contrato de payment_method_id. provided=false →
  -- preservar; provided=true + NULL → desimputar; provided=true + valor →
  -- reimputar, previa validación de pertenencia a la cuenta y sucursal
  -- operativa (mismo guard que rpc_create_sale_operation_v2, C-26). La
  -- validación corre ACÁ, antes del REVERSE (gate 2.9: una reimputación
  -- inválida no debe revertir ni reaplicar stock).
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
    -- stock-edicion-sucursal-piso (D4): una sucursal vigente que fue DESACTIVADA no se
    -- preserva — no se lista ni se vende, y el stock que se devolviera o descontara ahí
    -- quedaría invisible. Se trata como una fila sin sucursal: cae en la principal
    -- operativa por el bloque de abajo (el mismo respaldo que ya tiene el borrado, D6
    -- de stock-movimientos-sucursal-origen). Una sucursal cerrada y activa no entra
    -- acá: se preserva como hasta hoy.
    IF v_final_branch_id IS NOT NULL AND EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id AND is_active = FALSE
    ) THEN
      v_final_branch_id := NULL;
    END IF;
  END IF;

  -- ventas-sucursal-por-defecto (D5, OQ-7): para la VENTA, NULL significa "la
  -- principal". Ni la intención de desimputar (p_branch_provided con NULL) ni una
  -- fila vigente sin sucursal (residuo histórico) se preservan: se resuelve a la
  -- principal operativa ANTES del REVERSE, igual que la validación de arriba (gate
  -- 2.9 de edicion-preserva-contexto: una edición inválida no revierte ni
  -- reaplica stock). Una sucursal vigente no nula se preserva sin revalidar, como
  -- hoy; una explícita inválida sigue dando P0422 branch_invalid. El REVERSE de
  -- una fila NULL ya caía en la principal vigente (op_stock_movement) y el APPLY
  -- descuenta de esa misma sucursal: el neto es cero. Compra y gasto conservan
  -- las tres intenciones del contrato tri-estado.
  IF v_final_branch_id IS NULL THEN
    v_final_branch_id := public.c26_default_branch(v_account_id);
    IF v_final_branch_id IS NULL OR NOT EXISTS (
      SELECT 1 FROM public.branches
      WHERE id = v_final_branch_id AND account_id = v_account_id
        AND is_active = TRUE AND status = 'active'
    ) THEN
      RAISE EXCEPTION 'no_branch_found: la cuenta no tiene una sucursal operativa a la cual asignar la venta'
        USING ERRCODE = 'P0422';
    END IF;
  END IF;

  -- edicion-preserva-contexto (F1, design §D3): tri-estado para canal —
  -- mismo contrato. Sin conjunto cerrado en el schema (sales.canal es texto
  -- libre, sin CHECK) — se valida longitud igual que rpc_create_sale_operation_v2.
  IF p_canal_provided THEN
    v_canal_clean := NULLIF(trim(COALESCE(p_canal, '')), '');
    IF v_canal_clean IS NOT NULL AND length(v_canal_clean) > 40 THEN
      RAISE EXCEPTION 'canal too long (max 40 chars)' USING ERRCODE = 'P0400';
    END IF;
    v_final_canal := v_canal_clean;
  ELSE
    v_final_canal := v_old_canal;
  END IF;

  -- ── edicion-operaciones-con-dinero (tanda B, D12 pasos 4-6): el PLAN de dinero ───────────────────────────────────────
  -- Total calculado del payload (el mismo redondeo unico al centavo del alta), huella y efecto deseado por libro, y los
  -- bloqueos de negocio como DATOS. En seco se devuelve el plan sin escribir; en firme se levanta el primer bloqueo y se
  -- toman los locks de lo que el plan va a escribir, en orden fijo, ANTES de tocar stock. El operation_id es ESTABLE (D2):
  -- una operacion legacy sin id recibe uno nuevo y su huella se busca por el id de fila.
  SELECT COALESCE(round(SUM(x.amount * x.quantity), 2), 0) INTO v_pre_total
  FROM   jsonb_to_recordset(p_items) AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid);

  IF v_final_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind_final FROM public.payment_methods WHERE id = v_final_payment_method_id;
  ELSE
    v_kind_final := NULL;
  END IF;

  SELECT s.date::date, s.client_id INTO v_old_date, v_old_client
  FROM   public.sales s WHERE s.id = ANY(p_sale_ids) ORDER BY s.id LIMIT 1;

  v_refs := CASE WHEN v_old_operation_id IS NULL THEN p_sale_ids
                 ELSE array_remove(ARRAY[v_old_operation_id, v_order_id], NULL) END;
  v_new_op_id := COALESCE(v_old_operation_id, gen_random_uuid());

  v_plan := public._op_edit_plan(
    v_account_id, 'sale', v_refs, v_new_op_id, v_pre_total, v_old_date, p_date,
    v_old_payment_method_id, v_final_payment_method_id, v_kind_final,
    v_old_client, p_client_id, v_final_branch_id,
    p_cash_provided, p_cash_session_id, p_bank_account_provided, p_bank_account_id,
    p_due_date_provided, p_due_date);

  IF v_dry_fiscal IS NOT NULL THEN
    v_plan := jsonb_set(v_plan, '{blocks}',
      jsonb_build_array(public._op_edit_block('fiscal', 'P0423', split_part(v_dry_fiscal, ':', 1), v_dry_fiscal)) || (v_plan->'blocks'));
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('dry_run', true, 'plan', v_plan, 'voided_fiscal_document', v_voided_doc);
  END IF;

  PERFORM public._op_edit_raise_blocks(v_plan);
  PERFORM public._op_edit_lock(v_plan);

  -- Estado ANTERIOR para el rastro (D14), antes de borrar las filas.
  SELECT jsonb_build_object(
           'total',             round(COALESCE(SUM(COALESCE(s.total, s.amount * s.quantity)), 0), 2),
           'payment_method_id', v_old_payment_method_id,
           'client_id',         v_old_client,
           'date',              v_old_date,
           'branch_id',         v_old_branch_id,
           'lines',             COALESCE(jsonb_agg(jsonb_build_object('product_id', s.product_id, 'quantity', s.quantity,
                                                                      'amount', s.amount) ORDER BY s.id), '[]'::jsonb))
  INTO   v_before
  FROM   public.sales s WHERE s.id = ANY(p_sale_ids);

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- stock-movements-edicion: id/operation_id agregados al SELECT — id vieja
  -- es el reference_id de la pata REVERSE, operation_id agrupa el movimiento
  -- bajo la operación a la que pertenecía la fila que se está reemplazando.
  -- La pata REVERSE sigue devolviendo a la sucursal VIEJA de cada fila
  -- (v_old_sale.branch_id) — no cambia con F1 (§D8: REVERSE = sucursal vieja).
  FOR v_old_sale IN
    SELECT id, product_id, quantity, unit_id, branch_id, operation_id
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      -- Nombre actual del producto para el movimiento (congelar el nombre no
      -- es el contrato de este movimiento — el name_snapshot vive en la
      -- línea, no acá — se usa el mismo patrón que la creación: products.name
      -- vigente al momento de la operación).
      SELECT name INTO v_old_product_name FROM public.products WHERE id = v_old_sale.product_id;

      -- design §D5 (stock-movements-edicion): la pata REVERSE copia el
      -- unit_cost_snapshot del movimiento ORIGINAL si existe; si no, NULL.
      -- ventas-unidades-conversion (D6): la pata REVERSE devuelve EXACTAMENTE
      -- lo que el movimiento original descontó (quantity_delta, ya en unidad
      -- base del producto), nunca la cantidad cruda de la línea. Sin
      -- movimiento (fila anterior al ledger C-21) cae a la definición única.
      SELECT unit_cost_snapshot, -quantity_delta INTO v_reverse_unit_cost, v_reverse_delta
      FROM   public.stock_movements
      WHERE  reference_id = v_old_sale.id AND reference_type = 'sale'
      ORDER  BY created_at DESC
      LIMIT  1;

      -- C-21 checkpoint #2: devolver a la branch original de la venta (o default).
      -- stock-movements-edicion (D2/D3): op_stock_movement aplica el delta
      -- (misma aritmética que antes) Y emite el movimiento espejo REVERSE:
      -- type='sale_return', reference_id=id VIEJO, reference_type='sale_update'.
      -- stock-edicion-sucursal-piso (D4): si la sucursal de la venta fue DESACTIVADA, el
      -- stock se devuelve a la principal operativa (sucursal nula = c26_default_branch
      -- dentro de op_stock_movement) y el movimiento deja la sucursal original en la
      -- metadata — mismo respaldo y mismas claves que rpc_reverse_stock_movement. Antes
      -- volvía a la desactivada, donde nadie lo ve ni lo puede vender.
      v_rev_branch := v_old_sale.branch_id;
      v_rev_meta   := NULL;
      IF v_old_sale.branch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.branches
        WHERE id = v_old_sale.branch_id AND account_id = v_account_id AND is_active = FALSE
      ) THEN
        v_rev_branch := NULL;
        v_rev_meta   := jsonb_build_object('fallback_from_branch_id', v_old_sale.branch_id,
                                           'fallback_reason', 'branch_inactive');
      END IF;

      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_old_sale.product_id, v_old_product_name,
        v_rev_branch,
        COALESCE(v_reverse_delta,
                 public._uom_normalize_quantity(v_old_sale.product_id, v_old_sale.unit_id, v_old_sale.quantity)),
        'sale_return',
        v_old_sale.id, 'sale_update', v_old_sale.operation_id,
        v_reverse_unit_cost, 'Reversa por edición de operación', v_rev_meta
      );
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  -- sale_items.sale_id tiene FK ON DELETE CASCADE: este DELETE es lo que
  -- borraba la línea sin recrearla (el hallazgo de edicion-operaciones-lineas).
  -- El acarreo de arriba ya capturó lo necesario antes de perderlo.
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  -- edicion-operaciones-con-dinero (D2): v_new_op_id ya se resolvio arriba (estable); las filas se re-insertan con el MISMO operation_id.

  -- edicion-preserva-contexto (F3, design §D7): quantity pasa de integer a
  -- numeric — único eslabón entero de una cadena que ya es numeric(15,4) de
  -- punta a punta. unit_id se suma al recordset (igual forma que la
  -- creación) para escribirlo real en vez de NULL explícito (§D7 último
  -- párrafo).
  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    -- asiento-venta-formulario: acumular el total nuevo (mismo patrón que
    -- rpc_create_sale_operation_v2) para el ajuste contable de más abajo.
    v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock).
      -- edicion-operaciones-lineas: se agrega name/sku/cost a la misma
      -- lectura para resolver el snapshot fresco sin una consulta extra.
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
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- ventas-unidades-conversion (D1): cantidad de la línea nueva en unidad
      -- base del producto — gate de stock y pata APPLY usan este valor.
      v_apply_qty_norm := public._uom_normalize_quantity(v_item.product_id, v_item.unit_id, v_item.quantity);

      -- stock-edicion-sucursal-piso (D1): gate de stock POR SUCURSAL, la misma donde se
      -- aplica el descuento (v_final_branch_id), igual que el alta (rpc_create_sale_
      -- operation_v2, C-26 OQ-A). Antes el gate era Σ branch_stock de TODAS las
      -- sucursales pero el descuento caía en UNA: con el total alcanzando y la
      -- sucursal no, la edición pasaba el gate y explotaba después con 23514
      -- (branch_stock_quantity_non_negative), que el backend devolvía como un 422
      -- genérico. Ahora rechaza con el mismo P0409 de stock insuficiente que el alta
      -- (el literal que el frontend ya traduce), antes de escribir la línea nueva — la
      -- transacción entera se revierte, incluida la pata REVERSE.
      SELECT COALESCE(quantity, 0) INTO v_branch_qty
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id AND branch_id = v_final_branch_id;
      v_branch_qty := COALESCE(v_branch_qty, 0);

      IF v_branch_qty < v_apply_qty_norm THEN
        IF p_branch_provided AND p_branch_id IS NOT NULL THEN
          RAISE EXCEPTION 'insufficient_branch_stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        ELSE
          RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P0409';
        END IF;
      END IF;

      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal = v_final_* (F1 §D3),
      -- unit_id = v_item.unit_id (F1 §D7, viaja con la línea).
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (COALESCE(v_author, v_uid), v_account_id, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;

      -- edicion-operaciones-lineas (D2/D4): la línea sigue al header.
      -- product_id presente en el mapa viejo → acarrea (una corrección de
      -- cantidad/precio no re-precifica); ausente → snapshot fresco
      -- (producto nuevo, ítem agregado, u operación que nunca tuvo línea).
      -- stock-movements-edicion: v_line_snap se calcula SIEMPRE (antes vivía
      -- adentro del IF v_flag_on) porque el movimiento de stock lo necesita
      -- exista o no la línea — el kill-switch apaga sale_items, no el ledger.
      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

      IF v_flag_on THEN
        -- edicion-preserva-contexto: unit_id = v_item.unit_id en vez de NULL
        -- explícito (F1 §D7 último párrafo).
        INSERT INTO public.sale_items (
          sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
          name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot, snapshot_backfilled
        ) VALUES (
          v_new_sale_id, v_item.product_id, v_account_id, NULL,
          v_item.quantity, v_item.unit_id, v_item.amount, v_item.amount * v_item.quantity,
          v_line_snap->>'name_snapshot',
          v_line_snap->>'sku_snapshot',
          (v_line_snap->>'unit_cost_snapshot')::numeric,
          (v_line_snap->>'iva_rate_snapshot')::numeric,
          COALESCE((v_line_snap->>'snapshot_backfilled')::boolean, false)
        );
      END IF;

      -- C-21 checkpoint #2: single-write branch_stock.
      -- stock-movements-edicion (D2/D3/D5): pata APPLY — type='sale',
      -- reference_id=id NUEVO, reference_type='sale' (indistinguible de la
      -- creación — el contrato del que depende la reversa al eliminar).
      -- unit_cost_snapshot reusa v_line_snap, la misma decisión de acarreo
      -- que la línea (sin re-valuar al costo actual).
      -- edicion-preserva-contexto (F1 §D8): la sucursal pasa a ser
      -- v_final_branch_id (la efectiva) en vez de NULL — editar deja de
      -- mudar stock a la sucursal default.
      PERFORM public.op_stock_movement(
        v_account_id, v_uid, v_item.product_id, v_product.name,
        v_final_branch_id, -v_apply_qty_norm, 'sale', v_new_sale_id, 'sale',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
      -- account_id sealed from caller's resolved account (C-05 D7).
      -- metodos-pago-operaciones: payment_method_id = v_final_payment_method_id (D5).
      -- edicion-preserva-contexto: branch_id/canal/unit_id preservados/reimputados igual.
      INSERT INTO public.sales
        (user_id, account_id, client_id, product_id, amount, quantity, unit_id, total, currency, date, operation_id, branch_id, canal, payment_method_id)
      VALUES
        (COALESCE(v_author, v_uid), v_account_id, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id, v_final_branch_id, v_final_canal, v_final_payment_method_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  -- ventas-unidades-conversion (cuarta revisión): el total de DINERO se
  -- redondea al centavo UNA vez, sobre Σ(amount × quantity). El acumulador
  -- era numeric(15,2) y redondeaba cada suma parcial: dos líneas de 0,333 kg
  -- a $999 cargaban 665,34 a caja/banco/cuenta corriente/evento contra una
  -- venta de 665,334 y una factura de round(Σ) = 665,33.
  v_total_sum := round(v_total_sum, 2);

  -- edicion-operaciones-con-dinero (D12 paso 9): escrituras de dinero segun el plan. El total del loop tiene que coincidir con
  -- el que se uso para planificar (misma formula): si no, abortar es mas seguro que escribir un importe distinto del planeado.
  IF v_total_sum <> v_pre_total THEN
    RAISE EXCEPTION 'edit_total_mismatch: el total calculado (%) no coincide con el planificado (%)', v_total_sum, v_pre_total
      USING ERRCODE = 'P0400';
  END IF;
  PERFORM public._op_edit_apply(v_account_id, 'sale', v_plan, v_new_op_id, v_new_op_id, v_kind_final,
                                v_final_payment_method_id, v_final_branch_id, p_date, NULL, p_reason);

  -- edicion-preserva-contexto (F1, design §D9): la orden promovida SIN
  -- comprobante "real" se re-apunta al operation_id nuevo, en la misma
  -- transacción — cierra en su causa raíz la OQ-C de edicion-operaciones-
  -- lineas (3 órdenes colgadas en prod hoy, no reconstruibles
  -- retroactivamente: nada registró antes el mapeo operation_id viejo→nuevo
  -- de esas ediciones — ver design §D10).
  --
  -- "no tiene comprobante fiscal asociado" usa la MISMA definición que el
  -- guard F2 de arriba (§D5): fiscal_document_id NULL, o apuntando a un
  -- comprobante 'rejected' (nunca existió fiscalmente) — no solo NULL a
  -- secas. Sin este matiz, una orden cuyo único comprobante quedó rejected
  -- SÍ pasa el guard F2 (rejected no bloquea, D5) y SÍ se edita, pero
  -- fiscal_document_id sigue NOT NULL apuntando al doc rejected → un
  -- `WHERE fiscal_document_id IS NULL` a secas la deja huérfana (gate 2.8,
  -- descubierto en RED contra esta migración: no era redundante con F2, F2
  -- ya deja pasar exactamente este caso).
  --
  -- venta-editable-vs-promocion-legacy (N3): la orden re-apuntada SIGUE a la
  -- operación también en importes. Re-apuntar sólo sale_operation_id dejaba
  -- total, cliente y líneas VIEJOS: la re-facturación después de anular (D5
  -- de venta-editable-sin-cae) y el "Facturar" de una venta del POS editada
  -- emitían por el importe anterior. El recálculo vive en UN solo lugar,
  -- compartido con la promoción: _sales_order_sync_from_operation. El
  -- predicado del re-apuntado no cambia; el helper de anulación ya corrió
  -- arriba, así que acá sólo llegan órdenes sin comprobante o con uno
  -- rechazado/anulado (a lo sumo una: índice único parcial).
  UPDATE public.sales_orders so
  SET    sale_operation_id = v_new_op_id
  WHERE  so.sale_operation_id = v_old_operation_id
    AND  NOT EXISTS (
      SELECT 1 FROM public.fiscal_documents fd
      WHERE fd.id = so.fiscal_document_id
        AND fd.status IN ('pending_cae', 'authorized')
    )
  RETURNING so.id INTO v_resync_id;

  IF v_resync_id IS NOT NULL THEN
    PERFORM public._sales_order_sync_from_operation(v_resync_id, v_new_op_id, v_account_id);
    -- edicion-operaciones-con-dinero (7.4): el recalculo de la orden NO toca la forma de pago y el listado lee
    -- COALESCE(sales.payment_method_id, sales_orders.payment_method_id): una venta del POS editada de efectivo a
    -- transferencia mostraria la forma vieja si la fila de venta quedara sin forma. Se alinea la orden con lo imputado.
    UPDATE public.sales_orders SET payment_method_id = v_final_payment_method_id WHERE id = v_resync_id;
  END IF;

  -- asiento-venta-formulario (D7, override del PO): ajustar el rastro
  -- contable AHORA que v_new_op_id/v_total_sum/v_final_payment_method_id
  -- son finales. v_pending_event_id / v_has_posted_entry ya fueron
  -- resueltos ANTES del REVERSE/DELETE (con el lock tomado en el momento
  -- correcto) — acá sólo se actúa sobre lo ya resuelto.
  IF v_final_payment_method_id IS NOT NULL THEN
    SELECT kind INTO v_kind_final
    FROM public.payment_methods
    WHERE id = v_final_payment_method_id;
  ELSE
    v_kind_final := NULL;
  END IF;

  IF v_pending_event_id IS NOT NULL THEN
    -- Caso B (D7): reemplazar el evento pendiente EN EL LUGAR — el
    -- dispatcher, cuando lo procese, genera un solo asiento final,
    -- correcto, referenciando v_new_op_id. No se emite un segundo evento.
    IF v_pending_event_type = 'SaleOperationCreated' THEN
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = jsonb_build_object(
               'account_id',     v_account_id,
               'operation_id',   v_new_op_id,
               'total',          v_total_sum,
               'payment_method', v_kind_final,
               'client_id',      p_client_id,
               'sale_date',      p_date,
               'occurred_at',    now()
             )
      WHERE  id = v_pending_event_id;
    ELSE
      -- 'SaleOperationAdjusted' todavía pendiente (edición encadenada antes
      -- de que el relay procese la anterior): se actualiza el destino
      -- (new_operation_id) y los valores nuevos, pero se PRESERVA
      -- old_operation_id — la referencia al asiento a revertir no cambia,
      -- sigue siendo el mismo asiento original, todavía no tocado. Esto
      -- colapsa N ediciones-antes-de-procesar en un solo evento final.
      UPDATE public.events
      SET    aggregate_id = v_new_op_id,
             payload = v_pending_payload
                        || jsonb_build_object(
                             'new_operation_id', v_new_op_id,
                             'total',            v_total_sum,
                             'payment_method',   v_kind_final,
                             'client_id',        p_client_id,
                             'sale_date',        p_date,
                             'occurred_at',      now()
                           )
      WHERE  id = v_pending_event_id;
    END IF;
  ELSIF v_has_posted_entry THEN
    -- Caso C (D7): el asiento ya fue posteado — emitir el evento de
    -- ajuste. INSERT plano, SIN bloque EXCEPTION (D6): swallowear el
    -- fallo reproduciría en silencio el bug que este change arregla.
    INSERT INTO public.events
      (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
    VALUES (
      v_account_id, 'SaleOperationAdjusted', 'SaleOperation', v_new_op_id,
      jsonb_build_object(
        'old_operation_id', v_old_operation_id,
        'new_operation_id', v_new_op_id,
        'sales_order_id',   v_order_id,
        'account_id',       v_account_id,
        'total',            v_total_sum,
        'payment_method',   v_kind_final,
        'client_id',        p_client_id,
        'sale_date',        p_date,
        'occurred_at',      now()
      ),
      now()
    );
  END IF;
  -- Caso A (D7): ni v_pending_event_id ni v_has_posted_entry — no-op contable
  -- (operación anterior al productor, o que nunca tuvo evento).

  -- venta-editable-sin-cae: el descriptor del comprobante anulado viaja en la
  -- respuesta para que el toast diga "se anuló el comprobante 0003-00000005"
  -- con lo que dice el SERVIDOR, nunca con lo que el cliente creía.
  -- edicion-operaciones-con-dinero (D14): rastro de la edicion en audit_logs, en la misma transaccion.
  PERFORM public._op_edit_audit(
    v_account_id, v_uid, 'sale_operation.edited', 'sale_operation', v_new_op_id, v_before,
    jsonb_build_object('total', v_total_sum, 'payment_method_id', v_final_payment_method_id, 'client_id', p_client_id,
                       'date', p_date, 'branch_id', v_final_branch_id,
                       'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', x.product_id, 'quantity', x.quantity,
                                                                              'amount', x.amount)), '[]'::jsonb)
                                 FROM jsonb_to_recordset(p_items) AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid))),
    v_plan, v_voided_doc, p_reason);

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items,
                            'voided_fiscal_document', v_voided_doc, 'money', v_plan);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean,uuid,boolean,uuid,boolean,date,boolean,text,boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean,uuid,boolean,uuid,boolean,date,boolean,text,boolean) TO authenticated, service_role;
COMMENT ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb,uuid,boolean,uuid,boolean,text,boolean,uuid,boolean,uuid,boolean,date,boolean,text,boolean) IS
$cmt$edicion-preserva-contexto: preserva branch_id/canal/unit_id al editar (F1, tri-estado para branch_id/canal), bloquea la edición de una operación facturada con P0423 (F2), acepta quantity decimal (F3), y re-apunta sales_orders promovida sin comprobante al operation_id nuevo (F1 §D9). Base: #415 (líneas) + #417 (espejo de stock) + #419 (forma de pago). ventas-sucursal-por-defecto: un branch_id nulo, vigente o informado, se resuelve a la principal. stock-edicion-sucursal-piso: el gate de stock es POR SUCURSAL (la misma donde se descuenta; P0409 insufficient_branch_stock / Insufficient stock, ya no 23514) y una sucursal vigente DESACTIVADA no se preserva ni recibe la reversa: cae en la principal operativa, con fallback_from_branch_id en la metadata del movimiento.$cmt$;

-- ── rpc_atomic_update_purchase_operation (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_update_purchase_operation(p_purchase_ids uuid[], p_date date, p_description text, p_items jsonb, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_provided boolean DEFAULT false, p_branch_id uuid DEFAULT NULL::uuid, p_branch_provided boolean DEFAULT false, p_supplier_id uuid DEFAULT NULL::uuid, p_supplier_provided boolean DEFAULT false, p_cost_center_id uuid DEFAULT NULL::uuid, p_cost_center_provided boolean DEFAULT false, p_cash_session_id uuid DEFAULT NULL::uuid, p_cash_provided boolean DEFAULT false, p_bank_account_id uuid DEFAULT NULL::uuid, p_bank_account_provided boolean DEFAULT false, p_due_date date DEFAULT NULL::date, p_due_date_provided boolean DEFAULT false, p_reason text DEFAULT NULL::text, p_dry_run boolean DEFAULT false)
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
  -- edicion-operaciones-con-dinero (tanda B): plan de dinero, huella y rastro
  v_old_date             date;
  v_pre_total            numeric;
  v_refs                 uuid[];
  v_plan                 jsonb;
  v_before               jsonb;
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

  -- edicion-operaciones-con-dinero (tanda B, D1): se RETIRAN los tres P0423 de dinero (cuenta corriente del proveedor, banco y
  -- caja). La edicion calcula la huella neta y el efecto deseado de cada libro y escribe solo donde difieren (plan de abajo).
  -- Sigue en pie el bloqueo que NO es de dinero: la compra nacida de un remito (delivery_note_purchase_locked).

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

  -- edicion-operaciones-con-dinero (tanda B, D8): credit_requires_supplier ya no se evalua por presencia de parametros sino cuando
  -- el efecto de cuenta corriente existe (hay huella o cambio el contrato de pago): lo resuelve el plan. Se retira el rechazo
  -- de la transicion a credito: la edicion ya puede postear el cargo.

  -- ── edicion-operaciones-con-dinero (tanda B, D12 pasos 4-6): el PLAN de dinero ───────────────────────────────────────
  SELECT COALESCE(round(SUM(x.amount * x.quantity), 2), 0) INTO v_pre_total
  FROM   jsonb_to_recordset(p_items) AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid);

  SELECT p.date::date INTO v_old_date FROM public.purchases p WHERE p.id = ANY(v_locked_ids) ORDER BY p.id LIMIT 1;

  v_refs := CASE WHEN v_old_op_id IS NULL THEN v_locked_ids ELSE ARRAY[v_old_op_id] END;
  v_new_op_id := COALESCE(v_old_op_id, gen_random_uuid());

  v_plan := public._op_edit_plan(
    v_account_id, 'purchase', v_refs, v_new_op_id, v_pre_total, v_old_date, p_date,
    v_old_payment_method_id, v_final_payment_method_id, v_final_kind,
    v_old_supplier_id, v_final_supplier_id, v_final_branch_id,
    p_cash_provided, p_cash_session_id, p_bank_account_provided, p_bank_account_id,
    p_due_date_provided, p_due_date);

  IF p_dry_run THEN
    RETURN jsonb_build_object('dry_run', true, 'plan', v_plan);
  END IF;

  PERFORM public._op_edit_raise_blocks(v_plan);
  PERFORM public._op_edit_lock(v_plan);

  SELECT jsonb_build_object(
           'total',             round(COALESCE(SUM(COALESCE(p.total, p.amount * p.quantity)), 0), 2),
           'payment_method_id', v_old_payment_method_id,
           'supplier_id',       v_old_supplier_id,
           'date',              v_old_date,
           'branch_id',         v_old_branch_id,
           'lines',             COALESCE(jsonb_agg(jsonb_build_object('product_id', p.product_id, 'quantity', p.quantity,
                                                                      'amount', p.amount) ORDER BY p.id), '[]'::jsonb))
  INTO   v_before
  FROM   public.purchases p WHERE p.id = ANY(v_locked_ids);

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
  -- edicion-operaciones-con-dinero (D2): v_new_op_id ya se resolvio arriba (estable); las filas se re-insertan con el MISMO operation_id.

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

  -- ── edicion-operaciones-con-dinero (tanda B, D12 paso 9): escrituras de dinero segun el plan ─────────────────────────
  PERFORM public._op_edit_apply(v_account_id, 'purchase', v_plan, v_new_op_id, v_new_op_id, v_final_kind,
                                v_final_payment_method_id, v_final_branch_id, p_date, p_description, p_reason);

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

  -- edicion-operaciones-con-dinero (D14): rastro de la edicion en audit_logs, en la misma transaccion.
  PERFORM public._op_edit_audit(
    v_account_id, v_uid, 'purchase_operation.edited', 'purchase_operation', v_new_op_id, v_before,
    jsonb_build_object('total', v_pre_total, 'payment_method_id', v_final_payment_method_id, 'supplier_id', v_final_supplier_id,
                       'date', p_date, 'branch_id', v_final_branch_id,
                       'lines', (SELECT COALESCE(jsonb_agg(jsonb_build_object('product_id', x.product_id, 'quantity', x.quantity,
                                                                              'amount', x.amount)), '[]'::jsonb)
                                 FROM jsonb_to_recordset(p_items) AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid))),
    v_plan, NULL, p_reason);

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items, 'money', v_plan);
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[],date,text,jsonb,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,date,boolean,text,boolean) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[],date,text,jsonb,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,date,boolean,text,boolean) TO authenticated, service_role;
COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[],date,text,jsonb,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,uuid,boolean,date,boolean,text,boolean) IS
$cmt$caja-compras-cobranzas (D8): el guard P0423 suma un tercer EXISTS contra
  cash_movements (movement_type=purchase_payment) — una compra con caja
  posteada también pasa a ser inmutable. Mismo predicado en el derivado de
  lectura del listado (backend/repositories/purchase_repository.py).
  remitos-compra (D9): una compra con origen de remito no se edita: P0423 delivery_note_purchase_locked, después de la comprobación de existencia y ANTES de los tres P0423 de dinero (sin tocar stock ni nada).
  stock-edicion-sucursal-piso (D2): chequeo previo de la pata REVERSE — si la mercadería de la compra ya se vendió, rechaza con P0409 purchase_edit_stock_consumed (cuánto queda y cuánto habría que restar) en vez de 23514.$cmt$;

-- ── rpc_create_purchase_operation_v2 (cuerpo previo) ─────────────────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation_v2(p_idempotency_key text, p_date date, p_description text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid             uuid;
  v_account_id      uuid;
  v_new_op_id       uuid;
  v_existing_op     uuid;
  v_item            RECORD;
  v_product         RECORD;
  v_new_purchase_id uuid;
  v_result_items    jsonb := '[]'::jsonb;
  v_qty_before      numeric;
  v_qty_after       numeric;
  v_unit_factor     numeric(20,10);
  v_qty_norm        numeric(15,4);
  v_stock_sum       numeric(15,4);
  v_inserted        integer;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id
  FROM   current_account_ids() AS cai
  LIMIT  1;

  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  -- multiusuario-operativo (tanda B, D9): el ROL decide, antes de cualquier escritura. El observador
  -- (sin rol de escritura) da P0401; un rol de escritura sin la capacidad del dominio, P0403.
  PERFORM public._account_assert_capability(v_account_id, ARRAY['owner', 'admin', 'purchases'], 'tu rol no permite registrar compras (requiere compras, administrador o dueño)');

  IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
    RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P0400';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P0400';
  END IF;

  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
  VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM   public.operation_idempotency
    WHERE  user_id = v_uid
      AND  operation_kind = 'purchase'
      AND  idempotency_key = p_idempotency_key;

    SELECT COALESCE(
             jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
             '[]'::jsonb
           )
    INTO   v_result_items
    FROM   public.purchases p
    WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

    RETURN jsonb_build_object(
      'operation_id', v_existing_op,
      'items',        v_result_items,
      'replayed',     true
    );
  END IF;

  FOR v_item IN
    SELECT *
    FROM   jsonb_to_recordset(p_items)
             AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
    ORDER BY product_id
  LOOP
    IF v_item.quantity IS NULL OR v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P0400';
    END IF;
    IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
      RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P0400';
    END IF;

    v_unit_factor := 1.0;
    IF v_item.unit_id IS NOT NULL THEN
      SELECT factor INTO v_unit_factor
      FROM   public.units_of_measure
      WHERE  id = v_item.unit_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P0404';
      END IF;
    END IF;
    v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

    IF v_item.product_id IS NOT NULL THEN
      -- C-21 checkpoint #2: FOR UPDATE = mutex por producto (sin leer stock)
      SELECT id, user_id, is_variant, name INTO v_product
      FROM   public.products
      WHERE  id = v_item.product_id
        AND account_id = v_account_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
      END IF;

      -- multiusuario-operativo (tanda B, D8): la tenencia del producto la decide la CUENTA (filtro del SELECT … FOR UPDATE
      -- de arriba: un producto de otra cuenta es indistinguible de uno inexistente, P0404), nunca quién lo cargó.

      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION
            'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
            USING ERRCODE = 'P0422';
        END IF;
      END IF;

      -- OQ2: doble escritura — header flat + purchase_items
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;

      INSERT INTO public.purchase_items (
        purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
      ) VALUES (
        v_new_purchase_id, v_item.product_id, v_account_id, NULL,
        v_item.quantity, v_item.unit_id,
        v_item.amount, v_item.amount * v_item.quantity
      );

      -- C-21 checkpoint #2: before/after desde Σ branch_stock
      SELECT COALESCE(SUM(quantity), 0) INTO v_stock_sum
      FROM   public.branch_stock
      WHERE  product_id = v_item.product_id;

      v_qty_before := v_stock_sum;
      v_qty_after  := v_stock_sum + v_qty_norm;

      PERFORM public.c21_apply_branch_stock_delta(
        v_account_id, v_item.product_id, NULL, v_qty_norm);

      INSERT INTO public.stock_movements (
        user_id, account_id, product_id, product_name, type,
        quantity_delta, quantity_before, quantity_after,
        reference_id, reference_type, performed_by,
        operation_group_id
      ) VALUES (
        v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
        v_qty_norm, v_qty_before, v_qty_after,
        v_new_purchase_id, 'purchase', v_uid,
        v_new_op_id
      );

    ELSE
      INSERT INTO public.purchases
        (user_id, account_id, product_id, amount, quantity, unit_id, total, description, date, operation_id)
      VALUES
        (v_uid, v_account_id, NULL,
         v_item.amount, v_item.quantity, v_item.unit_id,
         v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id)
      RETURNING id INTO v_new_purchase_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object(
    'operation_id', v_new_op_id,
    'items',        v_result_items,
    'replayed',     false
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.rpc_create_purchase_operation_v2(text,date,text,jsonb) FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rpc_create_purchase_operation_v2(text,date,text,jsonb) TO service_role;
COMMENT ON FUNCTION public.rpc_create_purchase_operation_v2(text,date,text,jsonb) IS NULL;

-- Reinserta el flag (enabled = true) para las cuentas con operaciones, como lo dejó deudas-menores-agosto.
INSERT INTO public.account_feature_flags (account_id, flag_key, enabled)
SELECT DISTINCT a.account_id, 'sale_items_rpc_v2', true
  FROM (SELECT account_id FROM public.sales WHERE account_id IS NOT NULL
        UNION SELECT account_id FROM public.purchases WHERE account_id IS NOT NULL) a
ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = true;
