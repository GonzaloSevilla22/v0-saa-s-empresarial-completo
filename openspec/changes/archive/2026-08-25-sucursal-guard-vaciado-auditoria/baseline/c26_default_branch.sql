-- BASELINE VIVO capturado de prod (gxdhpxvdjjkmxhdkkwyb) el 2026-08-25 via
-- pg_get_functiondef. NO se toca en este change; se captura por completitud
-- del barrido (task 1.3/2.1) -- solo LEE branches, no escribe.
CREATE OR REPLACE FUNCTION public.c26_default_branch(p_account_id uuid)
 RETURNS uuid
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    (SELECT b.id FROM public.branches b
      WHERE b.account_id = p_account_id AND b.is_active AND b.status = 'active'
      ORDER BY b.created_at ASC LIMIT 1),
    (SELECT b.id FROM public.branches b
      WHERE b.account_id = p_account_id
      ORDER BY b.created_at ASC LIMIT 1)
  );
$function$
