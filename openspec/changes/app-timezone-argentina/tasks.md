# Tasks: app-timezone-argentina

> Strict TDD en cada task de código: safety net (baseline de tests de los archivos a tocar) → RED → GREEN → TRIANGULATE → REFACTOR. Tests de fecha SIEMPRE con instantes absolutos (ISO con Z) — nunca `new Date()` sin argumento en asserts (deterministas en cualquier huso de CI).
> Prerrequisito: aplicar ANTES `kpi-ia-canonical-revenue` (D6 — comparte `buildBusinessSnapshot.ts` y las 4 Edge Functions IA).

## 1. Helpers canónicos + paridad

- [x] 1.1 RED: tests de `argentinaToday()`/`argentinaDate()` en `frontend/__tests__/date-range.test.ts` (ubicación real del archivo existente, no `lib/date-range.test.ts`) con la tabla de casos canónica (20:59 ART, 21:00 ART, 23:59 ART, 00:00 ART, borde de mes 31→1, borde de año 31-dic 22:00 ART)
- [x] 1.2 GREEN: implementado en `frontend/lib/date-range.ts` vía `Intl.DateTimeFormat('en-CA', { timeZone: 'America/Argentina/Mendoza' })` (D1); tabla de casos exportada (`argentinaDayCases`) para el test de paridad
- [x] 1.3 RED+GREEN: `supabase/functions/_shared/argentina-time.ts` con la misma API mínima (`argentinaToday` + helpers de ventana rolling para Edge Functions); test de paridad `frontend/__tests__/lib/argentina-time-parity.test.ts` importa ambos helpers y la tabla compartida
- [x] 1.4 REFACTOR: `utcDayRange`/`utcMonthRange`/`utcPrevMonthRange`/`monthKey`/`parseMonthKey` re-anclados de día-browser a día-argentino sin cambiar firmas (D2); `parseMonthKey` ahora ancla a medianoche ART (`argentinaMidnightUtc`) en vez del constructor `Date` local, para que el roundtrip con `monthKey`/`utcMonthRange` sea correcto en cualquier huso de runtime (gap encontrado en el diseño original: construir con componentes locales rompía el roundtrip en CI-UTC). Triangulado con casos de franja nocturna y bordes de mes/año; suite vitest completa verde

## 2. Path de escritura (formularios)

- [x] 2.1 Safety net: no existían tests previos para `sale-form`/`purchase-form`/`expense-form-v2` (baseline = 0); se crearon tests nuevos de regresión por formulario (render con hooks/child components mockeados, foco exclusivo en el `<input type="date">`)
- [x] 2.2 RED→GREEN: default y `max` de fecha en `sale-form.tsx` (líneas sin cambio real: :98, :611) → `argentinaToday()`; test con instante `2026-06-09T01:00:00.000Z` (22:00 ART del día anterior) en `frontend/__tests__/components/sale-form-date-default.test.tsx`
- [x] 2.3 Ídem `purchase-form.tsx` (:97/:483, test `purchase-form-date-default.test.tsx`) y `expense-form-v2.tsx` (:31/:104, test `expense-form-date-default.test.tsx`)
- [x] 2.4 Ídem sitios menores de escritura: `comunidad/page.tsx:109`, `InvoiceAIButton.tsx:94` (fallback de fecha de factura) migrados sin test dedicado (sustitución mecánica de `argentinaToday()`, ya exhaustivamente probado — juicio de proporcionalidad, sin infra de test previa y de bajo riesgo); `expense-import-dialog.tsx:166` (comparación "es hoy") SÍ tiene test dedicado (`expense-import-dialog-parse-and-validate.test.ts`, vía `parseAndValidate` exportado) porque además arrastró un segundo sitio no listado en proposal.md: `excel.ts:238` (`parseDate`, fallback de fecha del importador CSV) — el proposal lo daba por "fuera de alcance" (nombre de archivo de exportación) pero en el código actual esa línea es la lógica de parseo de fecha en sí, consumida por este mismo sitio; se migró junto para no dejar la comparación de la línea 166 comparando ART contra UTC (test `excel-parse-date.test.ts`)

## 3. Path de lectura (frontend)

- [ ] 3.1 RED→GREEN: `dashboard/page.tsx:117` (filtro insights de "hoy") → `argentinaToday()`
- [ ] 3.2 RED→GREEN: `buildBusinessSnapshot.ts:68-70` (nowStr/d30Str/d60Str) y `aiCopilotService.ts:43` → ventanas ancladas al día argentino (sobre el código ya migrado por `kpi-ia-canonical-revenue`)
- [ ] 3.3 RED→GREEN: `sales-chart.tsx:16` (bucketing por día del gráfico) → día argentino; verificar que las etiquetas del eje no se corren

## 4. Edge Functions (fallbacks rolling)

- [ ] 4.1 RED→GREEN: fallbacks sin `dateFrom`/`dateTo` de `ai-resumen` (daily/weekly/monthly) anclados a `argentina-time.ts`; aritmética en `_shared`, cableado en `index.ts` (testeable desde vitest)
- [ ] 4.2 Ídem `ai-insights` (d30/d60), `ai-simulador` (firstDayOfMonth) y `ai-prediccion`

## 5. SQL sweep

- [ ] 5.1 Sweep de definiciones VIGENTES en `supabase/migrations/` con `CURRENT_DATE`/`now()::date` como día de negocio; clasificar cada sitio (migrar / deliberado-documentado / muerto)
- [ ] 5.2 Si hay sitios a migrar: una migración `CREATE OR REPLACE` idempotente → `reporting_local_today()` (sin DROP, firmas intactas); si hay 0, documentar el resultado del sweep en el PR

## 6. Verificación y cierre

- [ ] 6.1 Suites completas verdes: `pnpm -C frontend test` (baseline 751+) y gate `validate-kpis` local si aplica
- [ ] 6.2 Verificación manual del escenario nocturno: con reloj del sistema simulado (o instante inyectado) a las 22:00 ART, el form de venta defaultea a HOY y "ventas hoy" del dashboard incluye la venta recién cargada
- [ ] 6.3 PR con tabla de evidencia TDD + nota del cambio visible (fechas nocturnas corregidas) + resultado del sweep 5.1 + decisión OQ-1 (backfill NO, salvo pedido del PO); merge con checks verdes
