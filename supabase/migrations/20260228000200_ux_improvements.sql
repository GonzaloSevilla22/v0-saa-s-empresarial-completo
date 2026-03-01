-- Add parent_id for self-referential product variants and barcode field
ALTER TABLE public.products 
ADD COLUMN IF NOT EXISTS parent_id UUID REFERENCES public.products(id) ON DELETE SET NULL,
ADD COLUMN IF NOT EXISTS barcode TEXT,
ADD COLUMN IF NOT EXISTS min_stock INTEGER DEFAULT 5;

-- Standardize clients table (ensuring phone is present and category if used)
ALTER TABLE public.clients
ADD COLUMN IF NOT EXISTS phone TEXT,
ADD COLUMN IF NOT EXISTS category TEXT;

-- Add overstock_threshold to profiles for stock alerts
ALTER TABLE public.profiles
ADD COLUMN IF NOT EXISTS overstock_threshold INTEGER DEFAULT 100;

-- Ensure GIN index for analytics is truly efficient for variants
CREATE INDEX IF NOT EXISTS idx_products_parent ON public.products(parent_id);
CREATE INDEX IF NOT EXISTS idx_products_barcode ON public.products(barcode);

-- Update RLS for the new columns (implicit in existing policies usually, but good to note)
COMMENT ON COLUMN public.products.parent_id IS 'Reference to the parent product for grouping variants.';
COMMENT ON COLUMN public.products.barcode IS 'Manual or automatic barcode for the product.';
