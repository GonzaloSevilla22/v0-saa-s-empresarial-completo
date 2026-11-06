## Context

El Tablero (`frontend/app/(dashboard)/dashboard/page.tsx`) arma hoy, de arriba abajo: `KpiSummaryBlock` (5 tarjetas mensuales con badge contra el mes anterior), una fila de 5 `KpiCard` (Ventas / Gastos / Ganancia neta del mes, Productos en alerta, Por cobrar), y abajo `SalesChart` + `AiSummaryCard` + `AiAlerts` + `RecentActivity`. La campana (`NotificationBell`) vive en el encabezado global (`components/dashboard/breadcrumb-nav.tsx`), no sólo en el Tablero.

Lo medido el 2026-11-06 (código de `main` @ `1374ff66` y prod sólo `SELECT`):

**Gráfico.** `SalesChart` llama a `useSales()` sin parámetros, que pide `GET /sales?page=0&page_size=25` (`hooks/data/use-sales.ts`): el gráfico de 7 días **suma sólo las 25 filas de venta más recientes**. Para cualquier negocio con más de 25 líneas en la semana, los días viejos salen en cero o recortados. Además ignora el `BranchFilter`, no resta notas de crédito y tiene colores hex/hsl fijos de tema oscuro (grilla, ejes, tooltip). `/estadisticas` ya tiene la fuente canónica: `useSalesEvolution({start,end,bucket,branchId,canal})` → `GET /reports/statistics/evolution` → `rpc_sales_evolution`, que devuelve `points` (con huecos rellenados por `generate_series`), `current` y `previous` (totales del período anterior de igual longitud), resta NC por el helper único y recorta al historial del plan (`reporting_plan_window`, `window.clamped`). Y el gráfico compartido `components/charts/ReportTimeSeriesChart.tsx` ya soporta una serie secundaria punteada con tokens del design system.

**Tarjetas.** Cuerpos vivos leídos con `pg_get_functiondef` en prod:
- `rpc_dashboard_kpi_summary(p_from,p_to,p_prev_from,p_prev_to,p_branch_id)`: `net_profit = (ventas − NC) − (gastos + compras)`; `avg_ticket = ventas BRUTAS / operaciones` (sin restar NC); `cost_per_sale = costo de lo vendido / operaciones` (costo = `unit_cost_snapshot` de la línea, si no el costo actual del producto, si no 0; cantidad en unidad base); stock sin rotación = Σ `branch_stock.quantity × costo actual` de los productos con existencias > 0 sin ninguna venta en el mes (con sucursal elegida, una venta sin sucursal cuenta como rotación; excluye `untracked`/`variant_only`/borrados; los sin costo valen 0 y se cuentan aparte); `collected_revenue` («Cobrado») = devengado − cargos a cuenta corriente + cobros, `NULL` con sucursal elegida.
- `rpc_dashboard_channel_margin`: por canal, `(ventas brutas − costo de lo vendido) / ventas brutas`, sólo canales con ventas > 0, `sin_canal` como tramo propio, líder = mayor margen; **no resta NC**.
- `get_dashboard_financials(from,to,branch)`: `total_income = ventas − NC`, `total_expenses = gastos` (**sin compras**), `net_profit = ingreso − (gastos + compras)`. Por eso «Ventas del mes − Gastos del mes ≠ Ganancia neta del mes» cuando hay compras: es la confusión que el PO quiere poder explicarse.
- `get_dashboard_critical_stock(p_branch_id)`: `COUNT(DISTINCT product_id)` sobre `branch_stock` con `min_stock > 0 AND quantity <= min_stock`; excluye `untracked`/`variant_only`/borrados. Es una foto de **ahora**, no del mes.

