-- =============================================================================
-- MIGRATION: 20260517000000_ci_compat_stubs.sql
-- DESCRIPTION: Minimal stubs for tables and columns that exist on the live DB
--              (applied via MCP / stub migrations) but are absent from the
--              committed migration chain and therefore missing in CI.
--
--              ALL DDL is idempotent:
--                - ADD COLUMN IF NOT EXISTS   — no-op if column already exists
--                - CREATE TABLE IF NOT EXISTS — no-op if table already exists
--                - ENABLE ROW LEVEL SECURITY  — idempotent (notice only)
--
--              The subsequent 20260517000001/2/3 migrations reference these
--              tables and columns; without them CI fails with:
--                "relation does not exist" / "column does not exist"
-- =============================================================================


-- ── 1. Missing columns on existing tables ────────────────────────────────────
-- company_id / supplier_id were added to these tables by stub migrations that
-- contain no DDL; they exist on the live DB but not in a fresh CI database.

ALTER TABLE public.products    ADD COLUMN IF NOT EXISTS company_id   uuid;
ALTER TABLE public.clients     ADD COLUMN IF NOT EXISTS company_id   uuid;
ALTER TABLE public.sales       ADD COLUMN IF NOT EXISTS company_id   uuid;
ALTER TABLE public.purchases   ADD COLUMN IF NOT EXISTS company_id   uuid;
ALTER TABLE public.purchases   ADD COLUMN IF NOT EXISTS supplier_id  uuid;
ALTER TABLE public.expenses    ADD COLUMN IF NOT EXISTS company_id   uuid;


-- ── 2. Missing tables (in dependency order) ───────────────────────────────────
-- Only the columns required by 20260517000001/2/3 policy expressions and
-- FK indexes are included. On the live DB these CREATE TABLE statements are
-- no-ops because IF NOT EXISTS short-circuits on the existing real table.

-- 2a. Stand-alone root tables
CREATE TABLE IF NOT EXISTS public.companies (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  name       text        NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.units_of_measure (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id    uuid,
  name       text        NOT NULL,
  symbol     text,
  is_system  boolean     DEFAULT false,
  created_at timestamptz DEFAULT now()
);

-- 2b. Tables that depend on companies
CREATE TABLE IF NOT EXISTS public.company_users (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid,
  user_id    uuid,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.audit_logs (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid,
  user_id    uuid,
  action     text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.events (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid,
  title      text,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.suppliers (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid,
  name       text        NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.warehouses (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id uuid,
  name       text        NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.inventory_movements (
  id            uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  company_id    uuid,
  created_by    uuid,
  movement_type text,
  quantity      numeric,
  created_at    timestamptz DEFAULT now()
);

-- 2c. Tables that depend on products (already exists)
CREATE TABLE IF NOT EXISTS public.product_variants (
  id         uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
  product_id uuid,
  name       text,
  created_at timestamptz DEFAULT now()
);

-- 2d. Tables that depend on warehouses / product_variants
CREATE TABLE IF NOT EXISTS public.inventory_stock (
  id           uuid    DEFAULT gen_random_uuid() PRIMARY KEY,
  variant_id   uuid,
  warehouse_id uuid,
  quantity     numeric DEFAULT 0
);

-- 2e. Line-item tables (depend on their parent operation tables)
CREATE TABLE IF NOT EXISTS public.purchase_items (
  id          uuid    DEFAULT gen_random_uuid() PRIMARY KEY,
  purchase_id uuid,
  variant_id  uuid,
  quantity    numeric,
  price       numeric
);

CREATE TABLE IF NOT EXISTS public.sale_items (
  id         uuid    DEFAULT gen_random_uuid() PRIMARY KEY,
  sale_id    uuid,
  variant_id uuid,
  quantity   numeric,
  price      numeric
);


-- ── 3. Enable RLS on stub tables ─────────────────────────────────────────────
-- 20260517000003 creates RLS policies on all these tables.
-- Policies can be created before RLS is enabled, but enabling it here matches
-- the live DB state and is idempotent (safe to run even if already enabled).

ALTER TABLE public.companies           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.units_of_measure    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.company_users       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_logs          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.suppliers           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.warehouses          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_variants    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.inventory_stock     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_items          ENABLE ROW LEVEL SECURITY;
