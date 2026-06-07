## Why

Los usuarios del plan Avanzado y PRO ya pueden ver la rentabilidad por producto (C-11), pero no tienen orientación sobre qué precio cobrar para maximizar su margen. Agregar sugerencia de precio óptimo vía IA cierra el ciclo analytics→acción: el usuario pasa de ver "mi margen es bajo" a recibir una recomendación concreta de precio con argumento narrativo.

## What Changes

- Nueva Edge Function `ai-precio`: recibe `product_id`, consulta historial de ventas de los últimos 90 días + costo del producto, construye prompt con elasticidad implícita (variación cantidad vendida vs precio) y envía a OpenAI para obtener precio óptimo sugerido con argumento narrativo.
- Modal "Sugerir precio IA" accesible desde: (a) vista de detalle de producto y (b) página `/rentabilidad` (C-11).
- Resultado del modal: precio sugerido, margen proyectado con ese precio, argumento IA.
- Cada sugerencia se guarda en `ai_insights` con `type = 'oportunidad'`.
- Usa el contador `ai_queries_used` (incrementa 1 por llamada), con check de cuota previo.
- Gating UI: ocultar/deshabilitar para planes `'gratis'` e `'inicial'`.
- Fallback gracioso cuando no hay historial de ventas suficiente (0 ventas en 90 días).

## Capabilities

### New Capabilities

- `ai-price-suggestion`: Edge Function + modal de sugerencia de precio óptimo por producto, con gating por plan y fallback gracioso.

### Modified Capabilities

- `product-profitability`: Se agrega el botón "Sugerir precio IA" al panel de cada producto en `/rentabilidad`, invocando la nueva capability.

## Impact

- **Nueva Edge Function**: `supabase/functions/ai-precio/index.ts`
- **Nuevo componente**: `components/ai/PriceSuggestionModal.tsx`
- **Páginas modificadas**: `app/(dashboard)/productos/[id]/page.tsx`, `app/(dashboard)/rentabilidad/page.tsx`
- **Tablas afectadas**: `ai_insights` (INSERT), `profiles` (lectura de `ai_queries_used`)
- **Dependencias**: C-11 (`product-profitability` page, `rpc_product_profitability`), C-04 (`ai_queries_used` counter), C-02 (plan gating)
- **Sin migraciones SQL**: no requiere cambios de schema (usa tablas existentes)
