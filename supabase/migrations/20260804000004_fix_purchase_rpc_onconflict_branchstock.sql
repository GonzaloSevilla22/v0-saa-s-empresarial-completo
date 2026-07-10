-- =============================================================================
-- MIGRATION: 20260804000004_fix_purchase_rpc_onconflict_branchstock.sql
-- CHANGE:    Hotfix de producción — rpc_create_purchase_operation rota
--            (POST /purchases → 500 "Error interno de base de datos")
--
-- SÍNTOMA: toda compra falla con 500. Logs de Postgres:
--   ERROR: there is no unique or exclusion constraint matching the ON CONFLICT
--   specification
--
-- CAUSA RAÍZ (dos regresiones introducidas al copiar un cuerpo pre-C-21 en los
-- CREATE OR REPLACE de cost-center-dimension [20260802000001] y journal-entry-outbox
-- [20260803000002]):
--
--   BUG 1 (el que dispara el 500, antes de tocar stock):
--     INSERT ... operation_idempotency ... ON CONFLICT (user_id, idempotency_key)
--     El único índice único de operation_idempotency es
--     operation_idempotency_user_kind_key_unique (user_id, operation_kind, idempotency_key).
--     No existe constraint sobre (user_id, idempotency_key) → 42P10 en CADA compra.
--
--   BUG 2 (latente, líneas con producto): el cuerpo seguía leyendo/escribiendo
--     public.products.stock:
--       SELECT id, stock, ... FROM products
--       UPDATE public.products SET stock = stock + v_qty_norm ...
--     pero C-21 (20260623000001) DROPeó products.stock — branch_stock es el único
--     ledger de inventario. Aunque se arregle el BUG 1, las compras de producto
--     fallarían en "column stock does not exist".
--
-- FIX (restaura el patrón canónico de C-21 §5c, preservando TODO lo agregado
--      después: validación de branch_id/cost_center_id, propagación de cost_center_id
--      y la emisión del evento PurchaseCreated al outbox en la misma tx — DEC-20):
--   1. ON CONFLICT (user_id, operation_kind, idempotency_key)  [+ replay SELECT con
--      operation_kind = 'purchase'].
--   2. SELECT id, user_id, is_variant, name FROM products FOR UPDATE  (sin stock).
--   3. before/after = Σ branch_stock; PERFORM c21_apply_branch_stock_delta(
--      v_account_id, product_id, p_branch_id, +v_qty_norm)  (escritura de stock C-21).
--
-- SIN cambio de firma: rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid).
-- El backend lo llama con (key, date, desc, items, NULL, cost_center_id) — sin cambios.
-- La emisión doble NO aplica: el POST /purchases usa repo.create_operation (sin evento
-- Python); el único emisor de PurchaseCreated en ese path es esta RPC.
--
-- GOVERNANCE: MEDIO (lógica de negocio: stock + idempotencia; restaura comportamiento
--   conocido-bueno de C-21; sin cambio de firma ni de datos).
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration — desincroniza el history)
--
-- ROLLBACK: reaplicar la definición de 20260803000002_purchase_created_producer.sql
--   (re-introduce ambos bugs — no recomendado).
--
-- NOTA (fuera de alcance, detectado en los logs): el consumer del outbox
--   (rpc_process_outbox_dispatch / _journal_post_from_event) falla con
--   'null value in column "operation_id" of relation "operation_idempotency"' al
--   procesar eventos (p.ej. SaleConfirmed). Eso NO bloquea ventas/compras (es el
--   posteo asíncrono al journal). Se trata por separado.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_create_purchase_operation(
    p_idempotency_key  text,
    p_date             date,
    p_description      text,
    p_items            jsonb,
    p_branch_id        uuid DEFAULT NULL,
    p_cost_center_id   uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
/*
  Hotfix 20260804000004: corrige ON CONFLICT (3 columnas) y escritura de stock
  vía branch_stock (C-21). Preserva cost-center-dimension + el productor
  PurchaseCreated de journal-entry-outbox (DEC-20: evento en la misma tx).
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
    v_stock_sum       numeric(15,4);   -- C-21: Σ branch_stock (reemplaza products.stock)
    v_inserted        integer;
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

    -- FIX BUG 1: el índice único es (user_id, operation_kind, idempotency_key).
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
            -- FIX BUG 2: FOR UPDATE = mutex por producto, SIN leer products.stock (DROPeado en C-21)
            SELECT id, user_id, is_variant, name INTO v_product
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

            -- FIX BUG 2: stock sobre branch_stock (C-21). before/after = Σ branch_stock.
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
            'payment_method', 'credit',
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

COMMENT ON FUNCTION public.rpc_create_purchase_operation(text, date, text, jsonb, uuid, uuid) IS
    'cost-center-dimension + journal-entry-outbox + hotfix 20260804000004: '
    'Compra multi-línea idempotente. Stock sobre branch_stock vía c21_apply_branch_stock_delta (C-21), '
    'NO products.stock. ON CONFLICT (user_id, operation_kind, idempotency_key). '
    'Emite PurchaseCreated al outbox en la misma tx (DEC-20). SECURITY DEFINER. REVOCADO de anon/PUBLIC.';


-- ============================================================
-- Gate de introspección (corre SIEMPRE, incl. prod): garantiza que el cuerpo
-- desplegado tiene los dos fixes y no reaparece ninguna de las dos regresiones.
-- ============================================================
DO $gate$
DECLARE
  v_def text;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'rpc_create_purchase_operation'
    AND p.pronargs = 6;

  IF v_def IS NULL THEN
    RAISE EXCEPTION 'GATE FAILED: rpc_create_purchase_operation(6-arg) no existe tras el CREATE OR REPLACE';
  END IF;

  -- BUG 1 corregido: ON CONFLICT de 3 columnas presente.
  IF v_def NOT ILIKE '%on conflict (user_id, operation_kind, idempotency_key)%' THEN
    RAISE EXCEPTION 'GATE FAILED: ON CONFLICT no usa (user_id, operation_kind, idempotency_key)';
  END IF;

  -- BUG 2 corregido: sin escritura a products.stock; usa branch_stock.
  IF v_def ILIKE '%update public.products%set%stock%' OR v_def ILIKE '%stock = stock +%' THEN
    RAISE EXCEPTION 'GATE FAILED: el cuerpo todavía escribe products.stock (DROPeado en C-21)';
  END IF;
  IF v_def NOT ILIKE '%c21_apply_branch_stock_delta%' OR v_def NOT ILIKE '%branch_stock%' THEN
    RAISE EXCEPTION 'GATE FAILED: el cuerpo no escribe stock vía branch_stock/c21_apply_branch_stock_delta';
  END IF;

  RAISE NOTICE 'fix-purchase-rpc gate OK: ON CONFLICT 3-col + branch_stock, sin products.stock';
END
$gate$;
