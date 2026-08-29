-- Baseline capturado de PROD (gxdhpxvdjjkmxhdkkwyb) el 2026-08-29, via
-- pg_get_functiondef(oid) -- task 1.6 de gastos-forma-pago.
-- MAX(version) al momento de la captura: 20261014000001 (263 migraciones).
-- md5(pg_get_functiondef) = 83e9af886e5b9317c1e4aa90b83e3659 - length = 184.
-- Rol en el change: REUSO SIN TOCAR: dia local ART. Comparacion directa contra p_date date, nunca timestamptz::date (D1).
--
-- Procedencia del byte exacto: el cuerpo se materializo desde el stack local
-- (supabase db reset sobre las mismas 263 migraciones) y se verifico contra PROD
-- por md5 EXACTO del pg_get_functiondef vivo. El stack local guarda CR embebidos
-- (los .sql del working tree estan en CRLF por core.autocrlf=true), por eso el
-- hash se calcula sobre replace(def, chr(13), '') -- que da byte-identico a PROD.

CREATE OR REPLACE FUNCTION public.reporting_local_today()
 RETURNS date
 LANGUAGE sql
 STABLE
AS $function$
  SELECT (now() AT TIME ZONE 'America/Argentina/Mendoza')::date;
$function$
