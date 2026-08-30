-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = 5fa1096b4c1481b36d6e04c8eaadbfdc - length = 469.
-- Rol en el change: REUSO SIN TOCAR: COALESCE(p_branch_id, c26_default_branch(cuenta)) para persistir branch_id (D6).
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

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
