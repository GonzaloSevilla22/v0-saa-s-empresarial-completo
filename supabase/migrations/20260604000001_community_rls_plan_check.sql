-- Community RLS: add plan check to posts and replies INSERT
-- Part of change C-09 community-bug-fixes
-- Only users with plan = 'pro' can create posts or replies.
-- SELECT, DELETE, UPDATE policies remain unchanged.

-- Posts INSERT: only pro plan
DROP POLICY IF EXISTS "Pro users can insert posts" ON public.posts;
CREATE POLICY "Pro users can insert posts"
ON public.posts FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = (SELECT auth.uid())
      AND plan = 'pro'
  )
);

-- Replies INSERT: only pro plan
DROP POLICY IF EXISTS "Pro users can insert replies" ON public.replies;
CREATE POLICY "Pro users can insert replies"
ON public.replies FOR INSERT
WITH CHECK (
  EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = (SELECT auth.uid())
      AND plan = 'pro'
  )
);
