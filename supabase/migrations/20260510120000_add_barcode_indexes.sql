-- Migration: add_barcode_indexes
-- Adds a partial unique index on products.barcode (per user) and a fast
-- lookup index.  Before creating the unique constraint, existing duplicate
-- barcodes (same user_id + barcode value) are deduplicated by nulling out
-- all records except the first one (ordered by id) in each group.

-- Step 1: Deduplicate — keep the earliest product per (user_id, barcode),
--         set barcode = NULL for every duplicate so the unique index can
--         be created without conflicts.
WITH ranked_dupes AS (
  SELECT id,
         ROW_NUMBER() OVER (
           PARTITION BY user_id, barcode
           ORDER BY id
         ) AS rn
  FROM products
  WHERE barcode IS NOT NULL
    AND barcode <> ''
)
UPDATE products
SET barcode = NULL
WHERE id IN (
  SELECT id FROM ranked_dupes WHERE rn > 1
);

-- Step 2: Unique index — one non-empty barcode per user.
--         NULL and empty-string barcodes are excluded so products without
--         a barcode assigned never violate uniqueness.
CREATE UNIQUE INDEX IF NOT EXISTS idx_products_barcode_unique
  ON products (user_id, barcode)
  WHERE barcode IS NOT NULL AND barcode <> '';

-- Step 3: Fast lookup index used by scan-to-cart operations.
CREATE INDEX IF NOT EXISTS idx_products_barcode
  ON products (barcode)
  WHERE barcode IS NOT NULL AND barcode <> '';