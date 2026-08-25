-- BASELINE VIVO capturado de prod (gxdhpxvdjjkmxhdkkwyb) el 2026-08-25 via
-- pg_get_functiondef.
CREATE OR REPLACE FUNCTION public.rpc_create_branch(p_account_id uuid, p_name text, p_address text DEFAULT NULL::text)
 RETURNS branches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_plan            TEXT;
  v_max_branches    INTEGER;
  v_has_module      BOOLEAN;
  v_active_count    INTEGER;
  v_new_branch      public.branches;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.account_members
    WHERE account_id = p_account_id
      AND user_id    = auth.uid()
  ) THEN
    RAISE EXCEPTION 'unauthorized'
      USING ERRCODE = 'P0401';
  END IF;

  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can create branches'
      USING ERRCODE = 'P0401';
  END IF;

  SELECT
    pl.max_branches,
    pl.has_branches_module
  INTO v_max_branches, v_has_module
  FROM public.accounts a
  JOIN public.plan_limits pl ON pl.plan = a.billing_plan
  WHERE a.id = p_account_id;

  IF NOT FOUND OR NOT v_has_module THEN
    RAISE EXCEPTION 'branch_limit_exceeded: branches module requires pro plan'
      USING ERRCODE = 'P0403';
  END IF;

  SELECT COUNT(*) INTO v_active_count
  FROM public.branches
  WHERE account_id = p_account_id
    AND is_active  = TRUE;

  IF v_active_count >= v_max_branches THEN
    RAISE EXCEPTION 'branch_limit_exceeded: plan allows % branches, account has %',
      v_max_branches, v_active_count
      USING ERRCODE = 'P0403';
  END IF;

  BEGIN
    INSERT INTO public.branches (account_id, name, address)
    VALUES (p_account_id, p_name, p_address)
    RETURNING * INTO v_new_branch;
  EXCEPTION
    WHEN unique_violation THEN
      RAISE EXCEPTION 'branch_name_duplicate: a branch named % already exists in this account', p_name
        USING ERRCODE = 'P0409';
  END;

  RETURN v_new_branch;
END;
$function$
