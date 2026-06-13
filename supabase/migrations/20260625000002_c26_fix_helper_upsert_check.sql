-- =============================================================================
-- MIGRATION: 20260625000002_c26_fix_helper_upsert_check.sql
-- CHANGE:    C-26 — HOTFIX del helper de escritura vs CHECK non-negative
--
-- BUG (detectado por smoke transaccional minutos después de 20260625000001):
--   `INSERT ... VALUES (p_delta) ON CONFLICT DO UPDATE SET quantity = quantity
--   + delta` falla con el CHECK `quantity >= 0` cuando p_delta < 0 AUNQUE la
--   fila exista y el UPDATE resultante fuera válido: Postgres valida los CHECK
--   constraints de la fila PROPUESTA antes de resolver el conflicto. Con el
--   CHECK de C-26 aplicado, TODA venta (delta negativo sobre fila existente)
--   reventaba con 23514.
--
-- FIX: UPDATE-then-INSERT.
--   - UPDATE: si deja negativo, el CHECK lo rechaza (red de seguridad — el
--     gate de los RPCs ya lo impide antes con error claro).
--   - INSERT solo si no existía la fila: delta positivo la crea; delta
--     negativo sin fila = no hay stock → el CHECK lo rechaza (correcto).
--   - Race UPDATE→INSERT: los RPCs lockean la fila del producto (FOR UPDATE)
--     antes de llamar al helper → serializado por producto.
--
-- Los demás writers no están afectados (sus VALUES propuestos son >= 0):
--   rpc_transfer_stock (GREATEST(0,…) / +qty), rpc_adjust_branch_stock
--   (set absoluto >= 0), rpc_bulk_upsert_products (set absoluto >= 0).
--
-- APPLY: npx supabase db push  (NUNCA MCP apply_migration)
-- =============================================================================

CREATE OR REPLACE FUNCTION public.c21_apply_branch_stock_delta(
  p_account_id uuid,
  p_product_id uuid,
  p_branch_id  uuid,
  p_delta      numeric
)
RETURNS void
LANGUAGE plpgsql
SET search_path TO 'public'
AS $$
DECLARE
  v_branch_id uuid := p_branch_id;
BEGIN
  IF p_account_id IS NULL OR p_product_id IS NULL
     OR p_delta IS NULL OR p_delta = 0 THEN
    RETURN;
  END IF;

  -- C-26: branch destino = la indicada, o la default OPERATIVA de la cuenta.
  IF v_branch_id IS NULL THEN
    v_branch_id := public.c26_default_branch(p_account_id);
  END IF;

  -- Cuenta sin branches (cuentas nuevas): lazy-create de la default.
  IF v_branch_id IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (p_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_branch_id := public.c26_default_branch(p_account_id);
  END IF;

  -- C-26 fix: UPDATE-then-INSERT — el upsert clásico (INSERT VALUES(delta)
  -- ON CONFLICT) viola el CHECK quantity >= 0 en la fase INSERT cuando
  -- delta < 0, aunque la fila exista y el resultado final fuera válido.
  UPDATE public.branch_stock
  SET    quantity = quantity + p_delta
  WHERE  product_id = p_product_id AND branch_id = v_branch_id;

  IF NOT FOUND THEN
    INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
    VALUES (p_account_id, p_product_id, v_branch_id, p_delta);
  END IF;
END;
$$;
