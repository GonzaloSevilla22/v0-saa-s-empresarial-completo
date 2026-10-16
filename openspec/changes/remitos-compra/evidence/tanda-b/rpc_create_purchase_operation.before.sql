CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(p_idempotency_key text, p_date date, p_description text, p_items jsonb, p_branch_id uuid DEFAULT NULL::uuid, p_cost_center_id uuid DEFAULT NULL::uuid, p_payment_method_id uuid DEFAULT NULL::uuid, p_bank_account_id uuid DEFAULT NULL::uuid, p_supplier_id uuid DEFAULT NULL::uuid, p_cash_session_id uuid DEFAULT NULL::uuid, p_due_date date DEFAULT NULL::date)
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
    v_cash_session_status text;
    v_cash_session_branch uuid;
    -- compras-gastos-sucursal-por-defecto (D1/D2/D3):
    v_branch              RECORD;
    v_gate_branch         uuid;
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
                   AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)
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
            SELECT id, user_id, is_variant, name, sku, cost INTO v_product
            FROM   public.products
            WHERE  id = v_item.product_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P0404';
            END IF;

            IF v_product.user_id <> v_uid THEN
                RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P0403';
            END IF;

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

            -- compras-gastos-sucursal-por-defecto (D1/D2): se guarda v_gate_branch (la elegida o
            -- la principal), la misma con la que entra el stock — no el p_branch_id crudo.
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 v_gate_branch, p_cost_center_id, p_payment_method_id,
                 p_supplier_id,
                 v_product.name, v_product.sku, v_product.cost, NULL)
            RETURNING id INTO v_new_purchase_id;

            IF v_flag_on THEN
                INSERT INTO public.purchase_items (
                    purchase_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal,
                    name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot
                ) VALUES (
                    v_new_purchase_id, v_item.product_id, v_account_id, NULL,
                    v_item.quantity, v_item.unit_id,
                    v_item.amount, v_item.amount * v_item.quantity,
                    v_product.name, v_product.sku, v_product.cost, NULL
                );
            END IF;

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

        ELSE
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
        IF v_kind IS DISTINCT FROM 'cash' THEN
            RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
                USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM v_gate_branch THEN
            RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta y pertenecer a la sucursal efectiva de la compra'
                USING ERRCODE = 'P0422';
        END IF;

        IF p_date <> public.reporting_local_today() THEN
            RAISE EXCEPTION 'cash_optin_requires_today: sólo se puede registrar en caja una compra fechada hoy (%)', public.reporting_local_today()
                USING ERRCODE = 'P0422';
        END IF;

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

    RETURN jsonb_build_object(
        'operation_id', v_new_op_id,
        'items',        v_result_items,
        'replayed',     false
    );
END;
$function$
