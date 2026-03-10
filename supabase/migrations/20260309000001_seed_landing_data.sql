-- Seed initial landing data
INSERT INTO public.landing_sections (slug, type, title, subtitle, content, position, active)
VALUES 
('hero-main', 'hero', 'Automatizá tu Empresa con IA', 'La plataforma ERP todo-en-uno que escala con tu negocio. Gestión de stock, finanzas y comunidad en un solo lugar.', 'Potenciá tu productividad con nuestras herramientas inteligentes diseñadas para emprendedores modernos.', 1, true),

('features-grid', 'features', 'Todo lo que necesitás', 'Descubrí las herramientas que transformarán tu flujo de trabajo.', 'Nuestra plataforma integra gestión de ventas, compras, stock y análisis avanzado con inteligencia artificial para darte una ventaja competitiva.', 2, true),

('benefit-ai', 'image_text', 'Inteligencia Artificial Aplicada', 'No más decisiones a ciegas.', 'Nuestros algoritmos analizan tus datos históricos para darte predicciones de venta precisas y alertas de rentabilidad en tiempo real.', 3, true),

('cta-bottom', 'cta', '¿Listo para empezar?', 'Unite a cientos de empresas que ya están optimizando sus procesos.', 'Registrate hoy y obtené acceso completo a todas nuestras funcionalidades.', 4, true);
