## Why

Los microemprendedores necesitan comparar su desempeño entre períodos (este mes vs el anterior, esta temporada vs la del año pasado) para tomar decisiones informadas. Sin una comparación estructurada, la visión del tablero es solo un snapshot estático; con C-12 pasa a ser un diagnóstico de tendencia. Es el complemento analítico natural de C-11 (rentabilidad por producto) y está desbloqueado por C-04.

## What Changes

- Nuevo RPC `rpc_period_comparison(p_period_a_start, p_period_a_end, p_period_b_start, p_period_b_end)` que devuelve métricas agregadas para dos períodos: ventas totales, gastos totales, número de operaciones, top 5 productos por revenue, y deltas porcentuales entre períodos.
- Nueva Edge Function `ai-comparativo`: llama al RPC, envía el resumen comparativo a GPT-4o-mini, genera análisis narrativo accionable, inserta en `ai_insights` (type=`'comparativo'`) e incrementa `ai_queries_used`.
- Nueva página `/reportes/comparativo`: selectores de fecha para dos períodos, cards de KPIs con delta %, charts lado a lado (Recharts), panel de último análisis IA con botón "Analizar con IA".
- Gating: disponible solo para planes `'avanzado'` y `'pro'`; los demás ven `PlanGateFallback`. El selector de fechas respeta `historyDays` del plan activo.
- Link "Comparativo" en sidebar bajo el grupo "Inteligencia", visible con badge Crown para planes inferiores.

## Capabilities

### New Capabilities

- `comparative-reports`: Comparación de métricas de negocio entre dos períodos definidos por el usuario, con análisis IA narrativo de las variaciones.

### Modified Capabilities

- `ai-usage-counters`: La Edge Function `ai-comparativo` usa el counter `'queries'` — mismo flujo que `ai-rentabilidad`. Sin cambio de requisitos, solo un consumer más del patrón ya especificado.

## Impact

- **DB**: Un nuevo RPC con SECURITY DEFINER, sin nuevas tablas.
- **Edge Functions**: Nueva función `supabase/functions/ai-comparativo/index.ts`, reutiliza `_shared/ai-quota.ts`.
- **Frontend**: Nueva página `app/(dashboard)/reportes/comparativo/page.tsx`, nuevo hook `hooks/use-period-comparison.ts`, tipo `PeriodComparison` en `lib/types.ts`.
- **Sidebar**: Nuevo ítem en el grupo "Inteligencia" de `components/app-sidebar.tsx`.
- **Sin migraciones de datos**: El RPC opera sobre tablas existentes (`sales`, `expenses`, `purchases`).
