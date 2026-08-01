-- ═══════════════════════════════════════════════════════════════════════════
-- Crea el RPC public.increment_seguros_clicks — faltante desde que shipeó la
-- feature de seguros (2026-03), detectado por el nuevo gate CI del frontend
-- (scripts/ci/check_frontend_table_refs.py, PR #350).
-- ═══════════════════════════════════════════════════════════════════════════
--
-- HALLAZGO: frontend/lib/services/insuranceService.ts:116 llama
--   supabase.rpc("increment_seguros_clicks", { row_id: id })
-- Esa función nunca se creó — confirmado que NO existe ni en prod
-- (gxdhpxvdjjkmxhdkkwyb, verificado via MCP execute_sql de solo lectura) ni
-- en ningún archivo de esta cadena de migraciones (grep vacío). El propio
-- código ya tenía un fallback defensivo (líneas 117-121 de ese archivo, sin
-- tocar en esta migración): ante el error del RPC hace un `select` + `update`
-- NO ATÓMICO de `clicks_count`. Ese fallback corría SIEMPRE en prod desde el
-- día uno — el RPC "rápido" nunca existió —, con riesgo de lost-update si
-- dos usuarios incrementan la misma fila casi al mismo tiempo (dos lecturas
-- del mismo valor viejo, dos updates, se pierde un incremento).
--
-- Esta migración crea el RPC que el frontend siempre esperó, con un
-- incremento atómico que además cierra esa carrera:
--   UPDATE community.seguros SET clicks_count = COALESCE(clicks_count,0)+1
--   WHERE id = row_id
--
-- Nombre/schema: `public.increment_seguros_clicks` (NO `community.*`).
-- Motivo: la llamada en insuranceService.ts usa el cliente supabase-js por
-- defecto (`const supabase = createClient()`, sin `.schema('community')`
-- para ESTA llamada puntual — sí lo usa para `.from('seguros')` en otras
-- líneas del mismo archivo, pero no para `.rpc(...)`). PostgREST resuelve
-- `.rpc(...)` contra el schema `public` salvo que se indique lo contrario,
-- así que la función tiene que vivir ahí para que ese literal exacto
-- resuelva sin tocar el frontend.
--
-- SECURITY DEFINER: `community.seguros` tiene RLS con una sola policy de
-- escritura ("Admins have full access", FOR ALL, requiere
-- profiles.role = 'admin' — ver 20260310000005_create_seguros.sql). Un
-- usuario `authenticated` común (los dos callers actuales de
-- insuranceService, frontend/app/(dashboard)/{admin/,}seguros/page.tsx, son
-- rutas del dashboard autenticado, no landing pública) NO puede hacer
-- UPDATE ahí directamente por RLS — necesita DEFINER para correr con los
-- privilegios del owner de la función y esquivar esa restricción admin-only,
-- igual que el resto de los RPCs de "click"/contador de este proyecto.
--
-- `SET search_path = ''` + referencia fully-qualified (`community.seguros`)
-- en vez de `SET search_path = public`: evita depender del search_path si la
-- tabla se vuelve a mover de schema (ya pasó una vez con C-23/v20-community-
-- schema-split, ver 20260615000001_community_schema_move.sql).

CREATE OR REPLACE FUNCTION public.increment_seguros_clicks(row_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE community.seguros
  SET clicks_count = COALESCE(clicks_count, 0) + 1
  WHERE id = row_id;
END;
$$;

-- Regla dura del proyecto (advisors 0028/0029, ver supabase/tests/
-- test_function_acl_gate.sql): REVOKE FROM PUBLIC solo no alcanza para una
-- SECURITY DEFINER recién creada — los default privileges de un CREATE
-- fresco le regalan EXECUTE a `anon` también, hay que revocarlo explícito.
-- El gate de ACLs corta el CI si esto falta.
REVOKE EXECUTE ON FUNCTION public.increment_seguros_clicks(uuid) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.increment_seguros_clicks(uuid) TO authenticated;
