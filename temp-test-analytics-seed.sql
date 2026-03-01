-- =======================================================================================
-- SEED SCRIPT: temp-test-analytics-seed.sql
-- PURPOSE: Mock data spanning 45 days to test UMV, Cohorts, Habit, and Admin RPCs.
-- =======================================================================================

-- IMPORTANT: This script assumes you already have 'admin' access or it creates one.

-- 1. Create two users: one Admin, one Normal
INSERT INTO auth.users (id, email, raw_user_meta_data)
VALUES 
  ('a0000000-0000-0000-0000-000000000001', 'admin.dashboard@eie.com', '{"name": "Admin EIE"}'),
  ('a0000000-0000-0000-0000-000000000002', 'normal.user@eie.com', '{"name": "Normal User"}')
ON CONFLICT (id) DO NOTHING;

-- Grant Admin Role (if not default)
UPDATE public.profiles SET role = 'admin' WHERE id = 'a0000000-0000-0000-0000-000000000001';

-- 2. Mock 'first_operation' and 'operation_created' events to test Activation
-- Admin activated 40 days ago.
INSERT INTO public.analytics_events (user_id, event_name, created_at, event_data)
VALUES 
  ('a0000000-0000-0000-0000-000000000001', 'first_operation', now() - interval '40 days', '{"type": "sale"}'),
  ('a0000000-0000-0000-0000-000000000001', 'operation_created', now() - interval '40 days', '{"type": "sale"}'),
-- Normal user activated 25 days ago.
  ('a0000000-0000-0000-0000-000000000002', 'first_operation', now() - interval '25 days', '{"type": "purchase"}'),
  ('a0000000-0000-0000-0000-000000000002', 'operation_created', now() - interval '25 days', '{"type": "purchase"}');

-- 3. Mock UMV via AI Insights
-- Admin requested insight 39 days ago -> UMV Achieved on Day 39 ago.
INSERT INTO public.analytics_events (user_id, event_name, created_at, event_data)
VALUES 
  ('a0000000-0000-0000-0000-000000000001', 'insight_generated', now() - interval '39 days', '{"type": "general", "source_function": "ai-insights"}');

-- Normal user NO insight currently (meaning NO UMV) to test UMV% accuracy.

-- 4. Mock Retention Data
-- Cohort for Admin is 40 days ago. Retained if operation between Day 30 and 37 after activation.
-- 40 days ago + 32 days = 8 days ago. Let's make the Admin retained!
INSERT INTO public.analytics_events (user_id, event_name, created_at, event_data)
VALUES 
  ('a0000000-0000-0000-0000-000000000001', 'operation_created', now() - interval '8 days', '{"type": "sale"}');

-- 5. Mock Habit (Active Days) for the Admin over the last week.
INSERT INTO public.analytics_events (user_id, event_name, created_at, event_data)
VALUES 
  ('a0000000-0000-0000-0000-000000000001', 'operation_created', now() - interval '1 days', '{"type": "sale"}'),
  ('a0000000-0000-0000-0000-000000000001', 'operation_created', now() - interval '2 days', '{"type": "sale"}'),
  ('a0000000-0000-0000-0000-000000000001', 'operation_created', now() - interval '4 days', '{"type": "sale"}');

-- 6. Mock Community & other AI types
INSERT INTO public.analytics_events (user_id, event_name, created_at, event_data)
VALUES 
  ('a0000000-0000-0000-0000-000000000001', 'insight_generated', now() - interval '5 days', '{"type": "prediction"}'),
  ('a0000000-0000-0000-0000-000000000002', 'insight_generated', now() - interval '5 days', '{"type": "simulation"}'),
  ('a0000000-0000-0000-0000-000000000001', 'post_created', now() - interval '3 days', '{}'),
  ('a0000000-0000-0000-0000-000000000002', 'reply_created', now() - interval '2 days', '{}');

-- Check overview mapping quickly via RPC logic simulation (only admins can execute)
SELECT public.rpc_admin_kpi_overview(now() - interval '45 days', now(), 'week');
SELECT * FROM public.rpc_admin_retention_30d('week', now() - interval '45 days', now());
SELECT * FROM public.rpc_admin_weekly_usage_distribution(now() - interval '7 days', now());
