> **Modo TDD estricto activo.** Cada grupo sigue el ciclo RED → GREEN → TRIANGULATE → REFACTOR.
> Antes de tocar un archivo existente: correr su suite y capturar la línea base ("N tests passing").
> Si algo ya venía roto, se reporta como fallo preexistente y NO se arregla acá.
>
> **Runner**: `pnpm -C frontend vitest run <archivo>` para un archivo puntual (ojo: `pnpm test -- --run <file>` **no filtra** — gotcha conocido del proyecto). Suite completa: `pnpm -C frontend test`.
> **Sin migraciones en este change**: no hay `db push`, no hay gates SQL.
> **Sin superficie frontend nueva**: no se crean pantallas ni rutas; la única verificación visual es el caso degradado (grupo 7).

## 1. Línea base y capa canónica pura del frontend

- [x] 1.1 **[SAFETY NET]** Correr `pnpm -C frontend test` completa y anotar la línea base exacta en el resumen final (esperado ≈751 passing). Anotar cualquier fallo preexistente por nombre de archivo — no se arregla en este change
- [x] 1.2 **[RED]** Crear `frontend/__tests__/reporting/revenue-canon.test.ts` con los tests de `lineRevenue`/`sumLineRevenue` fallando por módulo inexistente. Caso testigo obligatorio: fila con `amount = 1000`, `quantity = 3`, `total = 3000` → aporta **3000** (es la venta multi-unidad que hoy subcuenta en los 4 consumidores rotos)
- [x] 1.3 **[GREEN]** Crear `frontend/lib/reporting/revenue-canon.ts` con `lineRevenue(row)` = `COALESCE(total, amount)` y `sumLineRevenue(rows)`. Tipos explícitos (`SaleRevenueRow` con `amount`/`total` en `number | string | null`) — **nada de `any`**, los numerics de Postgres llegan como string por supabase-js. Cabecera del archivo con el puntero al módulo gemelo de Deno y al test de paridad (D3)
- [x] 1.4 **[TRIANGULATE]** Casos que rompen un "Fake It": fila legacy `total = NULL` → usa `amount`; `total = 0` legítimo → aporta 0 y **no** cae al fallback (bug clásico de `||` vs `??`); numerics como string (`"1500.50"`) → 1500.5 sin pérdida de decimales; lista vacía → 0; `amount` y `total` ambos `NULL` → 0
- [x] 1.5 **[RED→GREEN]** `netMarginPct(netProfit, revenue)`: devuelve el porcentaje redondeado, y **`null`** cuando `revenue` es 0, negativo o nulo (no 0 — "sin base de cálculo" no es "margen cero"). Tests para ganancia negativa (margen negativo, se informa) y para revenue 0
- [x] 1.6 **[RED→GREEN]** `previousWindow(from, to)` en el mismo módulo: intervalo inmediatamente anterior de igual duración (D2). Tests: ventana de mes completo; ventana de 30 días; ventana de 1 día; verificación de que el rango devuelto **nunca queda invertido** (`prevFrom <= prevTo`) y de que no se solapa con la ventana original
- [x] 1.7 **[REFACTOR]** Docblock del módulo explicando por qué la fórmula es `COALESCE(total, amount)` (en filas modernas `amount` es precio unitario) con el puntero a `openspec/specs/reporting-invariants/spec.md`. Suite del archivo en verde

## 2. Acceso al read-model canónico desde el frontend (dedupe del hook)

