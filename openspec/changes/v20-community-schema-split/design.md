# Design: v20-community-schema-split (C-23)

## Context

16 tablas no-ERP en `public` (~17 filas en total, auditado 2026-06-10). Acceso actual: frontend vía supabase-js directo (`.from("posts")` etc., 10 archivos), una Edge Function (`fair-advisor` escribe `fair_recommendations`), backend Python no las toca. Ninguna está en la publicación `supabase_realtime` ni tiene suscripciones `postgres_changes`. FKs salientes hacia `public.profiles`, `auth.users` y `public.accounts`; **ninguna FK entrante desde tablas ERP**.

## Goals / Non-Goals

**Goals**
- Bounded context `community` aislado a nivel schema, con RLS y datos intactos.
- Cambio de código mínimo y mecánico (`.schema("community")`).
- ERP completamente inafectado en todo momento.

**Non-Goals**
- No se migra el módulo comunidad al backend Python (sigue supabase-js directo).
- No se tocan `profiles`, `accounts` ni `analytics_events` (quedan en `public`).
- No se crean vistas de compatibilidad permanentes (ver Decisión 3).
- No se renombra ni refactoriza ninguna tabla movida (solo cambia el schema).

## Decisions

1. **`ALTER TABLE ... SET SCHEMA` en lugar de CREATE+COPY+DROP** — El explore doc asumía que Supabase requiere recrear las tablas; es incorrecto: `SET SCHEMA` es Postgres estándar y preserva datos, FKs, índices, triggers, grants por tabla y políticas RLS de forma atómica. Elimina el mayor riesgo del plan original (recrear RLS a mano).
2. **Dos migraciones separadas** — (A) `CREATE SCHEMA community` + grants (inocua, se puede aplicar en cualquier momento); (B) los 16 `SET SCHEMA` (el corte real). Permite exponer el schema en PostgREST entre A y B, de modo que cuando las tablas se muevan la API ya las sirva.
3. **Ventana breve en lugar de vistas de compatibilidad** — Vistas `public.<tabla>` → `community.<tabla>` mantendrían el frontend viejo vivo, pero duplican cada relación en dos schemas expuestos y rompen el resource embedding de PostgREST con ambigüedad (`posts` embebe `post_likes` y `profiles`). Con ~17 filas y módulos de bajo tráfico, una ventana de minutos (migración B → deploy frontend) es el trade-off correcto. El ERP no participa de la ventana.
4. **`.schema("community")` por llamada, sin wrapper** — supabase-js v2 lo soporta nativo y tipado (con types regenerados de ambos schemas). Un helper/cliente dedicado agregaría indirección sin valor para ~30 call sites mecánicos.
5. **Exposición de PostgREST como paso de configuración explícito** — `Exposed schemas` no es SQL; se hace en Dashboard (Settings → Data API → agregar `community`) o Management API. Es checkpoint con el PO antes del corte. Sin este paso, `.schema("community")` devuelve 406.
6. **Verificación del embedding cross-schema antes del merge** — `posts` embebe `public.profiles`. PostgREST soporta embedding entre schemas expuestos vía FK, pero se verifica con una query REST real post-migración B y pre-merge del frontend (gate del corte).
7. **`course_progress` se mueve también** — no estaba en el roadmap (0 filas, sin referencias en código, FK a `courses`); dejarla en `public` rompería el objetivo de namespace limpio.

## Risks / Trade-offs

- [Embedding cross-schema fallara en PostgREST] → gate de verificación (Decisión 6); fallback: reemplazar el embed de `profiles(name)` por segunda query al cliente (cambio local en `use-posts`/`getReplies`).
- [Olvidar una referencia `.from()` sin schema] → búsqueda exhaustiva en CI/tests (scenario "cero referencias residuales"); los 404 de PostgREST harían el fallo visible de inmediato en los módulos community.
- [Ventana de corte más larga de lo previsto (CI lento)] → la migración B se aplica manualmente coordinada con el merge, no se delega al CI; si algo falla, rollback inmediato con `SET SCHEMA public` inverso (igual de atómico).
- [Tipos TS desincronizados] → regen con `--schema public,community` en el mismo PR.

## Migration Plan

1. **Pre-corte** (sin impacto): aplicar migración A (`CREATE SCHEMA` + grants) + exponer `community` en Dashboard (PO o Management API). Verificar con un `GET` que el schema responde.
2. **Corte** (ventana de minutos, coordinada): aplicar migración B (16 × `SET SCHEMA`); verificar conteos de filas + RLS + embedding (queries REST de prueba); mergear el PR del frontend; deploy Vercel + redeploy `fair-advisor`.
3. **Rollback**: si la verificación del paso 2 falla → migración inversa `ALTER TABLE community.<t> SET SCHEMA public` (atómica, sin pérdida) y se pospone el merge.

## Open Questions

Ninguna bloqueante. El paso de Dashboard (Exposed schemas) requiere acceso del PO si la Management API no está disponible desde el entorno del agente.
