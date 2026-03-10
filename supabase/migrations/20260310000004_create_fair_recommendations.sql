-- Create fair_recommendations table
CREATE TABLE IF NOT EXISTS public.fair_recommendations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
    recommendation JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.fair_recommendations ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Users can view their own fair recommendations"
    ON public.fair_recommendations
    FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can insert their own fair recommendations"
    ON public.fair_recommendations
    FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- Indexes
CREATE INDEX IF NOT EXISTS fair_recommendations_user_id_idx ON public.fair_recommendations(user_id);
CREATE INDEX IF NOT EXISTS fair_recommendations_created_at_idx ON public.fair_recommendations(created_at DESC);
