# Tasks — plan-gating-engine

> Governance **MEDIO** para lógica de negocio y UI. **CRÍTICO** para la migration de RLS (toca datos de usuarios reales).
> Orden de implementación: hooks core → auth context → RLS migration → UI → Edge Functions.
> Tests: `tsc --noEmit` tras cada bloque. Migration via `npx supabase db push`.

## 1. Hooks core de gating

- [x] 1.1 `hooks/auth/use-plan-limits.ts` creado (convención del proyecto: `hooks/auth/`, no `lib/hooks/`). React Query, staleTime 1h, fallback a constants si falla la DB.
- [x] 1.2 `lib/plan-utils.ts` creado: `PLAN_HIERARCHY`, `getEffectivePlan` (trial-aware), `planHasAccess`, `PLAN_DISPLAY_NAMES`.
- [x] 1.3 `hooks/auth/use-plan-gate.ts` creado: recibe `requiredPlan`, retorna `{ hasAccess, effectivePlan, limits, isLoading }`.
- [x] 1.4 `tsc --noEmit` pasa. `planHasAccess` verificado por la lógica de PLAN_HIERARCHY.indexOf.

## 2. Contexto de auth — `effectivePlan`

- [x] 2.1 `effectivePlan: Plan` agregado al `User` interface en `lib/types.ts`. Calculado en ambos branches de `setUser()` con `getEffectivePlan(...)`.
- [x] 2.2 `effectivePlan` expuesto en `AuthContextType` y en el value del provider (`user?.effectivePlan ?? "gratis"`).
- [x] 2.3 `tsc --noEmit` pasa limpio.

## 3. Componente `PlanGate` refactorizado

- [x] 3.1 `components/shared/plan-gate.tsx` refactorizado: usa `usePlanGate(requiredPlan)`, muestra "Requiere plan {nombre}". CTA apunta a `/configuracion` (TODO C-10: `/planes`).
- [x] 3.2 `tsc --noEmit` pasa.

## 4. Migration RLS — comunidad actualizada

- [x] 4.1 `supabase/migrations/20260605030000_gating_rls_update.sql` creado. **SECURITY FIX descubierto**: había DOS policies PERMISSIVE de INSERT por tabla ("Pro users can insert..." + "Users can insert own...") que se combinan con OR → la ownership-only dejaba pasar a cualquier usuario sin importar el plan (el gate de C-09 nunca aplicó). Fix: dropear AMBAS y crear UNA sola con ownership AND `billing_plan IN ('avanzado','pro')`.
- [x] 4.2 `npx supabase db push` aplicado al proyecto remoto `gxdhpxvdjjkmxhdkkwyb`.
- [x] 4.3 Verificado vía SQL: exactamente 1 policy INSERT por tabla (`posts_insert_owner_and_plan`, `replies_insert_owner_and_plan`). Las legacy fueron removidas.

## 5. Migración de checks `user.plan` → `user.effectivePlan` en UI

- [x] 5.1 `comunidad/page.tsx`: `isPro = planHasAccess(effectivePlan, "avanzado")` (coincide con la RLS).
- [x] 5.2 `configuracion/page.tsx`: `isPro` usa `planHasAccess`; usage stats leen límites reales de `usePlanLimits()`.
- [x] 5.3 `cursos/page.tsx`: `isPro` = avanzado+. `cursos/[id]/page.tsx`: PlanGate con `requiredPlan="avanzado"` (eliminado check manual redundante).
- [x] 5.4 `insights/page.tsx`: límite real `maxAiQueriesPerMonth` + contador `aiQueriesUsed`. `isFree` removido (sin uso).
- [x] 5.5 `app-sidebar.tsx`: badge Crown usa `!planHasAccess(effectivePlan, "avanzado")`.
- [x] 5.6 `tsc --noEmit` pasa limpio.

## 6. Límites numéricos — Productos y Clientes

- [x] 6.1 `productos/page.tsx`: `isAtLimit` usa `usePlanLimits().maxProducts`. Banner y contador del header usan el límite real del plan.
- [x] 6.2 `clientes/page.tsx`: gate con `pq.meta.totalCount >= maxClients` (total real, no la página). Botón "Nuevo cliente" deshabilitado + banner al alcanzar el límite.
- [x] 6.3 `tsc --noEmit` pasa. Banner condicionado a `isAtLimit`/`isAtClientLimit` (verificación visual diferida a QA real).

## 7. Edge Functions IA — verificación de cuota server-side

- [x] 7.1 Helper compartido `supabase/functions/_shared/ai-quota.ts` (`checkAiQuota` + `incrementAiUsage`, trial-aware). `ai-insights`: check antes de OpenAI → 429 si excede.
- [x] 7.2 `ai-insights`: `incrementAiUsage(supabase, user.id, 'queries')` tras la llamada exitosa.
- [x] 7.3 Patrón replicado en `ai-prediccion`, `ai-resumen`, `ai-simulador` (usan `supabaseClient`). fair-advisor → C-04 (`ai_advice_used`).
- [ ] 7.4 ⚠️ **Pendiente deploy manual**: las Edge Functions deben desplegarse tras el merge del PR (`supabase functions deploy ai-insights ai-prediccion ai-resumen ai-simulador`). No desplegadas a prod en esta sesión para respetar el flujo de validación por PR. TEST de cuota se corre post-deploy.

## 8. Invalidación de cache al cambiar de plan

- [x] 8.1 `auth-context.tsx`: tras `refreshSession()` se llama a `queryClient.invalidateQueries({ queryKey: ["planLimits"] })`. `useQueryClient` importado; QueryProvider envuelve AuthProvider (verificado en layout).
- [x] 8.2 `tsc --noEmit` pasa limpio.

## 9. Cierre

- [x] 9.1 `tsc --noEmit` pasa sin errores en todo el proyecto (Edge Functions excluidas, son Deno).
- [x] 9.2 Verificado vía SQL: `posts_insert_owner_and_plan` y `replies_insert_owner_and_plan` con `billing_plan IN ('avanzado','pro')`; legacy removidas.
- [ ] 9.3 Marcar `[x]` C-02 en `CHANGES.md` tras archivar.
