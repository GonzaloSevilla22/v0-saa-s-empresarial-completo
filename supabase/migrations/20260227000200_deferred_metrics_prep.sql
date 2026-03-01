-- =======================================================================================
-- MIGRATION: 20260227000200_deferred_metrics_prep.sql
-- DESCRIPTION: Postponed Schema preparation for CAC, Physical Origin, NPS, and MRR.
-- STATUS: Commented out intentionally per MVP V1 requirements.
-- =======================================================================================

/*
-- 1. CAC and Physical Channel Origin (To be added to profiles)
-- These columns will track how much was spent to acquire the user and through which channel.
ALTER TABLE public.profiles
ADD COLUMN acquisition_source text NULL,
ADD COLUMN acquisition_cost numeric NULL;

-- 2. NPS (Net Promoter Score) Tracking
-- A dedicated table to store quarterly or bi-annual NPS survey results per user.
CREATE TABLE public.nps_surveys (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  score integer CHECK (score >= 0 AND score <= 10) NOT NULL,
  feedback text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);
CREATE INDEX idx_nps_surveys_user ON public.nps_surveys(user_id);

-- 3. MRR / ARPU (Monthly Recurring Revenue / Average Revenue Per User)
-- (No immediate schema changes needed here as MRR can primarily be derived from Stripe Webhooks 
-- inserting rows into a 'subscriptions' table, or dynamically aggregating the 'sales'/'purchases' 
-- tables depending on the exact billing architecture chosen later).
*/

-- This file is intentionally empty of executable SQL commands for now.
-- Run `supabase db push` or `reset` safely; nothing will break.
SELECT 1 AS "deferred_metrics_acknowledged";
