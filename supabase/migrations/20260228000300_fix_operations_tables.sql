-- Fix Sales and Purchases tables
ALTER TABLE public.sales ADD COLUMN IF NOT EXISTS total numeric;
ALTER TABLE public.purchases ADD COLUMN IF NOT EXISTS total numeric;
