-- =============================================================================
-- MIGRATION: 20260426000001_drop_vulnerable_rpc_overloads.sql
-- DESCRIPTION: Drop old SECURITY DEFINER RPC overloads that accept p_user_id.
--
-- ROOT CAUSE:
--   Migration 20260425000001_security_hardening.sql used CREATE OR REPLACE
--   to fix RPCs by removing p_user_id and adding a new parameter. However,
--   PostgreSQL's CREATE OR REPLACE can only replace a function with the
--   exact same signature. When the 5th argument type changed (uuid to text),
--   Postgres created a NEW overload instead of replacing the old one.
--
--   The old vulnerable versions still exist and are callable by any
--   authenticated user:
--     rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid)
--     rpc_atomic_create_purchase(uuid, numeric, integer, uuid)
--     rpc_atomic_log_ai_insight(uuid, text, text, text)
--
-- ATTACK VECTOR:
--   An authenticated user calls the old overload with another user's UUID as
--   p_user_id to create sales/purchases in the victim's account, exhaust their
--   free-plan quota, or inject poisoned data into their AI metrics.
--
-- FIX: Explicitly DROP the old signatures. The secure versions from the
--      hardening migration remain active.
--
-- NOTE: Inline comments inside DROP FUNCTION argument lists are intentionally
--       omitted — they trigger "multiple commands in prepared statement" errors
--       in the Supabase CLI migration runner.
-- =============================================================================

-- rpc_atomic_create_sale — old 5th arg was p_user_id uuid (now p_currency text)
DROP FUNCTION IF EXISTS public.rpc_atomic_create_sale(uuid, uuid, numeric, integer, uuid);

-- rpc_atomic_create_purchase — old 4th arg was p_user_id uuid (now p_description text)
DROP FUNCTION IF EXISTS public.rpc_atomic_create_purchase(uuid, numeric, integer, uuid);

-- rpc_atomic_log_ai_insight — old 1st arg was p_user_id uuid (now removed entirely)
DROP FUNCTION IF EXISTS public.rpc_atomic_log_ai_insight(uuid, text, text, text);
