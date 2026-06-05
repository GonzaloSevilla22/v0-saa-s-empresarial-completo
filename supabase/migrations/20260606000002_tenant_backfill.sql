-- =============================================================================
-- Migration: 20260606000002_tenant_backfill.sql
-- Change: C-05 multi-user-tenant-architecture — Bloque B
-- Description: Backfill 1:1 — cada profiles → 1 account (owner) + member
--
-- Tasks covered:
--   2.1  INSERT INTO accounts from profiles (idempotente)
--   2.2  INSERT INTO account_members role='owner' (idempotente)
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.1  Crear una cuenta por cada profile que aún no tenga cuenta
-- ─────────────────────────────────────────────────────────────────────────────
-- Idempotente: WHERE NOT EXISTS evita duplicar si ya existe una cuenta para
-- ese owner_user_id (posible en reruns o si Bloque A dejó filas parciales).
--
-- Mapeos desde profiles:
--   billing_plan       → profiles.billing_plan
--   billing_status     → profiles.billing_status  (respetamos el valor real,
--                         que ya fue normalizado por C-01/C-03)
--   trial_plan         → profiles.trial_plan
--   trial_started_at   → profiles.trial_started_at
--   trial_expires_at   → profiles.trial_expires_at
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO accounts (
  id,
  owner_user_id,
  billing_plan,
  billing_status,
  trial_plan,
  trial_started_at,
  trial_expires_at,
  created_at
)
SELECT
  gen_random_uuid()        AS id,
  p.id                     AS owner_user_id,
  p.billing_plan           AS billing_plan,
  p.billing_status         AS billing_status,
  p.trial_plan             AS trial_plan,
  p.trial_started_at       AS trial_started_at,
  p.trial_expires_at       AS trial_expires_at,
  p.created_at             AS created_at
FROM profiles p
WHERE NOT EXISTS (
  SELECT 1
  FROM   accounts a
  WHERE  a.owner_user_id = p.id
);

-- ─────────────────────────────────────────────────────────────────────────────
-- 2.2  Registrar al owner como miembro de su propia cuenta
-- ─────────────────────────────────────────────────────────────────────────────
-- ON CONFLICT DO NOTHING es seguro porque account_members tiene
-- UNIQUE(account_id, user_id) definido en 20260606000001_tenant_tables.sql.
-- ─────────────────────────────────────────────────────────────────────────────
INSERT INTO account_members (account_id, user_id, role)
SELECT
  a.id               AS account_id,
  a.owner_user_id    AS user_id,
  'owner'::text      AS role
FROM accounts a
ON CONFLICT (account_id, user_id) DO NOTHING;
