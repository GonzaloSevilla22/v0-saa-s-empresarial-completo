## Context

C-01 agregó `products`, `sales`, `purchases` con `cost`/`price`. C-02 implementó el sistema de cuotas IA. C-04 completó el reset mensual y el RPC atómico. C-05 introdujo la arquitectura multi-tenant con `account_id` en `sales`/`purchases` y la función `current_account_ids()`. El CHANGES.md original especifica `rpc_product_profitability(p_user_id, p_period_days)` — ese signature es anterior a C-05 y debe actualizarse.

## Goals / Non-Goals

**Goals:**
- RPC `rpc_product_profitability` que calcula margen bruto por SKU en un período dado
- Edge Function `ai-rentabilidad` con cuota IA, análisis OpenAI, e INSERT en `ai_insights`
- Página `/rentabilidad` gateada a 'avanzado'/'pro' con tabla + bar chart + insight IA

**Non-Goals:**
- Margen neto (no incluye gastos fijos/indirectos — es margen bruto por SKU)
- Rentabilidad por categoría o por cliente
- Histórico de insights de margen (solo el último en el panel)
- Sugerencia de precios (eso es C-13)

## Decisions

### D1 — RPC sin parámetro de identidad (alina con C-05 D7)

**Decisión**: `rpc_product_profitability(p_period_days INT DEFAULT 30)` — sin `p_user_id`. El RPC deriva el `account_id` internamente vía `current_account_ids()`, igual que todos los RPCs post C-05.

**Alternativa descartada**: pasar `p_account_id` como parámetro — viola el patrón establecido en C-05; un usuario podría pasar el account_id de otra cuenta.

### D2 — Costo: purchases reales con fallback a catalogo

**Decisión**: `total_cost` por producto = `COALESCE(SUM(purchases.total), products.cost * SUM(sales.quantity))`. Si hay registros de compra en el período, se usan esos. Si no, se multiplica el costo de catálogo (`products.cost`) por las unidades vendidas.

**Alternativa descartada**: solo catálogo — ignora variaciones de precio de compra real. Solo purchases — excluiría productos que se compraron antes del período pero se vendieron en él.

**Trade-off**: el fallback al catálogo puede sobreestimar margen si el costo real difiere. Aceptable para el MVP; es un indicador de tendencia, no un cálculo contable exacto.

### D3 — Scoping por account_id en el RPC

**Decisión**: el RPC filtra `sales WHERE account_id = v_account_id` (derivado de `current_account_ids()`). RLS ya restringe al account, pero el filtro explícito en el RPC es defensa en profundidad.

### D4 — Counter de cuota: 'queries' (no nuevo tipo)

**Decisión**: `ai-rentabilidad` usa el counter `'queries'` del shared `ai-quota.ts`, igual que `ai-insights`, `ai-prediccion`, etc.

**Alternativa descartada**: crear un counter `'profitability'` — no justificado; el modelo de negocio agrupa todos los análisis en un único límite "Consultas IA".

### D5 — Período: `historyDays` del plan como cota máxima

**Decisión**: la página pasa `p_period_days = Math.min(requestedDays, limits.historyDays)` al llamar a la Edge Function. La Edge Function a su vez pasa `p_period_days` al RPC. Esto respeta el límite de historial del plan sin codificarlo en el RPC.

**Razón**: el RPC es reutilizable desde otros contextos (admin, reportes futuros). Las restricciones de plan pertenecen en la capa de aplicación.

### D6 — Prompt OpenAI: top 5 / bottom 5 por gross_margin_pct

**Decisión**: enviar los 5 productos con mayor margen y los 5 con menor margen (o todos si son menos de 10). El prompt instruye a OpenAI a identificar oportunidades (subir precio en top performers, revisar costos en bottom performers).

**Razón**: limitar el payload a 10 productos evita tokens excesivos y mantiene la respuesta enfocada y accionable (RN-30).

### D7 — Fallback sin incremento de cuota

**Decisión**: si OpenAI falla (timeout o error), el counter NO se incrementa. Consistente con el patrón de `ai-insights` y `fair-advisor`.

## Risks / Trade-offs

- **[Risk] Productos sin compras registradas** → fallback a `products.cost`; si el campo cost está vacío/cero, el margen = 100% (incorrecto). Mitigación: filtrar productos con `cost IS NULL OR cost = 0` y mostrar advertencia en la UI.
- **[Risk] Muchos productos (>500 SKUs)** → el RPC puede ser lento. Mitigación: `LIMIT 200` en el RPC para el MVP; el ordering por `gross_margin_pct DESC` garantiza que se muestran los más relevantes.
- **[Risk] `current_account_ids()` retorna múltiples cuentas** → `LIMIT 1` en el SELECT (igual que en RPCs C-05). El usuario opera sobre su cuenta principal activa.
- **[Trade-off] Período de análisis fijo al llamar desde la Edge Function** → la Edge Function recibe `period_days` en el body de la request; si no se envía, usa `30` como default.

## Migration Plan

1. Crear migración con `rpc_product_profitability` → validar en Supabase dev con datos reales
2. Crear `supabase/functions/ai-rentabilidad/` con la Edge Function
3. Crear `app/(dashboard)/rentabilidad/page.tsx` con gating + tabla + chart
4. PR → CI deploya Edge Functions; `npx supabase db push` para la migración

**Rollback**: dropear el RPC + eliminar la Edge Function. La página `/rentabilidad` no rompe nada si no existe el RPC — simplemente no mostrará datos.

## Open Questions

- ¿La tabla en la UI muestra variantes como filas separadas o agrupadas bajo el padre? → Para el MVP: filas separadas (cada SKU es una fila). Agrupar por padre es complejidad de C-13+.
- ¿Se puede llamar a `rpc_product_profitability` directamente desde el cliente (para la tabla de datos) o solo vía la Edge Function? → El RPC es `SECURITY DEFINER` con GRANT a `authenticated`, por lo que el cliente Supabase puede llamarlo directamente. La tabla de datos se fetchea desde el cliente; el botón "Analizar con IA" llama a la Edge Function.
