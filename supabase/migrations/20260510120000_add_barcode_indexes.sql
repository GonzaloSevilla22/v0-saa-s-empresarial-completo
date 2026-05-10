-- Migration: add_barcode_indexes
-- Adds a partial unique index on products.barcode (per user) so that
-- two products belonging to the same user cannot share the same non-null
-- barcode.  Also adds a plain index for fast barcode lookups during
-- scanner scan-to-cart operations.

-- Unique index: (user_id, barcode) where barcode is meaningful.
-- NULL and empty-string barcodes are excluded so that many products
-- can have no barcode assigned without violating uniqueness.
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_barcode_unique
  ON products (user_id, barcode)
  WHERE barcode IS NOT NULL AND barcode <> '';

-- Fast lookup index used by scan-to-cart (filters on barcode alone
-- and then verifies user_id via RLS — still benefits from this index).
CREATE INDEX IF NOT EXISTS idx_products_barcode
  ON products (barcode)
  WHERE barcode IS NOT NULL AND barcode <> '';