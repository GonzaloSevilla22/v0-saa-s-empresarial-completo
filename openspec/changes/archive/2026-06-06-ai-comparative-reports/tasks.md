## 1. DB — RPC de comparación de períodos

- [x] 1.1 Crear `supabase/migrations/<ts>_period_comparison.sql` con el RPC `rpc_period_comparison(p_a_start DATE, p_a_end DATE, p_b_start DATE, p_b_end DATE)` RETURNS TABLE — SECURITY DEFINER, `search_path = public`, deriva `v_accounts` vía `SELECT ARRAY(SELECT current_account_ids())`, lanza excepción P403 si el array está vacío
- [x] 1.2 Cuerpo del RPC: CTEs separados para cada fuente × período — `sales_a`, `sales_b`, `expenses_a`, `expenses_b`, `purchases_a`, `purchases_b` con `COALESCE(SUM(amount), 0)` y `COUNT(*)` filtrados por `account_id = ANY(v_accounts)` y `date BETWEEN p_*_start AND p_*_end`; `CROSS JOIN` final que calcula los 8 totales y los 4 deltas vía `ROUND((b - a) / NULLIF(a, 0) * 100, 2)`
- [x] 1.3 Agregar `REVOKE ALL ON FUNCTION rpc_period_comparison(...) FROM PUBLIC; GRANT EXECUTE ON FUNCTION rpc_period_comparison(...) TO authenticated`

## 2. Edge Function — ai-comparativo

- [x] 2.1 Crear `supabase/functions/ai-comparativo/index.ts`: CORS headers, helpers `jsonResponse`/`fallbackResponse`/`extractErrorMessage`, `fetchWithTimeout` (25s), imports de `checkAiQuota` / `incrementAiUsage` desde `'../_shared/ai-quota.ts'`
- [x] 2.2 Handler: auth con `supabaseClient.auth.getUser()`, quota check `checkAiQuota(supabaseClient, user.id, 'queries')` → 429 si excedido; leer `period_a_start`, `period_a_end`, `period_b_start`, `period_b_end` del body JSON
- [x] 2.3 Llamar a `supabaseClient.rpc('rpc_period_comparison', { p_a_start, p_a_end, p_b_start, p_b_end })` y extraer la primera fila del resultado
- [x] 2.4 Construir prompt para OpenAI: incluir los 8 totales y los 4 deltas con etiquetas legibles en español; solicitar objeto JSON `{ insight: string, recommendations: string[] }` con análisis accionable de las variaciones
- [x] 2.5 Llamar a OpenAI (`gpt-4o-mini`, `response_format: { type: 'json_object' }`, `max_tokens: 600`, `temperature: 0.3`); en timeout retornar `fallbackResponse` sin incrementar cuota
- [x] 2.6 INSERT en `ai_insights` (`user_id`, `type = 'comparativo'`, `priority = 'alta'`, `message` = el `insight` de OpenAI); luego `await incrementAiUsage(supabaseClient, user.id, 'queries')`; retornar `{ ok: true, data: { insight, recommendations } }`

## 3. Frontend — Tipos y Hook

- [x] 3.1 Agregar en `lib/types.ts` el tipo `PeriodComparison`: `{ period_a_revenue: number; period_a_expenses: number; period_a_purchases: number; period_a_operations: number; period_b_revenue: number; period_b_expenses: number; period_b_purchases: number; period_b_operations: number; revenue_delta_pct: number | null; expenses_delta_pct: number | null; purchases_delta_pct: number | null; operations_delta_pct: number | null }` y `ComparativeInsight`: `{ id: string; message: string; created_at: string }`
- [x] 3.2 Crear `hooks/use-period-comparison.ts`: hook `usePeriodComparison(aStart, aEnd, bStart, bEnd)` — `useQuery` con `queryKey: ['periodComparison', aStart, aEnd, bStart, bEnd]`, llama a `supabase.rpc('rpc_period_comparison', ...)`, staleTime 5 minutos, `enabled` solo cuando los 4 parámetros están definidos; retorna `{ data: PeriodComparison | null; isLoading; isError }`

## 4. Frontend — Página /reportes/comparativo

- [x] 4.1 Crear `app/(dashboard)/reportes/comparativo/page.tsx` como Client Component (`'use client'`): comprobar plan con `usePlanGate('avanzado')`; si `!gate.hasAccess` renderizar `PlanGateFallback` (mismo patrón que /rentabilidad) y retornar
- [x] 4.2 Selectores de fecha para Período A y Período B con shadcn/ui `Popover` + `Calendar`: por defecto Período A = primer día del mes actual hasta hoy, Período B = primer y último día del mes anterior; deshabilitar fechas anteriores a `today - historyDays` del plan
- [x] 4.3 Detectar solapamiento de períodos (`aEnd >= bStart && bEnd >= aStart`) y mostrar un banner de advertencia amarillo cuando se detecte
- [x] 4.4 Cuatro KPI cards (Ventas, Gastos, Compras, Operaciones): cada card muestra valor período A (formato ARS), valor período B y un `Badge` de delta — verde con `+X%` si positivo, rojo con `−X%` si negativo, gris con `N/A` si null; para gastos invertir el color (caída = verde, subida = roja)
- [x] 4.5 BarChart agrupado (Recharts `BarChart` con dos `Bar` — una por período, colores distintos): eje X = las 3 métricas monetarias (ventas, gastos, compras), eje Y = monto en ARS; incluir `Legend` con etiquetas de los períodos
- [x] 4.6 Panel de último insight IA: `useQuery` sobre `ai_insights` donde `type = 'comparativo'` ORDER BY `created_at DESC LIMIT 1`, staleTime 30s; mostrar `message` en card con fecha; si no hay insight mostrar placeholder "Usá el análisis IA para obtener observaciones"
- [x] 4.7 Botón "Analizar con IA": POST a `${NEXT_PUBLIC_SUPABASE_URL}/functions/v1/ai-comparativo` con `{ period_a_start, period_a_end, period_b_start, period_b_end }` y `Authorization: Bearer <access_token>` vía `supabase.auth.getSession()`; gestionar estado `isAnalyzing`; manejar 429 con `toast.warning`, fallback con `toast.warning`, éxito con `toast.success` + invalidar query de insight

## 5. Navegación

- [x] 5.1 Agregar en `components/app-sidebar.tsx` el ítem `{ title: "Comparativo", href: "/reportes/comparativo", icon: GitCompare, pro: true }` en el grupo "Inteligencia", importando `GitCompare` de lucide-react

## 6. CHANGES.md

- [x] 6.1 Marcar `[x]` en la entrada de `C-12` en `CHANGES.md`