- [x] 2.1 **[SAFETY NET]** Correr `pnpm -C frontend vitest run __tests__/hooks/use-dashboard-kpi-summary.test.ts` y anotar la línea base — es el test que protege el refactor de este grupo
- [x] 2.2 **[RED]** Crear `frontend/__tests__/reporting/kpi-summary.test.ts`: `mapKpiSummaryRow` mapea las 16 columnas snake_case → camelCase, los numerics-como-string se convierten a number, los `null` se preservan como `null` (no 0) y las columnas RN-D3 **ausentes** (`invoiced_revenue?`) no rompen el mapeo. Falla por módulo inexistente
- [x] 2.3 **[GREEN]** Crear `frontend/lib/reporting/kpi-summary.ts` moviendo desde `hooks/data/use-dashboard-kpi-summary.ts` —sin cambiar comportamiento— el tipo `RpcRow`, el helper `num()`, el tipo público `DashboardKpiSummary` y el mapeo. Agregar `fetchKpiSummary(supabase, { from, to, prevFrom, prevTo, branchId })` que arma los params, llama `supabase.rpc("rpc_dashboard_kpi_summary", …)` y devuelve la fila mapeada o `null`
- [x] 2.4 **[GREEN]** Reescribir `hooks/data/use-dashboard-kpi-summary.ts` para que sea solo `useQuery` + `fetchKpiSummary`, re-exportando `DashboardKpiSummary` desde su nueva casa para no romper importadores. **El test de 2.1 debe seguir verde sin tocarlo** — incluido su assert de que `rpc()` recibe exactamente los params esperados (`p_branch_id` presente solo si hay sucursal)
- [x] 2.5 **[TRIANGULATE]** Tests de `fetchKpiSummary` con doble del cliente: respuesta con fila → objeto mapeado; respuesta vacía (`data: []`) → `null`; `error` presente → **propaga el error** (la decisión de degradar es del consumidor, no de la capa de acceso — D4); `branchId = null` → el param `p_branch_id` no se envía
- [x] 2.6 **[REFACTOR]** Verificar que ningún otro archivo del frontend haya quedado con una copia del mapeo (`grep` por `net_profit`/`invoiced_revenue` en `frontend/`). Suite completa de vitest en verde contra la línea base de 1.1

## 3. Módulo compartido del runtime Deno + test de paridad

- [x] 3.1 **[RED]** Crear `frontend/__tests__/reporting/edge-reporting-canon.test.ts` importando `"../../supabase/functions/_shared/reporting-canon"` **por ruta relativa** (patrón ya probado en `__tests__/ai-quota.test.ts` y otros 3 archivos). Falla por módulo inexistente
- [x] 3.2 **[GREEN]** Crear `supabase/functions/_shared/reporting-canon.ts` con: (a) las funciones puras `lineRevenue`/`sumLineRevenue`/`netMarginPct`/`previousWindow`, gemelas de las del frontend; (b) `fetchKpiSummary(client, window)` con el **cliente inyectado** y **cero referencias a `Deno.*` a nivel de módulo** (condición para que vitest pueda importarlo). Cabecera con el puntero al gemelo del frontend y al test de paridad
- [x] 3.3 **[TRIANGULATE]** Repetir contra este módulo la batería de 1.4/1.5/1.6 (legacy sin total, `total = 0`, numerics string, revenue 0, ventana no invertida) + los casos de `fetchKpiSummary` de 2.5 con un doble del cliente
- [x] 3.4 **[RED→GREEN]** Crear `frontend/__tests__/reporting/reporting-canon-parity.test.ts`: una **única tabla de casos** exportada, ejecutada contra las dos implementaciones, con assert de igualdad resultado a resultado. Demostrar que el test **no es vacuo**: alterar temporalmente una de las dos copias (p. ej. que `lineRevenue` devuelva `amount`) y confirmar que el test se pone rojo; revertir
- [x] 3.5 **[REFACTOR]** Confirmar que el módulo `_shared` no importa nada del frontend ni del registro `jsr:`/`npm:` (debe ser TS puro sin dependencias) — es lo que lo hace deployable a Deno y testeable en vitest a la vez

## 4. Copiloto — `buildBusinessSnapshot`

