# Plan de remediación — Consistencia de KPIs

> ✅ **PROGRAMA COMPLETO — 2026-08-12.** Los 6 changes (5 del plan + timezone) implementados, mergeados, verificados en prod y archivados: 17 PRs (#377–#387, #394–#399). Las 4 decisiones del PO (OQ-1 híbrida, OQ-2 backfill SÍ, OQ-4 MRR suscripción>plan efectivo, OQ-5 retención [30,60) censurada) firmadas el 12-08 e implementadas el mismo día. Pendiente solo: verificaciones manuales del PO (sección 5, punto 5).

> Origen: auditoría del 05-08-2026 (`docs/status KPI al 05-08-26.docx`).
> Verificación contra main actual: 2026-08-11. **Los 6 hallazgos siguen vigentes** — ningún commit posterior al 05-08 tocó la capa de reporting/IA/analytics.

---

## 1. Veredictos de verificación (código actual)

| # | Hallazgo | Veredicto | Evidencia clave (main hoy) |
|---|----------|-----------|----------------------------|
| F1 | IA suma `amount` (precio unitario) en vez de `COALESCE(total, amount)` | ✅ CONFIRMADO | `frontend/lib/ai/buildBusinessSnapshot.ts:84,129` (select `amount` de `sales` + reduce); `supabase/functions/ai-insights/index.ts:99,116,139` (v_sales_flat.amount); `ai-simulador/index.ts:92,96`; `ai-prediccion/index.ts:92`. **Excepción: `ai-resumen` ya suma bien** (`total ?? amount`, línea 113). |
| F2 | Margen/ganancia omite compras y NC | ✅ CONFIRMADO | Canon: `net_profit = (revenue − nc) − (expenses + purchases)` en `20260814000001:598`. Copiloto: `margenNeto = (rev − gastos)/rev` (`buildBusinessSnapshot.ts:141-143`); `ai-resumen:115`: `balance = ventas − gastos`; ai-insights ídem. |
| F3a | RPC mensual mezcla datos globales al filtrar sucursal | ✅ CONFIRMADO | En la definición vigente (`20260814000001`, no redefinida después): `sales_agg:500`, `expenses_agg:553`, `purchases_agg:562` **sí** filtran `p_branch_id`; `nc_agg:509`, `charges_agg:527`, `payments_agg:538`, `stagnant_curr/prev:567-596` **no**. |
| F3b | Dashboard diario usa otro RPC y no descuenta NC | ✅ CONFIRMADO (matiz) | Diario = `get_dashboard_financials` (vigente `20260610000001`): suma `COALESCE(total,amount)` ✓ y filtra sucursal ✓ en las 3 CTEs, pero `net_profit = ingresos − (gastos + compras)` **sin NC** (línea 81). Diario y mensual disienten en NC. |
| F4 | Stock crítico del dashboard: agregado global, ignora selector de sucursal | ✅ CONFIRMADO | `frontend/app/(dashboard)/dashboard/page.tsx:44-51`: filtra `products` (stock agregado Σ branch_stock) sin usar `branchId` (definido recién en :56); duplica el predicado inline en vez de usar `lib/product-stock.ts`. La RPC canónica `get_dashboard_critical_stock` (guards restaurados en `20260823000001`) no se usa acá. |
| F5 | Rutas modernas no emiten `analytics_events` → activación/UMV/retención subcontadas | ✅ CONFIRMADO | `backend/` tiene **cero** referencias a `analytics_events`; `expense_repository.py:22-37` INSERT directo. El path vivo de gastos es `use-expenses-query.ts` → `POST /expenses` (bypassa el legacy `services.ts:70-93`, único emisor de `operation_created`/`first_operation`). Consumidores que exigen esos eventos siguen vivos: `rpc_admin_kpi_overview`, `rpc_admin_retention_30d`, UMV en `unify_insights.sql:133`. |
| F6 | Paneles admin con motores obsoletos | ✅ CONFIRMADO (corrección de nombre) | La RPC viva es `rpc_admin_business_kpis` (definida en `20260228000400`, sin redefinición posterior): `MRR = pro_users × 15` (:42-45), solo `profiles.plan='pro'` — ignora el billing real de 4 tiers (`get_effective_plan`). `admin/analytics/page.tsx:111` suma activos diarios (duplica personas) y :113 hardcodea la ventana de 37 días. Retención vigente (`20260309000003:82-83`): solo días 30→37. |

**Excepciones deliberadas (NO tocar):** margen por canal sin NC (documentado — NC sin canal atribuible) y margen de catálogo con costo actual vs rentabilidad histórica con snapshots (métricas distintas).

---

## 2. Diagnóstico raíz

El canon existe y está bien (`rpc_dashboard_kpi_summary`, `rpc_period_comparison`, `rpc_product_profitability`, `get_dashboard_critical_stock`, RN-D1..D5) pero **no hay enforcement de consumo**: cada consumidor decide si usa el canon o recalcula. Las rupturas están en los consumidores (IA, dashboard stock, admin) y en un productor muerto (`analytics_events`). Es exactamente el patrón que la regla "reutilización antes que repetición" busca evitar.

---

## 3. Plan por fases (changes OPSX propuestos)

### Fase 1 — Quick wins (sin decisiones de PO, riesgo bajo)

**C-KPI-1 `kpi-ia-canonical-revenue`** — governance MEDIUM — ✅ **COMPLETADO** (PR [#377](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/377))
- Delta medido en producción (solo lectura, cuenta real, últimos 30 días): ingresos `SUM(amount)` → `SUM(COALESCE(total,amount)) − NC` **+11,92%**; margen `(ventas−gastos)/ventas` → `((ventas−NC)−(gastos+compras))/(ventas−NC)` **−12,44 puntos** (compras del período totalmente ausentes del cálculo viejo).
- Verificación manual en vivo (Copiloto vs Tablero, caso degradado visual, post-deploy) queda pendiente del PO — requiere sesión autenticada real.
- Corregir los 4 consumidores IA para ingresos y margen:
  - `buildBusinessSnapshot.ts`: select `total` y sumar `COALESCE(total, amount)`; `margenNeto` pasa a `(ventas − NC − gastos − compras)/ventas` — ideal: consumir `rpc_dashboard_kpi_summary` en vez de recalcular.
  - `ai-insights`, `ai-simulador`, `ai-prediccion`: ídem (v_sales_flat ya expone `total`).
  - `ai-resumen`: solo el balance (agregar compras y NC).
- TDD: vitest sobre `buildBusinessSnapshot` (caso qty>1 que hoy subcuenta); helpers de fórmula unit-testeados para las Edge Functions.
- Impacto hoy: la IA aconseja sobre ventas subestimadas (toda venta con cantidad>1) y margen inflado.
- Sin superficie frontend nueva (cambian números, no pantallas).

**C-KPI-2 `kpi-critical-stock-dashboard`** — governance LOW/MEDIUM — ✅ **COMPLETADO Y ARCHIVADO** (PRs [#381](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/381) apply / [#382](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/382) archive, 2026-08-12). RPC extendida `get_dashboard_critical_stock(p_branch_id)` sobre branch_stock; tenancy corregida (miembros no-owner leían 0); delta prod 412→265 (−35,7%, por exclusión de untracked/variant_only/soft-deleted).
- La tarjeta de stock crítico del dashboard pasa a la definición operativa por sucursal: `branch_stock.quantity <= min_stock` respetando el selector `?branch=`, reutilizando `lib/product-stock.ts` (borrar el predicado inline duplicado). Evaluar usar `get_dashboard_critical_stock` (verificar si acepta `p_branch_id`; si no, extenderla).
- Impacto hoy: faltantes locales invisibles (sucursal A sin stock queda tapada por el agregado).

### Fase 2 — Consistencia de sucursal y NC (1 decisión de PO)

**C-KPI-3 `kpi-branch-consistency`** — governance MEDIUM — 🔶 **PARCIAL** (PRs [#385](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/385)/[#386](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/386), 2026-08-12): diario ya resta NC (diario ≡ mensual, gate CI nuevo), stagnant por sucursal + exclusión soft-deleted, helper único de NC. **Grupo 6 (atribución NC por sucursal + collected_revenue NULL bajo filtro) espera OQ-1** — change abierto sin archivar. Dato clave del propose: el ledger de cta cte está VACÍO en prod (OQ-1 fija semántica antes de que existan datos); recomendación: híbrida (NC por documento origen vía sales_orders.branch_id NOT NULL; cargos/cobros a nivel cuenta).
- `rpc_dashboard_kpi_summary`: aplicar `p_branch_id` a `nc_agg`/`charges_agg`/`payments_agg` (vía join al documento origen si `customer_account_movements` no tiene branch) y a stock sin rotación (vía `branch_stock`).
- `get_dashboard_financials` (diario): restar NC para alinear con el mensual.
- **Gate CI nuevo**: assert en `validate-kpis` que diario y mensual den lo mismo sobre la misma ventana/seed — previene re-divergencia.
- ⚠️ **Decisión PO (OQ-1)**: si las NC/cobros no tienen sucursal atribuible, ¿se atribuyen por la venta origen o se documenta "ajustes a nivel cuenta" (como margen por canal)?

### Fase 3 — Revivir la telemetría de producto (2 decisiones de PO)

**C-KPI-4 `analytics-events-revival`** — governance MEDIUM — 🔶 **EMISIÓN EN PROD** (PRs [#383](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/383)/[#384](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/384), 2026-08-12): triggers vivos en sales/purchases/expenses (verificado en prod), degrade-don't-fail, dedupe por índices únicos parciales, analytics_events.account_id nuevo, gate test_analytics_events.sql en CI. **Backfill espera OQ-2** (recomendación: SÍ backfillear — sin él, los usuarios actuales quedan fuera de las cohortes de retención para siempre; costo trivial ~29 cuentas). OQ-3 menor pendiente: índice único para umv_reached.
- Emitir `operation_created`/`first_operation` desde **un único choke point a nivel DB** (trigger AFTER INSERT en `sales`/`purchases`/`expenses`, patrón degrade-don't-fail como el seed de provisioning) para que todas las rutas (FastAPI, RPCs v2, legacy) emitan uniforme — evita re-duplicar lógica por consumidor.
- ⚠️ **Decisión PO (OQ-2)**: ¿backfill histórico de eventos derivado de las tablas operativas (recupera series de activación/retención/UMV) o corte desde fecha X?
- Prerequisito de valor para la Fase 4: sin esto, los paneles admin miden ruido.

### Fase 4 — Paneles admin honestos (depende de Fase 3 + 2 decisiones de PO)

**C-KPI-5 `admin-kpi-refresh`** — governance MEDIUM — 🔶 **PARCIAL** ([PR #387](https://github.com/GonzaloSevilla22/v0-saa-s-empresarial-completo/pull/387), 2026-08-12, verificado en prod): "Usuarios Comunidad" ahora COUNT(DISTINCT), activaciones/UMV como distintos-sobre-rango, `data_coverage` declara el agujero de eventos, muerto el hardcode de 37d en el cliente, y **fix de los RPCs de comunidad rotos desde C-23** (leían `public.posts` movida al schema `community` — 42P01: `/admin/metricas/comunidad` estaba caído desde entonces). **Grupos 8 (MRR) y 9 (retención) esperan OQ-4/OQ-5** — change abierto. Hallazgo clave del propose: el MRR legacy era ficción (35/35 perfiles con plan='pro'; realidad: 1 cuenta paga de $69.900 ARS + 33 trials PRO que vencen 30-08→04-09 + 1 exenta; ya existe `plan_limits.price_monthly` como tabla de precios real).
- MRR real desde el billing vigente (suscripciones + precio por plan efectivo), no `pro × 15`.
- "Usuarios Comunidad": `COUNT(DISTINCT user_id)` en la RPC (hoy suma activos diarios y duplica personas).
- Retención: implementar la definición que cierre PA-07.
- ⚠️ **Decisión PO (OQ-3)**: fuente y precios para MRR. **(OQ-4 = PA-07)**: retención "≥30 días" ¿ventana 30-37 o abierta?

---

## 4. Orden recomendado y esfuerzo

| Orden | Change | Esfuerzo | Bloqueado por | Estado |
|-------|--------|----------|---------------|--------|
| 1 | C-KPI-1 IA canónica | S-M | — | ✅ PR #377 (+archive #378) |
| 2 | C-KPI-2 stock crítico dashboard | S | — | ✅ PR #381 (+archive #382) |
| 3 | C-KPI-3 sucursal + NC + gate CI | M | — | ✅ PRs #385/#386 + #396/#397 (OQ-1 híbrida) — archivado |
| 4 | C-KPI-4 analytics_events | M | — | ✅ PRs #383/#384 + #394/#395 (backfill 926 eventos + índice umv) — archivado |
| 5 | C-KPI-5 admin refresh | M | — | ✅ PRs #387 + #398/#399 (MRR $69.900 ARS real, pipeline trials $2.306.700; retención [30,60) con cohortes reales) — archivado |

> Extra fuera de este plan, mismo ciclo: **`app-timezone-argentina`** ✅ COMPLETADO Y ARCHIVADO (PRs #379/#380) — día de negocio anclado a America/Argentina/Mendoza en toda la app (formularios, dashboard, IA, Edge Functions, 4 RPCs SQL); de paso corrigió el bug de escritura nocturna (ventas 21:00–24:00 se guardaban con fecha de mañana) y una regresión latente de PeriodFilter (mes anterior corrido 2 meses en runtimes UTC).

## 5. Decisiones pendientes del PO (2026-08-12)

1. **OQ-1 (C-KPI-3 grupo 6)**: atribución de NC bajo filtro de sucursal. Recomendación: híbrida — NC a la sucursal del documento origen (`sales_orders.branch_id` NOT NULL lo hace exacto); cargos/cobros quedan a nivel cuenta y `collected_revenue` se muestra NULL bajo filtro (la tarjeta ya oculta la línea).
2. **OQ-2 (C-KPI-4 backfill)**: recomendación **SÍ** — `INSERT…SELECT` con `source='backfill'` deduplicado; sin él la retención no da números útiles hasta ~37 días post-deploy y los usuarios actuales quedan fuera de las cohortes para siempre.
3. **OQ-3 menor (C-KPI-4)**: índice único parcial para `umv_reached` (misma carrera que first_operation). Una línea.
4. **OQ-4/OQ-5 (C-KPI-5)**: fuente y precios de MRR real + definición de retención (PA-07: ¿ventana 30-37 o "≥30 días" abierta?). Sin esto no se propone C-KPI-5.
5. **Verificaciones manuales pendientes**: Copiloto vs Tablero en vivo (post #377) y form de venta nocturno (post #379) — requieren tu sesión.
