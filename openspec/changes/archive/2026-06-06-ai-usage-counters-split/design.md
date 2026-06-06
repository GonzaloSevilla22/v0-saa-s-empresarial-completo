## Context

C-01 añadió `ai_queries_used`, `ai_advice_used`, `usage_reset_at` a `profiles`. C-02 implementó `_shared/ai-quota.ts` (check + increment) y lo conectó a `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador`. Quedan pendientes: (a) `fair-advisor` sin cuota, (b) el incremento de `_shared/ai-quota.ts` es un read-modify-write con riesgo de race condition bajo carga concurrente, y (c) no existe el reset mensual automático — sin él los contadores se acumulan indefinidamente.

El `usage_reset_at` fue nombrado así en C-01 (en lugar de `ai_counters_reset_at` del spec original). El diseño usa ese nombre canónico.

## Goals / Non-Goals

**Goals:**
- Implementar el cron job mensual de reset de contadores IA
- Reemplazar el read-modify-write de `incrementAiUsage` por un RPC atómico en DB
- Conectar `fair-advisor` al sistema de cuotas con counter `'advice'`
- Proveer un hook `useAiUsage()` para que la UI muestre cuota restante
- Resolver PA-05 (período de reset mensual)

**Non-Goals:**
- Cambiar los límites por plan (eso vive en `plan_limits` desde C-01)
- Implementar la UI de "upgrade" cuando se agota la cuota (eso es C-10)
- Agregar nuevos tipos de contadores IA (scope de C-11/C-12)
- Migrar `copiloto-ia` (la función no existe en el proyecto actual)

## Decisions

### D1 — RPC atómico para incremento

**Decisión**: agregar `rpc_increment_ai_usage(p_user_id UUID, p_counter TEXT)` que corre `UPDATE profiles SET ai_queries_used = ai_queries_used + 1 WHERE id = p_user_id` (o `ai_advice_used + 1`). Ejecuta como SECURITY DEFINER con `search_path = ''`.

**Alternativa descartada**: mantener el read-modify-write del cliente — funciona para el MVP pero introduce inconsistencias si el usuario tiene dos tabs abiertas simultáneamente.

**Por qué importa ahora**: el `_shared/ai-quota.ts` ya documenta esto como deuda técnica de C-04. Resolverlo en este change mantiene el comentario como contrato cumplido.

### D2 — Reset mensual vía pg_cron

**Decisión**: un cron job de pg_cron `'0 0 1 * *'` (00:00 UTC, día 1 de cada mes) que corre:
```sql
UPDATE profiles SET ai_queries_used = 0, ai_advice_used = 0, usage_reset_at = now()
WHERE billing_status IN ('active', 'trialing');
```
Solo resetea usuarios activos/trial; los cancelados se resetean igual (no tiene costo y evita lógica condicional).

**Alternativa**: reset diario con ventana de 30 días. Descartada porque el concepto de "per month" es más natural para el usuario y consistente con el billing mensual.

### D3 — `useAiUsage()` como hook independiente

**Decisión**: hook separado de `usePlanLimits()`. `usePlanLimits()` es read-only de `plan_limits` (público, cacheado 1h). `useAiUsage()` lee el perfil del usuario (privado, stale 30s). Mezclarlos forzaría a `usePlanLimits()` a autenticarse y refrescar más seguido.

**Interface**:
```ts
useAiUsage(): {
  queriesUsed: number
  queriesRemaining: number   // max - used (clamped to 0)
  adviceUsed: number
  adviceRemaining: number
  resetAt: string | null     // ISO timestamp
  isLoading: boolean
}
```

## Risks / Trade-offs

- **[Risk] pg_cron no habilitado** → C-03 ya habilitó pg_cron en producción. La migration verifica con `IF NOT EXISTS` por idempotencia.
- **[Risk] Race condition residual en `fair-advisor`** → el RPC atómico (D1) elimina el riesgo. Durante el deploy hay una ventana breve donde `fair-advisor` aún usa el cliente viejo; es aceptable porque `fair-advisor` tiene tráfico bajo.
- **[Trade-off] `useAiUsage()` hace un fetch extra al perfil** → staleTime de 30s minimiza requests; el perfil ya se fetchea en auth-context, pero ese canal no expone los contadores IA.

## Migration Plan

1. Aplicar migration (cron job + RPC) a rama Supabase → validar manualmente
2. Actualizar `_shared/ai-quota.ts` + `fair-advisor/index.ts`
3. PR → CI deploya Edge Functions automáticamente
4. Mergear → merge a `main` triggerea el cron schedule en producción

**Rollback**: el cron job se puede eliminar con `SELECT cron.unschedule('reset-ai-counters')`. El RPC se puede dropear. Los cambios a las Edge Functions se revierten desplegando el commit anterior.

## Open Questions

- PA-05 resuelto: reset mensual (primer día del mes, 00:00 UTC). Documentar en `knowledge-base/10_preguntas_abiertas.md`.
