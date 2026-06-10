# Proposal: v20-community-schema-split (C-23)

## Why

16 tablas que no pertenecen al ERP operativo (comunidad, educación, verticales, marketing) conviven en el schema `public` junto a las tablas de ventas/compras/stock, compartiendo namespace, ciclo de deploy y superficie de RLS (riesgo 4 del modelo V2 §2.6). Separarlas en un schema Postgres `community` delimita el bounded context, simplifica la auditoría del ERP (las queries de `information_schema`/advisors dejan de mezclar dominios) y habilita evolucionar comunidad sin tocar el core. El momento es ahora: las tablas tienen ~17 filas en total (riesgo de datos mínimo) y la Fase 6 exige limpiar deuda antes de construir V2.1.

## What Changes

- Crear schema `community` con grants equivalentes a `public` (USAGE + privilegios por defecto para `anon`/`authenticated`/`service_role`).
- Mover 16 tablas vía `ALTER TABLE ... SET SCHEMA community` (preserva datos, FKs, índices, triggers y políticas RLS — **corrige el supuesto del explore doc** de que Supabase requiere recrear las tablas): `courses`, `course_modules`, `course_lessons`, `course_enrollments`, `course_progress`†, `lesson_progress`, `posts`, `replies`, `post_likes`, `meetings`, `seguros`, `purchase_pools`, `landing_sections`, `fair_recommendations`, `fair_ai_tools`, `copilot_prompts`.
  - † `course_progress` no estaba en el roadmap (el explore no la detectó) pero existe con 0 filas y FK a `courses` — se mueve con su dominio.
- Exponer `community` en la Data API de Supabase (PostgREST `Exposed schemas`) — paso de configuración fuera de SQL.
- Frontend: 10 archivos cambian `supabase.from("<tabla>")` → `supabase.schema("community").from("<tabla>")` (hooks `use-posts`/`use-courses-query`, servicios course/insurance/fairAiTools/fairAdvisor/copilotPrompts, `lib/landing.ts`, `app/actions/landing.ts`, página admin cursos). El insert a `analytics_events` de `use-posts` queda en `public`.
- Edge Function `fair-advisor`: única EF que toca una tabla movida (`fair_recommendations`) — mismo cambio `.schema("community")` + redeploy.
- Regenerar `frontend/lib/database.types.ts` con `--schema public,community`.
- Verificación post-migración del embedding cross-schema (`posts` embebe `public.profiles`) antes de mergear el frontend.

**BREAKING (ventana breve)**: entre la aplicación de la migración y el deploy del frontend nuevo, el módulo comunidad/cursos/seguros/feria devuelve errores (las tablas ya no están en `public`). El ERP (ventas/compras/stock/clientes/dashboard) no se ve afectado en ningún momento. Ventana estimada: minutos; módulos de muy bajo tráfico (4 posts, 4 cursos).

## Capabilities

### New Capabilities
- `community-schema`: aislamiento del dominio comunidad/educación/verticales en el schema Postgres `community` — tablas movidas con RLS intacta, API expuesta, acceso del frontend vía `.schema("community")` y ERP verificado sin acoplamiento.

### Modified Capabilities
<!-- vacío — ningún spec existente cambia sus requirements; el acceso a datos del ERP no se toca -->

## Impact

- **DB**: 2 migraciones nuevas en `supabase/migrations/` (schema+grants; moves). Sin pérdida de datos; FKs cross-schema (`community.posts → public.profiles`, `→ auth.users`, `→ public.accounts`) siguen válidas.
- **Config Supabase**: agregar `community` a Exposed schemas (Dashboard → Settings → Data API) — requiere acción en dashboard o Management API.
- **Frontend**: `hooks/data/use-posts.ts`, `hooks/data/use-courses-query.ts`, `lib/services/{courseService,insuranceService,fairAiToolsService,fairAdvisorService,copilotPromptsService}.ts`, `lib/landing.ts`, `app/actions/landing.ts`, `app/(dashboard)/admin/cursos/page.tsx`, `lib/database.types.ts` (regen), tests nuevos/actualizados.
- **Edge Functions**: `supabase/functions/fair-advisor/index.ts` (+ redeploy).
- **Sin impacto**: backend Python (no consume tablas community), Realtime (ninguna tabla movida está en la publicación `supabase_realtime`), webhooks de pagos.
- **Governance**: MEDIO — implementación con checkpoints; la ventana de corte y el paso de dashboard se coordinan con el PO.
