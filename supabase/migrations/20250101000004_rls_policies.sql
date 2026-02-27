-- enable rls
alter table public.products enable row level security;
alter table public.clients enable row level security;
alter table public.sales enable row level security;
alter table public.purchases enable row level security;
alter table public.expenses enable row level security;
alter table public.insights enable row level security;
alter table public.posts enable row level security;
alter table public.replies enable row level security;
alter table public.courses enable row level security;
alter table public.course_progress enable row level security;
alter table public.analytics_events enable row level security;

-- PROFILES
create policy "Users can view own profile" on public.profiles for select using (auth.uid() = id);
create policy "Users can update own profile" on public.profiles for update using (auth.uid() = id);
create policy "Admins can view all profiles" on public.profiles for select using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
create policy "Admins can update all profiles" on public.profiles for update using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- PRODUCTS
create policy "Users can do all to own products" on public.products for all using (auth.uid() = user_id);

-- CLIENTS
create policy "Users can do all to own clients" on public.clients for all using (auth.uid() = user_id);

-- SALES
create policy "Users can do all to own sales" on public.sales for all using (auth.uid() = user_id);

-- PURCHASES
create policy "Users can do all to own purchases" on public.purchases for all using (auth.uid() = user_id);

-- EXPENSES
create policy "Users can do all to own expenses" on public.expenses for all using (auth.uid() = user_id);

-- INSIGHTS
create policy "Users can do all to own insights" on public.insights for all using (auth.uid() = user_id);

-- POSTS (public read, authenticated user create/update own, admin all)
create policy "Anyone can view posts" on public.posts for select using (true);
create policy "Users can insert own posts" on public.posts for insert with check (auth.uid() = user_id);
create policy "Users can update own posts" on public.posts for update using (auth.uid() = user_id);
create policy "Users can delete own posts" on public.posts for delete using (auth.uid() = user_id);
create policy "Admins can delete any post" on public.posts for delete using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- REPLIES
create policy "Anyone can view replies" on public.replies for select using (true);
create policy "Users can insert own replies" on public.replies for insert with check (auth.uid() = user_id);
create policy "Users can update own replies" on public.replies for update using (auth.uid() = user_id);
create policy "Users can delete own replies" on public.replies for delete using (auth.uid() = user_id);
create policy "Admins can delete any reply" on public.replies for delete using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- COURSES (public read, admin full)
create policy "Anyone can view courses" on public.courses for select using (true);
create policy "Admins can insert courses" on public.courses for insert with check (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
create policy "Admins can update courses" on public.courses for update using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
create policy "Admins can delete courses" on public.courses for delete using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));

-- COURSE PROGRESS
create policy "Users can do all to own course progress" on public.course_progress for all using (auth.uid() = user_id);

-- ANALYTICS EVENTS (insert only for users, admin read all)
create policy "Users can insert own analytics events" on public.analytics_events for insert with check (auth.uid() = user_id or user_id is null);
create policy "Admins can read all analytics events" on public.analytics_events for select using (exists (select 1 from public.profiles where id = auth.uid() and role = 'admin'));
