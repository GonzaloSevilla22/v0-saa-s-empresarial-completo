-- Create seguros table
CREATE TABLE IF NOT EXISTS seguros (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    title TEXT NOT NULL,
    description TEXT,
    coverage TEXT,
    price TEXT,
    contact_url TEXT,
    is_visible BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now()
);

-- Enable RLS
ALTER TABLE seguros ENABLE ROW LEVEL SECURITY;

-- Policies
DROP POLICY IF EXISTS "Public items are viewable by everyone" ON seguros;
CREATE POLICY "Public items are viewable by everyone" ON seguros
    FOR SELECT USING (is_visible = true);

DROP POLICY IF EXISTS "Admins have full access" ON seguros;
CREATE POLICY "Admins have full access" ON seguros
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Index for visibility
CREATE INDEX IF NOT EXISTS idx_seguros_visibility ON seguros(is_visible);

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

DROP TRIGGER IF EXISTS update_seguros_updated_at ON seguros;
CREATE TRIGGER update_seguros_updated_at
    BEFORE UPDATE ON seguros
    FOR EACH ROW
    EXECUTE PROCEDURE update_updated_at_column();