- [x] 4.1 **[SAFETY NET]** El archivo `frontend/lib/ai/buildBusinessSnapshot.ts` **no tiene ningún test hoy**: dejarlo anotado explícitamente como línea base = 0 y crear la suite antes de tocar una línea
- [x] 4.2 **[RED]** Crear `frontend/__tests__/ai/buildBusinessSnapshot.test.ts` con un doble de `SupabaseClient` (encadenable `.from().select().gte()` + `.rpc()`). Tests que fallan con el código actual: venta de 3 unidades a $1.000 → `ventas.total = 3000` (hoy da 1000); período con compras y NC → `gastos.margen_neto_pct` canónico (hoy inflado); `ganancia_neta` presente en el resultado (hoy no existe)
- [x] 4.3 **[GREEN]** En `buildBusinessSnapshot`: llamar `fetchKpiSummary` con la ventana de 30 días y su previa; `ventas.total` ← `invoicedRevenue`; `vs_periodo_anterior` ← comparación contra `prevInvoicedRevenue`; `gastos.margen_neto_pct` ← `netMarginPct(netProfit, invoicedRevenue)`; agregar `ganancia_neta` ← `netProfit`. **Eliminar el fetch de `prevSales`** (queda sin consumidor) y agregar `total` al `select` de las ventas del período
- [x] 4.4 **[GREEN]** Cambiar el tipo `BusinessSnapshot`: `gastos.margen_neto_pct: number | null` y `gastos.ganancia_neta: number | null`. Ajustar `snapshotToText` y `buildAdaptiveContext` para **omitir** esos fragmentos cuando son `null` (D4) — y agregar la ganancia en pesos a la línea de GASTOS cuando está disponible (D5)
- [x] 4.5 **[GREEN]** Reemplazar los tres `reduce` sobre `s.amount` que quedan (revenue por producto :175, revenue por cliente :268, y el total :129 si sobreviviera) por `lineRevenue`/`sumLineRevenue` del módulo canónico
- [x] 4.6 **[TRIANGULATE]** Camino degradado: doble donde `rpc()` devuelve `error` → `ventas.total` sale calculado con `sumLineRevenue` sobre las filas locales, `margen_neto_pct` y `ganancia_neta` son `null`, `vs_periodo_anterior` no afirma una comparación falsa, la función **no lanza**, y `snapshotToText`/`buildAdaptiveContext` no emiten líneas de margen ni de ganancia
- [x] 4.7 **[TRIANGULATE]** Clamp del top cliente (D6): escenario con NC grande donde el revenue bruto del mayor cliente supera el ingreso neto → la participación informada es **100%**, nunca más
- [x] 4.8 **[TRIANGULATE]** Regresión de lo que NO cambia: `productos.sin_rotacion`, `productos.stock_critico` y `productos.margen_bajo` conservan exactamente su comportamiento actual (stock crítico es C-KPI-2, margen de catálogo es excepción deliberada). Tests que fallarían si el refactor los tocara de contrabando
- [x] 4.9 **[TRIANGULATE]** Casos borde: cuenta sin ventas (`invoicedRevenue = 0` → margen `null`, sin división por cero); cuenta sin gastos ni compras; `netProfit` negativo → margen negativo se informa
- [x] 4.10 **[REFACTOR]** Verificar que no quedó ni un `Number(r.amount)` suelto en el archivo (`grep`), que no se introdujo ningún `any` y que `app/api/ai/copilot/route.ts` no necesitó cambios de contrato

## 5. `ai-insights`

- [x] 5.1 **[RED]** Extender `frontend/__tests__/reporting/edge-reporting-canon.test.ts` (o crear el archivo hermano) con la aritmética que `ai-insights` delega al módulo compartido: agregación por producto con `sumLineRevenue` sobre filas de `v_sales_flat`, incluido el caso multi-unidad
- [x] 5.2 **[GREEN]** En `supabase/functions/ai-insights/index.ts`: agregar `fetchKpiSummary` con la ventana de 30 d + previa; `totalRevenue` ← `invoicedRevenue`, `netProfit` ← `netProfit`, `margenNeto` ← `netMarginPct`, `vsPrev` ← contra `prevInvoicedRevenue`. **Eliminar el fetch `prevSalesRes`**; agregar `total` al `select` de `v_sales_flat` (la vista ya lo expone desde `20260616000004`)
- [x] 5.3 **[GREEN]** Reemplazar el `reduce` de revenue por producto (`:139`) por `lineRevenue` del módulo compartido, con interfaz local explícita para la fila — sin `any` en las expresiones tocadas (D8)
- [x] 5.4 **[GREEN]** `contextBlock`: incluir la ganancia neta en pesos y **omitir** la línea de ganancia/margen cuando el canon no respondió, usando el mismo `.filter(Boolean)` que ya filtra las secciones vacías
- [x] 5.5 **[TRIANGULATE]** Verificar por lectura que en `index.ts` **no quedó ninguna aritmética financiera** — solo cableado. Cualquier fórmula que sobreviva ahí es un punto ciego de CI (las Edge Functions no tienen runner)

## 6. `ai-simulador`, `ai-prediccion` y `ai-resumen`

