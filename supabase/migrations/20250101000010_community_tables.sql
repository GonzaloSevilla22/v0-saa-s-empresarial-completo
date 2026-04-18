-- Create tables (idempotent)
CREATE TABLE IF NOT EXISTS public.meetings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  meeting_url text NOT NULL,
  start_time timestamptz NOT NULL,
  created_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.purchase_pools (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  description text,
  target_amount numeric NOT NULL,
  current_amount numeric DEFAULT 0,
  closes_at timestamptz NOT NULL,
  status text DEFAULT 'open' CHECK (status IN ('open', 'closing', 'closed')),
  created_at timestamptz DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.purchase_pools ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Meetings are viewable by everyone" ON public.meetings;
CREATE POLICY "Meetings are viewable by everyone" ON public.meetings FOR SELECT USING (true);

DROP POLICY IF EXISTS "Purchase pools are viewable by everyone" ON public.purchase_pools;
CREATE POLICY "Purchase pools are viewable by everyone" ON public.purchase_pools FOR SELECT USING (true);

DROP POLICY IF EXISTS "Admins can manage meetings" ON public.meetings;
CREATE POLICY "Admins can manage meetings" ON public.meetings FOR ALL USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

DROP POLICY IF EXISTS "Admins can manage purchase pools" ON public.purchase_pools;
CREATE POLICY "Admins can manage purchase pools" ON public.purchase_pools FOR ALL USING (
  EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin')
);

-- Triggers for Notifications

-- 1. Meeting created -> Notice
CREATE OR REPLACE FUNCTION public.notify_meeting_created()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.email_logs (event_type, recipient, subject, metadata)
  VALUES (
    'meeting_notice',
    'all_users',
    'Nueva Reunión: ' || NEW.title,
    jsonb_build_object('meeting_id', NEW.id, 'title', NEW.title, 'start_time', NEW.start_time, 'url', NEW.meeting_url)
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_meeting_created ON public.meetings;
CREATE TRIGGER on_meeting_created
  AFTER INSERT ON public.meetings
  FOR EACH ROW EXECUTE PROCEDURE public.notify_meeting_created();

-- 2. Pool created -> Notice
CREATE OR REPLACE FUNCTION public.notify_pool_created()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.email_logs (event_type, recipient, subject, metadata)
  VALUES (
    'pool_notice',
    'all_users',
    'Pool de Compra Abierto: ' || NEW.title,
    jsonb_build_object('pool_id', NEW.id, 'title', NEW.title, 'closes_at', NEW.closes_at)
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_pool_created ON public.purchase_pools;
CREATE TRIGGER on_pool_created
  AFTER INSERT ON public.purchase_pools
  FOR EACH ROW EXECUTE PROCEDURE public.notify_pool_created();
