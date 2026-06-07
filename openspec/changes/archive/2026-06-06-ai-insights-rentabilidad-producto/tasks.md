## 1. DB Migration — rpc_product_profitability

- [x] 1.1 Crear `supabase/migrations/20260606110000_product_profitability.sql` con la función `rpc_product_profitability(p_period_days INT DEFAULT 30)` — RETURNS TABLE, SECURITY DEFINER, `search_path = public`, deriva `v_account_id` vía `current_account_ids() LIMIT 1`, lanza excepción P403 si no hay cuenta activa
- [x] 1.2 El cuerpo del RPC calcula por `product_id`: `total_revenue = SUM(s.total)` desde `sales`, `total_cost = COALESCE(SUM(p.total), pr.cost * SUM(s.quantity))` desde `purchases` (fallback a catálogo), `gross_margin = total_revenue - total_cost`, `gross_margin_pct = ROUND((gross_margin / NULLIF(total_revenue,0)) * 100, 2)`, `units_sold = SUM(s.quantity)`, `last_sale_date = MAX(s.date)` — solo productos con al menos una venta en el período (`s.date >= now() - p_period_days * interval '1 day'`), LIMIT 200 ORDER BY `gross_margin_pct DESC`
- [x] 1.3 Agregar `REVOKE ALL ... FROM PUBLIC; GRANT EXECUTE ... TO authenticated` para el nuevo RPC

## 2. Edge Function — ai-rentabilidad

- [x] 2.1 Crear `supabase/functions/ai-rentabilidad/index.ts`: skeleton con CORS headers, `jsonResponse`/`fallbackResponse`/`extractErrorMessage`, `fetchWithTimeout` (AI_TIMEOUT_MS = 25_000), import de `checkAiQuota` / `incrementAiUsage` desde `'../_shared/ai-quota.ts'`
- [x] 2.2 Handler: auth con `supabaseClient.auth.getUser()`, quota check `checkAiQuota(supabaseClient, user.id, 'queries')` → 429 si excedido; leer `period_days` del body JSON (default 30)
- [x] 2.3 Llamar a `supabaseClient.rpc('rpc_product_profitability', { p_period_days: periodDays })` y construir `topProducts` (top 5 por `gross_margin_pct`) y `bottomProducts` (bottom 5, los de menor margen — los últimos 5 del resultado ordenado DESC)
- [x] 2.4 Llamar a OpenAI (`gpt-4o-mini`, `response_format: { type: 'json_object' }`) con prompt que incluye top/bottom performers y solicita un objeto `{ insight: string, recommendations: string[] }` con análisis accionable en español
- [x] 2.5 INSERT en `ai_insights` (`user_id`, `type = 'margen'`, `priority = 'alta'`, `message` = el `insight` de OpenAI) y luego `await incrementAiUsage(supabaseClient, user.id, 'queries')`; retornar `{ ok: true, data: { insight, recommendations } }`

## 3. Frontend — Tipos

- [x] 3.1 Agregar en `lib/types.ts` los tipos `ProductProfitability` (`{ product_id: string; product_name: string; total_revenue: number; total_cost: number; gross_margin: number; gross_margin_pct: number; units_sold: number; last_sale_date: string | null }`) y `ProfitabilityInsight` (`{ id: string; message: string; created_at: string }`)

## 4. Frontend — Hook useProfitability

- [x] 4.1 Crear `hooks/use-profitability.ts`: hook que llama a `supabase.rpc('rpc_product_profitability', { p_period_days })` vía `useQuery`, staleTime 5 minutos, retorna `{ data: ProductProfitability[]; isLoading; isError }`; acepta `periodDays: number` como parámetro

## 5. Frontend — Página /rentabilidad

- [x] 5.1 Crear `app/(dashboard)/rentabilidad/page.tsx` como Client Component (`'use client'`): comprobar plan con `usePlanGate('avanzado')`; si `!gate.hasAccess` renderizar `<PlanGate requiredPlan="avanzado" />` y retornar
- [x] 5.2 Tabla de rentabilidad: columnas Producto / Ingresos / Costo / Margen % / Unidades, ordenada por `gross_margin_pct` DESC, usando datos de `useProfitability(periodDays)` donde `periodDays = limits.historyDays ?? 30`
- [x] 5.3 Bar chart horizontal (Recharts `BarChart` + `Bar` + `XAxis` + `YAxis` + `Tooltip`): top 10 productos por `gross_margin_pct`, eje X = margen %, eje Y = nombre producto
- [x] 5.4 Panel de último insight IA: fetch del último registro de `ai_insights` con `type = 'margen'` usando `useQuery` (staleTime 30s); mostrar el `message` en un card
- [x] 5.5 Botón "Analizar con IA": POST a `${process.env.NEXT_PUBLIC_SUPABASE_URL}/functions/v1/ai-rentabilidad` con `{ period_days: periodDays }` y el header `Authorization: Bearer <access_token>` vía `supabase.auth.getSession()`; gestionar estado `isAnalyzing` (spinner en el botón); invalidar la query de `ai_insights` al completarse exitosamente

## 6. Navegación

- [x] 6.1 Buscar el sidebar/nav del dashboard y agregar el link "Rentabilidad" que apunta a `/rentabilidad` (icono `TrendingUp` de lucide-react); visible solo cuando el plan efectivo es `'avanzado'` o `'pro'` (usar `usePlanGate` o chequeo de plan directo)

## 7. CHANGES.md

- [x] 7.1 Marcar `[x]` en la entrada de `C-11` en `CHANGES.md`
