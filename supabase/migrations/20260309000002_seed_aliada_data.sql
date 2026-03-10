-- Seed initial landing data for ALIADA
DELETE FROM public.landing_sections;

INSERT INTO public.landing_sections (slug, type, title, subtitle, content, position, active)
VALUES 
('hero-main', 'hero', 'Potenciá tu Negocio con ALIADA', 'La plataforma integral que transforma tu gestión empresarial con Inteligencia Artificial.', 'Gestioná ventas, stock y comunidad en un solo lugar. Diseñado para emprendedores que buscan el siguiente nivel.', 1, true),

('features-grid', 'features', 'Herramientas Inteligentes', 'Todo lo que necesitás para escalar tu empresa sin fricciones.', 'Descubrí cómo ALIADA centraliza tu operativa y te brinda insights accionables en tiempo real.', 2, true),

('benefit-ai', 'image_text', 'IA que Trabaja para Vos', 'Decisiones basadas en datos, no en instintos.', 'Los algoritmos de ALIADA analizan tu historial para predecir tendencias y optimizar tu rentabilidad automáticamente.', 3, true),

('cta-bottom', 'cta', 'Unite a la Revolución ALIADA', 'Cientos de emprendedores ya están transformando sus negocios.', 'Empezá hoy mismo y descubrí el poder de una gestión inteligente.', 4, true);
