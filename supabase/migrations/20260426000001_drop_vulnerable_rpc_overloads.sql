-- =============================================================================
-- MIGRATION: 20260426000001_drop_vulnerable_rpc_overloads.sql
-- DESCRIPTION: Drop old SECURITY DEFINER RPC overloads that accept p_user_id.
--
-- ROOT CAUSE:
--   Migration 20260425000001_security_hardening.sql used CREATE OR REPLACE
--   to fix RPCs by removing p_user_id and adding a new parameter. However,
--   PostgreSQL's CREATE OR REPLACE can only replace a function with the
--   *exact same* signature. When the 5th argument type changed (uuid → text),
--   Postgres created a NEW overload instead of replacing the old one.
--
--   As a result, the old vulnerable versions still exist and are callable by
--   any authenticated user:
--
--   rpc_atomic_create_sale(uuid, uuid, numeric, integer, UUID)   ← p_user_id
--   rpc_atomic_create_purchase(uuid, numeric, integer, UUID)     ← p_user_id
--   rpc_atomic_log_ai_insight(UUID, text, text, text)            ← p_user_id as 1st arg
--
-- ATTACK VECTOR:
--   An authenticated user calls the old overload with another user's UUID as
--   p_user_id to create sales/purchases in the victim's account, exhaust their
--   free-plan quota, or inject poisoned data into their AI metrics.
--
-- FIX: Explicitly DROP the old signatures. The secure versions from the
--      hardening migration remain active.
-- =============================================================================

-- ── rpc_atomic_create_sale (old: 5th arg was p_user_id uuid) ─────────────────
DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(
  uuid,      -- p_client_id
  uuid,      -- p_product_id
  numeric,   -- p_amount
  integer,   -- p_quantity
  uuid       -- p_user_id  ← the vulnerable argument
);

-- ── rpc_atomic_create_purchase (old: 4th arg was p_user_id uuid) ─────────────
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(
  uuid,      -- p_product_id
  numeric,   -- p_amount
  integer,   -- p_quantity
  uuid       -- p_user_id  ← the vulnerable argument
);

-- ── rpc_atomic_log_ai_insight (old: 1st arg was p_user_id uuid) ──────────────
DROP FUNCTION IF EXISTS public.rpc_atomic_log_ai_insight(
  uuid,      -- p_user_id  ← the vulnerable argument
  text,      -- p_type
  text,      -- p_content
  text       -- p_source_function
);

-- =============================================================================
-- VERIFICATION QUERIES (run manually after applying)
-- =============================================================================
--
-- Confirm only the secure (no p_user_id) versions remain:
--
--   SELECT proname, pg_get_function_arguments(oid) AS args
--   FROM pg_proc
--   WHERE proname IN (
--     'rpc_atomic_create_sale',
--     'rpc_atomic_create_purchase',
--     'rpc_atomic_log_ai_insight'
--   )
--   AND pronamespace = 'public'::regnamespace;
--
-- Expected output (3 rows, no uuid as first/last arg):
--   rpc_atomic_create_sale      | p_client_id uuid, p_product_id uuid, p_amount numeric, p_quantity integer, p_currency text
--   rpc_atomic_create_purchase  | p_product_id uuid, p_amount numeric, p_quantity integer, p_description text
--   rpc_atomic_log_ai_insight   | p_type text, p_content text, p_source_function text
--
-- Confirm attempting to call old signatures fails:
--   SELECT rpc_atomic_create_sale(
--     gen_random_uuid(), gen_random_uuid(), 100, 1, gen_random_uuid()
--   );
--   → Expected: ERROR: function rpc_atomic_create_sale(...uuid) does not exist
-- =============================================================================
