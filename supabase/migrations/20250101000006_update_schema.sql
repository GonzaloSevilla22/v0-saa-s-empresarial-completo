-- Add missing columns to products
alter table public.products 
add column if not exists category text,
add column if not exists min_stock integer not null default 0;

-- Ensure margin can be calculated or stored
-- In this case, we'll just calculate it in the frontend or view, 
-- but we can add it as a column if the user wants it persisted.

-- Add currency to sales (was missing in migration but exists in TS)
alter table public.sales
add column if not exists currency text not null default 'ARS';

-- Add status and phone to clients (status was missing)
alter table public.clients
add column if not exists status text not null default 'activo';
