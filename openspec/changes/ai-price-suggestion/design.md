## Context

C-11 introdujo la página `/rentabilidad` con cálculo de margen por SKU y análisis IA (`ai-rentabilidad`). C-13 extiende ese módulo con una nueva acción: sugerir el precio óptimo para un producto individual. El patrón es idéntico al establecido en C-11 — Edge Function que consulta datos reales → prompt OpenAI → INSERT en `ai_insights` → respuesta al cliente.

Estado actual: las páginas `/productos/[id]` y `/rentabilidad` no tienen integración con precio sugerido. La tabla `ai_insights` soporta `type = 'oportunidad'` (RN-34). Los contadores `ai_queries_used` están operativos (C-04).

## Goals / Non-Goals

**Goals:**
- Edge Function `ai-precio` que recibe `product_id`, calcula elasticidad implícita desde el historial de 90 días y retorna precio sugerido + argumento narrativo
- Modal reutilizable `PriceSuggestionModal` invocable desde producto detail y desde `/rentabilidad`
- Gating por plan (solo `avanzado` y `pro`)
- Fallback gracioso cuando historial < 3 ventas (no hay suficiente señal)
- Guardar sugerencia en `ai_insights` (`type='oportunidad'`)

**Non-Goals:**
- No se agrega nueva tabla ni migración SQL
- No se implementa ajuste automático de precio (es sugerencia, no acción)
- No se persiste la sugerencia histórica más allá de `ai_insights` (sin tabla dedicada)
- No se soporta precio por variante (solo precio de producto padre/standalone)

## Decisions

### D-1: Cálculo de elasticidad implícita en la Edge Function, no en SQL

El cálculo de elasticidad (correlación entre cambio de precio registrado en `purchases.unit_price` vs cantidad vendida) requiere lógica iterativa que es más natural en TypeScript que en SQL. La Edge Function consulta las ventas de los últimos 90 días via Supabase Client, calcula la correlación localmente, y construye el payload para OpenAI.

**Alternativa descartada**: RPC SQL dedicado. El cálculo de correlación lineal en PL/pgSQL es posible pero frágil y difícil de depurar. El patrón establecido en `ai-rentabilidad` (Edge Function con lógica de análisis local) es más mantenible.

### D-2: Umbral mínimo de 3 ventas para llamar a OpenAI

Con menos de 3 ventas en 90 días no hay señal de elasticidad útil. En ese caso la Edge Function retorna un fallback estructurado `{ ok: true, fallback: true, reason: 'insufficient_data' }` sin gastar cuota IA ni escribir en `ai_insights`.

**Alternativa descartada**: Siempre llamar a OpenAI con costo_catalogo como fallback de datos. Genera sugerencias de baja calidad que erosionan la confianza del usuario en el feature.

### D-3: Modal compartido `PriceSuggestionModal` invocado desde dos puntos de entrada

El modal es un componente React independiente que acepta `productId` y `productName` como props. Esto evita duplicar la lógica de llamada a la Edge Function en ambas páginas.

### D-4: El contador `ai_queries_used` se verifica y se incrementa en la Edge Function (patrón C-04)

Consistente con `ai-rentabilidad` y demás Edge Functions IA. El check de cuota ocurre antes de llamar a OpenAI; el incremento ocurre solo tras una respuesta exitosa (no fallback).

## Risks / Trade-offs

- **[Riesgo] Historial de precios no siempre está en `purchases.unit_price`** → Si el usuario no registra compras con `unit_price` consistente, la elasticidad calculada es ruidosa. Mitigación: el prompt instruye a OpenAI a basar la sugerencia en el costo actual del catálogo (`products.cost`) cuando la señal de compras es débil.

- **[Riesgo] El usuario puede no entender "precio sugerido" como orientativo** → El modal incluye copy explícito: "Esta es una sugerencia basada en tu historial. La decisión final es tuya." Mitigación editorial, no técnica.

- **[Trade-off] No se persiste histórico de sugerencias** → `ai_insights` actúa como log implícito (se puede consultar por `type='oportunidad'` y `metadata.product_id`). Si en el futuro se necesita historial por producto, se puede agregar un filtro sobre `ai_insights`.

## Migration Plan

No requiere migración SQL. El deploy es:
1. Deploy Edge Function `ai-precio` a Supabase
2. Deploy frontend con el nuevo modal y los botones en las dos páginas
3. No hay rollback especial: si el botón no aparece el usuario no pierde funcionalidad existente

## Open Questions

- ¿Mostrar el precio sugerido en la moneda del perfil del usuario (ARS) o siempre en la unidad base? → Asumir ARS por defecto (todos los usuarios actuales son AR).
- ¿Incluir el precio sugerido en el panel lateral de `/rentabilidad` junto con el botón "Analizar con IA" existente, o solo en el detalle de fila? → Botón en cada fila de la tabla (más accesible).
