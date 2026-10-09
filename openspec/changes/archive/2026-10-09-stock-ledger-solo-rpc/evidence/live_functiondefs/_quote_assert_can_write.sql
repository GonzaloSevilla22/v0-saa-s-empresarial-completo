CREATE OR REPLACE FUNCTION public._quote_assert_can_write(p_account_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT public.is_account_writer(p_account_id) THEN
    RAISE EXCEPTION 'unauthorized' USING ERRCODE = 'P0401';
  END IF;
  IF NOT (public.account_user_active_roles(p_account_id, auth.uid()) && ARRAY['seller', 'admin', 'owner']) THEN
    RAISE EXCEPTION 'insufficient_role: tu rol no permite gestionar presupuestos (requiere vendedor, administrador o dueño)'
      USING ERRCODE = 'P0403';
  END IF;
END;
$function$

