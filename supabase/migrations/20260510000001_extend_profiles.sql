-- Applied directly via MCP on 2026-05-10. Stub recovered from supabase_migrations.schema_migrations.

-- Personal profile columns
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS last_name     text,
  ADD COLUMN IF NOT EXISTS avatar_url    text,
  ADD COLUMN IF NOT EXISTS business_name text,
  ADD COLUMN IF NOT EXISTS phone         text,
  ADD COLUMN IF NOT EXISTS bio           text
    CONSTRAINT profiles_bio_length CHECK (char_length(bio) <= 300);

-- System preference columns
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS currency    text NOT NULL DEFAULT 'ARS'
    CONSTRAINT profiles_currency_values
    CHECK (currency IN ('ARS', 'USD', 'EUR', 'BRL', 'CLP')),
  ADD COLUMN IF NOT EXISTS timezone    text NOT NULL
    DEFAULT 'America/Argentina/Buenos_Aires',
  ADD COLUMN IF NOT EXISTS date_format text NOT NULL DEFAULT 'DD/MM/YYYY'
    CONSTRAINT profiles_date_format_values
    CHECK (date_format IN ('DD/MM/YYYY', 'MM/DD/YYYY', 'YYYY-MM-DD')),
  ADD COLUMN IF NOT EXISTS language    text NOT NULL DEFAULT 'es';

-- Auto-update updated_at trigger
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_profiles_updated_at ON public.profiles;
CREATE TRIGGER trg_profiles_updated_at
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();

-- Storage bucket: avatars
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,
  2097152,
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Storage RLS policies
DROP POLICY IF EXISTS "avatars_public_read"  ON storage.objects;
CREATE POLICY "avatars_public_read" ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars');

DROP POLICY IF EXISTS "avatars_owner_insert" ON storage.objects;
CREATE POLICY "avatars_owner_insert" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'avatars'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "avatars_owner_update" ON storage.objects;
CREATE POLICY "avatars_owner_update" ON storage.objects
  FOR UPDATE USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

DROP POLICY IF EXISTS "avatars_owner_delete" ON storage.objects;
CREATE POLICY "avatars_owner_delete" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_profiles_business_name
  ON public.profiles (business_name)
  WHERE business_name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_currency
  ON public.profiles (currency);
