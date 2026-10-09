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
$function$

