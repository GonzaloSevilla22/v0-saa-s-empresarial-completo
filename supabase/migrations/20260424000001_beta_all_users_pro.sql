-- Beta phase: all users start as PRO so early testers have full access.
-- When freemium enforcement is ready, revert the default to 'free' and
-- manually downgrade users who should be on the free plan.

-- 1. Upgrade all existing profiles to pro
UPDATE public.profiles
SET plan = 'pro'
WHERE plan = 'free';

-- 2. Change the default for new signups to pro
ALTER TABLE public.profiles
  ALTER COLUMN plan SET DEFAULT 'pro'::user_plan;
