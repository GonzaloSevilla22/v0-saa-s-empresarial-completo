create type user_role as enum ('user', 'admin');
create type user_plan as enum ('free', 'pro');

create table public.profiles (
  id uuid references auth.users(id) on delete cascade not null primary key,
  role user_role default 'user'::user_role not null,
  plan user_plan default 'free'::user_plan not null,
  insights_used integer default 0 not null,
  insights_reset_at timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null
);

alter table public.profiles enable row level security;
