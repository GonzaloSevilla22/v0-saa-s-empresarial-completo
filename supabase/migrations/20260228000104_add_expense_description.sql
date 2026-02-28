-- Add description column to expenses table
ALTER TABLE public.expenses ADD COLUMN IF NOT EXISTS description text;
