-- BASELINE VIVO capturado de prod (gxdhpxvdjjkmxhdkkwyb) el 2026-08-25 via
-- pg_get_functiondef.
CREATE OR REPLACE FUNCTION public.rpc_close_branch(p_branch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_uid          uuid;
  v_account_id   uuid;
  v_branch       RECORD;
  v_stock        numeric;
  v_other_active integer;
BEGIN
  v_uid := (SELECT auth.uid());
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege';
  END IF;

  SELECT cai INTO v_account_id FROM current_account_ids() AS cai LIMIT 1;
  IF v_account_id IS NULL THEN
    RAISE EXCEPTION 'Usuario sin cuenta activa' USING ERRCODE = 'P0403';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can close a branch'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT id, status INTO v_branch
  FROM   public.branches
  WHERE  id = p_branch_id AND account_id = v_account_id AND is_active = TRUE
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found' USING ERRCODE = 'P0404';
  END IF;

  IF v_branch.status = 'closed' THEN
    RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'closed', 'changed', false);
  END IF;

  -- OQ-B: cierre bloqueado si la sucursal tiene stock (transferir primero)
  SELECT COALESCE(SUM(quantity), 0) INTO v_stock
  FROM   public.branch_stock
  WHERE  branch_id = p_branch_id;

  IF v_stock > 0 THEN
    RAISE EXCEPTION 'branch_has_stock: la sucursal tiene % unidades — transferí el stock antes de cerrarla', v_stock
      USING ERRCODE = 'P0409';
  END IF;

  -- D6: debe quedar al menos una sucursal operativa en la cuenta
  SELECT count(*) INTO v_other_active
  FROM   public.branches
  WHERE  account_id = v_account_id AND is_active = TRUE
    AND  status = 'active' AND id <> p_branch_id;

  IF v_other_active = 0 THEN
    RAISE EXCEPTION 'last_active_branch: no se puede cerrar la única sucursal operativa de la cuenta'
      USING ERRCODE = 'P0409';
  END IF;

  UPDATE public.branches
  SET    status = 'closed', closed_at = now()
  WHERE  id = p_branch_id;

  RETURN jsonb_build_object('branch_id', p_branch_id, 'status', 'closed', 'changed', true);
END;
$function$