**Campana.** `useNotifications` trae las últimas 20 filas (leídas o no) y el badge cuenta las no leídas **entre esas 20**. `markNotificationRead` hace el `UPDATE` pero **no toca la caché** de React Query y el canal Realtime sólo escucha `INSERT`: la notificación no cambia en pantalla hasta un resync. El panel es un `DropdownMenu` cuyo ítem sólo marca leído; no navega a ningún lado. En prod: `StockBelowMinimum` 273 filas (3 leídas), `CashSessionClosed` 2, `FiscalDocumentRejected` 1, `QuoteAccepted` 1; los otros 6 tipos del catálogo (`TYPE_LABELS`) no tienen filas todavía. Payloads reales: stock `{product_id, branch_id, current_qty, min_qty}`; caja `{session_id, branch_id, difference, …}`; fiscal `{fiscal_document_id, error, branch_id}`; presupuesto `{quote_id, total, branch_id, seller_id}`.

**Resumen IA.** La Edge Function `ai-resumen` responde 200 en ~8 s (logs del orquestador, 2026-11-06) y `analytics_events` registra 42 `insight_generated` de `ai-resumen` en noviembre, 199 en octubre, 300 en septiembre: **la función funciona y cobra cuota en cada montaje del Tablero**. Su camino de éxito devuelve `{ ok: true, data: insight }` donde `insight = to_jsonb(fila de public.insights)`, y la tabla `insights` tiene `id, user_id, type, priority, message, created_at, account_id` — **no tiene `content`** desde `20260629000001_unify_insights` (la tabla legacy tenía `content`; la unificación la renombró a `message`). La tarjeta lee `data.data.content` → `undefined` → muestra «No se pudo generar el resumen en este momento.». El único camino que todavía mostraba texto es el degradado (falla de la RPC → `data` es el string crudo), p. ej. plan free con `insights_used >= 5`. La tarjeta además no tiene tope de espera: si la llamada no se resuelve, se queda en «Cargando resumen inteligente...» indefinidamente.

**Causa raíz confirmada por el orquestador (2026-11-06), con evidencia en el navegador real del PO y en prod.** La promesa de `invoke` sí se asienta: la función responde 200 con `{ ok: true, data: <fila de insights> }`, la tarjeta lee `data?.data?.content` → `undefined` → cae al fallback «No se pudo generar el resumen en este momento.», que en Chrome aparece tras ~15 s. El PO lo percibe como *«queda en cargando para siempre, nunca muestra nada»* porque el estado inicial reutiliza como texto «Cargando resumen inteligente...», no hay ninguna señal visual de progreso más allá del ícono de Regenerar girando, y lo que llega al final nunca es un resumen. **El fix del campo (`message ?? content` + test de regresión) lo hace el orquestador en un PR ad-hoc aparte; este change NO lo duplica**: el ítem 4 queda acotado a la experiencia de la tarjeta (estado de carga visible, Regenerar operable, error legible, sin reutilizar «Cargando…» como texto inicial) y a no gastar una consulta de IA en cada visita.

## Goals / Non-Goals

**Goals:**
- Gráfico con rango elegible (7 / 30 / 90 / personalizado) y comparación con el período anterior, desde la fuente canónica, con sucursal y en ambos temas.
- Las 9 tarjetas pedidas abren un diálogo con el origen exacto del número, contextualizado al período y sucursal vigentes.
- Avisos de la campana descartables, navegables al destino y que se cierran solos al navegar.
- Resumen IA del día que se ve, con estados de carga y error honestos, sin gastar cuota en cada visita.

**Non-Goals:**
- Contenido/calidad del prompt de IA, contexto que recibe el modelo y alertas IA (`AiAlerts`): change futuro `ia-insights-tablero` (explore `openspec/explore/2026-11-06-mejora-ia.md`).
- Cambiar cualquier RPC, endpoint o Edge Function. Si una definición resulta mal (p. ej. Ticket Promedio no resta NC), el diálogo **la dice tal cual es**; corregirla es otro change.
- El auto-generado de «Consejos IA» del montaje del Tablero (`aiInsightService.generateInsights`) — otra superficie.
- Historial de notificaciones leídas (pantalla propia), estado «descartada» distinto de «leída», notificaciones por email.
- Migrar otras pantallas al diálogo explicativo (sólo el Tablero).

