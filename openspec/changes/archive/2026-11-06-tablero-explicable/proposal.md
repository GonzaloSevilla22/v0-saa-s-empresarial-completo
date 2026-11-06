## Why

El PO pidió el 2026-11-06 cuatro arreglos sobre el Tablero (`/dashboard`), todos de la misma familia: hoy el Tablero muestra números que no se pueden interrogar ni accionar. El gráfico «Ventas últimos 7 días» no deja elegir fechas ni comparar (y, medido en el código, **sólo suma las 25 filas de venta más recientes**, sin sucursal ni notas de crédito); las tarjetas KPI no dicen de dónde sale cada número; la campana lista avisos que no se pueden cerrar ni llevan a ningún lado; y el «Resumen IA del día» no muestra el resumen desde fines de junio, aunque la Edge Function lo genera y gasta cuota en cada visita.

Pedidos textuales:
1. *«quiero que se pueda elegir las fechas para ver la comparación bien, no solo los últimos 7 días»*
2. *«quiero que esto sean botones que se abran y te muestren de dónde sale la información de ahí y se cierre con una cruz, como un menú superpuesto»* (todas las tarjetas menos «Por cobrar», que ya lleva a `/cobranzas`)
3. *«que se puedan cerrar, o hacer click para enviarte a la alerta, y que se cierre sola después de esta»*
4. «Resumen IA del día»: *«lleva meses sin funcionar»*, queda en «Cargando resumen inteligente…».

## What Changes

- **Gráfico de ventas del Tablero con rango y comparación** (`components/dashboard/sales-chart.tsx`): presets 7 / 30 / 90 días + rango personalizado; serie del período anterior de igual longitud superpuesta y variación porcentual del total. Deja de agregar `sales` en el cliente: consume la fuente canónica de `/estadisticas` (`useSalesEvolution` → `GET /reports/statistics/evolution` → `rpc_sales_evolution`), que ya resta notas de crédito, respeta el `BranchFilter` y recorta al historial del plan en el servidor. Usa el gráfico compartido `ReportTimeSeriesChart` (tokens del design system: deja de tener colores fijos de tema oscuro).
- **Tarjetas KPI explicables** (`KpiSummaryCard`, `KpiCard`): las 9 tarjetas (Ganancia Neta, Margen por Canal, Stock sin Rotación, Costo por Venta, Ticket Promedio; Ventas / Gastos / Ganancia neta del mes, Productos en alerta) pasan a ser botones que abren un diálogo superpuesto (cruz, `Esc`, foco atrapado y devuelto) con: qué mide en lenguaje llano, la cuenta, el período y los filtros que aplican **ahora** (mes, sucursal), de qué datos sale, qué no incluye y un enlace a la pantalla del detalle. Los textos viven en un catálogo único (`lib/dashboard-kpi-explanations.ts`) escrito contra el cuerpo vivo de las RPCs. «Por cobrar» conserva su `href` sin cambios.
- **Campana accionable** (`components/dashboard/NotificationBell.tsx`, `hooks/data/use-notifications.ts`): cada aviso tiene botón de cerrar (lo marca leído y desaparece del panel al instante), el cuerpo navega al destino de la alerta (mapeo `type`/`payload` → ruta para los 10 tipos) y al navegar el aviso se marca leído y el panel se cierra solo. El panel lista sólo los avisos sin leer, con contador exacto y «Marcar todas como leídas». Reutiliza `read`/`read_at`: **sin migración**. Corrige de paso que marcar leído nunca actualizaba la caché (el badge no bajaba hasta el próximo resync).
- **Resumen IA del día que funciona** (`components/dashboard/ai-summary-card.tsx`): causa raíz confirmada con evidencia en el navegador del PO y en prod — desde `20260629000001_unify_insights` la fila de `insights` que devuelve `rpc_atomic_log_ai_insight` trae el texto en `message` y la tarjeta lo busca en `content`, así que tras ~15 s cae al fallback; el PO lo vive como *«queda en cargando para siempre»* porque el texto inicial es «Cargando…» y nunca llega un resumen. **El fix del campo va en un PR ad-hoc aparte del orquestador; este change no lo duplica** y se acota a la experiencia: estado de carga propio y visible («suele tardar unos segundos»; deja de usar «Cargando…» como texto inicial), error legible por causa, «Regenerar» siempre operable (tope duro de 30 s), y la llamada en una consulta de React Query cacheada por día que evita gastar una consulta de IA en cada visita al Tablero.
- `/cobranzas` acepta `?tab=payables` para que el aviso de deuda con proveedores abra la pestaña correcta.

**Sin cambios de backend, base de datos ni Edge Functions** (100 % frontend; declarado). La calidad del contenido de la IA queda fuera: la cubre el explore `openspec/explore/2026-11-06-mejora-ia.md` (change futuro `ia-insights-tablero`).

## Capabilities

### New Capabilities

Ninguna: todo cae en capabilities existentes.

### Modified Capabilities
- `dashboard-kpi-summary`: tres requirements nuevos — tarjetas explicables con diálogo de origen del dato; gráfico de ventas del Tablero con rango elegible, comparación y fuente canónica; Resumen IA del día visible, con estados de carga/error y sin regenerar en cada visita.
- `in-app-notifications`: un requirement nuevo — campana accionable (descartar, navegar al destino, cierre automático, sólo no leídas, marcar todas).

## Impact

- **Frontend**: `components/dashboard/{sales-chart,kpi-card,KpiSummaryCard,KpiSummaryBlock,NotificationBell,ai-summary-card}.tsx`, `components/dashboard/KpiExplainDialog.tsx` (nuevo), `lib/dashboard-kpi-explanations.ts`, `lib/notification-routes.ts`, `lib/ai-summary.ts` (nuevos, puros), `hooks/data/use-notifications.ts`, `hooks/data/use-ai-daily-summary.ts` (nuevo), `app/(dashboard)/dashboard/page.tsx`, `app/(dashboard)/cobranzas/page.tsx` (lee `?tab=`), `components/ui/dialog.tsx` (rótulo accesible de la cruz: «Cerrar»).
- **Arnés y E2E**: `app/dev-harness/tablero-explicable/` + `e2e/harness/tablero-explicable-visual.spec.ts` (4 combinaciones desktop/móvil × claro/oscuro).
- **Superficie**: todo en `/dashboard` (entrada existente «Tablero» del sidebar) y en la campana del encabezado (global, `components/dashboard/breadcrumb-nav.tsx`). Sin rutas nuevas.
- **APIs consumidas sin cambios**: `GET /reports/statistics/evolution`, PostgREST `notifications` (SELECT/UPDATE con RLS), Edge Function `ai-resumen`.
- **Governance**: MEDIO (lectura y presentación; la única escritura es `notifications.read`/`read_at`, ya permitida por RLS).
