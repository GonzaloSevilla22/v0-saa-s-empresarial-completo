DO $$
BEGIN
  DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid);
  DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, uuid);
  DROP FUNCTION IF EXISTS public.rpc_atomic_log_ai_insight(uuid, text, text, text);
END;
$$;
