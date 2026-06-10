-- C-23 v20-community-schema-split — Migración B (CORTE)
-- Mueve las 16 tablas no-ERP al schema community.
-- SET SCHEMA preserva datos, FKs, índices, triggers, grants por tabla y políticas RLS.
-- Las FKs cross-schema (→ public.profiles, → auth.users, → public.accounts) siguen válidas.
-- Rollback: ALTER TABLE community.<t> SET SCHEMA public (inverso, atómico).

ALTER TABLE IF EXISTS public.courses             SET SCHEMA community;
ALTER TABLE IF EXISTS public.course_modules      SET SCHEMA community;
ALTER TABLE IF EXISTS public.course_lessons      SET SCHEMA community;
ALTER TABLE IF EXISTS public.course_enrollments  SET SCHEMA community;
ALTER TABLE IF EXISTS public.course_progress     SET SCHEMA community;
ALTER TABLE IF EXISTS public.lesson_progress     SET SCHEMA community;
ALTER TABLE IF EXISTS public.posts               SET SCHEMA community;
ALTER TABLE IF EXISTS public.replies             SET SCHEMA community;
ALTER TABLE IF EXISTS public.post_likes          SET SCHEMA community;
ALTER TABLE IF EXISTS public.meetings            SET SCHEMA community;
ALTER TABLE IF EXISTS public.seguros             SET SCHEMA community;
ALTER TABLE IF EXISTS public.purchase_pools      SET SCHEMA community;
ALTER TABLE IF EXISTS public.landing_sections    SET SCHEMA community;
ALTER TABLE IF EXISTS public.fair_recommendations SET SCHEMA community;
ALTER TABLE IF EXISTS public.fair_ai_tools       SET SCHEMA community;
ALTER TABLE IF EXISTS public.copilot_prompts     SET SCHEMA community;
