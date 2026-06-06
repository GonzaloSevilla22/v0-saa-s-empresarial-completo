## Why

Los contadores `ai_queries_used` y `ai_advice_used` existen en `profiles` desde C-01, y C-02 implementó el check/increment en 4 de las 5 Edge Functions de IA. Faltan: (a) el reset mensual automático, (b) wiring de `fair-advisor` al sistema de cuotas, y (c) un RPC atómico para el incremento (actualmente read-modify-write, con riesgo de race condition). Sin el reset mensual, los contadores nunca se limpian y los usuarios llegan al límite permanentemente.

## What Changes

- **Migración SQL**: cron job mensual `reset-ai-counters` — primer día del mes, setea `ai_queries_used = 0`, `ai_advice_used = 0`, `usage_reset_at = now()` en todos los perfiles activos
- **Migración SQL**: RPC `rpc_increment_ai_usage(p_user_id UUID, p_counter TEXT)` — incremento atómico con un solo UPDATE (reemplaza el read-modify-write de `_shared/ai-quota.ts`)
- **Edge Function `fair-advisor`**: agrega `checkAiQuota(supabase, userId, 'advice')` antes de llamar a OpenAI, `incrementAiUsage(supabase, userId, 'advice')` después
- **Edge Function `_shared/ai-quota.ts`**: actualizar `incrementAiUsage` para usar el RPC atómico
- **Frontend `useAiUsage()`**: hook nuevo que lee `ai_queries_used`, `ai_advice_used`, `usage_reset_at` del perfil y calcula `queriesRemaining` / `adviceRemaining`; alimenta los indicadores de cuota en la UI de IA
- **Resolución PA-05**: documentar que el reset es mensual (primer día del mes a las 00:00 UTC)

## Capabilities

### New Capabilities

- `ai-usage-counters`: monthly reset cron, atomic increment RPC, and frontend usage hook for AI query quotas

### Modified Capabilities

- `plan-gating`: extends quota enforcement to `fair-advisor`; replaces read-modify-write increment with atomic RPC

## Impact

- `supabase/migrations/`: una nueva migración con el cron job y el RPC
- `supabase/functions/fair-advisor/index.ts`: agrega quota check/increment
- `supabase/functions/_shared/ai-quota.ts`: actualiza `incrementAiUsage` para usar el RPC
- `hooks/auth/use-ai-usage.ts`: nuevo hook
- `knowledge-base/10_preguntas_abiertas.md`: resolución de PA-05
- Sin cambios a `usePlanLimits()` — ya expone `maxAiQueriesPerMonth` / `maxAiAdvicePerMonth` correctamente desde C-02
