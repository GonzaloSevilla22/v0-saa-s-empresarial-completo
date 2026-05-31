-- =============================================================================
-- ROLLBACK for: 20260528164840_drop_dead_rpc_overloads.sql
--
-- PURPOSE:
--   If you need to roll back app code to a version that still calls
--   rpc_atomic_create_sale / rpc_atomic_create_purchase, run this script
--   FIRST to restore those overloads before deploying the old app version.
--
-- WHEN TO USE:
--   Only if reverting to a commit prior to feat(p1): remove dead create-sale/
--   purchase paths (PR #89). The new rpc_create_sale_operation /
--   rpc_create_purchase_operation are NOT touched by this rollback.
--
-- HOW TO APPLY:
--   psql $DATABASE_URL -f supabase/migrations_bak/rollback_20260528164840_drop_dead_rpc_overloads.sql
--   OR via Supabase dashboard SQL editor.
-- =============================================================================

-- ── 5-arg sale overload (original v1, was dead code) ──────────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_user_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid;
  v_sale_id  uuid;
  v_qty_norm numeric(15,4) := p_quantity::numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.sales (user_id, client_id, product_id, amount, quantity, total, currency, date)
  VALUES (v_uid, p_client_id, p_product_id, p_amount, p_quantity, p_amount * p_quantity, 'ARS', CURRENT_DATE)
  RETURNING id INTO v_sale_id;
  UPDATE public.products SET stock = stock - v_qty_norm WHERE id = p_product_id;
  RETURN jsonb_build_object('id', v_sale_id);
END;
$$;

-- ── 7-arg sale overload (was production path, now replaced by rpc_create_sale_operation) ──
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_sale(
  p_client_id  uuid,
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   numeric,
  p_unit_id    uuid,
  p_currency   text,
  p_date       date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_sale_id     uuid;
  v_unit_factor numeric(20,10) := 1.0;
  v_qty_norm    numeric(15,4);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_unit_id IS NOT NULL THEN
    SELECT factor INTO v_unit_factor FROM public.units_of_measure WHERE id = p_unit_id;
  END IF;
  v_qty_norm := (p_quantity * v_unit_factor)::numeric(15,4);
  INSERT INTO public.sales (user_id, client_id, product_id, amount, quantity, unit_id, total, currency, date)
  VALUES (v_uid, p_client_id, p_product_id, p_amount, p_quantity, p_unit_id, p_amount * p_quantity, p_currency, p_date)
  RETURNING id INTO v_sale_id;
  UPDATE public.products SET stock = stock - v_qty_norm WHERE id = p_product_id;
  RETURN jsonb_build_object('id', v_sale_id);
END;
$$;

-- ── 4-arg purchase overload (original v1, was dead code) ──────────────────────
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id uuid,
  p_amount     numeric,
  p_quantity   integer,
  p_user_id    uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_purchase_id uuid;
  v_qty_norm    numeric(15,4) := p_quantity::numeric;
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO public.purchases (user_id, product_id, amount, quantity, total, date)
  VALUES (v_uid, p_product_id, p_amount, p_quantity, p_amount * p_quantity, CURRENT_DATE)
  RETURNING id INTO v_purchase_id;
  UPDATE public.products SET stock = stock + v_qty_norm WHERE id = p_product_id;
  RETURN jsonb_build_object('id', v_purchase_id);
END;
$$;

-- ── 6-arg purchase overload (was production path, now replaced by rpc_create_purchase_operation) ──
CREATE OR REPLACE FUNCTION public.rpc_atomic_create_purchase(
  p_product_id  uuid,
  p_amount      numeric,
  p_quantity    numeric,
  p_unit_id     uuid,
  p_description text,
  p_date        date
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid         uuid;
  v_purchase_id uuid;
  v_unit_factor numeric(20,10) := 1.0;
  v_qty_norm    numeric(15,4);
BEGIN
  v_uid := auth.uid();
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;
  IF p_unit_id IS NOT NULL THEN
    SELECT factor INTO v_unit_factor FROM public.units_of_measure WHERE id = p_unit_id;
  END IF;
  v_qty_norm := (p_quantity * v_unit_factor)::numeric(15,4);
  INSERT INTO public.purchases (user_id, product_id, amount, quantity, unit_id, total, description, date)
  VALUES (v_uid, p_product_id, p_amount, p_quantity, p_unit_id, p_amount * p_quantity, p_description, p_date)
  RETURNING id INTO v_purchase_id;
  UPDATE public.products SET stock = stock + v_qty_norm WHERE id = p_product_id;
  RETURN jsonb_build_object('id', v_purchase_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_sale(uuid, uuid, numeric, numeric, uuid, text, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, integer, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.rpc_atomic_create_purchase(uuid, numeric, numeric, uuid, text, date) TO authenticated;
