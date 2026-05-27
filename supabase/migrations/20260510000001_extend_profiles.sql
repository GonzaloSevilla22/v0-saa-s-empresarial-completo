-- =============================================================================
-- MIGRATION: 20260510000001_extend_profiles.sql
-- DESCRIPTION: Extend profiles table with personal info, business data,
--              and system preferences for the user settings module.
--              Also adds the missing updated_at trigger and the avatars
--              storage bucket with owner-scoped RLS policies.
--
-- ALL changes are additive (ADD COLUMN IF NOT EXISTS + defaults).
-- Existing rows will receive the column defaults — no data loss.
-- =============================================================================

-- ── 1. Personal profile columns ───────────────────────────────────────────────
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS last_name     text,
  ADD COLUMN IF NOT EXISTS avatar_url    text,
  ADD COLUMN IF NOT EXISTS business_name text,
  ADD COLUMN IF NOT EXISTS phone         text,
  ADD COLUMN IF NOT EXISTS bio           text
    CONSTRAINT profiles_bio_length CHECK (char_length(bio) <= 300);

-- ── 2. System preference columns ─────────────────────────────────────────────
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

-- ── 3. Auto-update updated_at (was missing) ───────────────────────────────────
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
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

-- ── 4. Storage bucket: avatars ────────────────────────────────────────────────
-- Public bucket so avatar URLs are directly accessible without a signed token.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'avatars',
  'avatars',
  true,
  2097152,              -- 2 MB per file
  ARRAY['image/jpeg', 'image/png', 'image/webp', 'image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- ── 5. Storage RLS policies ───────────────────────────────────────────────────

-- 5a. Anyone can read avatar objects (public CDN-style access)
DROP POLICY IF EXISTS "avatars_public_read" ON storage.objects;
CREATE POLICY "avatars_public_read" ON storage.objects
  FOR SELECT
  USING (bucket_id = 'avatars');

-- 5b. Authenticated user can upload only inside their own folder ({uid}/...)
DROP POLICY IF EXISTS "avatars_owner_insert" ON storage.objects;
CREATE POLICY "avatars_owner_insert" ON storage.objects
  FOR INSERT
  WITH CHECK (
    bucket_id = 'avatars'
    AND auth.role() = 'authenticated'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 5c. Owner can replace / update their own avatar
DROP POLICY IF EXISTS "avatars_owner_update" ON storage.objects;
CREATE POLICY "avatars_owner_update" ON storage.objects
  FOR UPDATE
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- 5d. Owner can delete their own avatar
DROP POLICY IF EXISTS "avatars_owner_delete" ON storage.objects;
CREATE POLICY "avatars_owner_delete" ON storage.objects
  FOR DELETE
  USING (
    bucket_id = 'avatars'
    AND (storage.foldername(name))[1] = auth.uid()::text
  );

-- ── 6. Performance indexes ────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_profiles_business_name
  ON public.profiles (business_name)
  WHERE business_name IS NOT NULL;

CREATE INDEX IF NOT EXISTS idx_profiles_currency
  ON public.profiles (currency);

-- ── 7. Fix check_low_stock trigger — SECURITY DEFINER ─────────────────────────
-- Root cause: function was SECURITY INVOKER. When stock ≤ 5 on INSERT, the
-- trigger tried to SELECT from auth.users which the authenticated role cannot
-- access, causing a permission-denied error and a 403 on the product INSERT.
-- Fix: SECURITY DEFINER + SET search_path = public (prevents path hijacking).
CREATE OR REPLACE FUNCTION public.check_low_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  recent_alert boolean;
BEGIN
  IF NEW.stock <= 5 AND (TG_OP = 'INSERT' OR OLD.stock > 5) THEN
    SELECT EXISTS (
      SELECT 1 FROM public.email_logs
      WHERE event_type = 'low_stock_alert'
        AND metadata->>'product_id' = NEW.id::text
        AND created_at > now() - INTERVAL '24 hours'
    ) INTO recent_alert;

    IF NOT recent_alert THEN
      INSERT INTO public.email_logs (user_id, event_type, recipient, subject, metadata)
      SELECT
        NEW.user_id,
        'low_stock_alert',
        u.email,
        'Alerta de Stock Bajo: ' || NEW.name,
        jsonb_build_object(
          'product_id',    NEW.id,
          'product_name',  NEW.name,
          'current_stock', NEW.stock
        )
      FROM auth.users u
      WHERE u.id = NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END;
$$;
