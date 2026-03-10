-- Add missing columns to courses table for full admin management
alter table public.courses
  add column if not exists is_pro boolean not null default false,
  add column if not exists level text not null default 'basico',
  add column if not exists category text not null default 'General',
  add column if not exists students integer not null default 0,
  add column if not exists rating numeric not null default 5.0;
