-- =============================================================================
-- caja-compras-cobranzas — la compra en efectivo, el cobro y el pago de
-- cuenta corriente empiezan a descontar/sumar en la caja.
-- =============================================================================
--
-- Pedido textual del PO (2026-09-01): "No se registra la compra con Efectivo
-- en el historial de caja y tampoco cuando cobrás una cuenta corriente; tiene
-- que funcionar; también cuando se elimine una compra en efectivo se
-- compense." Sign-off del PO (2026-09-01, "aplicalo con todas las
-- recomendaciones") sobre el grupo 0: (a) los 4 compras/6 cobros/1 pago
-- históricos quedan SIN movimiento de caja para siempre (D11, sin backfill
-- honesto); (b) una compra que ya impactó la caja pasa a ser INMUTABLE — se
-- corrige borrando y recargando (D8); (c) borrar una compra en efectivo
-- exige la caja abierta (P0426, D7). Las 5 OQs salieron por su opción
-- recomendada: OQ-1 payment_method persistido en cobros/pagos (SÍ), OQ-2
-- opt-in pre-marcado en los tres caminos (SÍ), OQ-3 relabel de
-- purchase_payment sin sign-off adicional (SÍ), OQ-4 reverso de cobros FUERA
-- de este change, OQ-5 sin backfill confirmado.
--
-- MAX(version) de prod re-verificado 2026-09-01 (sólo SELECT, MCP) justo
-- antes de escribir este archivo: 20261017000001 con 266 migraciones,
-- idéntico al último archivo de origin/main → este archivo usa
-- 20261018000001. En este proyecto la renumeración mordió tres veces; por
-- eso se re-verifica acá y no sólo al principio del apply.
--
-- GATE DE INTEGRIDAD DE FUNCIÓN (regla del proyecto): las cuatro RPCs que
-- este change reescribe, más rpc_create_expense/rpc_delete_expense (moldes
-- de referencia), están capturadas por pg_get_functiondef EN VIVO de prod en
-- openspec/changes/caja-compras-cobranzas/baseline/*.sql, con md5 y length.
-- Las siete coinciden EXACTO contra el checkpoint 1.2 del apply (cero
-- divergencias). La reescritura de cada una parte de ese baseline, NUNCA del
-- archivo de migración.
--
-- REUTILIZACIÓN ANTES QUE REPETICIÓN (regla PO 2026-08-02): este archivo NO
-- crea ni un helper SQL nuevo. Cada predicado se COPIA:
--   · las tres condiciones del opt-in de caja de la compra
--     ← rpc_create_expense (baseline; a su vez copiado de
--       rpc_create_sale_operation_v2)
--   · la compensación de caja por borrado (disparo por existencia, jamás por
--     signo, P0426 sin sesión abierta)
--     ← rpc_delete_expense (baseline)
--   · el tercer término del guard de inmutabilidad P0423
--     ← el mismo patrón de los dos EXISTS ya presentes en
--       rpc_atomic_update_purchase_operation
-- Los helpers compartidos (c28_register_cash_movement,
-- _pay_register_operation_bank_movement, _pay_register_party_charge,
-- _pay_reverse_party_charge) NO se tocan.
--
-- ERRCODEs: CERO nuevos. P0400/P0401/P0409/P0412/P0422/P0423/P0426 ya existen
-- y ya están mapeados en backend/core/errors.py. P0001 PROHIBIDO.
--
-- Idempotente: CHECK con DROP+ADD, columnas con ADD COLUMN IF NOT EXISTS,
-- las tres RPCs de alta con DROP FUNCTION IF EXISTS (firma vieja) + CREATE
-- (firma nueva, D6 — un CREATE OR REPLACE con un parámetro nuevo crearía un
-- OVERLOAD, no reemplazaría la función: bug 42725 documentado), con
-- REVOKE/GRANT explícito de PUBLIC/anon/authenticated en el mismo archivo
-- para las tres (gotcha: un DROP FUNCTION resetea las ACLs). Las otras dos
-- RPCs (rpc_delete_purchase_operation, rpc_atomic_update_purchase_operation)
-- NO cambian de firma → CREATE OR REPLACE alcanza, conserva ACLs.
--
-- Orden del archivo (Migration Plan de design.md):
--   (1) CHECK de cash_movements.movement_type: 8 → 11 tipos.
--   (2) payments_received / payments_made ganan payment_method (OQ-1).
--   (3) DROP+CREATE de rpc_create_purchase_operation, rpc_register_payment_
--       received y rpc_register_payment_made, con REVOKE/GRANT.
--   (4) CREATE OR REPLACE de rpc_delete_purchase_operation (pata de caja).
--   (5) CREATE OR REPLACE de rpc_atomic_update_purchase_operation (P0423
--       suma el movimiento de caja).
-- =============================================================================


-- ═══════════════════ (1) CHECK — 8 → 11 tipos, idempotente ═══════════════════

ALTER TABLE public.cash_movements
  DROP CONSTRAINT IF EXISTS cash_movements_movement_type_check;

ALTER TABLE public.cash_movements
  ADD CONSTRAINT cash_movements_movement_type_check
  CHECK (movement_type IN (
    'sale', 'purchase_payment', 'expense', 'advance', 'withdrawal',
    'sale_reversal', 'expense_reversal',
    -- caja-compras-cobranzas: tres tipos nuevos.
    'purchase_payment_reversal', 'payment_received', 'payment_made',
    'adjustment'
  ));

COMMENT ON CONSTRAINT cash_movements_movement_type_check ON public.cash_movements IS
  'caja-compras-cobranzas: 11 tipos. purchase_payment_reversal (ingreso,
  reversa de compra), payment_received (ingreso, cobro de cuenta corriente),
  payment_made (egreso, pago a proveedor) — nuevos. purchase_payment pasa a
  significar "compra en efectivo" (relabel de etiqueta en el frontend, 0 filas
  en prod al momento del cambio — no reescribe historia).';


-- ═══════════════ (2) payments_received / payments_made — OQ-1 ════════════════
-- Columnas aditivas y nullable, sin backfill (D11: el método de pago nunca se
-- persistió antes de este change, así que no hay nada que rellenar).

ALTER TABLE public.payments_received ADD COLUMN IF NOT EXISTS payment_method text NULL;
ALTER TABLE public.payments_made     ADD COLUMN IF NOT EXISTS payment_method text NULL;

COMMENT ON COLUMN public.payments_received.payment_method IS
  'caja-compras-cobranzas (OQ-1): método con el que se cobró — cash/transfer/
  card/check. NULL en las filas históricas (sin backfill, D11).';
COMMENT ON COLUMN public.payments_made.payment_method IS
  'caja-compras-cobranzas (OQ-1): método con el que se pagó — cash/transfer/
  card/check. NULL en las filas históricas (sin backfill, D11).';


-- ═════════ (3a) rpc_create_purchase_operation — DROP + CREATE ════════════════
-- Firma vieja (9 args, sin p_cash_session_id) — DROP explícito, D6.
DROP FUNCTION IF EXISTS public.rpc_create_purchase_operation(
  text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid
);

CREATE FUNCTION public.rpc_create_purchase_operation(
  p_idempotency_key text,
  p_date date,
  p_description text,
  p_items jsonb,
  p_branch_id uuid DEFAULT NULL::uuid,
  p_cost_center_id uuid DEFAULT NULL::uuid,
  p_payment_method_id uuid DEFAULT NULL::uuid,
  p_bank_account_id uuid DEFAULT NULL::uuid,
  p_supplier_id uuid DEFAULT NULL::uuid,
  -- caja-compras-cobranzas (D2/D6): trailing, DEFAULT NULL = no-op (la compra
  -- se registra igual sin tocar la caja). Copiado literal del molde de
  -- rpc_create_expense: mismos tres tokens de error P0422, mismo orden,
  -- misma comparación p_date::date (sin timestamptz) contra
  -- reporting_local_today().
  p_cash_session_id uuid DEFAULT NULL::uuid
)
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
    v_unit_factor     numeric(20,10);
    v_qty_norm        numeric(15,4);
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
    v_total_sum       numeric(15,2) := 0;
    v_kind            text;            -- pagos-cableados-restantes (D7)
    -- caja-compras-cobranzas (D2):
    v_cash_movement_id    uuid;
    v_cash_session_status text;
    v_cash_session_branch uuid;
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
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.branches
            WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P0404';
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

            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id,
                 name_snapshot, sku_snapshot, unit_cost_snapshot, iva_rate_snapshot)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
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

            PERFORM public.c21_apply_branch_stock_delta(
                v_account_id, v_item.product_id, p_branch_id, v_qty_norm);

            INSERT INTO public.stock_movements (
                user_id, account_id, product_id, product_name, type,
                quantity_delta, quantity_before, quantity_after,
                reference_id, reference_type, performed_by,
                operation_group_id, branch_id, unit_cost_snapshot
            ) VALUES (
                v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                v_qty_norm, v_qty_before, v_qty_after,
                v_new_purchase_id, 'purchase', v_uid,
                v_new_op_id, p_branch_id, v_product.cost
            );

        ELSE
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id, payment_method_id,
                 supplier_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id, p_payment_method_id,
                 p_supplier_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ── caja-compras-cobranzas (D2) — OPT-IN DE CAJA, 3 condiciones ───────────
    -- Copiado LITERAL del molde de rpc_create_expense: mismos tres tokens de
    -- error, mismo orden, y p_date (`date`) comparado DIRECTO contra
    -- reporting_local_today() — PROHIBIDO castear a timestamptz (el ::date
    -- implícito usaría la timezone del servidor/UTC, y una compra cargada
    -- entre las 21:00 y las 23:59 de Mendoza se rechazaría con P0422 justo
    -- cuando el usuario sabe que es hoy).
    --
    -- "Sucursal efectiva de la compra" = p_branch_id tal cual (sin COALESCE a
    -- una default: a diferencia del gasto, la compra no resuelve una
    -- sucursal por defecto — D3 sólo exige que se PERSISTA la elegida). Una
    -- compra sin sucursal (p_branch_id NULL) no puede satisfacer esta
    -- condición para ninguna caja real: es el comportamiento correcto, no un
    -- caso sin cubrir.
    IF p_cash_session_id IS NOT NULL THEN
        IF v_kind IS DISTINCT FROM 'cash' THEN
            RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si el kind derivado es cash (recibido: %)', COALESCE(v_kind, 'NULL')
                USING ERRCODE = 'P0422';
        END IF;

        SELECT cs.status, cb.branch_id INTO v_cash_session_status, v_cash_session_branch
        FROM public.cash_sessions cs
        JOIN public.cashboxes cb ON cb.id = cs.cashbox_id
        WHERE cs.id = p_cash_session_id;

        IF v_cash_session_status IS DISTINCT FROM 'open' OR v_cash_session_branch IS DISTINCT FROM p_branch_id THEN
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
    PERFORM public._pay_register_operation_bank_movement(
        v_account_id, v_kind, p_payment_method_id, p_bank_account_id,
        v_total_sum, 'out', 'purchase', v_new_op_id,
        p_date, p_branch_id, NULL
    );

    -- compras-proveedor-cuenta-corriente (D8): cargo en la cuenta corriente
    -- del proveedor.
    IF v_kind = 'credit' THEN
        PERFORM public._pay_register_party_charge(
            v_account_id, 'supplier', p_supplier_id, v_total_sum, v_new_op_id, v_new_op_id
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
$function$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid, uuid, uuid, uuid, uuid) IS
  'caja-compras-cobranzas: suma p_cash_session_id opcional trailing — con las
  tres condiciones verificadas en servidor (kind=cash, sesión abierta en la
  sucursal efectiva, fecha=hoy), descuenta de la caja por el total de la
  compra vía c28_register_cash_movement, tipo purchase_payment. Ausencia =
  no-op (D2).';


-- ═════════ (3b) rpc_register_payment_received — DROP + CREATE ════════════════
DROP FUNCTION IF EXISTS public.rpc_register_payment_received(
  text, uuid, numeric, uuid, text, uuid
);

CREATE FUNCTION public.rpc_register_payment_received(
  p_idempotency_key text,
  p_client_id uuid,
  p_amount numeric,
  p_reference_sale_id uuid DEFAULT NULL::uuid,
  p_payment_method text DEFAULT 'cash'::text,
  p_bank_account_id uuid DEFAULT NULL::uuid,
  -- caja-compras-cobranzas (D5): trailing, DEFAULT NULL = no-op. DOS
  -- condiciones (no tres): payments_received no tiene columna de fecha ni de
  -- sucursal propias (verificado contra information_schema) — "hoy" es
  -- verdadero por construcción (created_at = now()) y la sucursal la aporta
  -- la sesión elegida. La pertenencia de la sesión a la cuenta la aporta el
  -- backstop P0401 de c28_register_cash_movement (tenancy-guard-caja-outbox).
  p_cash_session_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_customer_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
  v_client               uuid;
  -- caja-compras-cobranzas (D5):
  v_cash_movement_id     uuid;
  v_cash_session_status  text;
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

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- caja-compras-cobranzas (D5): informar sesión de caja con un método
  -- distinto de cash se rechaza ANTES de tocar cualquier libro — mismo
  -- criterio que el resto de los guards de payload de esta función.
  IF p_cash_session_id IS NOT NULL AND p_payment_method IS DISTINCT FROM 'cash' THEN
    RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si payment_method=cash (recibido: %)', p_payment_method
      USING ERRCODE = 'P0422';
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el cliente tiene que
  -- pertenecer al tenant.
  SELECT id INTO v_client
  FROM public.clients
  WHERE id = p_client_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'client_not_found: %', p_client_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_received'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_received', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    -- Replay: devolver el resultado original sin re-ejecutar. caja-compras-
    -- cobranzas (D12): el RETURN acá corta antes del bloque de caja de más
    -- abajo — un replay NO postea un segundo movimiento.
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_received'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',           NULL,
      'customer_account_id',  NULL,
      'balance_after',        NULL,
      'replayed',             true,
      'operation_id',         v_existing_op
    );
  END IF;

  -- Resolver/crear la CustomerAccount (OQ-4 C-30 lazy auto-create)
  v_customer_account_id := public.c30_get_or_create_customer_account(v_account_id, p_client_id);

  -- Registrar el movimiento con signo negativo (reduce la deuda, OQ-1 C-30)
  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_customer_account_movement(
    v_customer_account_id,
    -p_amount,
    'payment_received',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.customer_account_movements
  WHERE id = v_movement_id;

  -- caja-compras-cobranzas (OQ-1): payment_method persistido en la fila.
  INSERT INTO public.payments_received
    (id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by, payment_method)
  VALUES
    (v_payment_id, v_account_id, v_customer_account_id, p_client_id, p_amount, p_reference_sale_id, v_movement_id, v_uid, p_payment_method);

  -- ── caja-compras-cobranzas (D5) — OPT-IN DE CAJA, 2 condiciones ───────────
  -- Dentro del alcance de la clave de idempotencia (D12): la escritura queda
  -- adentro del bloque protegido, después de resolver la cuenta corriente y
  -- antes del commit.
  IF p_cash_session_id IS NOT NULL THEN
    SELECT status INTO v_cash_session_status
    FROM public.cash_sessions
    WHERE id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta'
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      p_cash_session_id, p_amount, 'payment_received', v_payment_id, NULL
    );
  END IF;
  -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

  -- D2: ruteo OPERACIONAL intra-tx — bank_movement solo para métodos bancarios.
  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := CASE WHEN p_payment_method = 'card' THEN 'card_settlement' ELSE 'transfer_in' END;

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      p_amount,
      v_bank_movement_type,
      'payment_received',
      v_payment_id,
      public.reporting_local_today(),
      NULL,
      NULL
    );
  END IF;

  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentReceived',
    'CustomerAccount',
    v_customer_account_id,
    jsonb_build_object(
      'account_id',           v_account_id,
      'customer_account_id',  v_customer_account_id,
      'client_id',            p_client_id,
      'payment_id',           v_payment_id,
      'amount',               p_amount,
      'balance_after',        v_balance_after,
      'reference_sale_id',    p_reference_sale_id,
      'payment_method',       p_payment_method,
      'bank_account_id',      p_bank_account_id,
      'occurred_at',          now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',           v_payment_id,
    'customer_account_id',  v_customer_account_id,
    'balance_after',        v_balance_after,
    'replayed',             false,
    'operation_id',         v_new_op_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid, uuid) IS
  'caja-compras-cobranzas: suma p_cash_session_id opcional trailing — con
  payment_method=cash y sesión abierta, ingresa a la caja vía
  c28_register_cash_movement, tipo payment_received (positivo). Ausencia =
  no-op. payment_method se persiste en payments_received desde este change
  (OQ-1).';


-- ═════════════ (3c) rpc_register_payment_made — DROP + CREATE ════════════════
DROP FUNCTION IF EXISTS public.rpc_register_payment_made(
  text, uuid, numeric, uuid, text, uuid
);

CREATE FUNCTION public.rpc_register_payment_made(
  p_idempotency_key text,
  p_supplier_id uuid,
  p_amount numeric,
  p_reference_purchase_id uuid DEFAULT NULL::uuid,
  p_payment_method text DEFAULT 'cash'::text,
  p_bank_account_id uuid DEFAULT NULL::uuid,
  -- caja-compras-cobranzas (D5): espejo exacto de rpc_register_payment_received.
  p_cash_session_id uuid DEFAULT NULL::uuid
)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid                 uuid;
  v_account_id          uuid;
  v_supplier_account_id uuid;
  v_inserted            integer;
  v_existing_op         uuid;
  v_new_op_id           uuid;
  v_movement_id         uuid;
  v_payment_id          uuid;
  v_balance_after        numeric(15,2);
  v_bank_account         public.bank_accounts%ROWTYPE;
  v_bank_movement_type   text;
  v_bank_movement_id     uuid;
  v_supplier             uuid;
  -- caja-compras-cobranzas (D5):
  v_cash_movement_id     uuid;
  v_cash_session_status  text;
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

  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'invalid_amount: amount debe ser > 0, recibido: %', p_amount
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method IS NULL OR p_payment_method NOT IN ('cash', 'transfer', 'card', 'check') THEN
    RAISE EXCEPTION 'invalid_payment_method: % no está en la taxonomía {cash,transfer,card,check}',
      p_payment_method
      USING ERRCODE = 'P0400';
  END IF;

  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    IF p_bank_account_id IS NULL THEN
      RAISE EXCEPTION 'bank_account_required: payment_method=% exige p_bank_account_id', p_payment_method
        USING ERRCODE = 'P0400';
    END IF;

    SELECT * INTO v_bank_account
    FROM public.bank_accounts
    WHERE id = p_bank_account_id
      AND account_id = v_account_id;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'bank_account_not_found: %', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;

    IF NOT v_bank_account.is_active THEN
      RAISE EXCEPTION 'bank_account_inactive: la cuenta % está inactiva', p_bank_account_id
        USING ERRCODE = 'P0412';
    END IF;
  END IF;

  -- caja-compras-cobranzas (D5): mismo guard que el cobro.
  IF p_cash_session_id IS NOT NULL AND p_payment_method IS DISTINCT FROM 'cash' THEN
    RAISE EXCEPTION 'cash_optin_requires_cash_kind: p_cash_session_id sólo aplica si payment_method=cash (recibido: %)', p_payment_method
      USING ERRCODE = 'P0422';
  END IF;

  -- cuenta-corriente-party-guard (D1 capa 2 / D2): el proveedor tiene que
  -- pertenecer al tenant.
  SELECT id INTO v_supplier
  FROM public.suppliers
  WHERE id = p_supplier_id AND account_id = v_account_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'supplier_not_found: %', p_supplier_id USING ERRCODE = 'P0404';
  END IF;

  -- Idempotencia DEC-06 (OQ-5 C-30): operation_kind='payment_made'
  v_new_op_id := gen_random_uuid();

  INSERT INTO public.operation_idempotency
    (user_id, idempotency_key, operation_kind, operation_id)
  VALUES
    (v_uid, p_idempotency_key, 'payment_made', v_new_op_id)
  ON CONFLICT (user_id, operation_kind, idempotency_key) DO NOTHING;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;

  IF v_inserted = 0 THEN
    SELECT operation_id INTO v_existing_op
    FROM public.operation_idempotency
    WHERE user_id = v_uid
      AND operation_kind = 'payment_made'
      AND idempotency_key = p_idempotency_key;

    RETURN jsonb_build_object(
      'payment_id',          NULL,
      'supplier_account_id', NULL,
      'balance_after',       NULL,
      'replayed',            true,
      'operation_id',        v_existing_op
    );
  END IF;

  v_supplier_account_id := public.c30_get_or_create_supplier_account(v_account_id, p_supplier_id);

  v_payment_id := gen_random_uuid();
  v_movement_id := public.c30_register_supplier_account_movement(
    v_supplier_account_id,
    -p_amount,
    'payment_made',
    v_payment_id
  );

  SELECT balance_after INTO v_balance_after
  FROM public.supplier_account_movements
  WHERE id = v_movement_id;

  -- caja-compras-cobranzas (OQ-1): payment_method persistido en la fila.
  INSERT INTO public.payments_made
    (id, account_id, supplier_account_id, supplier_id, amount, reference_purchase_id, movement_id, created_by, payment_method)
  VALUES
    (v_payment_id, v_account_id, v_supplier_account_id, p_supplier_id, p_amount, p_reference_purchase_id, v_movement_id, v_uid, p_payment_method);

  -- ── caja-compras-cobranzas (D5) — OPT-IN DE CAJA, 2 condiciones ───────────
  IF p_cash_session_id IS NOT NULL THEN
    SELECT status INTO v_cash_session_status
    FROM public.cash_sessions
    WHERE id = p_cash_session_id;

    IF v_cash_session_status IS DISTINCT FROM 'open' THEN
      RAISE EXCEPTION 'cash_optin_requires_open_session: la sesión de caja debe estar abierta'
        USING ERRCODE = 'P0422';
    END IF;

    v_cash_movement_id := public.c28_register_cash_movement(
      p_cash_session_id, -p_amount, 'payment_made', v_payment_id, NULL
    );
  END IF;
  -- ── FIN OPT-IN DE CAJA ─────────────────────────────────────────────────────

  IF p_payment_method IN ('transfer', 'card', 'check') THEN
    v_bank_movement_type := 'transfer_out';

    v_bank_movement_id := public._register_bank_movement(
      p_bank_account_id,
      -p_amount,
      v_bank_movement_type,
      'payment_made',
      v_payment_id,
      public.reporting_local_today(),
      NULL,
      NULL
    );
  END IF;

  INSERT INTO public.events
    (account_id, event_type, aggregate_type, aggregate_id, payload, occurred_at)
  VALUES (
    v_account_id,
    'PaymentMade',
    'SupplierAccount',
    v_supplier_account_id,
    jsonb_build_object(
      'account_id',          v_account_id,
      'supplier_account_id', v_supplier_account_id,
      'supplier_id',         p_supplier_id,
      'payment_id',          v_payment_id,
      'amount',              p_amount,
      'balance_after',       v_balance_after,
      'payment_method',      p_payment_method,
      'bank_account_id',     p_bank_account_id,
      'occurred_at',         now()
    ),
    now()
  );

  RETURN jsonb_build_object(
    'payment_id',          v_payment_id,
    'supplier_account_id', v_supplier_account_id,
    'balance_after',       v_balance_after,
    'replayed',            false,
    'operation_id',        v_new_op_id
  );
END;
$function$;

REVOKE ALL     ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid, uuid) IS
  'caja-compras-cobranzas: espejo exacto de rpc_register_payment_received —
  p_cash_session_id opcional trailing, egresa de la caja (payment_made,
  negativo) con payment_method=cash y sesión abierta. payment_method se
  persiste desde este change (OQ-1).';


-- ═════════ (4) rpc_delete_purchase_operation — CREATE OR REPLACE ═════════════
-- Firma NO cambia — CREATE OR REPLACE alcanza, conserva ACLs (D6).
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
  v_reversed_type        text;
  -- caja-compras-cobranzas (D7):
  v_cashbox_id           uuid;
  v_cash_amount          numeric(12,2);
  v_open_session_id      uuid;
  v_cash_reversal_id     uuid;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM public.current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

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

  -- ── Cuenta corriente de proveedor: reversión del cargo (debit_note, P0425 si negativo) ──
  SELECT supplier_account_id, SUM(amount)
  INTO v_supplier_account_id, v_charge_amount
  FROM public.supplier_account_movements
  WHERE reference_id = v_operation_key AND movement_type = 'purchase'
  GROUP BY supplier_account_id;

  IF v_supplier_account_id IS NOT NULL AND v_charge_amount > 0 THEN
    PERFORM public._pay_reverse_party_charge(
      v_account_id, 'supplier', v_supplier_account_id, v_charge_amount,
      v_operation_key, v_operation_key
    );
  END IF;

  -- ── caja-compras-cobranzas (D7) — CAJA: contra-movimiento por EXISTENCIA ──
  -- Molde exacto de rpc_delete_expense. ⚠️ El guard es `<> 0`, NUNCA `> 0` ni
  -- `< 0`: existe movimiento de caja de la compra ⇒ SIEMPRE se compensa,
  -- cualquiera sea el signo. Condicionarlo al signo esperado dejaría pasar el
  -- borrado sin compensar y SIN levantar P0426 (el modo de falla exacto que
  -- motivó delete-guard-ledgers). La sesión ORIGINAL nunca se toca —
  -- append-only (RN-99); el contra-movimiento va SIEMPRE a la sesión abierta
  -- ACTUAL de la MISMA caja.
  SELECT cs.cashbox_id, v_sum.total
  INTO v_cashbox_id, v_cash_amount
  FROM (
    SELECT session_id, SUM(amount) AS total
    FROM public.cash_movements
    WHERE reference_id = v_operation_key AND movement_type = 'purchase_payment'
    GROUP BY session_id
  ) v_sum
  JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

  IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN
    SELECT id INTO v_open_session_id
    FROM public.cash_sessions
    WHERE cashbox_id = v_cashbox_id AND status = 'open'
    ORDER BY opened_at DESC
    LIMIT 1;

    IF v_open_session_id IS NULL THEN
      RAISE EXCEPTION 'no_open_session_for_reversal: abrí la caja para poder borrar esta compra'
        USING ERRCODE = 'P0426';
    END IF;

    -- El movimiento de la compra es NEGATIVO (egreso), así que -v_cash_amount
    -- da el INGRESO positivo que repone la plata en el cajón. Si por
    -- cualquier camino llegara con el signo contrario, la contra-partida sale
    -- negativa y compensa igual: el opuesto exacto de lo posteado.
    v_cash_reversal_id := public.c28_register_cash_movement(
      v_open_session_id, -v_cash_amount, 'purchase_payment_reversal', v_operation_key, 'Reversión por borrado de compra'
    );
  END IF;
  -- ── FIN CAJA ───────────────────────────────────────────────────────────────

  -- ── Banco: espejo con dirección invertida ─────────────────────────────────
  FOR v_bank_row IN
    SELECT id, bank_account_id, amount, movement_type, branch_id
    FROM public.bank_movements
    WHERE source_doc_type = 'purchase' AND source_doc_ref = v_operation_key
  LOOP
    v_reversed_type := CASE v_bank_row.movement_type
      WHEN 'transfer_in'  THEN 'transfer_out'
      WHEN 'transfer_out' THEN 'transfer_in'
      ELSE v_bank_row.movement_type
    END;

    PERFORM public._register_bank_movement(
      v_bank_row.bank_account_id, -v_bank_row.amount, v_reversed_type,
      'purchase', v_operation_key, CURRENT_DATE, v_bank_row.branch_id,
      'Reversión por borrado de operación'
    );
  END LOOP;

  -- ── Reversa de stock (rpc_reverse_stock_movement, sin cambios — #417) ─────
  FOR v_row IN SELECT unnest(v_purchase_ids) AS id LOOP
    PERFORM public.rpc_reverse_stock_movement(v_row.id, 'purchase', COALESCE(p_reason, 'Compra eliminada'));
  END LOOP;

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

  RETURN true;
END;
$function$;

COMMENT ON FUNCTION public.rpc_delete_purchase_operation(uuid, uuid, text) IS
  'caja-compras-cobranzas (D7): suma la pata de caja como segunda compensación
  (después de cuenta corriente, antes de banco) — contra-movimiento
  purchase_payment_reversal por existencia (no por signo), P0426 si no hay
  sesión abierta en esa caja. Orden final: cta cte → caja → banco → stock →
  evento → DELETE.';


-- ══════ (5) rpc_atomic_update_purchase_operation — CREATE OR REPLACE ═════════
-- Firma NO cambia — CREATE OR REPLACE alcanza, conserva ACLs.
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

      v_prev_snap := v_old_snapshots -> v_item.product_id::text;
      v_line_snap := public.op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost);

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
        v_final_branch_id, v_item.quantity, 'purchase', v_new_purchase_id, 'purchase',
        v_new_op_id, (v_line_snap->>'unit_cost_snapshot')::numeric,
        'Aplicación por edición de operación', NULL
      );

    ELSE
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
$function$;

COMMENT ON FUNCTION public.rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb, uuid, boolean, uuid, boolean, uuid, boolean, uuid, boolean) IS
  'caja-compras-cobranzas (D8): el guard P0423 suma un tercer EXISTS contra
  cash_movements (movement_type=purchase_payment) — una compra con caja
  posteada también pasa a ser inmutable. Mismo predicado en el derivado de
  lectura del listado (backend/repositories/purchase_repository.py).';
