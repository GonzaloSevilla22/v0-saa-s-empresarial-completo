-- Migration: 20260228000600_fix_rls_and_trigger.sql
-- Description: Fixes RLS recursion on profiles and ensures auth trigger exists

-- 1. Helper function for non-recursive admin check
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM public.profiles 
    WHERE id = auth.uid() 
    AND role = 'admin'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2. Fix Profile RLS Policies
DROP POLICY IF EXISTS "Users can view own profile" ON public.profiles;
DROP POLICY IF EXISTS "Users can update own profile" ON public.profiles;
DROP POLICY IF EXISTS "Admins can view all profiles" ON public.profiles;
DROP POLICY IF EXISTS "Admins can update all profiles" ON public.profiles;

-- Owner can always see and update their own profile
CREATE POLICY "Users can view own profile" ON public.profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON public.profiles FOR UPDATE USING (auth.uid() = id);

-- Admin can see and update everything
CREATE POLICY "Admins can view all profiles" ON public.profiles FOR SELECT USING (public.is_admin());
CREATE POLICY "Admins can update all profiles" ON public.profiles FOR UPDATE USING (public.is_admin());

-- 3. Restore Auth Trigger (Fixing the skip seen in logs)
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
DECLARE
  user_name text;
BEGIN
  -- Create the profile with default values
  INSERT INTO public.profiles (id, role, plan)
  VALUES (new.id, 'user', 'pro'); -- Default to PRO for now as per app requirements
  
  -- Extract name from metadata
  user_name := COALESCE(new.raw_user_meta_data->>'name', 'Emprendedor');

  -- Queue Welcome Email (if table exists)
  IF EXISTS (SELECT FROM information_schema.tables WHERE table_name = 'email_logs') THEN
    INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
    VALUES (new.id, 'welcome', new.email, '¡Bienvenido a ALIADATA!', jsonb_build_object('name', user_name));
  END IF;

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Ensure trigger is on auth.users (re-creating it just in case)
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE PROCEDURE public.handle_new_user();
