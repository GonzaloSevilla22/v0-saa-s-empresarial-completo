## Why

C-01 creó el schema de billing (columnas `billing_plan`, `plan_limits`, contadores IA) pero no activó ningún enforcement. Actualmente todos los usuarios acceden a todas las features sin restricción, sin importar su plan. C-02 conecta ese schema con la UI y la lógica de negocio: lee los límites de la DB en runtime, verifica el plan real del usuario (`billing_plan`), y bloquea o degrada el acceso cuando corresponde.

## What Changes

- **Nuevo hook `usePlanLimits()`**: fetches los límites del plan activo del usuario desde `plan_limits` (DB) usando React Query. Reemplaza las constantes hardcodeadas en `lib/constants.ts` como fuente de runtime.
- **Nuevo hook `usePlanGate()`**: expone `{ hasAccess, planRequired, currentPlan, limit }` para cualquier feature o recurso numérico. Centraliza toda la lógica de gating en un lugar.
- **Migración de `plan` → `billing_plan`**: todas las referencias a `user?.plan === "pro"` en la UI se actualizan para leer `user?.billingPlan` y comparar contra el plan real (jerarquía: `gratis < inicial < avanzado < pro`).
- **Límites numéricos aplicados**: al crear productos, clientes y registrar operaciones, se verifica que el usuario no superó el límite de su plan. Si lo superó, se muestra un CTA de upgrade en lugar del formulario.
- **Gating de features exclusivas**: acceso a módulos como rentabilidad por producto, sugerencia de precios y reportes comparativos se habilita solo para planes `avanzado` y `pro`.
- **Límites de IA conectados**: las Edge Functions de IA verifican `ai_queries_used` vs `max_ai_queries_per_month` del plan antes de llamar a OpenAI. Si el usuario agotó su cuota, se retorna un error 429 con mensaje claro.
- **RLS de comunidad actualizado**: la policy de INSERT en `posts` y `replies` pasa de verificar `plan = 'pro'` (columna ENUM legacy) a verificar `billing_plan IN ('avanzado', 'pro')`.
- **`PlanGate` component refactorizado**: usa `billing_plan` y la jerarquía de planes reales en lugar de la comparación binaria free/pro.

## Capabilities

### New Capabilities
- `plan-gating`: Runtime enforcement de límites y features por plan. Cubre el hook `usePlanLimits`, `usePlanGate`, el componente `PlanGate` refactorizado, y los CTA de upgrade.

### Modified Capabilities
- `billing`: La capability `billing` creada en C-01 se extiende: las REQUIREMENTS de enforcement de límites IA (verificación server-side en Edge Functions) y la RLS de comunidad actualizada cambian el comportamiento observable.

## Impact

- **`lib/hooks/usePlanLimits.ts`** (nuevo): React Query hook que lee `plan_limits` de Supabase.
- **`lib/hooks/usePlanGate.ts`** (nuevo): hook de gating con jerarquía de planes.
- **`components/shared/plan-gate.tsx`**: refactor para usar `billing_plan` y `usePlanGate`.
- **`contexts/auth-context.tsx`**: `PlanGate` y `upgradePlan`/`downgradePlan` usan `billing_plan`.
- **`app/(dashboard)/productos/page.tsx`**, **`clientes/page.tsx`**: agregan verificación de límite numérico antes del formulario de creación.
- **`components/app-sidebar.tsx`**: badge de plan usa `billing_plan`.
- **`supabase/functions/ai-insights/index.ts`** y demás Edge Functions IA: verifican cuota antes de llamar a OpenAI.
- **`supabase/migrations/<timestamp>_gating_rls_update.sql`**: actualiza la RLS de `posts`/`replies` para usar `billing_plan`.
- **`lib/constants.ts`**: las constantes legacy `MAX_PRODUCTS_FREE`, etc. quedan como fallback estático; en runtime se usan los valores de `plan_limits`.
- **Governance**: MEDIO — lógica de negocio de gating. CRÍTICO para la RLS de la DB.
