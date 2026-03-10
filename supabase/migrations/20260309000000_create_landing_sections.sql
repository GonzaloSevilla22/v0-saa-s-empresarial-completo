-- Create landing_sections table
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
CREATE POLICY "Allow public read access for landing sections"
ON public.landing_sections FOR SELECT
USING (active = true);

-- Allow admin write access (using service_role or authenticated with admin check)
-- For the purpose of this implementation, we'll allow authenticated users for now
-- but ideally this should be restricted to a specific 'admin' role if available.
CREATE POLICY "Allow admin write access for landing sections"
ON public.landing_sections FOR ALL
USING (auth.role() = 'authenticated');

-- Create storage bucket for landing images
INSERT INTO storage.buckets (id, name, public) 
VALUES ('landing', 'landing', true)
ON CONFLICT (id) DO NOTHING;

-- Storage policies for landing bucket
CREATE POLICY "Public Access"
ON storage.objects FOR SELECT
USING ( bucket_id = 'landing' );

CREATE POLICY "Admin Upload"
ON storage.objects FOR INSERT
WITH CHECK ( bucket_id = 'landing' AND auth.role() = 'authenticated' );

CREATE POLICY "Admin Update/Delete"
ON storage.objects FOR ALL
USING ( bucket_id = 'landing' AND auth.role() = 'authenticated' );

-- Trigger for updated_at
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ language 'plpgsql';

CREATE TRIGGER update_landing_sections_updated_at
    BEFORE UPDATE ON landing_sections
    FOR EACH ROW
    EXECUTE PROCEDURE update_updated_at_column();
