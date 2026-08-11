-- Cierra el hallazgo colateral de H-4 (PR #365): la policy de escritura de
-- community.landing_sections chequeaba solo auth.role() = 'authenticated'
-- (así desde su creación en 20260309000000). La estandarización de policies
-- de contenido admin a is_admin() (20260425000001 §7) cubrió seguros,
-- fair_ai_tools, copilot_prompts, courses, posts y replies pero OMITIÓ
-- landing_sections, y la pasada de initplan (20260517000003) la re-creó
-- preservando el check débil. Resultado: cualquier usuario logueado de
-- cualquier tenant podía crear/modificar/borrar las secciones de la landing
-- pública vía REST (defacement del sitio).
--
-- Fix: mismo patrón canónico que las demás tablas de contenido admin —
-- public.is_admin() (SECURITY DEFINER, chequea profiles.role = 'admin') en
-- USING y WITH CHECK. La lectura pública no cambia (policy separada,
-- active = true); los admins siguen viendo también las filas inactivas vía
-- esta policy FOR ALL (el panel /admin/landing las lista). El panel admin
-- escribe con el cliente de sesión del usuario (no service_role), así que
-- su flujo sigue pasando por esta policy y sigue funcionando.
-- Idempotente: DROP IF EXISTS + CREATE.

DROP POLICY IF EXISTS "Allow admin write access for landing sections"
  ON community.landing_sections;

CREATE POLICY "Allow admin write access for landing sections"
  ON community.landing_sections
  FOR ALL
  USING (public.is_admin())
  WITH CHECK (public.is_admin());