## Decisions

### D1 — El gráfico pasa a la fuente canónica de `/estadisticas`, no se arregla la agregación en el cliente
`SalesChart` usa `useSalesEvolution` dos veces: la consulta del período elegido (`points` + `current` + `previous`) y una segunda con `start/end = previous.start/previous.end` de la primera para obtener los **puntos** del período anterior (la RPC sólo devuelve sus totales). La segunda queda `enabled` sólo cuando la primera respondió. Alineación por índice (mismo largo y mismo bucket; si la cantidad de puntos difiere por el corte de semana/mes, se rellena con `null` y la línea punteada se corta).
- *Alternativa descartada*: subir el `page_size` de `useSales` o sumar en el cliente. Sigue sin NC, sin sucursal, sin clamp de plan, y repite una agregación que ya es canónica (regla «Reutilización antes que repetición»).
- *Alternativa descartada*: extender `rpc_sales_evolution` para devolver puntos del anterior — sería backend/migración para algo que dos lecturas resuelven.

### D2 — Rango y granularidad
Presets `7d` (default, conserva el comportamiento de hoy), `30d`, `90d` y `Personalizado` (dos `DateButton` de `components/shared/DateRangeButton.tsx`, con `minDate` = hoy − `historyDays` del plan y `maxDate` = hoy). Rango «últimos N días» = `[hoy − (N−1), hoy]`, día argentino (`argentinaDaysAgo`/`argentinaToday` de `lib/date-range.ts`). Bucket automático y puro (`chartBucketFor(start,end)` en `lib/sales-statistics.ts`): ≤ 31 días → día; ≤ 180 → semana; más → mes. El control es un `ToggleGroup` (mismo componente que `/estadisticas`). Estado local del componente, no en la URL (OQ-3). El selector de período mensual del Tablero (`?period=`) **no** afecta al gráfico: el gráfico tiene su propio rango, y su título lo dice («Ventas · últimos 30 días»).

### D3 — Comparación honesta con el historial del plan
Se dibuja la serie «Período anterior» y la variación `percentChange(current.netRevenue, previous.netRevenue)` **sólo si** la segunda consulta respondió con `window.clamped = false`. Si el período anterior cae (total o parcialmente) fuera del historial del plan, se muestra «El período anterior queda fuera del historial de tu plan» con enlace a `/planes` y no se compara (no se mezcla un total sin recortar con una serie recortada). Si la primera consulta viene `clamped`, se reutiliza el mismo aviso que `/estadisticas`. Métrica graficada: `netRevenue` (facturación neta de NC), igual que `/estadisticas`; el tooltip y el `aria-label` lo nombran «Ventas netas».
- *Hallazgo lateral (no se toca)*: `/estadisticas` muestra los totales del período anterior sin recorte aunque caigan fuera del historial del plan (`v_prev_*` no pasa por `reporting_plan_window`). Candidato en `CHANGES.md`.

