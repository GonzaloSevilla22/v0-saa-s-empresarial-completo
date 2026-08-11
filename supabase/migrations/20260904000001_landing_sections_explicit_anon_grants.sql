-- H-4 (informe QA del PR #361): la landing pública consulta
-- community.landing_sections como anon. En producción el acceso funciona,
-- pero el grant es IMPLÍCITO: nació de los default privileges del schema
-- public cuando la tabla se creó ahí (20260309000000) y sobrevivió al
-- SET SCHEMA community (20260615000001, que preserva grants por tabla).
-- Ninguna migración lo declara, así que una base reconstruida por una vía
-- que no arrastre esos defaults (p. ej. un restore sin ACLs) queda sin él
-- y la landing degrada con 42501 "permission denied" en cada request —
-- exactamente lo observado en el entorno local de la sesión QA.
--
-- Grants explícitos e idempotentes; no-op en producción (verificado
-- 2026-08-11: anon y authenticated ya tienen SELECT, y anon ya tiene USAGE
-- sobre el schema). La lectura sigue gateada por RLS: el público solo ve
-- filas con active = true ("Allow public read access for landing sections").

GRANT USAGE ON SCHEMA community TO anon, authenticated;
GRANT SELECT ON TABLE community.landing_sections TO anon, authenticated;
