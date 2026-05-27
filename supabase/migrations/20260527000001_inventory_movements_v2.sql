-- =============================================================================
-- MIGRATION: 20260527000001_inventory_movements_v2.sql
-- DESCRIPTION: Enhance the stock_movements table for ERP-grade inventory tracking.
--
-- Changes:
--   1. Add audit columns: quantity_before, quantity_after, reason, performed_by, metadata
--   2. Expand type CHECK to cover all movement categories (12 total)
--   3. Expand reference_type CHECK to cover update operations
--   4. Create rpc_stock_adjustment — manual inventory adjustment RPC
--      Supports: adjustment, physical_count, loss, damage, expiry, transfer_in/out
--
-- Design Principles:
--   - quantity_before + quantity_delta = quantity_after (enforced in RPC logic)
--   - Stock never goes negative (enforced in RPC)
--   - physical_count: caller provides new absolute qty; delta = new - old
--   - All other types: caller provides delta (positive = inbound, negative = outbound)
-- =============================================================================

-- ── 1. Add new audit columns ──────────────────────────────────────────────────
ALTER TABLE public.stock_movements
  ADD COLUMN IF NOT EXISTS quantity_before numeric,
  ADD COLUMN IF NOT EXISTS quantity_after  numeric,
  ADD COLUMN IF NOT EXISTS reason          text,
  ADD COLUMN IF NOT EXISTS performed_by    uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS metadata        jsonb DEFAULT '{}'::jsonb;

-- ── 2. Drop old narrow CHECK constraints and replace with expanded ones ────────
-- We use pg_get_constraintdef to find constraints by content (not by name),
-- because PostgreSQL auto-generates names that may vary across environments.
DO $$
DECLARE
  v_name text;
BEGIN
  -- Drop the CHECK constraint on the `type` column
  SELECT conname INTO v_name
  FROM pg_constraint
  WHERE conrelid = 'public.stock_movements'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%type = ANY%'
    AND conname NOT LIKE '%reference%'
  LIMIT 1;
  IF v_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.stock_movements DROP CONSTRAINT ' || quote_ident(v_name);
  END IF;

  -- Drop the CHECK constraint on the `reference_type` column
  SELECT conname INTO v_name
  FROM pg_constraint
  WHERE conrelid = 'public.stock_movements'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%reference_type = ANY%'
  LIMIT 1;
  IF v_name IS NOT NULL THEN
    EXECUTE 'ALTER TABLE public.stock_movements DROP CONSTRAINT ' || quote_ident(v_name);
  END IF;
END;
$$;

-- Add expanded type constraint
ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_type_check
  CHECK (type = ANY (ARRAY[
    'purchase',          -- stock inbound via supplier purchase
    'sale',              -- stock outbound via customer sale
    'adjustment',        -- manual correction (positive or negative)
    'return',            -- legacy: generic return
    'initial',           -- initial stock load
    'sale_return',       -- reversal of a sale (e.g. when editing an operation)
    'purchase_return',   -- reversal of a purchase
    'physical_count',    -- physical inventory count reconciliation
    'loss',              -- stock loss (theft, unknown)
    'damage',            -- damaged goods written off
    'expiry',            -- expired product removed from inventory
    'transfer_in',       -- transfer in from another location/warehouse
    'transfer_out'       -- transfer out to another location/warehouse
  ]));

-- Add expanded reference_type constraint
ALTER TABLE public.stock_movements
  ADD CONSTRAINT stock_movements_reference_type_check
  CHECK (reference_type = ANY (ARRAY[
    'sale',
    'purchase',
    'adjustment',
    'initial',
    'sale_update',
    'purchase_update'
  ]));

