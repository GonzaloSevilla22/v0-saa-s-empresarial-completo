-- =============================================================================
-- MIGRATION: 20260610000000_export_module.sql
-- CHANGE:    C-14 export-module
-- DESCRIPTION:
--   Adds data-export capability:
--     Block 1: profiles.exports_used counter
--     Block 2: export_logs table + RLS
--     Block 3: Storage bucket `exports` + bucket RLS
--     Block 4: rpc_increment_export_usage (atomic counter)
--     Block 5: pg_cron reset-export-counters (monthly)
--
-- ROLLBACK (in order):
--   SELECT cron.unschedule('reset-export-counters');
--   DROP FUNCTION IF EXISTS public.rpc_increment_export_usage(UUID);
--   DELETE FROM storage.objects WHERE bucket_id = 'exports';
--   DELETE FROM storage.buckets WHERE id = 'exports';
--   DROP TABLE IF EXISTS public.export_logs;
--   ALTER TABLE public.profiles DROP COLUMN IF EXISTS exports_used;
-- =============================================================================

-- ─── BLOCK 1: profiles.exports_used ──────────────────────────────────────────

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS exports_used integer NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.profiles.exports_used
  IS 'Number of exports generated this month. Reset monthly by reset-export-counters cron job.';

-- ─── BLOCK 2: export_logs table ───────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.export_logs (
  id                    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id                uuid        REFERENCES public.accounts(id) ON DELETE SET NULL,
  export_type           text        NOT NULL,
  CONSTRAINT export_logs_type_values CHECK (
    export_type IN ('sales_csv', 'purchases_csv', 'expenses_csv', 'stock_csv', 'full_report_xlsx')
  ),
  file_path             text        NOT NULL,
  signed_url            text,
  signed_url_expires_at timestamptz,
  status                text        NOT NULL DEFAULT 'generated',
  CONSTRAINT export_logs_status_values CHECK (status IN ('generated', 'expired', 'error')),
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_export_logs_user_id     ON public.export_logs (user_id);
CREATE INDEX IF NOT EXISTS idx_export_logs_created_at  ON public.export_logs (created_at DESC);

ALTER TABLE public.export_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "export_logs_select_own" ON public.export_logs;
CREATE POLICY "export_logs_select_own" ON public.export_logs
  FOR SELECT USING (user_id = auth.uid());

DROP POLICY IF EXISTS "export_logs_insert_own" ON public.export_logs;
CREATE POLICY "export_logs_insert_own" ON public.export_logs
  FOR INSERT WITH CHECK (user_id = auth.uid());

DROP POLICY IF EXISTS "export_logs_update_own" ON public.export_logs;
CREATE POLICY "export_logs_update_own" ON public.export_logs
  FOR UPDATE USING (user_id = auth.uid());

-- ─── BLOCK 3: Storage bucket `exports` ────────────────────────────────────────

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'exports',
  'exports',
  false,
  10485760,   -- 10 MB max per file
  ARRAY['text/csv', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet']
)
ON CONFLICT (id) DO NOTHING;

-- RLS: users can only read their own files (path starts with their user_id)
DROP POLICY IF EXISTS "exports_bucket_select_own" ON storage.objects;
CREATE POLICY "exports_bucket_select_own" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'exports' AND
    auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "exports_bucket_insert_own" ON storage.objects;
CREATE POLICY "exports_bucket_insert_own" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'exports' AND
    auth.uid()::text = (storage.foldername(name))[1]
  );

DROP POLICY IF EXISTS "exports_bucket_delete_own" ON storage.objects;
CREATE POLICY "exports_bucket_delete_own" ON storage.objects
  FOR DELETE USING (
    bucket_id = 'exports' AND
    auth.uid()::text = (storage.foldername(name))[1]
  );

-- ─── BLOCK 4: rpc_increment_export_usage ──────────────────────────────────────
-- Atomic counter increment — mirrors rpc_increment_ai_usage from C-04.

CREATE OR REPLACE FUNCTION public.rpc_increment_export_usage(
  p_user_id UUID
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF p_user_id IS DISTINCT FROM auth.uid() THEN
    RAISE EXCEPTION 'unauthorized';
  END IF;

  UPDATE public.profiles
  SET exports_used = exports_used + 1
  WHERE id = p_user_id;
END;
$$;

REVOKE ALL ON FUNCTION public.rpc_increment_export_usage(UUID) FROM PUBLIC;
GRANT  EXECUTE ON FUNCTION public.rpc_increment_export_usage(UUID) TO authenticated;

-- ─── BLOCK 5: pg_cron — monthly reset of export counters ─────────────────────
-- Runs 00:05 UTC on the 1st of each month (5 min after AI counters reset).

DO $$
BEGIN
  PERFORM cron.unschedule('reset-export-counters');
EXCEPTION WHEN OTHERS THEN
  -- Job did not exist yet — safe to ignore
END;
$$;

SELECT cron.schedule(
  'reset-export-counters',
  '5 0 1 * *',
  $$UPDATE public.profiles SET exports_used = 0$$
);

-- =============================================================================
-- VERIFICATION QUERIES (run manually after applying):
-- SELECT column_name FROM information_schema.columns WHERE table_name = 'profiles' AND column_name = 'exports_used';
-- SELECT count(*) FROM public.export_logs;  -- Expected: 0
-- SELECT id FROM storage.buckets WHERE id = 'exports';
-- SELECT jobname FROM cron.job WHERE jobname = 'reset-export-counters';
-- =============================================================================
