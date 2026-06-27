-- =============================================================================
-- MIGRATION: 20260803000002_purchase_created_producer.sql
-- CHANGE:    journal-entry-outbox
-- Design ref: openspec/changes/journal-entry-outbox/design.md (D9)
--
-- Agrega el productor PurchaseCreated a rpc_create_purchase_operation.
-- El INSERT de evento se realiza en la MISMA transacción que la compra (DEC-20).
-- Payload enriquecido: account_id, operation_id, total (Σ líneas), cost_center_id,
-- neto, iva_amount (se calculan de los items), occurred_at.
--
-- Task 4.1 (TDD RED→GREEN→TRIANGULATE):
--   RED:   test que una compra commitea 1 evento PurchaseCreated.
--   GREEN: productor agregado al RPC.
--   TRIANGULATE: rollback de compra → 0 eventos.
--
-- Task 4.3: se verifica que los productores SaleConfirmed/PaymentReceived/PaymentMade
--   ya existen y NO se re-crean.
--
-- IDEMPOTENCIA: CREATE OR REPLACE de rpc_create_purchase_operation.
-- APPLY: npx supabase db push (NUNCA MCP apply_migration).
-- =============================================================================

-- Agregar el productor PurchaseCreated como CREATE OR REPLACE de la función
-- (preservando toda la lógica existente de cost-center-dimension):

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
    p_idempotency_key  text,
    p_date             date,
    p_description      text,
    p_items            jsonb,
    p_branch_id        uuid DEFAULT NULL,
    p_cost_center_id   uuid DEFAULT NULL   -- cost-center-dimension: opcional
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
/*
  C-25 journal-entry-outbox (Task 4.1): agrega el productor PurchaseCreated.
  El INSERT de evento se realiza en la MISMA transacción que las INSERTs de compra,
  garantizando que un rollback de la compra también elimina el evento (DEC-20).

  Payload del evento PurchaseCreated:
    account_id, operation_id, total (Σ líneas), cost_center_id,
    neto (NULL hasta que haya IVA crédito fiscal en compras),
    iva_amount (NULL — future V2.6), occurred_at.

  La lógica de mapeo en _journal_post_from_event maneja el caso neto/iva=NULL
  como compra sin desglose de IVA (débito único 5100 [total]).

  Lógica de negocio sin cambios respecto a 20260802000001_cost_center_dimension.sql.
*/
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
    v_inserted        integer;
    -- journal-entry-outbox: totals para el payload del evento
    v_total_sum       numeric(15,2) := 0;
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
            USING ERRCODE = 'P403';
    END IF;

    IF p_idempotency_key IS NULL OR length(trim(p_idempotency_key)) = 0 THEN
        RAISE EXCEPTION 'idempotency_key is required' USING ERRCODE = 'P400';
    END IF;

    IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
        RAISE EXCEPTION 'p_items must be a non-empty array' USING ERRCODE = 'P400';
    END IF;

    IF jsonb_array_length(p_items) > 500 THEN
        RAISE EXCEPTION 'Too many items in a single operation (max 500)' USING ERRCODE = 'P400';
    END IF;

    -- Verify branch_id belongs to this account (if provided)
    IF p_branch_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.branches
            WHERE id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'branch_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
    END IF;

    -- cost-center-dimension: Verify cost_center_id belongs to this account (mirror of branch_id)
    IF p_cost_center_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1 FROM public.cost_centers
            WHERE id = p_cost_center_id AND account_id = v_account_id AND is_active = TRUE
        ) THEN
            RAISE EXCEPTION 'cost_center_not_found or not active for this account'
                USING ERRCODE = 'P404';
        END IF;
    END IF;

    v_new_op_id := gen_random_uuid();

    INSERT INTO public.operation_idempotency (user_id, idempotency_key, operation_kind, operation_id)
    VALUES (v_uid, p_idempotency_key, 'purchase', v_new_op_id)
    ON CONFLICT (user_id, idempotency_key) DO NOTHING;

    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    IF v_inserted = 0 THEN
        SELECT operation_id INTO v_existing_op
        FROM   public.operation_idempotency
        WHERE  user_id = v_uid AND idempotency_key = p_idempotency_key;

        SELECT COALESCE(
                   jsonb_agg(jsonb_build_object('id', p.id, 'product_id', p.product_id) ORDER BY p.id),
                   '[]'::jsonb
               )
        INTO   v_result_items
        FROM   public.purchases p
        WHERE  p.user_id = v_uid AND p.operation_id = v_existing_op;

        -- Idempotency replay: NO emitir evento duplicado (DEC-20)
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
            RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
        END IF;
        IF v_item.amount IS NULL OR v_item.amount <= 0 THEN
            RAISE EXCEPTION 'Amount must be greater than zero' USING ERRCODE = 'P400';
        END IF;

        v_unit_factor := 1.0;
        IF v_item.unit_id IS NOT NULL THEN
            SELECT factor INTO v_unit_factor
            FROM   public.units_of_measure
            WHERE  id = v_item.unit_id;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'Unit of measure not found: %', v_item.unit_id USING ERRCODE = 'P404';
            END IF;
        END IF;
        v_qty_norm := (v_item.quantity * v_unit_factor)::numeric(15,4);

        -- journal-entry-outbox: acumular total para el payload del evento
        v_total_sum := v_total_sum + (v_item.amount * v_item.quantity);

        IF v_item.product_id IS NOT NULL THEN
            SELECT id, stock, user_id, is_variant, name INTO v_product
            FROM   public.products
            WHERE  id = v_item.product_id
            FOR UPDATE;

            IF NOT FOUND THEN
                RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
            END IF;

            IF v_product.user_id <> v_uid THEN
                RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
            END IF;

            IF NOT v_product.is_variant THEN
                IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
                    RAISE EXCEPTION
                        'Este producto tiene variantes. Seleccioná una variante específica para registrar la compra.'
                        USING ERRCODE = 'P422';
                END IF;
            END IF;

            -- cost-center-dimension: p_cost_center_id propagated to all rows of this operation
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id)
            VALUES
                (v_uid, v_account_id, v_item.product_id,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id)
            RETURNING id INTO v_new_purchase_id;

            UPDATE public.products
            SET    stock = stock + v_qty_norm
            WHERE  id = v_item.product_id
            RETURNING stock - v_qty_norm, stock
            INTO   v_qty_before, v_qty_after;

            INSERT INTO public.stock_movements (
                user_id, account_id, product_id, product_name, type,
                quantity_delta, quantity_before, quantity_after,
                reference_id, reference_type, performed_by,
                operation_group_id, branch_id
            ) VALUES (
                v_uid, v_account_id, v_item.product_id, v_product.name, 'purchase',
                v_qty_norm, v_qty_before, v_qty_after,
                v_new_purchase_id, 'purchase', v_uid,
                v_new_op_id, p_branch_id
            );

        ELSE
            -- cost-center-dimension: p_cost_center_id propagated to non-product rows too
            INSERT INTO public.purchases
                (user_id, account_id, product_id, amount, quantity, unit_id,
                 total, description, date, operation_id, branch_id, cost_center_id)
            VALUES
                (v_uid, v_account_id, NULL,
                 v_item.amount, v_item.quantity, v_item.unit_id,
                 v_item.amount * v_item.quantity, p_description, p_date, v_new_op_id,
                 p_branch_id, p_cost_center_id)
            RETURNING id INTO v_new_purchase_id;
        END IF;

        v_result_items := v_result_items
            || jsonb_build_object('id', v_new_purchase_id, 'product_id', v_item.product_id);
    END LOOP;

    -- ── journal-entry-outbox (Task 4.1): emitir PurchaseCreated en la misma tx ─
    -- Payload enriquecido con cost_center_id para evitar lookup en el consumer.
    -- neto / iva_amount: NULL en V1 (sin desglose IVA crédito fiscal de compras).
    -- El consumer _journal_post_from_event trata neto=NULL como compra sin IVA (5100 único).
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
            'neto',           NULL,       -- V2.6: desglose IVA crédito fiscal de compras
            'iva_amount',     NULL,       -- V2.6: desglose IVA crédito fiscal de compras
            'payment_method', 'credit',   -- default: las compras son a crédito en V1
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
$$;

REVOKE ALL     ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) FROM anon;
GRANT  EXECUTE ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) TO authenticated;

COMMENT ON FUNCTION public.rpc_create_purchase_operation IS
    'cost-center-dimension + journal-entry-outbox (Task 4.1): '
    'Crea una operación de compra multi-línea con idempotencia, stock sobre branch_stock (C-21), '
    'y emite el evento PurchaseCreated al outbox en la MISMA transacción (DEC-20). '
    'En replay (idempotency hit) NO emite evento duplicado. '
    'Payload: {account_id, operation_id, total, cost_center_id, neto=NULL, iva_amount=NULL, payment_method}. '
    'SECURITY DEFINER. REVOCADO de anon/PUBLIC.';
