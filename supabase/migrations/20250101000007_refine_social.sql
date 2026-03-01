-- Refine posts table
alter table public.posts
add column if not exists category text,
add column if not exists likes_count integer not null default 0;

-- Ensure we can join with profiles to get author info
-- (Foreign key user_id already exists)
