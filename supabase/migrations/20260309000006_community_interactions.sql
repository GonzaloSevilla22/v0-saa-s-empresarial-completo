-- Community Interactions: Likes and Replies Count
-- This migration adds a post_likes table and updates counters on posts.

-- 1. Create post_likes table (idempotent)
CREATE TABLE IF NOT EXISTS public.post_likes (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  post_id UUID REFERENCES public.posts(id) ON DELETE CASCADE NOT NULL,
  user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE NOT NULL,
  created_at TIMESTAMPTZ DEFAULT now() NOT NULL,
  UNIQUE(post_id, user_id)
);

-- 2. Add replies_count to posts (idempotent)
ALTER TABLE public.posts ADD COLUMN IF NOT EXISTS replies_count INTEGER DEFAULT 0 NOT NULL;

-- 3. Enable RLS for post_likes
ALTER TABLE public.post_likes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anyone can view likes" ON public.post_likes;
CREATE POLICY "Anyone can view likes" ON public.post_likes FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can toggle own likes" ON public.post_likes;
CREATE POLICY "Users can toggle own likes" ON public.post_likes FOR ALL USING (auth.uid() = user_id);

-- 4. Triggers to maintain counters

-- Function to update like count
CREATE OR REPLACE FUNCTION public.update_post_likes_count()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    UPDATE public.posts SET likes_count = likes_count + 1 WHERE id = NEW.post_id;
  ELSIF (TG_OP = 'DELETE') THEN
    UPDATE public.posts SET likes_count = likes_count - 1 WHERE id = OLD.post_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_post_like_change ON public.post_likes;
CREATE TRIGGER on_post_like_change
  AFTER INSERT OR DELETE ON public.post_likes
  FOR EACH ROW EXECUTE PROCEDURE public.update_post_likes_count();

-- Function to update replies count
CREATE OR REPLACE FUNCTION public.update_post_replies_count()
RETURNS TRIGGER AS $$
BEGIN
  IF (TG_OP = 'INSERT') THEN
    UPDATE public.posts SET replies_count = replies_count + 1 WHERE id = NEW.post_id;
  ELSIF (TG_OP = 'DELETE') THEN
    UPDATE public.posts SET replies_count = replies_count - 1 WHERE id = OLD.post_id;
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_post_reply_change ON public.replies;
CREATE TRIGGER on_post_reply_change
  AFTER INSERT OR DELETE ON public.replies
  FOR EACH ROW EXECUTE PROCEDURE public.update_post_replies_count();

-- 5. Initialize existing counts (idempotent — UPDATE is safe)
UPDATE public.posts p
SET 
  likes_count = (SELECT count(*) FROM public.post_likes WHERE post_id = p.id),
  replies_count = (SELECT count(*) FROM public.replies WHERE post_id = p.id);
