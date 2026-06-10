-- C-23 v20-community-schema-split — Migración A (inocua, pre-corte)
-- Crea el schema community con grants equivalentes a public.
-- Las tablas se mueven en la migración B (corte coordinado).

CREATE SCHEMA IF NOT EXISTS community;

GRANT USAGE ON SCHEMA community TO postgres, anon, authenticated, service_role;

-- Privilegios por defecto para objetos futuros, espejo de public
ALTER DEFAULT PRIVILEGES IN SCHEMA community
  GRANT ALL ON TABLES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA community
  GRANT ALL ON SEQUENCES TO postgres, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA community
  GRANT ALL ON FUNCTIONS TO postgres, anon, authenticated, service_role;
