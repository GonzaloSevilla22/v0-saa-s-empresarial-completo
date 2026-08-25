-- BASELINE VIVO capturado de prod (gxdhpxvdjjkmxhdkkwyb) el 2026-08-25 via
-- pg_get_functiondef. Identico al capturado al proponer (2026-08-24) -- sin
-- sesiones paralelas que lo hayan tocado en el medio.
CREATE OR REPLACE FUNCTION public.rpc_deactivate_branch(p_branch_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_account_id UUID;
BEGIN
  SELECT account_id INTO v_account_id
  FROM public.branches
  WHERE id = p_branch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'branch_not_found'
      USING ERRCODE = 'P0404';
  END IF;

  IF NOT public.is_account_writer(v_account_id) THEN
    RAISE EXCEPTION 'unauthorized: only owner or admin can deactivate branches'
      USING ERRCODE = 'P0401';
  END IF;

  UPDATE public.branches
  SET is_active = FALSE
  WHERE id = p_branch_id;
END;
$function$