-- ── 3. Additional index for audit queries ─────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_stock_movements_type
  ON public.stock_movements (user_id, type, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_stock_movements_performed_by
  ON public.stock_movements (performed_by)
  WHERE performed_by IS NOT NULL;

-- ── 4. rpc_stock_adjustment ────────────────────────────────────────────────────
-- Manual inventory adjustment RPC.
--
-- Parameters:
--   p_product_id     — product to adjust (must belong to auth.uid())
--   p_quantity_delta — signed delta: positive = add stock, negative = remove stock
--                      For physical_count: pass (new_qty - current_qty)
--   p_type           — movement type (see CHECK constraint above for allowed values)
--   p_reason         — short reason text (e.g. "Conteo semestral", "Producto dañado")
--   p_notes          — optional free-form notes
--   p_reference_id   — optional UUID reference to an external document
--
-- Returns:
--   jsonb with movement_id, product_id, product_name,
--   quantity_before, quantity_after, quantity_delta, type
-- =============================================================================
CREATE OR REPLACE FUNCTION public.rpc_stock_adjustment(
  p_product_id     uuid,
  p_quantity_delta numeric,
  p_type           text    DEFAULT 'adjustment',
  p_reason         text    DEFAULT NULL,
  p_notes          text    DEFAULT NULL,
  p_reference_id   uuid    DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_product     RECORD;
  v_qty_before  numeric;
  v_qty_after   numeric;
  v_movement_id uuid;
BEGIN
  -- ── Auth: identity from JWT only ─────────────────────────────────────────────
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  -- ── Validate movement type ───────────────────────────────────────────────────
  IF p_type NOT IN (
    'adjustment', 'physical_count', 'loss', 'damage',
    'expiry', 'transfer_in', 'transfer_out'
  ) THEN
    RAISE EXCEPTION 'Invalid movement type for manual adjustment: %. '
      'Allowed: adjustment, physical_count, loss, damage, expiry, transfer_in, transfer_out',
      p_type
      USING ERRCODE = 'check_violation';
  END IF;

  -- ── Validate delta ───────────────────────────────────────────────────────────
  IF p_quantity_delta = 0 THEN
    RAISE EXCEPTION 'quantity_delta no puede ser cero' USING ERRCODE = 'check_violation';
  END IF;

  -- ── Lock product row (prevent concurrent adjustments) ─────────────────────
  SELECT id, stock, name, stock_control_type
  INTO v_product
  FROM public.products
  WHERE id = p_product_id AND user_id = v_uid
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Producto no encontrado o acceso denegado'
      USING ERRCODE = 'no_data_found';
  END IF;

  -- ── Compute before/after ─────────────────────────────────────────────────────
  v_qty_before := v_product.stock;
  v_qty_after  := v_product.stock + p_quantity_delta;

  -- ── Prevent negative stock ───────────────────────────────────────────────────
  IF v_qty_after < 0 THEN
    RAISE EXCEPTION 'Stock insuficiente. Disponible: %, solicitado quitar: %',
      v_qty_before, ABS(p_quantity_delta)
      USING ERRCODE = 'integrity_constraint_violation';
  END IF;

  -- ── Apply stock change ────────────────────────────────────────────────────────
  UPDATE public.products
  SET stock = v_qty_after
  WHERE id = p_product_id AND user_id = v_uid;

  -- ── Record movement ───────────────────────────────────────────────────────────
  INSERT INTO public.stock_movements (
    user_id,
    product_id,
    type,
    quantity_delta,
    quantity_before,
    quantity_after,
    reason,
    notes,
    performed_by,
    reference_id,
    reference_type
  ) VALUES (
    v_uid,
    p_product_id,
    p_type,
    p_quantity_delta,
    v_qty_before,
    v_qty_after,
    p_reason,
    p_notes,
    v_uid,
    p_reference_id,
    CASE WHEN p_reference_id IS NOT NULL THEN 'adjustment' ELSE NULL END
  )
  RETURNING id INTO v_movement_id;

  RETURN jsonb_build_object(
    'movement_id',     v_movement_id,
    'product_id',      p_product_id,
    'product_name',    v_product.name,
    'quantity_before', v_qty_before,
    'quantity_after',  v_qty_after,
    'quantity_delta',  p_quantity_delta,
    'type',            p_type
  );
END;
$$;

REVOKE ALL  ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rpc_stock_adjustment(uuid, numeric, text, text, text, uuid) TO authenticated;