### D4 — Tarjeta explicable: un catálogo puro + un diálogo + una prop opcional en las dos tarjetas base
- `lib/dashboard-kpi-explanations.ts` exporta `KPI_EXPLANATIONS: Record<DashboardKpiId, KpiExplanation>` con `{ title, what, formula, period: "month" | "month-vs-prev" | "now", branch: "applies" | "applies-legacy-rotation" | "not-applicable", sources, excludes: string[], notes?: string[], link: { href, label }, technicalSource }` (`technicalSource` = nombre de RPC; no se muestra al usuario, lo usan tests y quien mantiene el texto). Es la **única** fuente de los textos.
- `components/dashboard/KpiExplainDialog.tsx`: `Dialog` de shadcn (`DialogTitle` = título de la tarjeta, `DialogDescription` = `what`), secciones «Cómo se calcula», «Período y filtros» (dinámico: «Mes: noviembre de 2026 (hora de Argentina)», «Sucursal: Todas / <nombre>», «Comparado con: octubre de 2026»), «De dónde salen los datos», «No incluye», y un botón-enlace «Ver el detalle en …». Cruz arriba a la derecha (la de `DialogContent`), `Esc` y clic afuera cierran, Radix atrapa y devuelve el foco a la tarjeta.
- `KpiSummaryCard` y `KpiCard` ganan la prop opcional `explanation?: { id: DashboardKpiId; context: KpiExplainContext }`. Con ella, el contenedor es un `<button type="button">` con `aria-haspopup="dialog"`, `aria-label="<título>: <valor>. Ver de dónde sale"`, foco visible y un ícono `Info` chico (pista visual de que se puede abrir). Sin ella, render idéntico al actual (las otras pantallas que usan `KpiCard` —`/estadisticas`, `/admin/analytics`— no cambian). `href` y `explanation` son mutuamente excluyentes (tipo discriminado); «Por cobrar» sigue con `href="/cobranzas"`.
- *Alternativa descartada*: `Sheet` lateral o `Popover`. El pedido es «un menú superpuesto que se cierra con una cruz»: el `Dialog` es eso, centrado en desktop y a ancho completo con margen en móvil, y ya cumple foco/`Esc`. Un `Popover` no atrapa foco y en móvil tapa la tarjeta.

### D5 — Los textos de las 9 tarjetas (entregable)
Redactados contra los cuerpos vivos de §Context. «Mes» = mes del selector de período del Tablero (mes en curso por defecto), calendario de Argentina. Fuente al usuario en lenguaje llano; entre corchetes, el `technicalSource` (no visible).

**1. Ganancia Neta** (bloque superior) — [`rpc_dashboard_kpi_summary.net_profit`]
- *Qué es*: lo que le quedó al negocio en el mes después de restar lo que gastó y lo que compró.
- *Cuenta*: Ventas del mes − Notas de crédito del mes − Gastos del mes − Compras del mes.
- *Período y filtros*: mes seleccionado; sucursal elegida (si hay). La etiqueta de color compara contra el mes anterior.
- *De dónde sale*: tus ventas, notas de crédito, gastos y compras registrados con fecha en el mes.
- *No incluye*: lo cobrado o no cobrado (una venta a cuenta corriente cuenta el día que se vende); presupuestos ni remitos; el costo de la mercadería vendida (lo que se resta es lo que **compraste** en el mes, no el costo de lo que vendiste).
- *Nota*: si aparece «Cobrado: $X», es lo que entró de verdad: ventas − ventas a cuenta corriente + cobros recibidos. No se calcula con una sucursal elegida, porque los cobros no tienen sucursal.
- *Ver detalle*: `/reportes/comparativo` («Reporte comparativo»).

**2. Margen por Canal** — [`rpc_dashboard_channel_margin`]
- *Qué es*: de cada $100 vendidos por cada canal (local, Instagram, Mercado Libre…), cuánto queda después de pagar la mercadería.
- *Cuenta*: por canal, (ventas − costo de lo vendido) ÷ ventas × 100. El costo de cada producto es el que tenía **en el momento de la venta**; si esa venta no lo guardó, se usa el costo actual del producto.
- *Período y filtros*: mes seleccionado; sucursal elegida. «X lidera» = canal de mayor margen; el color compara el margen total contra el mes anterior.
- *De dónde sale*: tus ventas del mes con su canal y las líneas de producto de cada venta.
- *No incluye*: notas de crédito (el margen es sobre lo vendido bruto); gastos ni compras; canales sin ventas en el mes. Las ventas sin canal aparecen como «Sin canal». Un producto sin costo cargado cuenta costo $0 y **agranda** el margen.
- *Ver detalle*: `/estadisticas` («Estadísticas: por dónde se vende»).

