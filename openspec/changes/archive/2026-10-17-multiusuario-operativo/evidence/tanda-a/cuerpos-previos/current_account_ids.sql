CREATE OR REPLACE FUNCTION public.current_account_ids()
 RETURNS SETOF uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT account_id
  FROM   public.account_members
  WHERE  user_id = (SELECT auth.uid())
$function$

-- ACL: {postgres=X/postgres,anon=X/postgres,authenticated=X/postgres,service_role=X/postgres}
-- COMMENT: (none)
