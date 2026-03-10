-- Add foreign key constraints to allow PostgREST joins between community tables and profiles
-- This fixes the 400 Bad Request error when fetching posts with author names

-- Add FK for posts
ALTER TABLE public.posts
DROP CONSTRAINT IF EXISTS posts_user_id_fkey,
ADD CONSTRAINT posts_user_id_fkey 
FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

-- Add FK for replies
ALTER TABLE public.replies
DROP CONSTRAINT IF EXISTS replies_user_id_fkey,
ADD CONSTRAINT replies_user_id_fkey 
FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;

-- Add comment to explain why this is here
COMMENT ON TABLE public.posts IS 'Community posts linked to user profiles for author identification';
COMMENT ON TABLE public.replies IS 'Post replies linked to user profiles for author identification';
