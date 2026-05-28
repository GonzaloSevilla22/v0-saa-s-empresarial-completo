-- =============================================================================
-- MIGRATION: 20260528000001_operation_idempotency.sql
-- DESCRIPTION: Foundational idempotency ledger for financial operations.
--
-- WHY:
--   Today a double-submit / retry / browser-resend of a "create sale" or
--   "create purchase" produces a real duplicate in the DB. There is no
--   idempotency key and no unique constraint anywhere on the create path.
--   This table is the single, durable identity of a business operation:
--   the same idempotency_key can only ever resolve to ONE operation.
--
-- DESIGN (deliberately minimal — NOT a Stripe-style processing/completed cache):
--   - The row is written INSIDE the same transaction as the operation it
--     guards. If the operation commits, the key is taken. If the operation
--     rolls back (e.g. insufficient stock), the row rolls back too and the
--     key is freed for a legitimate retry. There is therefore NO "processing"
--     limbo state and NO possibility of an orphaned lock.
--   - operation_id points at the resulting operation group (sales.operation_id
--     / purchases.operation_id). On replay, the guarding RPC re-SELECTs the
--     original line rows by this id and returns the same aggregate — we do NOT
--     store a response blob (that would drift toward the cache pattern we
--     explicitly rejected).
--
-- SCOPING:
--   UNIQUE is (user_id, idempotency_key), NOT (idempotency_key) alone.
--   A globally-unique key would let user B reuse user A's key and receive
--   A's operation back (cross-user replay leak). Scoping by user_id closes
--   that and also gives the lookup index natural locality. The system has no
--   tenant/org concept — user_id IS the ownership boundary, consistent with
--   every other table.
--
-- ACCESS:
--   Written ONLY by SECURITY DEFINER operation RPCs. Authenticated users get
--   SELECT on their own rows (for debugging/inspection) and nothing else —
--   no INSERT/UPDATE/DELETE policy means RLS denies those for the API role.
-- =============================================================================

CREATE TABLE IF NOT EXISTS public.operation_idempotency (
  id              uuid        NOT NULL DEFAULT gen_random_uuid(),
  user_id         uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  idempotency_key text        NOT NULL,
  operation_kind  text        NOT NULL CHECK (operation_kind = ANY (ARRAY['sale', 'purchase'])),
  operation_id    uuid,        -- resulting operation group (sales/purchases.operation_id)
  created_at      timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT operation_idempotency_pkey PRIMARY KEY (id),
  CONSTRAINT operation_idempotency_user_key_unique UNIQUE (user_id, idempotency_key)
);

-- Lookup index for the replay path: "given (user, key), find the operation".
-- The UNIQUE constraint already creates a usable index on (user_id, idempotency_key),
-- so no separate index is needed for the conflict/lookup.

-- Reverse lookup: "given an operation_id, find its idempotency record" (audit / cleanup).
CREATE INDEX IF NOT EXISTS idx_operation_idempotency_operation
  ON public.operation_idempotency (user_id, operation_id)
  WHERE operation_id IS NOT NULL;

-- ── Row-Level Security ────────────────────────────────────────────────────────
ALTER TABLE public.operation_idempotency ENABLE ROW LEVEL SECURITY;

-- Authenticated users may read ONLY their own idempotency records.
CREATE POLICY "operation_idempotency_select"
  ON public.operation_idempotency
  FOR SELECT
  USING (user_id = auth.uid());

-- No INSERT/UPDATE/DELETE policies are defined on purpose: with RLS enabled,
-- the absence of a policy denies the operation for the authenticated role.
-- All writes go through SECURITY DEFINER RPCs (function owner bypasses RLS),
-- so clients can never forge, mutate, or delete an idempotency record.

COMMENT ON TABLE public.operation_idempotency IS
  'Idempotency ledger for create-operation RPCs. One (user_id, idempotency_key) '
  'maps to exactly one operation. Written inside the operation transaction so it '
  'commits/rolls-back atomically — no processing/completed state, no orphan locks.';
