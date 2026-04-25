-- Fix profile names and community visibility

-- 1. Add name column to profiles
ALTER TABLE public.profiles ADD COLUMN IF NOT EXISTS name text;

-- 2. Update existing profiles with names from auth.users metadata
UPDATE public.profiles
SET name = COALESCE(u.raw_user_meta_data->>'name', u.email::text)
FROM auth.users u
WHERE public.profiles.id = u.id;

-- 3. Update handle_new_user to include name
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
DECLARE
  user_name text;
BEGIN
  -- Extract name from metadata or email
  user_name := COALESCE(new.raw_user_meta_data->>'name', split_part(new.email, '@', 1));

  -- Create the profile with default values, including name
  INSERT INTO public.profiles (id, name, role, plan)
  VALUES (new.id, user_name, 'user', 'pro'); -- Default to PRO for now as per app requirements
  
  -- Queue Welcome Email (if table exists)
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'email_logs') THEN
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    VALUES (new.id, 'welcome', new.email, '¡Bienvenido a ALIADATA!', jsonb_build_object('name', user_name));
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 4. Adjust RLS to allow viewing names of other users
-- This is critical for the community module to display author names
DROP POLICY IF EXISTS "Profiles are viewable by everyone" ON public.profiles;
CREATE POLICY "Profiles are viewable by everyone" ON public.profiles
  FOR SELECT USING (true);
