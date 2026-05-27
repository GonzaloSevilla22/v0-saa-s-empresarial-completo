-- Applied directly via MCP on 2026-04-26. Stub recovered from supabase_migrations.schema_migrations.
DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid);
  DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, uuid);
  DROP FUNCTION IF EXISTS public.rpc_atomic_log_ai_insight(uuid, text, text, text);
END;
$$
