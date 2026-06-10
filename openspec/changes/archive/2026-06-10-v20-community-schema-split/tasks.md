# Tasks: v20-community-schema-split (C-23)

> TDD estricto donde hay lógica testeable (frontend). Las migraciones se verifican con queries reales contra la DB. Governance MEDIO: checkpoints marcados con ⚠️ se coordinan con el PO antes de ejecutar.

## 1. Migración A — schema y grants (sin impacto)

- [x] 1.1 Crear migración `<timestamp>_community_schema_create.sql`: `CREATE SCHEMA IF NOT EXISTS community` + `GRANT USAGE` a `anon`/`authenticated`/`service_role` + `ALTER DEFAULT PRIVILEGES IN SCHEMA community` (tablas/secuencias/funciones, equivalente a `public`)
- [x] 1.2 Aplicar migración A vía `npx supabase db push` y verificar el schema con `information_schema.schemata`
- [x] 1.3 ⚠️ Exponer `community` en la Data API (Dashboard → Settings → Data API → Exposed schemas, o Management API) y verificar con un GET REST que el schema responde

## 2. Migración B — movimiento de tablas (preparada, NO aplicada aún)

- [x] 2.1 Crear migración `<timestamp>_community_schema_move.sql`: 16 × `ALTER TABLE public.<t> SET SCHEMA community` (courses, course_modules, course_lessons, course_enrollments, course_progress, lesson_progress, posts, replies, post_likes, meetings, seguros, purchase_pools, landing_sections, fair_recommendations, fair_ai_tools, copilot_prompts)

## 3. Frontend — código y tests (TDD)

- [x] 3.1 RED: tests de `use-posts` (nuevo archivo o extensión del existente) — el mock del cliente exige `.schema("community")` en posts/post_likes/replies y `analytics_events` permanece en `public` (sin `.schema`)
- [x] 3.2 GREEN: `use-posts.ts` — todas las llamadas a posts/post_likes/replies vía `.schema("community")`
- [x] 3.3 RED+GREEN: `use-courses-query.ts` + `courseService.ts` (courses, course_modules, course_lessons, course_enrollments, lesson_progress) con `.schema("community")` y test del hook
- [x] 3.4 GREEN mecánico (sin lógica nueva): `insuranceService.ts`, `fairAiToolsService.ts`, `fairAdvisorService.ts`, `copilotPromptsService.ts`, `lib/landing.ts`, `app/actions/landing.ts`, `admin/cursos/page.tsx` — `.schema("community")` en todas las llamadas a tablas movidas
- [x] 3.5 Verificación de cero referencias residuales: búsqueda `from("<tabla movida>")` sin `.schema` en `frontend/` → 0 resultados
- [x] 3.6 Edge Function `fair-advisor/index.ts`: `.schema('community')` en `fair_recommendations`
- [x] 3.7 Regenerar `frontend/lib/database.types.ts` con `--schema public,community` (hecho en el corte, post-migración B)
- [x] 3.8 Suites completas: vitest frontend + `tsc --noEmit` + pytest backend (sin regresiones sobre baseline)

## 4. Corte coordinado ⚠️

- [x] 4.1 ⚠️ Checkpoint con el PO ("dale", 2026-06-10): confirmar momento del corte (ventana de minutos en módulos comunidad/cursos/seguros/feria; ERP inafectado)
- [x] 4.2 Aplicar migración B vía `npx supabase db push`; verificar conteos (posts=4, courses=4, replies=2, enrollments=4, fair_recommendations=3) y FKs cross-schema en `pg_constraint`
- [x] 4.3 Gate de embedding — falló el cross-schema directo (PGRST200: PostgREST no embebe entre schemas); resuelto con vista puente `community.profiles` (security_invoker, migración 20260615000002) → 200 OK con embeds correctos, sin cambios de código
- [x] 4.4 Merge del PR (#151, 2026-06-10) + deploy Vercel; redeploy de `fair-advisor` (hecho en el corte)
- [x] 4.5 Smoke test post-deploy: verificado por el PO ("deploy funcionando") + gate REST 200 con embeds pre-merge

## 5. Cierre

- [x] 5.1 Marcar C-23 `[x]` en CHANGES.md + archive del change (PR docs)
