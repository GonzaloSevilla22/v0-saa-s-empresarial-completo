-- =============================================================================
-- MIGRATION: 20260520000001_rpc_atomic_update_sale_operation.sql
-- DESCRIPTION: Atomic RPC for editing an existing sale operation.
--
-- DESIGN PRINCIPLES:
--  1. Identity from auth.uid() only — never from caller input (CRITICAL-1 pattern)
--  2. SECURITY DEFINER + fixed search_path (prevents schema injection)
--  3. Reverse-delete-reinsert pattern inside a single transaction:
--       a) Restore stock for all old sale rows (stock += old.quantity)
--       b) DELETE old rows
--       c) INSERT new rows with FOR UPDATE lock on products (race-free stock check)
--  4. Phase 3 variant guard inherited from rpc_atomic_create_sale
--  5. Handles NULL product_id on old rows gracefully (product was deleted)
--  6. Assigns a fresh operation_id to all new rows
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(
  p_sale_ids  uuid[],
  p_client_id uuid,
  p_date      date,
  p_currency  text,
  p_items     jsonb    -- [{product_id uuid, amount numeric, quantity integer}]
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid          uuid;
  v_old_sale     RECORD;
  v_item         RECORD;
  v_product      RECORD;
  v_new_op_id    uuid;
  v_new_sale_id  uuid;
  v_result_items jsonb := '[]'::jsonb;
BEGIN
  -- Identity always comes from the JWT — never from caller input
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  IF array_length(p_sale_ids, 1) IS NULL OR array_length(p_sale_ids, 1) = 0 THEN
    RAISE EXCEPTION 'No sale IDs provided' USING ERRCODE = 'P400';
  END IF;

  -- Verify ownership: reject if any sale belongs to a different user
  IF EXISTS (
    SELECT 1 FROM public.sales
    WHERE id = ANY(p_sale_ids) AND user_id != v_uid
  ) THEN
    RAISE EXCEPTION 'Permission denied: sale belongs to another user' USING ERRCODE = 'P403';
  END IF;

  -- Verify all IDs exist
  IF (SELECT COUNT(*) FROM public.sales WHERE id = ANY(p_sale_ids))
      != array_length(p_sale_ids, 1)
  THEN
    RAISE EXCEPTION 'One or more sale IDs not found' USING ERRCODE = 'P404';
  END IF;

  -- ── STEP 1: REVERSE ─────────────────────────────────────────────────────────
  -- Restore stock for every original sale row that had a (non-deleted) product.
  -- UPDATE implicitly locks the product row for the duration of the transaction.
  FOR v_old_sale IN
    SELECT product_id, quantity
    FROM public.sales
    WHERE id = ANY(p_sale_ids)
  LOOP
    IF v_old_sale.product_id IS NOT NULL THEN
      UPDATE public.products
      SET stock = stock + v_old_sale.quantity
      WHERE id = v_old_sale.product_id AND user_id = v_uid;
    END IF;
  END LOOP;

  -- ── STEP 2: DELETE ──────────────────────────────────────────────────────────
  DELETE FROM public.sales WHERE id = ANY(p_sale_ids);

  -- ── STEP 3: APPLY NEW ITEMS ─────────────────────────────────────────────────
  v_new_op_id := gen_random_uuid();

  FOR v_item IN
    SELECT *
    FROM jsonb_to_recordset(p_items)
      AS x(product_id uuid, amount numeric, quantity integer)
  LOOP
    IF v_item.quantity <= 0 THEN
      RAISE EXCEPTION 'Quantity must be greater than zero' USING ERRCODE = 'P400';
    END IF;

    IF v_item.product_id IS NOT NULL THEN
      -- Lock product row FOR UPDATE — prevents concurrent stock exhaustion
      SELECT id, stock, user_id, is_variant INTO v_product
      FROM public.products
      WHERE id = v_item.product_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'Product not found: %', v_item.product_id USING ERRCODE = 'P404';
      END IF;

      IF v_product.user_id != v_uid THEN
        RAISE EXCEPTION 'Permission denied to product: %', v_item.product_id USING ERRCODE = 'P403';
      END IF;

      -- Phase 3: reject parent catalogue entries (those with variant children)
      IF NOT v_product.is_variant THEN
        IF EXISTS (SELECT 1 FROM public.products WHERE parent_id = v_item.product_id LIMIT 1) THEN
          RAISE EXCEPTION 'Este producto tiene variantes. Seleccioná una variante específica para registrar la venta.'
            USING ERRCODE = 'P422';
        END IF;
      END IF;

      IF v_product.stock < v_item.quantity THEN
        RAISE EXCEPTION 'Insufficient stock for product %', v_item.product_id USING ERRCODE = 'P409';
      END IF;

      INSERT INTO public.sales
        (user_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, p_client_id, v_item.product_id,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;

      UPDATE public.products
      SET stock = stock - v_item.quantity
      WHERE id = v_item.product_id;

    ELSE
      -- No product associated (edge case) — insert without stock management
      INSERT INTO public.sales
        (user_id, client_id, product_id, amount, quantity, total, currency, date, operation_id)
      VALUES
        (v_uid, p_client_id, NULL,
         v_item.amount, v_item.quantity, v_item.amount * v_item.quantity,
         p_currency, p_date, v_new_op_id)
      RETURNING id INTO v_new_sale_id;
    END IF;

    v_result_items := v_result_items
      || jsonb_build_object('id', v_new_sale_id, 'product_id', v_item.product_id);
  END LOOP;

  RETURN jsonb_build_object('operation_id', v_new_op_id, 'items', v_result_items);
END;
$$;

-- Explicit grants following project conventions
GRANT  EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb) FROM anon;
