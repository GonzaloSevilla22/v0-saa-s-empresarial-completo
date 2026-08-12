# Proposal: app-timezone-argentina

## Why

El "día de negocio" de la app tiene tres anclajes horarios conviviendo: día UTC del servidor (Edge Functions, `toISOString().split('T')[0]`), día local del browser (`lib/date-range.ts`) y día argentino real (`reporting_local_today()` en SQL, solo en 3 RPCs de reporting). Entre las 21:00 y las 24:00 hora argentina (UTC−3) todo lo anclado a UTC se corre un día: **una venta cargada a las 22:00 se guarda con fecha de mañana** (`sale-form.tsx:98` defaultea al día UTC), el dashboard filtra insights de "hoy" con el día UTC (`dashboard/page.tsx:117`) y las ventanas de la IA (`buildBusinessSnapshot.ts:68-70`, fallbacks de las Edge Functions) miden períodos corridos. El producto es para microemprendedores de Mendoza: la hora argentina debe ser el único reloj de negocio de toda la app.

## What Changes

- Se establece **`America/Argentina/Mendoza` como huso canónico de negocio** para toda la app (constante de plataforma; Argentina no tiene DST desde 2009, pero se usa IANA por si se reintroduce).
- Helpers canónicos de "día de negocio argentino" por capa, con la misma semántica y casos de prueba compartidos (test de paridad, patrón de `kpi-ia-canonical-revenue`):
  - Frontend: `frontend/lib/date-range.ts` se re-ancla de "día local del browser" a "día argentino" vía `Intl.DateTimeFormat` (nuevo `argentinaToday()`; `utcDayRange`/`utcMonthRange`/`monthKey`/`parseMonthKey` pasan a derivar de él).
  - Edge Functions: `supabase/functions/_shared/argentina-time.ts` (Deno corre en UTC — los fallbacks rolling de ai-resumen/ai-insights/ai-simulador/ai-prediccion se re-anclan).
  - Backend: `backend/core/timezone.py` con `ZoneInfo("America/Argentina/Mendoza")` para todo cómputo de día de negocio.
  - SQL: `reporting_local_today()` **ya existe** — se extiende su uso a toda RPC vigente que aún use `CURRENT_DATE`/`now()::date` para día de negocio.
- Migración de todos los sitios que computan fechas de negocio con día UTC: **path de escritura** (defaults y `max` de `sale-form.tsx`, `purchase-form.tsx`, `expense-form-v2.tsx`, `comunidad/page.tsx:109`, `InvoiceAIButton.tsx:94`, `expense-import-dialog.tsx:166`) y **path de lectura** (`dashboard/page.tsx:117`, `buildBusinessSnapshot.ts:68-70`, `aiCopilotService.ts:43`, `sales-chart.tsx:16`, ventanas de Edge Functions).
- **Fuera de alcance**: nombres de archivo de exportaciones (`excel.ts:238`, `ExportButton.tsx:95`, `exportaciones/page.tsx:89` — cosmético, sin efecto de negocio); fechas AFIP/WSFE (ARCA tiene sus propias reglas de fecha de comprobante — zona intocable); backfill de filas históricas mal fechadas (ver OQ-1 en design).

## Capabilities

### New Capabilities
- `business-day-timezone`: el día calendario de negocio de toda la app (escritura de operaciones, ventanas de reporting/IA, filtros de "hoy") se computa en `America/Argentina/Mendoza`, con helpers canónicos por capa y paridad verificada entre ellos.

### Modified Capabilities
<!-- reporting-invariants NO cambia: RN-D5 ya exige fecha local del tenant en RPCs de reporting; esta capability generaliza esa regla a las demás capas sin alterar los requirements existentes. -->

## Impact

- **Frontend**: `lib/date-range.ts` (re-anclaje), 3 formularios de operaciones, dashboard, `buildBusinessSnapshot.ts`, `aiCopilotService.ts`, `sales-chart.tsx`, `comunidad`, `InvoiceAIButton`, `expense-import-dialog` + tests vitest afectados.
- **Edge Functions**: `_shared/argentina-time.ts` nuevo + re-anclaje de fallbacks en las 4 funciones IA.
- **Backend**: `core/timezone.py` nuevo + sweep de `datetime.now()`/`date.today()` en services/repositories (AFIP excluido).
- **DB**: sin cambios de esquema; posible migración `CREATE OR REPLACE` de RPCs que aún usen `CURRENT_DATE` (sweep en apply).
- **Comportamiento visible**: los usuarios que cargan operaciones de noche (21:00–24:00) verán las fechas correctas; los números de "hoy" dejan de correrse un día en esa franja.
- **Interacción con `kpi-ia-canonical-revenue`**: toca los mismos archivos IA. Orden recomendado: aplicar primero el change de KPIs (ya apply-ready) y este después, para que el re-anclaje se haga sobre el código ya canónico.
- **Sin superficie frontend nueva**: cambian fechas/números de pantallas existentes; no hay rutas ni menús nuevos.
