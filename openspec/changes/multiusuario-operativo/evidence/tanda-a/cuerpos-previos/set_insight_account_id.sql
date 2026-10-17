CREATE OR REPLACE FUNCTION public.set_insight_account_id()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.account_id IS NULL THEN
    NEW.account_id := (
      SELECT account_id FROM public.account_members
      WHERE user_id = NEW.user_id ORDER BY account_id LIMIT 1
    );
  END IF;
  RETURN NEW;
END;
$function$

-- ACL: {postgres=X/postgres,service_role=X/postgres}
-- COMMENT: (none)
