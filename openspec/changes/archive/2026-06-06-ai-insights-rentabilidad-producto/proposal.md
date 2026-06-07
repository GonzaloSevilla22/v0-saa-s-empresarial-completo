## Why

C-02 + C-04 implementaron el gating de cuotas IA y el reset mensual. El sistema de cuotas está completo; ahora se desbloquea el primer análisis premium: **rentabilidad por producto**. Sin esta feature, los usuarios en plan Avanzado/Pro no tienen razón diferenciadora para pagar — no pueden ver qué productos generan margen real vs. cuáles están perdiendo plata.

## What Changes

- **RPC PostgreSQL `rpc_product_profitability(p_account_id UUID, p_period_days INT)`**: calcula por SKU desde `sales` y `purchases` — `total_revenue`, `total_cost`, `gross_margin`, `gross_margin_pct`, `units_sold`, `last_sale_date`. SECURITY DEFINER, validación interna de membresía.
- **Edge Function `ai-rentabilidad`**: llama al RPC → formatea los datos para OpenAI → genera análisis con top 5 / bottom 5 productos por margen → INSERT en `ai_insights` (type=`'margen'`). Usa `checkAiQuota` / `incrementAiUsage` (counter `'queries'`) del shared module.
- **Page `/rentabilidad`**: tabla de productos ordenada por margen (`gross_margin_pct` desc), gráfico bar chart (Recharts), botón "Analizar con IA" que llama a `ai-rentabilidad`.
- **Gating UI**: la página es exclusiva de `'avanzado'` y `'pro'` (RN-06). Para planes inferiores, se renderiza el componente `PlanGate` con CTA de upgrade en lugar del contenido.

## Capabilities

### New Capabilities

- `product-profitability`: RPC SQL para cálculo de margen por SKU, Edge Function de análisis IA, y página frontend `/rentabilidad` con tabla + gráfico + insight generado.

### Modified Capabilities

*(ninguna — el gating de plan ya está especificado en `plan-gating`. Esta feature lo consume sin cambiar sus requirements.)*

## Impact

- `supabase/migrations/`: nueva migración con `rpc_product_profitability`
- `supabase/functions/ai-rentabilidad/index.ts`: nueva Edge Function
- `app/(dashboard)/rentabilidad/page.tsx`: nueva página (App Router)
- `lib/types.ts`: tipos `ProductProfitability`, `ProfitabilityInsight` (si no existen)
- Sin cambios a `usePlanLimits()`, `usePlanGate()`, ni `_shared/ai-quota.ts` — se usan tal como están
