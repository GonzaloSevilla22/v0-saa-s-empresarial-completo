-- C-23 v20-community-schema-split — Vista puente para resource embedding
-- PostgREST NO soporta embedding entre schemas distintos (posts → public.profiles
-- devolvía PGRST200). Esta vista expone profiles dentro de community para que
-- `select=*,profiles(name)` siga resolviendo. security_invoker: la RLS de
-- public.profiles se evalúa con el rol del caller, semántica idéntica a la previa.
-- Ya aplicada en el corte vía SQL directo (CREATE OR REPLACE = idempotente).

CREATE OR REPLACE VIEW community.profiles
  WITH (security_invoker = true) AS
  SELECT id, name, avatar_url FROM public.profiles;
