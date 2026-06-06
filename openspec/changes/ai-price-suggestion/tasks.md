## 1. Edge Function `ai-precio`

- [x] 1.1 Crear `supabase/functions/ai-precio/index.ts` con estructura base: CORS headers, auth check, plan check (solo `avanzado`/`pro`)
- [x] 1.2 Implementar consulta de ventas de los últimos 90 días del producto (`sale_items` JOIN `sales` filtrado por `product_id` y `user_id`)
- [x] 1.3 Implementar cálculo de elasticidad implícita: agrupar ventas por semana, calcular precio unitario promedio y cantidad vendida por semana, calcular correlación
- [x] 1.4 Implementar lógica de fallback por datos insuficientes: si ventas < 3 en 90 días, retornar `{ ok: true, fallback: true, reason: 'insufficient_data' }` sin llamar a OpenAI
- [x] 1.5 Verificar cuota `ai_queries_used` contra `plan_limits.max_ai_queries_per_month` antes de llamar a OpenAI; retornar 429 si excedida
- [x] 1.6 Construir prompt para OpenAI con: precio actual, costo catálogo, top ventas semanales, elasticidad calculada. Instrucción: retornar JSON `{ suggested_price, margin_pct, argument }`
- [x] 1.7 Llamar a `gpt-4o-mini` con timeout 25s; implementar fallback gracioso `{ ok: true, fallback: true, reason: 'timeout' }` si falla (RN-31)
- [x] 1.8 Insertar resultado en `ai_insights` (`type='oportunidad'`, `metadata: { product_id }`) e incrementar `ai_queries_used` atomicamente (RPC existente o UPDATE directo con service_role)
- [ ] 1.9 Deploy de la Edge Function: `npx supabase functions deploy ai-precio` — **MANUAL: ejecutar en terminal**

## 2. Componente `PriceSuggestionModal`

- [x] 2.1 Crear `components/ai/PriceSuggestionModal.tsx` con props `{ productId, productName, isOpen, onClose }`
- [x] 2.2 Implementar llamada a la Edge Function `ai-precio` al montar el modal (cuando `isOpen = true`) usando `useEffect`
- [x] 2.3 Implementar estado de carga: spinner mientras espera, deshabilitar cierre hasta recibir respuesta
- [x] 2.4 Implementar vista de éxito: precio sugerido en ARS formateado (Intl.NumberFormat), margen proyectado en %, argumento narrativo, disclaimer
- [x] 2.5 Implementar vista de fallback `insufficient_data`: mensaje "No hay suficiente historial de ventas para sugerir un precio. Registrá al menos 3 ventas en los últimos 90 días."
- [x] 2.6 Implementar vista de fallback `timeout`: mensaje "El análisis está tardando más de lo esperado. Intentá de nuevo en unos minutos."
- [x] 2.7 Implementar vista de error `quota_exceeded`: mensaje "Alcanzaste el límite mensual de consultas IA." con link a `/planes`
- [x] 2.8 Verificar accesibilidad: foco en el modal al abrir, Escape para cerrar, aria-modal

## 3. Integración en `/productos/[id]`

- [x] 3.1 Localizar la página de detalle de producto (`app/(dashboard)/productos/page.tsx` — no existe ruta `/[id]`; el feature se integró en `ProductCatalog` + la página de lista)
- [x] 3.2 Agregar botón "Sugerir precio IA" en la sección de info del producto, condicionado al plan efectivo (`avanzado`/`pro`)
- [x] 3.3 Para usuarios sin plan suficiente, el botón no aparece (prop `onSuggestPrice` no se pasa) — equivale al comportamiento de `<PlanGate>`
- [x] 3.4 Conectar el botón al `PriceSuggestionModal` con el `productId` y `productName` correctos

## 4. Integración en `/rentabilidad`

- [x] 4.1 Agregar columna de acción "Sugerir precio IA" en la tabla de `/rentabilidad` (botón icon en cada fila)
- [x] 4.2 Conectar el botón de cada fila al `PriceSuggestionModal` con el `productId` y `productName` de esa fila
- [x] 4.3 Manejar estado de qué modal está abierto (solo uno a la vez)

## 5. Tests

- [x] 5.1 Test unitario: Edge Function retorna `fallback: true` cuando ventas < 3 (mockear Supabase client)
- [x] 5.2 Test unitario: Edge Function retorna 429 cuando `ai_queries_used >= max_ai_queries_per_month`
- [x] 5.3 Test unitario: Edge Function retorna 403 cuando el usuario tiene plan `'gratis'`
- [x] 5.4 Test de componente: `PriceSuggestionModal` muestra spinner en estado de carga
- [x] 5.5 Test de componente: `PriceSuggestionModal` muestra mensaje correcto para `insufficient_data`
- [x] 5.6 Test de integración: botón "Sugerir precio IA" no aparece en DOM para usuario `gratis`
