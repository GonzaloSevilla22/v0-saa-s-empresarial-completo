-- Add clicks_count to seguros
ALTER TABLE seguros ADD COLUMN IF NOT EXISTS clicks_count INTEGER DEFAULT 0;

-- Create fair_ai_tools table
CREATE TABLE IF NOT EXISTS fair_ai_tools (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    category TEXT NOT NULL,
    description TEXT,
    link TEXT,
    status TEXT DEFAULT 'active',
    clicks_count INTEGER DEFAULT 0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Create copilot_prompts table
CREATE TABLE IF NOT EXISTS copilot_prompts (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
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
ALTER TABLE fair_ai_tools ENABLE ROW LEVEL SECURITY;
ALTER TABLE copilot_prompts ENABLE ROW LEVEL SECURITY;

-- Policies
CREATE POLICY "Public tools are viewable by everyone" ON fair_ai_tools
    FOR SELECT USING (status = 'active');

CREATE POLICY "Admin full access fair_ai_tools" ON fair_ai_tools
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

CREATE POLICY "Public prompts are viewable by everyone" ON copilot_prompts
    FOR SELECT USING (status = 'active');

CREATE POLICY "Admin full access copilot_prompts" ON copilot_prompts
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Triggers for updated_at
CREATE TRIGGER update_fair_ai_tools_updated_at
    BEFORE UPDATE ON fair_ai_tools
    FOR EACH ROW
    EXECUTE PROCEDURE update_updated_at_column();

CREATE TRIGGER update_copilot_prompts_updated_at
    BEFORE UPDATE ON copilot_prompts
    FOR EACH ROW
    EXECUTE PROCEDURE update_updated_at_column();
