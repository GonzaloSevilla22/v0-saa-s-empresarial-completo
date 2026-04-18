-- Create ai_insights table (idempotent)
CREATE TABLE IF NOT EXISTS public.ai_insights (
    id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
    type text NOT NULL, -- ventas, stock, margen, producto, marketing
    priority text NOT NULL, -- alta, media, baja
    message text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- RLS Policies
ALTER TABLE public.ai_insights ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view their own insights" ON public.ai_insights;
CREATE POLICY "Users can view their own insights"
    ON public.ai_insights FOR SELECT
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "System/Functions can insert insights" ON public.ai_insights;
CREATE POLICY "System/Functions can insert insights"
    ON public.ai_insights FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Index for performance (idempotent)
CREATE INDEX IF NOT EXISTS idx_ai_insights_user_id ON public.ai_insights(user_id);
CREATE INDEX IF NOT EXISTS idx_ai_insights_created_at ON public.ai_insights(created_at);
