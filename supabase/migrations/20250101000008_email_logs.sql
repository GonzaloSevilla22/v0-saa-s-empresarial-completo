-- public.email_logs
CREATE TABLE IF NOT EXISTS public.email_logs (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  event_type text NOT NULL, -- e.g., 'welcome', 'meeting_reminder', 'pool_notice', 'stock_alert'
  recipient text NOT NULL,
  subject text NOT NULL,
  status text NOT NULL DEFAULT 'pending', -- 'pending', 'sent', 'failed'
  provider_id text, -- ID returned by Resend
  error_details text,
  metadata jsonb DEFAULT '{}'::jsonb, -- extra context like meeting_id, pool_id
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  sent_at timestamp with time zone,
  
  -- deduplication constraints based on event logic
  UNIQUE NULLS NOT DISTINCT (user_id, event_type, metadata)
);

-- RLS
ALTER TABLE public.email_logs ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins can view email logs" ON public.email_logs;
CREATE POLICY "Admins can view email logs" ON public.email_logs
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.profiles
      WHERE profiles.id = auth.uid() AND profiles.role = 'admin'
    )
  );

-- No insert/update/delete policies for authenticated users.
-- Only database triggers, Edge Functions (with service_role), or superusers should manipulate this.

CREATE INDEX IF NOT EXISTS idx_email_logs_status ON public.email_logs(status);
CREATE INDEX IF NOT EXISTS idx_email_logs_user ON public.email_logs(user_id);