**3. Stock sin Rotación** — [`rpc_dashboard_kpi_summary.stagnant_stock_*`]
- *Qué es*: cuánta plata tenés quieta en mercadería que no se vendió ni una vez en el mes.
- *Cuenta*: suma de existencias × costo actual de cada producto con stock que no tuvo ninguna venta en el mes. La etiqueta dice cuántos productos son; «N sin costo» son los que no tienen costo cargado y suman $0.
- *Período y filtros*: mes seleccionado (para saber si se vendió) y existencias **de hoy**; con una sucursal elegida, se miran el stock y las ventas de esa sucursal (una venta sin sucursal cuenta como que el producto rotó). El color compara contra el mes anterior (subir es malo).
- *De dónde sale*: existencias por sucursal, costo actual de cada producto y tus ventas del mes.
- *No incluye*: productos sin control de stock, productos «padre» de variantes (cuentan sus variantes) ni productos borrados.
- *Ver detalle*: `/stock`.

**4. Costo por Venta** — [`rpc_dashboard_kpi_summary.cost_per_sale`]
- *Qué es*: en promedio, cuánto te costó la mercadería de cada venta.
- *Cuenta*: costo de todo lo vendido en el mes ÷ cantidad de ventas del mes. Una venta con varios productos cuenta como una.
- *Período y filtros*: mes seleccionado; sucursal elegida. El color compara contra el mes anterior (subir es malo).
- *De dónde sale*: las líneas de producto de tus ventas, con el costo del momento de la venta (o el actual si no se guardó).
- *No incluye*: gastos ni compras; servicios y productos sin costo cargado (cuentan $0).
- *Ver detalle*: `/rentabilidad` («Rentabilidad por producto»).

**5. Ticket Promedio** — [`rpc_dashboard_kpi_summary.avg_ticket`]
- *Qué es*: cuánto gasta en promedio un cliente en cada compra.
- *Cuenta*: total vendido en el mes ÷ cantidad de ventas del mes (una venta con varios productos cuenta como una).
- *Período y filtros*: mes seleccionado; sucursal elegida. El color compara contra el mes anterior.
- *De dónde sale*: tus ventas del mes.
- *No incluye*: notas de crédito (se calcula sobre lo vendido antes de devoluciones); presupuestos ni remitos.
- *Ver detalle*: `/estadisticas`.

**6. Ventas del mes** — [`get_dashboard_financials.total_income`]
- *Qué es*: todo lo que vendiste en el mes, descontadas las devoluciones.
- *Cuenta*: total de las ventas con fecha en el mes − notas de crédito emitidas en el mes.
- *Período y filtros*: mes seleccionado; sucursal elegida.
- *De dónde sale*: tus ventas (mostrador, formulario y órdenes) y notas de crédito.
- *No incluye*: presupuestos ni remitos sin facturar; cobros de cuenta corriente (la venta a crédito cuenta el día que se vende, no cuando se cobra).
- *Ver detalle*: `/ventas`.

**7. Gastos del mes** — [`get_dashboard_financials.total_expenses`]
- *Qué es*: lo que pagaste en gastos del negocio en el mes (alquiler, servicios, sueldos…).
- *Cuenta*: suma de los gastos cargados con fecha en el mes.
- *Período y filtros*: mes seleccionado; con una sucursal elegida, sólo los gastos imputados a esa sucursal (los gastos cargados sin sucursal no entran).
- *De dónde sale*: tus gastos.
- *No incluye*: compras de mercadería — se cargan en Compras y se restan aparte en la Ganancia neta.
- *Ver detalle*: `/gastos`.

**8. Ganancia neta del mes** — [`get_dashboard_financials.net_profit`]
- *Qué es*: lo que te quedó en el mes. Es el mismo número que «Ganancia Neta» de arriba.
- *Cuenta*: Ventas del mes − Gastos del mes − **Compras del mes**. Por eso no da igual a Ventas − Gastos si compraste mercadería.
- *Período y filtros*: mes seleccionado; sucursal elegida.
- *De dónde sale*: tus ventas, notas de crédito, gastos y compras.
- *No incluye*: cobranzas pendientes; el costo de lo vendido (se resta lo comprado en el mes).
- *Ver detalle*: `/reportes/comparativo`.

