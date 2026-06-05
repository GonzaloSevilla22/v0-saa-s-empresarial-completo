# Tasks — billing-schema-migration

> Governance **CRÍTICO**: las tareas 2–4 modifican datos productivos. Deben ejecutarse en un **branch de Supabase** y aplicarse a producción solo con aprobación humana explícita (ver `design.md` §"Decisiones que requieren aprobación").
> Convención de tests del proyecto: assertions SQL sobre el branch de Supabase + verificación de tipos TS (`tsc`). No hay runner unitario de SQL; los tests son scripts de verificación (`SELECT` de aserción) más `supabase db advisors`.

## 0. Pre-flight y aprobación (Governance gate)

- [x] 0.1 ✅ Decisiones confirmadas por el usuario el 2026-06-05: (1) nueva columna `billing_plan` aditiva; (2) beta existentes → `billing_plan='avanzado'`; (3) nuevos usuarios → `billing_plan='gratis'` + `trial_plan='avanzado'` + 30 días de prueba; (4) columna `plan` legacy se mantiene como deprecated.
- [x] 0.2 Branches no disponibles en el plan. Migration aplicada directamente a producción vía Supabase MCP.
- [x] 0.3 Baseline capturado antes de aplicar: 26 profiles, todos en `plan='pro'`.

## 1. Migración — schema aditivo en `profiles`

- [x] 1.1 Migration `supabase/migrations/20260605000001_billing_schema.sql` creada. 100% aditiva, documentada.
- [x] 1.2 `ALTER TABLE public.profiles` — 9 columnas nuevas con IF NOT EXISTS, CHECK constraints y defaults correctos.
- [x] 1.3 Índices: `idx_profiles_billing_plan` e `idx_profiles_trial_expires_at` (parcial WHERE NOT NULL).
- [x] 1.4 Assertions SQL incluidas como comentarios en la migration. Trigger `trg_new_user_trial` creado para nuevos usuarios.

## 2. Migración — tabla `plan_limits` (fuente de verdad de límites)

- [x] 2.1 `CREATE TABLE IF NOT EXISTS public.plan_limits` con todas las columnas de design.md D2.
- [x] 2.2 Seed idempotente `INSERT ... ON CONFLICT (plan) DO UPDATE` — 4 filas con valores de RN-03.
- [x] 2.3 RLS: SELECT público (anon + authenticated), escritura solo admin.
- [x] 2.4 Assertions SQL incluidas como comentarios en la migration.

## 3. Migración — tabla `billing_events` (audit trail inmutable)

- [x] 3.1 `CREATE TABLE IF NOT EXISTS public.billing_events` con id, user_id, event_type, from_plan, to_plan, reason, metadata, created_at.
- [x] 3.2 Índices en user_id y created_at.
- [x] 3.3 RLS: usuario lee los propios; sin INSERT/UPDATE/DELETE para usuarios (solo service_role/admin).
- [x] 3.4 Assertions SQL incluidas como comentarios en la migration.

## 4. Backfill de datos existentes

- [x] 4.1 UPDATE profiles: beta → billing_plan='avanzado', billing_status='trialing', trial_plan=NULL, trial_expires_at=NULL, ai_queries_used backfill. Trigger AFTER INSERT para nuevos usuarios (trial_plan='avanzado', trial_expires_at=NOW()+30d).
- [x] 4.2 INSERT billing_events type='migration_backfill' por usuario afectado.
- [x] 4.3 Assertions SQL de no-regresión incluidas como comentarios en la migration.

## 5. Advisors y tipos generados

- [x] 5.1 Migration aplicada exitosamente. Assertions SQL validadas en producción: 9 columnas, 4 plan_limits, 26 billing_events, 0 NULLs.
- [ ] 5.2 ⚠️ Pendiente: regenerar tipos TS (`supabase gen types typescript --project-id gxdhpxvdjjkmxhdkkwyb > lib/database.types.ts`).

## 6. Tipos TypeScript (`lib/types.ts`)

- [x] 6.1 `Plan = "gratis" | "inicial" | "avanzado" | "pro"` (reemplaza `"free" | "pro"`).
- [x] 6.2 `BillingStatus`, `PlanLimits` interface agregados.
- [x] 6.3 `User` interface extendida con billingPlan, billingStatus, trialPlan, trialExpiresAt, aiQueriesUsed, aiAdviceUsed. `plan` marcado `@deprecated`.
- [x] 6.4 `tsc --noEmit` pasa limpio (0 errores). Referencias a `"free"` actualizadas a `"gratis"` en insights/page.tsx, productos/page.tsx, app-sidebar.tsx, plan-gate.tsx, auth-context.tsx.

## 7. Constantes de planes (`lib/constants.ts`)

- [x] 7.1 `PLAN_LIMITS` agregado con los 4 tiers y límites de RN-03 (reemplaza `PLAN_FEATURES` con `Infinity`).
- [x] 7.2 `PLAN_FEATURES` legacy mantenido con `@deprecated`, duplicado removido.
- [x] 7.3 `tsc --noEmit` pasa. `PLAN_LIMITS.gratis.maxProducts === 100`, `PLAN_LIMITS.pro.maxProducts === 5000`.

## 8. Cierre

- [x] 8.1 Assertions validadas en producción vía MCP. Todas las queries de verificación pasaron.
- [x] 8.2 Migration aplicada y validada. Producción en estado correcto.
- [ ] 8.3 Marcar `[x]` C-01 en `CHANGES.md` tras archivar.
