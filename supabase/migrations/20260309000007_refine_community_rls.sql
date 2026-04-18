-- Refine Community Interactions RLS and Checks
-- This fixes potential issues with "FOR ALL" policies not applying correctly to INSERTS

-- 1. Redefine post_likes policies
DROP POLICY IF EXISTS "Users can toggle own likes" ON public.post_likes;
DROP POLICY IF EXISTS "Anyone can view likes" ON public.post_likes;

CREATE POLICY "Anyone can view likes" ON public.post_likes 
FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert own likes" ON public.post_likes;
CREATE POLICY "Users can insert own likes" ON public.post_likes 
FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete own likes" ON public.post_likes;
CREATE POLICY "Users can delete own likes" ON public.post_likes 
FOR DELETE USING (auth.uid() = user_id);

-- 2. Ensure replies triggers are robust
-- (Already handled by SECURITY DEFINER in migration 0006)

-- 3. Double check posts deletion policy
DROP POLICY IF EXISTS "Users can delete own posts" ON public.posts;
CREATE POLICY "Users can delete own posts" ON public.posts 
FOR DELETE USING (auth.uid() = user_id);

-- 4. Unambiguous join for PostgREST
-- Ensure we have a comment to help PostgREST if needed (though FK should be enough)
COMMENT ON CONSTRAINT posts_user_id_fkey ON public.posts IS 'Author profile relationship';