**9. Productos en alerta** — [`get_dashboard_critical_stock`]
- *Qué es*: cuántos productos están en su stock mínimo o por debajo.
- *Cuenta*: productos con un mínimo configurado (mayor que 0) cuyas existencias están en ese mínimo o menos, en alguna sucursal (o en la elegida). Un producto en alerta en dos sucursales cuenta una vez.
- *Período y filtros*: **ahora** (no depende del mes elegido); sucursal elegida.
- *De dónde sale*: existencias y mínimos por sucursal.
- *No incluye*: productos con mínimo 0 (sin umbral), sin control de stock, «padre» de variantes ni borrados.
- *Ver detalle*: `/stock`.

Gate de fidelidad: un test por tarjeta fija que `technicalSource` existe, que el enlace es una ruta real del árbol `app/(dashboard)`, y que las frases que dependen de la definición («no resta notas de crédito» en Ticket/Margen, «compras» en Ganancia, «ahora» en Productos en alerta, «sin compras» en Gastos) siguen presentes; un comentario en cada RPC no se toca (no hay migración), así que el catálogo lleva arriba el md5 del cuerpo vivo leído el 2026-11-06 para que un cambio futuro de RPC sepa que hay un texto que revisar. md5 de `pg_get_functiondef` en prod (2026-11-06): `rpc_dashboard_kpi_summary` `3947671c25c1706fb255cbfc66454eef`; `rpc_dashboard_channel_margin` `7ddc661b4e1fa3fb7fb31ade4eceb308`; `get_dashboard_financials` `b32ce1c01a224e4eb86cb21c29f42f78`; `get_dashboard_critical_stock` `055c8d84499cfc75a53520e2ada3f6c3`; y, para D7, `rpc_atomic_log_ai_insight` `dcdefe0fc26728b39f9eb28bbd1f81fa`.

### D6 — Campana: Popover con filas accionables, sólo no leídas, actualización optimista
- `lib/notification-routes.ts` (puro): `notificationHref(n): string | null`. Mapeo:

  | `type` | Destino |
  |---|---|
  | `StockBelowMinimum` | `/stock?product=<payload.product_id>` (preselección ya existente en `/stock`); sin `product_id` → `/stock` |
  | `CashSessionClosed` | `/caja?branch=<payload.branch_id>` (o `/caja`) |
  | `FiscalDocumentRejected` | `/ventas` |
  | `QuoteAccepted` | `/presupuestos/<payload.quote_id>` (o `/presupuestos`) |
  | `TransferDispatched` | `/stock` |
  | `PlanLimitExceeded` | `/planes` |
  | `SubscriptionPaymentFailed`, `SubscriptionExpiringSoon` | `/facturacion` |
  | `ReceivablesOverdueDigest` | `/cobranzas` |
  | `PayablesOverdueDigest` | `/cobranzas?tab=payables` |
  | tipo desconocido | `null` (la fila sólo se puede cerrar) |

  Los ids del payload se validan como UUID antes de interpolarlos (un payload raro cae al destino sin parámetro, nunca arma una URL con texto arbitrario).
