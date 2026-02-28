-- public.email_logs
create table if not exists public.email_logs (
  id uuid default gen_random_uuid() primary key,
  user_id uuid references auth.users(id) on delete set null,
  event_type text not null, -- e.g., 'welcome', 'meeting_reminder', 'pool_notice', 'stock_alert'
  recipient text not null,
  subject text not null,
  status text not null default 'pending', -- 'pending', 'sent', 'failed'
  provider_id text, -- ID returned by Resend
  error_details text,
  metadata jsonb default '{}'::jsonb, -- extra context like meeting_id, pool_id
  created_at timestamp with time zone default now() not null,
  sent_at timestamp with time zone,
  
  -- deduplication constraints based on event logic
  unique nulls not distinct (user_id, event_type, metadata)
);

-- RLS
alter table public.email_logs enable row level security;

-- Only admins or the system can read all logs. 
-- Users cannot access this table directly to prevent leak of other emails.
-- A policy could be added for debugging if needed, but for Zero Trust, we keep it locked.
create policy "Admins can view email logs" on public.email_logs
  for select
  to authenticated
  using (
    exists (
      select 1 from public.profiles
      where profiles.id = auth.uid() and profiles.role = 'admin'
    )
  );

-- No insert/update/delete policies for authenticated users.
-- Only database triggers, Edge Functions (with service_role), or superusers should manipulate this.

create index idx_email_logs_status on public.email_logs(status);
create index idx_email_logs_user on public.email_logs(user_id);
