-- Drop old vulnerable RPC overloads that still accept p_user_id as a parameter.
-- Wrapped in a single DO block to avoid "multiple commands in prepared statement"
-- errors from the Supabase CLI migration runner.
DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid);
  DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, uuid);
  DROP FUNCTION IF EXISTS public.rpc_atomic_log_ai_insight(uuid, text, text, text);
END;
$$;
