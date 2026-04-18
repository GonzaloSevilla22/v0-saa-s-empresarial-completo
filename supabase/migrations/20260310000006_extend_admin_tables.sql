-- Add clicks_count to seguros (idempotent)
ALTER TABLE public.seguros ADD COLUMN IF NOT EXISTS clicks_count INTEGER DEFAULT 0;

-- Create fair_ai_tools table (idempotent)
CREATE TABLE IF NOT EXISTS public.fair_ai_tools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    link TEXT,
    status TEXT DEFAULT 'active',
    clicks_count INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create copilot_prompts table (idempotent)
CREATE TABLE IF NOT EXISTS public.copilot_prompts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    prompt_text TEXT NOT NULL,
    usage_count INTEGER DEFAULT 0,
    status TEXT DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE public.fair_ai_tools ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.copilot_prompts ENABLE ROW LEVEL SECURITY;

-- Policies for fair_ai_tools
DROP POLICY IF EXISTS "Public tools are viewable by everyone" ON public.fair_ai_tools;
CREATE POLICY "Public tools are viewable by everyone" ON public.fair_ai_tools
    FOR SELECT USING (status = 'active');

DROP POLICY IF EXISTS "Admin full access fair_ai_tools" ON public.fair_ai_tools;
CREATE POLICY "Admin full access fair_ai_tools" ON public.fair_ai_tools
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Policies for copilot_prompts
DROP POLICY IF EXISTS "Public prompts are viewable by everyone" ON public.copilot_prompts;
CREATE POLICY "Public prompts are viewable by everyone" ON public.copilot_prompts
    FOR SELECT USING (status = 'active');

DROP POLICY IF EXISTS "Admin full access copilot_prompts" ON public.copilot_prompts;
CREATE POLICY "Admin full access copilot_prompts" ON public.copilot_prompts
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Triggers for updated_at (idempotent)
DROP TRIGGER IF EXISTS update_fair_ai_tools_updated_at ON public.fair_ai_tools;
CREATE TRIGGER update_fair_ai_tools_updated_at
    BEFORE UPDATE ON public.fair_ai_tools
    FOR EACH ROW
    EXECUTE PROCEDURE public.update_updated_at_column();

DROP TRIGGER IF EXISTS update_copilot_prompts_updated_at ON public.copilot_prompts;
CREATE TRIGGER update_copilot_prompts_updated_at
    BEFORE UPDATE ON public.copilot_prompts
    FOR EACH ROW
    EXECUTE PROCEDURE public.update_updated_at_column();
