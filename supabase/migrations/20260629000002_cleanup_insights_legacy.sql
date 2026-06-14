-- C-24 v20-insights-unification — limpieza (paso 2)
-- Elimina la vista de compatibilidad `ai_insights` y la tabla de backup
-- `insights_legacy_backup`, una vez que TODO el código fue repuntado a `insights`
-- (paso 1, ya desplegado) y validado en producción.
--
-- Seguridad: las 462 filas legacy ya están migradas a `insights` (verificado:
-- migrated_from_legacy_present = 462), así que esto NO pierde datos de usuarios;
-- solo retira la red de rollback. Idempotente (IF EXISTS).

DROP VIEW  IF EXISTS public.ai_insights;
DROP TABLE IF EXISTS public.insights_legacy_backup;