- `NotificationBellView` cambia `DropdownMenu` por `Popover` (portal ya corregido en G1) con una lista: cada fila es un `<button>` (cuerpo: rótulo + fecha + «Ir a Stock»/«Ir a Caja»… desde un mapa de rótulos de destino) y un botón de cerrar `X` con `aria-label="Descartar: <rótulo>"`. Clic en el cuerpo → `markRead` + `router.push(href)` + cierra el popover. Clic en `X` → `markRead` (sin navegar). Encabezado del panel: «Notificaciones (N sin leer)» + «Marcar todas como leídas».
- `useNotifications`: la query pasa a `.eq("read", false)` (últimas 20 no leídas) con `count: "exact"` para el badge (deja de ser «no leídas entre las últimas 20»). Exporta `markRead(id)` y `markAllRead()` como mutaciones con **actualización optimista** (`setQueryData` quita la fila y baja el contador; `onError` restaura y avisa con `sonner`). `markAllRead` = `UPDATE notifications SET read=true, read_at=now() WHERE account_id = <cuenta activa> AND read = false` — la RLS de audiencia ya acota a lo que el usuario puede ver (spec `in-app-notifications`).
- **Sin migración**: «descartar» = «leer». OQ-1.
- *Alternativa descartada*: mantener `DropdownMenu` y meter un botón dentro del ítem: Radix `DropdownMenuItem` es un `menuitem`; un botón anidado rompe el rol y el `onSelect` cierra el menú en cada clic.

### D7 — Resumen IA: estados explícitos y consulta cacheada por día (el fix del campo va aparte)
- **Precondición**: el PR ad-hoc del orquestador (lectura de `message ?? content` + test de regresión) está mergeado en `main` antes del apply. El apply **reutiliza** esa lectura (si quedó inline en la tarjeta, se mueve sin cambios a `lib/ai-summary.ts` como `parseAiSummaryResponse` para que el hook la consuma; si ya vive en `lib/`, se importa) y conserva su test tal cual. No se reescribe ni se duplica.
- **Estado inicial**: el texto de la tarjeta deja de nacer como «Cargando resumen inteligente...». El estado de carga es un estado propio (no un string en el lugar del resumen): spinner + «Generando el resumen… suele tardar unos segundos» con `role="status"`/`aria-live="polite"`, y un esqueleto de dos líneas debajo.
- `lib/ai-summary.ts`: `aiSummaryErrorMessage(err)` mapea 429 («Llegaste al límite mensual de consultas de IA de tu plan. Se reinicia el 1.º de cada mes.»), 401 («Tu sesión venció. Volvé a ingresar.»), tope de espera («La IA tardó demasiado. Probá con Regenerar.»), respuesta sin texto («La IA no devolvió un resumen. Probá con Regenerar.») y el resto («No pudimos generar el resumen. Probá con Regenerar en unos minutos.»). Lee el estado de `FunctionsHttpError.context.status`.
- `hooks/data/use-ai-daily-summary.ts`: `useQuery` con key `queryKeys.aiSummary.daily(accountId, argentinaToday())`, `staleTime: Infinity`, `refetchOnWindowFocus/refetchOnMount: false`, `retry: false`. La `queryFn` invoca `ai-resumen` con el mismo cuerpo de hoy (`period: "daily"`, `utcDayRange()`) y un tope de 30 s (la función corta a OpenAI a los 25 s): `Promise.race` contra un temporizador sobre **toda** la operación (un `AbortSignal` sólo cortaría la petición, no la espera del token), más `signal` para liberar la conexión si `functions.invoke` lo acepta en la versión instalada. Regenerar = `refetch()`. Volver al Tablero en la misma sesión **no** vuelve a llamar a OpenAI (hoy cada montaje gasta una consulta de la cuota mensual), y como la consulta vive fuera del componente, un remontaje con la llamada en vuelo recibe su resultado en vez de disparar otra. El tope hoy no es la causa del síntoma (la promesa se asienta en ~15 s), pero sin él cualquier cuelgue futuro volvería a ser mudo.
- Tarjeta: cargando → spinner + «Generando el resumen… suele tardar unos segundos»; éxito → texto; error → mensaje legible en `text-destructive`/`text-muted-foreground` + Regenerar. Regenerar está deshabilitado **sólo** mientras hay una llamada en curso, y nunca más de 30 s. El pie «Ventas hoy» / «Stock bajo» no cambia.
- **Edge Function sin cambios**: el arreglo del campo en el cliente (PR ad-hoc) basta; normalizar el contrato de `ai-resumen` queda para `ia-insights-tablero`.

