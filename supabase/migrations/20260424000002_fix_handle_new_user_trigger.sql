-- Fix handle_new_user: stop hardcoding plan='free' so new signups
-- inherit the column DEFAULT (currently 'pro' for the beta phase).
-- email_logs already exists (migration 20250101000008), no changes needed there.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger AS $$
DECLARE
  user_name text;
BEGIN
  -- 1. Create the profile — omit plan so it uses the column DEFAULT
  INSERT INTO public.profiles (id, role)
  VALUES (new.id, 'user');

  -- 2. Extract name from raw_user_meta_data if exists, else default
  user_name := COALESCE(new.raw_user_meta_data->>'name', 'Emprendedor');

  -- 3. Queue the Welcome Email
  INSERT INTO public.email_logs (
    user_id,
    event_type,
    recipient,
    subject,
    metadata
  ) VALUES (
    new.id,
    'welcome',
    new.email,
    '¡Bienvenido a ALIADATA Emprendedores!',
    jsonb_build_object('name', user_name)
  );

  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
