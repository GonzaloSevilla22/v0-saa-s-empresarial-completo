-- =============================================================================
-- Migration: 20260606000003_account_id_columns.sql
-- Change: C-05 multi-user-tenant-architecture — Bloque C
-- Description: ADD COLUMN account_id en las 15 tablas scopeadas +
--              índices + backfill desde account_members(role='owner')
--
-- Tasks covered:
--   3.1  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id)
--   3.2  Índice idx_<tabla>_account_id en cada tabla
--   3.3  Backfill: account_id desde account_members por user_id + role='owner'
-- =============================================================================

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.1  ADD COLUMN account_id (nullable FK) en las 15 tablas
-- ─────────────────────────────────────────────────────────────────────────────
-- Se agrega como nullable para no romper inserciones existentes durante la
-- transición. Bloque D (RLS) lo hará obligatorio implícitamente vía policy.
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE sales
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE purchases
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE expenses
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE clients
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE stock_movements
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE units_of_measure
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE operation_idempotency
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE ai_insights
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE ai_conversations
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE fair_recommendations
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE invoice_documents
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE invoice_suppliers
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE product_aliases
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

ALTER TABLE course_progress
  ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES accounts(id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.2  Índices para performance en queries filtradas por account_id
-- ─────────────────────────────────────────────────────────────────────────────
-- IF NOT EXISTS evita error en rerun
-- ─────────────────────────────────────────────────────────────────────────────

CREATE INDEX IF NOT EXISTS idx_products_account_id
  ON products(account_id);

CREATE INDEX IF NOT EXISTS idx_sales_account_id
  ON sales(account_id);

CREATE INDEX IF NOT EXISTS idx_purchases_account_id
  ON purchases(account_id);

CREATE INDEX IF NOT EXISTS idx_expenses_account_id
  ON expenses(account_id);

CREATE INDEX IF NOT EXISTS idx_clients_account_id
  ON clients(account_id);

CREATE INDEX IF NOT EXISTS idx_stock_movements_account_id
  ON stock_movements(account_id);

CREATE INDEX IF NOT EXISTS idx_units_of_measure_account_id
  ON units_of_measure(account_id);

CREATE INDEX IF NOT EXISTS idx_operation_idempotency_account_id
  ON operation_idempotency(account_id);

CREATE INDEX IF NOT EXISTS idx_ai_insights_account_id
  ON ai_insights(account_id);

CREATE INDEX IF NOT EXISTS idx_ai_conversations_account_id
  ON ai_conversations(account_id);

CREATE INDEX IF NOT EXISTS idx_fair_recommendations_account_id
  ON fair_recommendations(account_id);

CREATE INDEX IF NOT EXISTS idx_invoice_documents_account_id
  ON invoice_documents(account_id);

CREATE INDEX IF NOT EXISTS idx_invoice_suppliers_account_id
  ON invoice_suppliers(account_id);

CREATE INDEX IF NOT EXISTS idx_product_aliases_account_id
  ON product_aliases(account_id);

CREATE INDEX IF NOT EXISTS idx_course_progress_account_id
  ON course_progress(account_id);

-- ─────────────────────────────────────────────────────────────────────────────
-- 3.3  Backfill: account_id = cuenta del owner de ese user_id
-- ─────────────────────────────────────────────────────────────────────────────
-- Patrón: JOIN con account_members WHERE role='owner' para encontrar la cuenta
-- del propietario de cada fila. Solo toca filas con account_id IS NULL
-- (idempotente en reruns).
--
-- Nota: units_of_measure.user_id es nullable — el JOIN natural lo filtra
-- automáticamente (NULLs no hacen match con am.user_id).
-- ─────────────────────────────────────────────────────────────────────────────

UPDATE products t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE sales t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE purchases t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE expenses t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE clients t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE stock_movements t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE units_of_measure t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE operation_idempotency t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE ai_insights t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE ai_conversations t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE fair_recommendations t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE invoice_documents t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE invoice_suppliers t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE product_aliases t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;

UPDATE course_progress t
SET    account_id = am.account_id
FROM   account_members am
WHERE  t.user_id = am.user_id
  AND  am.role   = 'owner'
  AND  t.account_id IS NULL;