### D8 — Tanda única
Las cuatro piezas son frontend, independientes entre sí y chicas; ninguna toca dinero ni esquema. Una sola tanda, un PR.

## Risks / Trade-offs

- [Dos consultas por cambio de rango en el gráfico] → la segunda depende de la primera y React Query cachea por key; `placeholderData: keepPreviousData` evita el parpadeo. Costo aceptable frente a una RPC nueva.
- [Plan free (30 días de historial) con preset 90 o 30] → el gráfico se recorta en el servidor y el aviso lo explica; la comparación se oculta (D3). Es el mismo contrato que `/estadisticas`.
- [Textos que envejecen si cambia una RPC] → catálogo único + test de fidelidad + md5 del cuerpo vivo anotado (D5).
- [Sólo no leídas: se pierde la vista de las leídas en la campana] → aceptado (OQ-1); no había otra forma de «cerrar» sin migración, y con 270 avisos de stock sin leer la lista mezclada era ilegible.
- [«Marcar todas» con muchas filas] → un `UPDATE` filtrado por cuenta y `read=false`; cubierto por el índice existente de `notifications` (verificar en el apply con `EXPLAIN` local).
- [Caché de un día del resumen IA] → si el usuario vende mucho después, el resumen queda viejo hasta que toca Regenerar; el pie «Ventas hoy» sí se actualiza. Trade-off a favor de no quemar cuota.
- [Rótulo de la cruz de `ui/dialog.tsx` pasa de «Close» a «Cerrar»] → afecta a todos los diálogos (mejora de a11y en una app en castellano); el apply busca tests que consulten el nombre «Close».

## Migration Plan

Sin migración, sin backend, sin Edge Functions. Merge = deploy de Vercel. Rollback = revert del PR.

## Open Questions

Todas resueltas por su opción recomendada — **Sign-off del PO por mandato (2026-11-06)**.

- **OQ-1** — ¿«Cerrar» un aviso necesita un estado «descartada» distinto de «leída»? (a) Reutilizar `read`/`read_at` y mostrar sólo no leídas **[recomendada, elegida]**; (b) columna `dismissed_at` (migración) para conservar las leídas visibles. *Cambiaría el diseño*: con (b) hay migración, gate SQL y la campana muestra leídas atenuadas.
- **OQ-2** — Contenedor del panel explicativo: (a) `Dialog` **[elegida]**; (b) `Sheet` lateral; (c) `Drawer` (vaul) en móvil + `Dialog` en desktop.
- **OQ-3** — ¿El rango del gráfico va en la URL? (a) Estado local, default 7 días **[elegida]** (el Tablero ya usa `?period=` y `?branch=` para otra cosa; sumar más parámetros confunde «compartir este Tablero»); (b) `?rango=`.
- **OQ-4** — ¿Mostrar al usuario el nombre técnico de la fuente (RPC)? (a) No, lenguaje llano; el nombre queda en el catálogo para mantenimiento **[elegida]**; (b) sí, en letra chica.
- **OQ-5** — Resumen IA: (a) generar al montar **una vez por día y sesión** y cachear **[elegida]**; (b) no generar al montar y esperar a que el usuario toque «Generar»; (c) leer el último insight de hoy de `insights` (no se puede distinguir el de `ai-resumen`: la tabla no guarda la función de origen). *Cambiaría el diseño*: (b) cambia el estado inicial de la tarjeta.
- **OQ-6** — Serie de comparación: (a) período anterior inmediato de igual longitud **[elegida]** (lo que ya calcula la RPC); (b) mismo período del año anterior (exige otra consulta y más historial que el plan free no tiene).
- **OQ-7** — «Marcar todas como leídas» en la campana: (a) sí **[elegida]**; (b) no, sólo de a una. Con 270 avisos de stock sin leer en prod, (b) hace la campana inutilizable.
