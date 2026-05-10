-- =============================================================================
-- Migration: invoice_ocr_system
-- Creates the full infrastructure for AI-powered invoice reading:
--   * invoices storage bucket (private, 20 MB, image + PDF)
--   * invoice_documents  — processed document registry with status tracking
--   * invoice_suppliers  — per-user supplier directory built from OCR
--   * product_aliases    — learned mappings from OCR text → product
-- =============================================================================

-- ── 1. Storage bucket ─────────────────────────────────────────────────────────
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'invoices',
  'invoices',
  false,
  20971520,   -- 20 MB
  ARRAY[
    'image/jpeg',
    'image/jpg',
    'image/png',
    'image/webp',
    'image/heic',
    'image/heif',
    'application/pdf'
  ]
)
ON CONFLICT (id) DO NOTHING;

-- ── 2. Storage RLS policies ───────────────────────────────────────────────────
-- Path convention: invoices/{user_id}/{document_uuid}.{ext}
-- The first folder segment must match the authenticated user's UUID.

DO $$
BEGIN
  -- INSERT (upload)
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'invoices_insert'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY invoices_insert ON storage.objects
        FOR INSERT WITH CHECK (
          bucket_id = 'invoices'
          AND auth.uid()::text = (storage.foldername(name))[1]
        )
    $policy$;
  END IF;

  -- SELECT (read)
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'invoices_select'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY invoices_select ON storage.objects
        FOR SELECT USING (
          bucket_id = 'invoices'
          AND auth.uid()::text = (storage.foldername(name))[1]
        )
    $policy$;
  END IF;

  -- DELETE
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'invoices_delete'
  ) THEN
    EXECUTE $policy$
      CREATE POLICY invoices_delete ON storage.objects
        FOR DELETE USING (
          bucket_id = 'invoices'
          AND auth.uid()::text = (storage.foldername(name))[1]
        )
    $policy$;
  END IF;
END $$;

-- ── 3. invoice_documents ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS invoice_documents (
  id                  uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id             uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,

  -- File info
  storage_path        text NOT NULL,          -- invoices/{user_id}/{uuid}.{ext}
  original_name       text,
  mime_type           text,
  file_size_bytes     bigint,

  -- Pipeline status
  status              text NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','processing','completed','failed')),
  error_message       text,
  processing_ms       integer,

  -- AI extraction output (raw)
  ai_model            text,
  ai_raw_response     jsonb,
  ai_confidence       numeric(4,3) CHECK (ai_confidence BETWEEN 0 AND 1),
  ai_warnings         text[],

  -- Normalized extracted header fields (for quick querying / dedup)
  supplier_name       text,
  supplier_cuit       text,
  invoice_number      text,
  invoice_date        date,
  invoice_type        text,                   -- A, B, C, otro
  invoice_currency    text DEFAULT 'ARS',
  invoice_total       numeric(15,2),

  -- Parsed items + matches (JSON saved for review modal)
  parsed_items        jsonb,

  -- Outcome
  purchase_operation_id uuid,                 -- set when user confirms → purchase

  created_at          timestamptz DEFAULT now(),
  updated_at          timestamptz DEFAULT now()
);

-- Dedup index: same user + same invoice number + same supplier CUIT
CREATE UNIQUE INDEX IF NOT EXISTS idx_invoice_documents_dedup
  ON invoice_documents (user_id, supplier_cuit, invoice_number)
  WHERE supplier_cuit IS NOT NULL AND invoice_number IS NOT NULL;

-- Status + user lookup
CREATE INDEX IF NOT EXISTS idx_invoice_documents_user_status
  ON invoice_documents (user_id, status, created_at DESC);

-- RLS
ALTER TABLE invoice_documents ENABLE ROW LEVEL SECURITY;

CREATE POLICY invoice_documents_select ON invoice_documents
  FOR SELECT USING (auth.uid() = user_id);

CREATE POLICY invoice_documents_insert ON invoice_documents
  FOR INSERT WITH CHECK (auth.uid() = user_id);

CREATE POLICY invoice_documents_update ON invoice_documents
  FOR UPDATE USING (auth.uid() = user_id);

CREATE POLICY invoice_documents_delete ON invoice_documents
  FOR DELETE USING (auth.uid() = user_id);

-- updated_at trigger
CREATE OR REPLACE FUNCTION update_invoice_documents_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_invoice_documents_updated_at ON invoice_documents;
CREATE TRIGGER trg_invoice_documents_updated_at
  BEFORE UPDATE ON invoice_documents
  FOR EACH ROW EXECUTE FUNCTION update_invoice_documents_updated_at();

-- ── 4. invoice_suppliers ──────────────────────────────────────────────────────
-- Simpler than the company-based `suppliers` table — keyed by user_id
-- for consistency with how products/purchases work.
CREATE TABLE IF NOT EXISTS invoice_suppliers (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  name        text NOT NULL,
  cuit        text,
  address     text,
  email       text,
  phone       text,
  notes       text,
  created_at  timestamptz DEFAULT now(),
  updated_at  timestamptz DEFAULT now(),
  UNIQUE (user_id, cuit)
);

ALTER TABLE invoice_suppliers ENABLE ROW LEVEL SECURITY;

CREATE POLICY invoice_suppliers_all ON invoice_suppliers
  FOR ALL USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- ── 5. product_aliases ────────────────────────────────────────────────────────
-- Stores learned mappings: OCR text → ERP product.
-- Grows automatically as users confirm or correct OCR matches.
CREATE TABLE IF NOT EXISTS product_aliases (
  id          uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id     uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  alias       text NOT NULL,        -- normalized OCR text (lowercase, trimmed)
  source      text DEFAULT 'manual' CHECK (source IN ('manual','auto')),
  created_at  timestamptz DEFAULT now(),
  UNIQUE (user_id, alias)
);

CREATE INDEX IF NOT EXISTS idx_product_aliases_user
  ON product_aliases (user_id, alias text_pattern_ops);

ALTER TABLE product_aliases ENABLE ROW LEVEL SECURITY;

CREATE POLICY product_aliases_all ON product_aliases
  FOR ALL USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);