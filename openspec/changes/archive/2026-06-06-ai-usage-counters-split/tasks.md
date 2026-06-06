## 1. DB Migration

- [x] 1.1 Crear `supabase/migrations/20260606100000_ai_usage_counters.sql` con el RPC `rpc_increment_ai_usage(p_user_id UUID, p_counter TEXT)` — UPDATE atómico con SECURITY DEFINER y `search_path = ''`
- [x] 1.2 Agregar en la misma migración el cron job `reset-ai-counters` con `cron.schedule('reset-ai-counters', '0 0 1 * *', $$UPDATE public.profiles SET ai_queries_used = 0, ai_advice_used = 0, usage_reset_at = now()$$)` — usar `IF NOT EXISTS` o `cron.unschedule` + `cron.schedule` para idempotencia
- [x] 1.3 Agregar RLS: el RPC solo puede ser invocado por `authenticated` y solo actualiza el propio `user_id` (o usar `SECURITY DEFINER` con validación interna `p_user_id = auth.uid()`)

## 2. Edge Functions — shared module

- [x] 2.1 Actualizar `supabase/functions/_shared/ai-quota.ts`: en `incrementAiUsage`, reemplazar el read-modify-write por una llamada al RPC `rpc_increment_ai_usage(userId, counter)` vía `supabase.rpc('rpc_increment_ai_usage', { p_user_id: userId, p_counter: counter })`

## 3. Edge Functions — fair-advisor

- [x] 3.1 Agregar `import { checkAiQuota, incrementAiUsage } from '../_shared/ai-quota.ts'` a `supabase/functions/fair-advisor/index.ts`
- [x] 3.2 Después del bloque de auth (step 1) y antes de la llamada a OpenAI, agregar `const quota = await checkAiQuota(supabase, user.id, 'advice'); if (!quota.allowed) return jsonResponse(quota.body, 429)`
- [x] 3.3 Después de la respuesta exitosa de OpenAI, agregar `await incrementAiUsage(supabase, user.id, 'advice')`

## 4. Frontend — hook useAiUsage

- [x] 4.1 Crear `hooks/auth/use-ai-usage.ts`: hook que fetcha `ai_queries_used`, `ai_advice_used`, `usage_reset_at` del perfil del usuario vía Supabase client, con staleTime 30s
- [x] 4.2 El hook calcula `queriesRemaining = Math.max(0, maxAiQueriesPerMonth - ai_queries_used)` y `adviceRemaining = Math.max(0, maxAiAdvicePerMonth - ai_advice_used)` — usar `usePlanLimits()` para los máximos
- [x] 4.3 Exportar `useAiUsage` desde `hooks/auth/index.ts` (o crear el barrel si no existe)

## 5. Resolución PA-05

- [x] 5.1 En `knowledge-base/10_preguntas_abiertas.md`, actualizar PA-05 con la resolución: reset mensual el primer día de cada mes a las 00:00 UTC via pg_cron `reset-ai-counters`

## 6. CHANGES.md

- [x] 6.1 Marcar `[x]` en la entrada de `C-04` en `CHANGES.md`