- [ ] 6.1 **[GREEN]** `ai-simulador/index.ts`: ventana = mes en curso, previa vía `previousWindow`. `totalSales` ← `invoicedRevenue`; el prompt pasa a informar además la ganancia neta canónica en lugar de dejar que el modelo reste ventas − gastos por su cuenta. Eliminar el `select('amount')` de `sales` (queda sin uso) y conservar el de `expenses` (el prompt sigue citando gastos)
- [ ] 6.2 **[GREEN]** `ai-prediccion/index.ts`: `totalSales` ← `invoicedRevenue` de la ventana de 30 d; `avgDailySales` = `invoicedRevenue / 30`. Conservar el fetch de filas (el prompt usa la cantidad de registros) agregándole `total`, que es además la fuente del camino degradado
- [ ] 6.3 **[GREEN]** `ai-resumen/index.ts`: **no tocar los ingresos** (`total ?? amount` en `:113` ya es correcto — es el único consumidor que estaba bien). El fix es `balance` (`:115`): pasa a `netProfit` del canon, con la ventana del caller (`dateFrom`/`dateTo` o la derivada de `period`) y su previa vía `previousWindow`. El fetch de ventas se conserva para el camino degradado
- [ ] 6.4 **[TRIANGULATE]** Para los tres: camino degradado explícito (RPC en error → ingresos por `sumLineRevenue` sobre filas locales, sin ganancia ni balance en el prompt, log con el prefijo de la función, sin 500 al usuario)
- [ ] 6.5 **[TRIANGULATE]** `ai-resumen` con rango arbitrario del caller: confirmar por lectura que un rango inválido produce `P400` del RPC y cae en el camino degradado (D4), sin filtrar datos de otra cuenta — el RPC resuelve la cuenta por `auth.uid()`, no por parámetro
- [ ] 6.6 **[REFACTOR]** Revisión final de los 4 `index.ts`: sin aritmética financiera propia, sin `any` en las expresiones tocadas, prefijos de log consistentes

## 7. Verificación integral, delta medido y cierre

- [ ] 7.1 Correr `pnpm -C frontend test` completa y comparar contra la línea base de 1.1: **cero regresiones**, y anotar el total nuevo (751 + los tests agregados)
- [ ] 7.2 **[VERIFICACIÓN MANUAL — obligatoria]** Contra una cuenta real con ventas multi-unidad: abrir el Tablero, anotar `invoiced_revenue` y Ganancia Neta del período, preguntarle al Copiloto por los ingresos y el margen del mismo período y **confirmar que los números coinciden**. Es el único gate que cubre el cableado (las fórmulas ya las cubre vitest)
- [ ] 7.3 **[VERIFICACIÓN MANUAL]** Medir y dejar escrito en el PR el **delta antes/después** de los ingresos y del margen que reporta la IA en esa cuenta (precedente: el +17,53% documentado en `v3-reporting-invariants`). Un delta desproporcionado es señal de otro defecto: se levanta **antes** de mergear, no después
- [ ] 7.4 **[VERIFICACIÓN VISUAL — caso degradado]** Forzar el fallo del RPC (mock o revocación temporal en un entorno de prueba) y confirmar que la respuesta del Copiloto renderiza bien sin las líneas de margen/ganancia: sin cadenas rotas tipo `Margen: null%`, sin bloques vacíos. Revisar en **desktop y mobile** y en **tema claro y oscuro** (regla PO 2026-08-02), aunque no haya componentes nuevos
- [ ] 7.5 Deploy de las 4 Edge Functions (`supabase functions deploy ai-insights ai-simulador ai-prediccion ai-resumen`). Recordar que el merge a main ya deployó el frontend por Actions/Vercel, y que la ventana entre ambos deploys es benigna (D9 / Migration Plan)
- [ ] 7.6 Verificación post-deploy en producción: generar un insight y un resumen reales y confirmar que sus cifras coinciden con el Tablero. Revisar los logs de las funciones buscando el mensaje del camino degradado — si aparece de forma sistemática, el canon no está resolviendo y hay que investigarlo antes de dar el change por cerrado
- [ ] 7.7 Actualizar `docs/plan-remediacion-kpis-2026-08-11.md` marcando C-KPI-1 como completado, con el delta medido en 7.3 y el puntero al PR
