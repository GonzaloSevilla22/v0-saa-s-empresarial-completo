-- Enable RLS (idempotent — safe to run multiple times)
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.clients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.expenses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.insights ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.replies ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.courses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.course_progress ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.analytics_events ENABLE ROW LEVEL SECURITY;

-- PROFILES
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
CREATE POLICY "Users can view own profile" ON public.profiles
  FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
CREATE POLICY "Users can update own profile" ON public.profiles
  FOR UPDATE USING (auth.uid() = id);

DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
CREATE POLICY "Admins can view all profiles" ON public.profiles
  FOR SELECT USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "Admins can update all profiles" ON public.profiles;
CREATE POLICY "Admins can update all profiles" ON public.profiles
  FOR UPDATE USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- PRODUCTS
DROP POLICY IF EXISTS "Users can do all to own products" ON public.products;
CREATE POLICY "Users can do all to own products" ON public.products
  FOR ALL USING (auth.uid() = user_id);

-- CLIENTS
DROP POLICY IF EXISTS "Users can do all to own clients" ON public.clients;
CREATE POLICY "Users can do all to own clients" ON public.clients
  FOR ALL USING (auth.uid() = user_id);

-- SALES
DROP POLICY IF EXISTS "Users can do all to own sales" ON public.sales;
CREATE POLICY "Users can do all to own sales" ON public.sales
  FOR ALL USING (auth.uid() = user_id);

-- PURCHASES
DROP POLICY IF EXISTS "Users can do all to own purchases" ON public.purchases;
CREATE POLICY "Users can do all to own purchases" ON public.purchases
  FOR ALL USING (auth.uid() = user_id);

-- EXPENSES
DROP POLICY IF EXISTS "Users can do all to own expenses" ON public.expenses;
CREATE POLICY "Users can do all to own expenses" ON public.expenses
  FOR ALL USING (auth.uid() = user_id);

-- INSIGHTS
DROP POLICY IF EXISTS "Users can do all to own insights" ON public.insights;
CREATE POLICY "Users can do all to own insights" ON public.insights
  FOR ALL USING (auth.uid() = user_id);

-- POSTS
DROP POLICY IF EXISTS "Anyone can view posts" ON public.posts;
CREATE POLICY "Anyone can view posts" ON public.posts
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert own posts" ON public.posts;
CREATE POLICY "Users can insert own posts" ON public.posts
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own posts" ON public.posts;
CREATE POLICY "Users can update own posts" ON public.posts
  FOR UPDATE USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own posts" ON public.posts;
CREATE POLICY "Users can delete own posts" ON public.posts
  FOR DELETE USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can delete any post" ON public.posts;
CREATE POLICY "Admins can delete any post" ON public.posts
  FOR DELETE USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- REPLIES
DROP POLICY IF EXISTS "Anyone can view replies" ON public.replies;
CREATE POLICY "Anyone can view replies" ON public.replies
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert own replies" ON public.replies;
CREATE POLICY "Users can insert own replies" ON public.replies
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own replies" ON public.replies;
CREATE POLICY "Users can update own replies" ON public.replies
  FOR UPDATE USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own replies" ON public.replies;
CREATE POLICY "Users can delete own replies" ON public.replies
  FOR DELETE USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Admins can delete any reply" ON public.replies;
CREATE POLICY "Admins can delete any reply" ON public.replies
  FOR DELETE USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- COURSES
DROP POLICY IF EXISTS "Anyone can view courses" ON public.courses;
CREATE POLICY "Anyone can view courses" ON public.courses
  FOR SELECT USING (true);

DROP POLICY IF EXISTS "Admins can insert courses" ON public.courses;
CREATE POLICY "Admins can insert courses" ON public.courses
  FOR INSERT WITH CHECK (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "Admins can update courses" ON public.courses;
CREATE POLICY "Admins can update courses" ON public.courses
  FOR UPDATE USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

DROP POLICY IF EXISTS "Admins can delete courses" ON public.courses;
CREATE POLICY "Admins can delete courses" ON public.courses
  FOR DELETE USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));

-- COURSE PROGRESS
DROP POLICY IF EXISTS "Users can do all to own course progress" ON public.course_progress;
CREATE POLICY "Users can do all to own course progress" ON public.course_progress
  FOR ALL USING (auth.uid() = user_id);

-- ANALYTICS EVENTS
DROP POLICY IF EXISTS "Users can insert own analytics events" ON public.analytics_events;
CREATE POLICY "Users can insert own analytics events" ON public.analytics_events
  FOR INSERT WITH CHECK (auth.uid() = user_id OR user_id IS NULL);

DROP POLICY IF EXISTS "Admins can read all analytics events" ON public.analytics_events;
CREATE POLICY "Admins can read all analytics events" ON public.analytics_events
  FOR SELECT USING (EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin'));
