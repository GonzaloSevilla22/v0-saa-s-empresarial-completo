-- Create landing_sections table (idempotent)
CREATE TABLE IF NOT EXISTS public.landing_sections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug TEXT UNIQUE NOT NULL,
    type TEXT NOT NULL, -- hero, features, image_text, benefits, testimonials, cta
    title TEXT,
    subtitle TEXT,
    content TEXT,
    image_url TEXT,
    button_text TEXT,
    button_link TEXT,
    position INTEGER DEFAULT 0,
    active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Enable RLS
ALTER TABLE public.landing_sections ENABLE ROW LEVEL SECURITY;

-- Allow public read access
DROP POLICY IF EXISTS "Allow public read access for landing sections" ON public.landing_sections;
CREATE POLICY "Allow public read access for landing sections"
ON public.landing_sections FOR SELECT
USING (active = true);

-- Allow admin write access
DROP POLICY IF EXISTS "Allow admin write access for landing sections" ON public.landing_sections;
CREATE POLICY "Allow admin write access for landing sections"
ON public.landing_sections FOR ALL
USING (auth.role() = 'authenticated');

-- Create storage bucket for landing images (idempotent)
INSERT INTO storage.buckets (id, name, public) 
VALUES ('landing', 'landing', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for landing bucket (idempotent)
DROP POLICY IF EXISTS "Public Access" ON storage.objects;
CREATE POLICY "Public Access"
ON storage.objects FOR SELECT
USING ( bucket_id = 'landing' );

DROP POLICY IF EXISTS "Admin Upload" ON storage.objects;
CREATE POLICY "Admin Upload"
ON storage.objects FOR INSERT
WITH CHECK ( bucket_id = 'landing' AND auth.role() = 'authenticated' );

DROP POLICY IF EXISTS "Admin Update/Delete" ON storage.objects;
CREATE POLICY "Admin Update/Delete"
ON storage.objects FOR ALL
USING ( bucket_id = 'landing' AND auth.role() = 'authenticated' );

-- Function for updated_at (idempotent via CREATE OR REPLACE)
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS update_landing_sections_updated_at ON public.landing_sections;
CREATE TRIGGER update_landing_sections_updated_at
    BEFORE UPDATE ON public.landing_sections
    FOR EACH ROW
    EXECUTE PROCEDURE public.update_updated_at_column();
