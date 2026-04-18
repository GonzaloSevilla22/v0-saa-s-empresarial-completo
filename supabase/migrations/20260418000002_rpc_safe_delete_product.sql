-- =============================================================================
-- MIGRATION: 20260418000002_rpc_safe_delete_product.sql
-- PURPOSE: Atomic RPC that safely deletes a product by first nullifying all
--          FK references, then performing the DELETE — all in one transaction.
--          Runs as SECURITY DEFINER to bypass RLS for the internal FK cleanup.
-- =============================================================================

CREATE OR REPLACE FUNCTION public.rpc_safe_delete_product(
  p_product_id uuid,
  p_user_id    uuid
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- 1. Ownership check (security: cannot delete other users' products)
  IF NOT EXISTS (
    SELECT 1 FROM public.products
    WHERE id = p_product_id AND user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'Producto no encontrado o sin permiso'
      USING ERRCODE = 'P0002';
  END IF;

  -- 2. Nullify FK in sales (preserves historical records, shows "Eliminado" in UI)
  UPDATE public.sales
  SET product_id = NULL
  WHERE product_id = p_product_id;

  -- 3. Nullify FK in purchases (same rationale)
  UPDATE public.purchases
  SET product_id = NULL
  WHERE product_id = p_product_id;

  -- 4. Detach variant products (self-referential FK on products.parent_id)
  UPDATE public.products
  SET parent_id = NULL
  WHERE parent_id = p_product_id;

  -- 5. Delete the product (no FK blockers remain at this point)
  DELETE FROM public.products
  WHERE id = p_product_id AND user_id = p_user_id;

END;
$$;

-- Grant execution to authenticated users (the function validates ownership internally)
GRANT EXECUTE ON FUNCTION public.rpc_safe_delete_product(uuid, uuid) TO authenticated;
