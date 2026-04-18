-- products
create table public.products (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  name text not null,
  price numeric not null default 0,
  cost numeric not null default 0,
  stock integer not null default 0,
  created_at timestamp with time zone default now() not null
);

-- clients
create table public.clients (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  name text not null,
  email text,
  phone text,
  created_at timestamp with time zone default now() not null
);

-- sales
create table public.sales (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  client_id uuid references public.clients(id) on delete set null,
  product_id uuid references public.products(id) on delete set null,
  amount numeric not null,
  quantity integer not null default 1,
  date timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null
);

-- purchases
create table public.purchases (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  product_id uuid references public.products(id) on delete set null,
  amount numeric not null,
  quantity integer not null default 1,
  date timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null
);

-- expenses
create table public.expenses (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  category text not null,
  amount numeric not null,
  date timestamp with time zone default now() not null,
  created_at timestamp with time zone default now() not null
);

-- insights
create table public.insights (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  type text not null, -- 'general', 'prediction', 'simulation'
  content text not null,
  actionable text,
  created_at timestamp with time zone default now() not null
);

-- posts
create table public.posts (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade not null,
  title text not null,
  content text not null,
  created_at timestamp with time zone default now() not null
);

-- replies
create table public.replies (
  id uuid default gen_random_uuid() primary key,
  post_id uuid references public.posts(id) on delete cascade not null,
  user_id uuid references auth.users(id) on delete cascade not null,
  content text not null,
  created_at timestamp with time zone default now() not null
);

-- courses
create table public.courses (
  id uuid default gen_random_uuid() primary key,
  title text not null,
  description text not null,
  content text not null,
  created_at timestamp with time zone default now() not null
);

-- course_progress
create table public.course_progress (
  id uuid default gen_random_uuid() primary key,
  course_id uuid references public.courses(id) on delete cascade not null,
  user_id uuid references auth.users(id) on delete cascade not null,
  completed boolean default false not null,
  created_at timestamp with time zone default now() not null,
  unique (course_id, user_id)
);

-- analytics_events
create table public.analytics_events (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete cascade,
  event_name text not null,
  event_data jsonb,
  created_at timestamp with time zone default now() not null
);

CREATE INDEX IF NOT EXISTS idx_products_user ON products(user_id);
CREATE INDEX IF NOT EXISTS idx_clients_user ON clients(user_id);
CREATE INDEX IF NOT EXISTS idx_sales_user ON sales(user_id);
CREATE INDEX IF NOT EXISTS idx_purchases_user ON purchases(user_id);
CREATE INDEX IF NOT EXISTS idx_expenses_user ON expenses(user_id);
CREATE INDEX IF NOT EXISTS idx_insights_user ON insights(user_id);
CREATE INDEX IF NOT EXISTS idx_posts_user ON posts(user_id);
CREATE INDEX IF NOT EXISTS idx_replies_user ON replies(user_id);
CREATE INDEX IF NOT EXISTS idx_course_progress_user ON course_progress(user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_events_user ON analytics_events(user_id);
CREATE INDEX IF NOT EXISTS idx_analytics_events_name ON analytics_events(event_name);

