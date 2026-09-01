-- ═══════════════════════════════════════════════════════════════════════════
-- seguros-perfil-asesor: extiende community.seguros para poder publicar el
-- perfil de un Productor Asesor de Seguros (PAS), no sólo ofertas de texto
-- libre. Acuerdo comercial real con Julián Dupás (docs/Julian_Dupas_PAS_v5_
-- 260814_174911.pdf); `/seguros` está en producción desde 2026-03 pero
-- `community.seguros` tiene 0 filas (verificado en prod el 2026-09-01) porque
-- el modelo de 4 campos de texto plano no puede contar lo que el material del
-- partner realmente es: 3 líneas de servicio, 4 pilares desarrollados, 14
-- ciudades de alcance, matrícula de PAS y contacto estructurado.
--
-- Decisión (ver openspec/changes/seguros-perfil-asesor/design.md D1-D10):
-- EXTENDER community.seguros con un discriminador `entry_type` en vez de
-- crear una tabla nueva de asesores — la tabla está vacía (nada que migrar),
-- y una tabla nueva duplicaría servicio/policies/CRUD/tracking (regla de
-- reutilización antes que repetición). Es 100% aditivo: las 4 columnas
-- existentes (`title`, `description`, `coverage`, `price`) no se tocan, y
-- todas las columnas nuevas son nullable o tienen default → ninguna fila
-- `entry_type = 'offer'` existente (hoy no hay ninguna, pero el contrato
-- vale para el futuro) deja de funcionar.
--
-- Sin cambios de RLS: las dos policies vivas ("Public items are viewable by
-- everyone" FOR SELECT USING (is_visible), "seguros_admin_all" FOR ALL admin)
-- ya cubren exactamente lo que el perfil necesita — "una fila visible leída
-- por cualquiera, escritura sólo admin".
-- ═══════════════════════════════════════════════════════════════════════════

-- ───────────────────────────────────────────────────────────────────────────
-- 1. Columnas nuevas — todas ADD COLUMN IF NOT EXISTS, todas nullable o con
--    default, para poder reaplicar esta migración sin romper (gotcha ya
--    conocido: Supabase reaplica migraciones por auto-apply desde GitHub).
-- ───────────────────────────────────────────────────────────────────────────

ALTER TABLE community.seguros
  ADD COLUMN IF NOT EXISTS entry_type        text        NOT NULL DEFAULT 'offer',
  ADD COLUMN IF NOT EXISTS slug              text,
  ADD COLUMN IF NOT EXISTS advisor_name      text,
  ADD COLUMN IF NOT EXISTS advisor_role      text,
  ADD COLUMN IF NOT EXISTS license_number    text,
  ADD COLUMN IF NOT EXISTS license_authority text,
  ADD COLUMN IF NOT EXISTS headline          text,
  ADD COLUMN IF NOT EXISTS bio               text,
  ADD COLUMN IF NOT EXISTS photo_url         text,
  ADD COLUMN IF NOT EXISTS contact_phone     text,
  ADD COLUMN IF NOT EXISTS contact_whatsapp  text,
  ADD COLUMN IF NOT EXISTS contact_email     text,
  ADD COLUMN IF NOT EXISTS service_lines     jsonb       DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS pillars           jsonb       DEFAULT '[]'::jsonb,
  ADD COLUMN IF NOT EXISTS coverage_areas    text[]      DEFAULT '{}'::text[],
  ADD COLUMN IF NOT EXISTS disclaimer        text,
  ADD COLUMN IF NOT EXISTS contact_clicks    jsonb       NOT NULL DEFAULT '{}'::jsonb,
  ADD COLUMN IF NOT EXISTS is_featured       boolean     NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS sort_order        integer     NOT NULL DEFAULT 0;

-- ───────────────────────────────────────────────────────────────────────────
-- 2. Restricciones — Postgres no soporta `ADD CONSTRAINT IF NOT EXISTS`, así
--    que se guardan con DROP CONSTRAINT IF EXISTS + ADD CONSTRAINT (patrón ya
--    usado en 20260906000001 y 20260929000001).
-- ───────────────────────────────────────────────────────────────────────────

-- 2.1 Conjunto cerrado de entry_type (D2). El default 'offer' hace que esta
--     migración sea compatible hacia atrás por construcción.
ALTER TABLE community.seguros
  DROP CONSTRAINT IF EXISTS seguros_entry_type_check;
ALTER TABLE community.seguros
  ADD CONSTRAINT seguros_entry_type_check
  CHECK (entry_type IN ('offer', 'advisor'));

-- 2.2 Invariante de datos (no de formulario): un asesor necesita slug para
--     tener URL de perfil. Vive en la tabla para que no se pueda evadir
--     escribiendo directo por la Data API.
ALTER TABLE community.seguros
  DROP CONSTRAINT IF EXISTS seguros_advisor_requires_slug_check;
ALTER TABLE community.seguros
  ADD CONSTRAINT seguros_advisor_requires_slug_check
  CHECK (entry_type <> 'advisor' OR slug IS NOT NULL);

-- 2.3 service_lines/pillars deben ser arrays JSON. Un CHECK no admite
--     subconsulta, así que esto NO valida la forma de cada elemento
--     (title/description, title/body) — eso se valida con Zod en el borde de
--     la app (frontend/lib/services/insuranceService.ts, esquema definido
--     junto a los tipos del perfil). Esto sólo impide que la columna termine
--     con un objeto u otro escalar en vez de una lista.
ALTER TABLE community.seguros
  DROP CONSTRAINT IF EXISTS seguros_service_lines_is_array_check;
ALTER TABLE community.seguros
  ADD CONSTRAINT seguros_service_lines_is_array_check
  CHECK (service_lines IS NULL OR jsonb_typeof(service_lines) = 'array');

ALTER TABLE community.seguros
  DROP CONSTRAINT IF EXISTS seguros_pillars_is_array_check;
ALTER TABLE community.seguros
  ADD CONSTRAINT seguros_pillars_is_array_check
  CHECK (pillars IS NULL OR jsonb_typeof(pillars) = 'array');

-- 2.4 Slug único (D4). Índice único PARCIAL: las filas 'offer' no tienen
--     slug, y aunque en Postgres los NULL no colisionan entre sí en un
--     índice único, dejar el WHERE explícito documenta la intención en vez
--     de depender de esa sutileza.
CREATE UNIQUE INDEX IF NOT EXISTS idx_seguros_slug_unique
  ON community.seguros (slug)
  WHERE slug IS NOT NULL;

-- ───────────────────────────────────────────────────────────────────────────
-- 3. Tracking por vía de contacto (D6) — función nueva, el contador viejo
--    (public.increment_seguros_clicks, creado en 20260831000001) NO se toca,
--    no se renombra, no se depreca. Es la red de seguridad del change: sus
--    7 tests en frontend/__tests__/seguros-click-tracking.test.tsx corren
--    sin editarse.
--
--    Réplica exacta del patrón de 20260831000001: SECURITY DEFINER (la RLS
--    de escritura es admin-only, un usuario authenticated común no puede
--    hacer UPDATE directo), SET search_path = '' + referencia calificada
--    community.seguros (ya se movió de schema una vez, C-23), y un único
--    UPDATE atómico. El conjunto de vías válidas se valida DENTRO de la
--    función: una vía desconocida no escribe ninguna clave rara en el
--    desglose, pero el total (clicks_count) se sigue incrementando igual.
-- ───────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.increment_seguros_contact_click(row_id uuid, channel text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  UPDATE community.seguros
  SET
    clicks_count = COALESCE(clicks_count, 0) + 1,
    contact_clicks = CASE
      WHEN channel IN ('whatsapp', 'email', 'phone', 'web') THEN
        COALESCE(contact_clicks, '{}'::jsonb)
          || jsonb_build_object(channel, COALESCE((contact_clicks ->> channel)::int, 0) + 1)
      ELSE
        COALESCE(contact_clicks, '{}'::jsonb)
    END
  WHERE id = row_id;
END;
$$;

-- Regla dura del proyecto (advisors 0028/0029, supabase/tests/
-- test_function_acl_gate.sql): REVOKE FROM PUBLIC solo no alcanza — los
-- default privileges de un CREATE fresco le regalan EXECUTE a `anon`
-- también. El gate de ACLs corta el CI si esto falta.
REVOKE EXECUTE ON FUNCTION public.increment_seguros_contact_click(uuid, text) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.increment_seguros_contact_click(uuid, text) TO authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- 4. Seed del partner (D10) — la tabla está vacía, esto es una carga inicial
--    idempotente, no un backfill de datos rotos.
--
--    is_visible = false a propósito: publicar es una decisión explícita del
--    PO con el toggle que ya existe en /admin/seguros, nunca un efecto
--    colateral de mergear este PR.
--
--    Contenido transcripto íntegro de docs/Julian_Dupas_PAS_v5_260814_
--    174911.pdf (sin parafrasear). Sign-off del PO (2026-09-01) resolvió
--    OQ-1 (WhatsApp: número personal de Julián, confirmado) y OQ-4
--    (disclaimer aprobado); OQ-3 confirmó la matrícula pero NO definió una
--    matrícula de broker propia, así que `license_authority` se siembra
--    vacía — ningún campo regulatorio se inventa.
--
--    ON CONFLICT (slug) DO UPDATE ... WHERE seguros.updated_at =
--    seguros.created_at: reaplicar esta misma migración (el gotcha de
--    auto-apply de Supabase) debe seguir siendo un no-op para una fila que
--    ya fue editada desde el panel. El trigger update_seguros_updated_at
--    sólo dispara en UPDATE (nunca en INSERT), así que created_at =
--    updated_at es exactamente "esta fila nunca fue tocada desde que se
--    sembró" — apenas el PO edite o publique (ambos son UPDATE), la
--    condición se vuelve falsa y el reseed deja de pisarla.
-- ───────────────────────────────────────────────────────────────────────────

INSERT INTO community.seguros (
  title,
  entry_type,
  slug,
  advisor_name,
  advisor_role,
  license_number,
  license_authority,
  headline,
  bio,
  service_lines,
  pillars,
  coverage_areas,
  contact_phone,
  contact_whatsapp,
  contact_email,
  contact_url,
  disclaimer,
  is_visible
)
VALUES (
  'Julián Dupás — Productor Asesor de Seguros',
  'advisor',
  'julian-dupas',
  'Julián Dupás',
  'Productor Asesor de Seguros',
  '98506',
  NULL,
  'Un seguro no termina cuando se emite la póliza.',
  'Mi trabajo comienza con el análisis de cada situación particular. Comparo alternativas entre distintas compañías, explico con claridad el alcance de cada cobertura y acompaño al asegurado durante todo el proceso, especialmente cuando debe afrontar un siniestro.' || E'\n\n' ||
    'Un seguro no es un trámite. Es una decisión.',
  '[
    {"title": "Autos y motos", "description": "Coberturas adaptadas al uso real del vehículo, con asesoramiento personalizado y seguimiento integral de los siniestros."},
    {"title": "Hogar y comercio", "description": "Sumas aseguradas actualizadas para que la cobertura responda adecuadamente cuando más la necesitás."},
    {"title": "Empresas, flotas y ART", "description": "Diseño integral del programa de seguros, adaptado a las características y necesidades de cada operación."}
  ]'::jsonb,
  '[
    {"title": "Comparación de alternativas", "body": "No trabajo con una única aseguradora. Antes de recomendar una alternativa, analizo las características específicas de cada riesgo: el uso del vehículo, la actividad comercial, la estructura de la empresa y sus necesidades de cobertura. A partir de ese análisis, evalúo las opciones disponibles y recomiendo la alternativa que considero más adecuada. El objetivo no es simplemente encontrar el menor precio, sino lograr un equilibrio entre cobertura, condiciones y respaldo, priorizando una solución que responda efectivamente cuando sea necesario utilizarla."},
    {"title": "Transparencia y asesoramiento", "body": "Considero fundamental que cada asegurado conozca de manera clara qué está contratando. Por eso, explico previamente las principales condiciones de la póliza, incluyendo coberturas, exclusiones, franquicias y períodos de carencia, para evitar inconvenientes y brindar mayor previsibilidad. Mi compromiso es recomendar únicamente aquello que considero adecuado para cada necesidad, aun cuando no implique la opción de mayor costo."},
    {"title": "Acompañamiento durante el siniestro", "body": "El momento de un siniestro es una instancia fundamental dentro del servicio. Por eso, acompaño personalmente al asegurado durante todo el proceso: desde la denuncia y presentación de la documentación hasta el seguimiento del expediente y la resolución del caso. La atención personalizada y el seguimiento permanente forman parte del servicio que ofrezco."},
    {"title": "Una cobertura debe mantenerse actualizada", "body": "Las necesidades y los valores asegurados pueden cambiar con el tiempo. Por eso, reviso periódicamente las pólizas para evaluar sumas aseguradas, incorporación o baja de bienes y modificaciones en la actividad o en la operación. Una póliza que no refleja la situación actual puede dejar de brindar la protección necesaria. Mantenerla actualizada también forma parte de mi asesoramiento."}
  ]'::jsonb,
  ARRAY['Necochea', 'Mar del Plata', 'Rosario', 'Concordia', 'C.A.B.A.', 'General Pico', 'Trenque Lauquen', 'Pergamino', 'Pilar', 'Río Cuarto', 'Mendoza', 'Tandil', 'La Plata', 'Balcarce'],
  '2266 474348',
  '5492266474348',
  'julian_dupas@argbroker.com.ar',
  'https://www.argbroker.com.ar',
  'Aliadata no es aseguradora ni intermediaria. La contratación se realiza directamente con el asesor y la compañía correspondiente.',
  false
)
ON CONFLICT (slug) DO UPDATE SET
  title              = EXCLUDED.title,
  advisor_name       = EXCLUDED.advisor_name,
  advisor_role       = EXCLUDED.advisor_role,
  license_number     = EXCLUDED.license_number,
  license_authority  = EXCLUDED.license_authority,
  headline           = EXCLUDED.headline,
  bio                = EXCLUDED.bio,
  service_lines      = EXCLUDED.service_lines,
  pillars            = EXCLUDED.pillars,
  coverage_areas     = EXCLUDED.coverage_areas,
  contact_phone      = EXCLUDED.contact_phone,
  contact_whatsapp   = EXCLUDED.contact_whatsapp,
  contact_email      = EXCLUDED.contact_email,
  contact_url        = EXCLUDED.contact_url,
  disclaimer         = EXCLUDED.disclaimer
WHERE community.seguros.updated_at = community.seguros.created_at;
