-- BASELINE VIVO capturado de prod (gxdhpxvdjjkmxhdkkwyb) el 2026-08-25 via
-- pg_get_functiondef. NO se toca en este change; se captura por completitud
-- del barrido (task 1.3/2.1) -- su INSERT sobre branches es alta perezosa
-- (INSERT-only), el disparador BEFORE UPDATE OR DELETE no lo alcanza.
CREATE OR REPLACE FUNCTION public.c21_apply_branch_stock_delta(p_account_id uuid, p_product_id uuid, p_branch_id uuid, p_delta numeric)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_branch_id uuid := p_branch_id;
BEGIN
  IF p_account_id IS NULL OR p_product_id IS NULL
     OR p_delta IS NULL OR p_delta = 0 THEN
    RETURN;
  END IF;

  IF v_branch_id IS NULL THEN
    v_branch_id := public.c26_default_branch(p_account_id);
  END IF;

  IF v_branch_id IS NULL THEN
    INSERT INTO public.branches (account_id, name, is_active, status, opened_at)
    VALUES (p_account_id, 'Casa Central', TRUE, 'active', now())
    ON CONFLICT (account_id, name) DO NOTHING;

    v_branch_id := public.c26_default_branch(p_account_id);
  END IF;

  UPDATE public.branch_stock
  SET    quantity = quantity + p_delta
  WHERE  product_id = p_product_id AND branch_id = v_branch_id;

  IF NOT FOUND THEN
    INSERT INTO public.branch_stock (account_id, product_id, branch_id, quantity)
    VALUES (p_account_id, p_product_id, v_branch_id, p_delta);
  END IF;
END;
$function$
