-- Add operation_id to sales and purchases for logical grouping of cart items.
-- Nullable: historical records keep NULL, new cart-based records share a UUID.
ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS operation_id UUID;

ALTER TABLE public.purchases
  ADD COLUMN IF NOT EXISTS operation_id UUID;

-- Indexes to efficiently query all items from the same cart operation
CREATE INDEX IF NOT EXISTS idx_sales_operation_id     ON public.sales(operation_id);
CREATE INDEX IF NOT EXISTS idx_purchases_operation_id ON public.purchases(operation_id);
