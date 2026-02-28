-- Create tables
create table public.meetings (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  meeting_url text not null,
  start_time timestamptz not null,
  created_at timestamptz default now()
);

create table public.purchase_pools (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  target_amount numeric not null,
  current_amount numeric default 0,
  closes_at timestamptz not null,
  status text default 'open' check (status in ('open', 'closing', 'closed')),
  created_at timestamptz default now()
);

-- Enable RLS
alter table public.meetings enable row level security;
alter table public.purchase_pools enable row level security;

create policy "Meetings are viewable by everyone" on public.meetings for select using (true);
create policy "Purchase pools are viewable by everyone" on public.purchase_pools for select using (true);

create policy "Admins can manage meetings" on public.meetings for all using (
  exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
);
create policy "Admins can manage purchase pools" on public.purchase_pools for all using (
  exists (select 1 from public.profiles where id = auth.uid() and role = 'admin')
);

-- Triggers for Notifications

-- 1. Meeting created -> Notice
create or replace function public.notify_meeting_created()
returns trigger as $$
begin
  insert into public.email_logs (event_type, recipient, subject, metadata)
  values (
    'meeting_notice',
    'all_users',
    'Nueva Reunión: ' || NEW.title,
    jsonb_build_object('meeting_id', NEW.id, 'title', NEW.title, 'start_time', NEW.start_time, 'url', NEW.meeting_url)
  );
  return NEW;
end;
$$ language plpgsql security definer;

create trigger on_meeting_created
  after insert on public.meetings
  for each row execute procedure public.notify_meeting_created();

-- 2. Pool created -> Notice
create or replace function public.notify_pool_created()
returns trigger as $$
begin
  insert into public.email_logs (event_type, recipient, subject, metadata)
  values (
    'pool_notice',
    'all_users',
    'Pool de Compra Abierto: ' || NEW.title,
    jsonb_build_object('pool_id', NEW.id, 'title', NEW.title, 'closes_at', NEW.closes_at)
  );
  return NEW;
end;
$$ language plpgsql security definer;

create trigger on_pool_created
  after insert on public.purchase_pools
  for each row execute procedure public.notify_pool_created();
