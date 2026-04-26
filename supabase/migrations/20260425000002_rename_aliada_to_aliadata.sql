-- Rename: update live DB functions/data that still reference the old brand name ALIADA → ALIADATA

-- 1. Recreate handle_new_user with updated welcome subject
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

-- 2. Update any existing welcome email_logs rows that still say ALIADA
UPDATE public.email_logs
SET subject = '¡Bienvenido a ALIADATA Emprendedores!'
WHERE event_type = 'welcome'
  AND subject = '¡Bienvenido a ALIADA Emprendedores!';

-- 3. Update landing content rows seeded with the old brand name
UPDATE public.landing_sections
SET
  title     = REPLACE(title,    'ALIADA', 'ALIADATA'),
  subtitle  = REPLACE(subtitle, 'ALIADA', 'ALIADATA'),
  content   = REPLACE(content,  'ALIADA', 'ALIADATA')
WHERE title    LIKE '%ALIADA%'
   OR subtitle LIKE '%ALIADA%'
   OR content  LIKE '%ALIADA%';
