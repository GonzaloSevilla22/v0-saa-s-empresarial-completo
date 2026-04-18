-- Create seguros table (idempotent)
CREATE TABLE IF NOT EXISTS public.seguros (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
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
ALTER TABLE public.seguros ENABLE ROW LEVEL SECURITY;

-- Policies
DROP POLICY IF EXISTS "Public items are viewable by everyone" ON public.seguros;
CREATE POLICY "Public items are viewable by everyone" ON public.seguros
    FOR SELECT USING (is_visible = true);

DROP POLICY IF EXISTS "Admins have full access" ON public.seguros;
CREATE POLICY "Admins have full access" ON public.seguros
    FOR ALL USING (
        EXISTS (
            SELECT 1 FROM public.profiles
            WHERE profiles.id = auth.uid()
            AND profiles.role = 'admin'
        )
    );

-- Index for visibility (idempotent)
CREATE INDEX IF NOT EXISTS idx_seguros_visibility ON public.seguros(is_visible);

-- Function for updated_at (idempotent via CREATE OR REPLACE)
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_seguros_updated_at ON public.seguros;
CREATE TRIGGER update_seguros_updated_at
    BEFORE UPDATE ON public.seguros
    FOR EACH ROW
    EXECUTE PROCEDURE public.update_updated_at_column();
