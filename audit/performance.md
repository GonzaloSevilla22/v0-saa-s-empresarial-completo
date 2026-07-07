# Auditoría de Performance — ALIADATA / EmprendeSmart-EIE

**Auditor:** Performance Engineer (consultora externa)
**Fecha:** 2026-07-07
**Alcance:** backend/repositories, backend/core (pool/db/redis), frontend/hooks (React Query), frontend/components (dashboard/tablas), frontend/app, frontend/next.config.mjs, frontend/providers. Estado real verificado contra PROD `gxdhpxvdjjkmxhdkkwyb` (MCP read-only: advisors, pg_indexes, pg_stat_user_tables/indexes, pg_policies, EXPLAIN).
**Clasificación del área:** Buena (con un riesgo de escala latente P1 y deuda de índices/bundle acotada).

---

## Resumen ejecutivo

El hot path transaccional (crear venta/compra, ajustes de stock, cta cte, outbox) está bien construido: la escritura vive en RPCs `SECURITY DEFINER` (UoW), el outbox usa `FOR UPDATE SKIP LOCKED` con índice parcial `events_unprocessed_idx (occurred_at) WHERE processed_at IS NULL`, las tablas de movimientos de cta cte tienen índices compuestos `(*_account_id, created_at DESC)` correctos, el pool asyncpg está configurado para pgBouncer transaction mode (`statement_cache_size=0`), y React Query tiene `staleTime`/`gcTime` razonables con invalidación por Realtime.

Los problemas reales son de **escala** y **transferencia de datos**, no de corrupción ni de dinero:

1. **Patrón RLS `account_id IN (SELECT current_account_ids())` fuerza Seq Scan** en las tablas de alto volumen (`sales`, `clients`, `expenses`, `purchases`). Verificado por EXPLAIN: el planner elige Seq Scan + Memoize semijoin a `account_members` en vez de un index range scan por `account_id`. Hoy es barato (279–1121 filas) pero los contadores de PROD ya muestran el síntoma: **679.570 seq scans en `sales`, 909.414 en `clients`, 251.982 en `purchases`, 145.314 en `expenses`**. No escala.

2. **Endpoints de lista sin paginación**: `GET /products` y `GET /clients` devuelven la lista completa (`list[ProductOut]` / `list[ClientApiRow]`) — 3.703 productos y 1.121 clientes en la cuenta más grande — sin LIMIT, sin GZip (no hay `GZipMiddleware` en FastAPI). Payload grande sobre el cold-start de Render free tier.

3. **`SalesChart` (dashboard, todos los usuarios) consume `useSales()`** que sólo trae la **primera página de 25 ventas** y filtra los últimos 7 días en cliente → además de un fetch redundante, es un **defecto de correctitud** silencioso a escala (el gráfico subvalúa si hay >25 ventas más recientes que la ventana de 7 días).

4. **Bundle**: `d3` (~250 KB) + `recharts` ambos como deps, Recharts importado estáticamente en 5 páginas de ruta, y **`next/dynamic` no se usa en ningún lado** → sin code-splitting de los gráficos pesados.

5. **178 advisories de performance de Supabase**: 67 multiple_permissive_policies, 55 unused_index, 48 unindexed_foreign_keys, 8 auth_rls_initplan.

---

## Verificación de estado real en PROD (MCP read-only)

### pg_stat_user_tables (síntoma de escala)
| tabla | live_rows | seq_scan | idx_scan |
|---|---|---|---|
| products | 3.703 | 18.695 | 9.098.347 |
| clients | 1.121 | **909.414** | 2.912.809 |
| stock_movements | 874 | 41 | 1.578 |
| sale_items | 293 | 707 | 37.676 |
| purchases | 287 | **251.982** | 11.380 |
| sales | 279 | **679.570** | 68.373 |
| expenses | 95 | **145.314** | 136 |

`expenses` es el caso extremo: 145k seq scans vs 136 idx scans; sus índices `idx_expenses_account_id` y `expenses_account_branch_idx` tienen **idx_scan=0** (nunca usados).

### EXPLAIN del patrón RLS (raíz del seq scan)
```
EXPLAIN SELECT * FROM expenses
 WHERE account_id IN (SELECT account_id FROM account_members WHERE user_id = <uid>)
 ORDER BY date DESC;
-> Sort
   -> Nested Loop
      -> Seq Scan on expenses  (rows=54)            <-- NO usa idx_expenses_account_id
      -> Memoize (Cache Key: expenses.account_id)
         -> Index Only Scan on account_members
```
El planner **escanea toda la tabla** y valida pertenencia por semijoin memoizado. Correcto y barato a 95 filas; catastrófico cuando una cuenta acumule decenas de miles de filas, porque el costo crece con el total global de la tabla, no con las filas de la cuenta.

Contraste — cuando el filtro `account_id = $1` es explícito (repos del backend), SÍ usa índice:
```
EXPLAIN COUNT(DISTINCT ...) FROM sales WHERE account_id = <uuid> ...
-> Index Scan using idx_sales_account_id (Index Cond: account_id = ...)
```
**Conclusión:** los seq scans vienen de las rutas **Supabase-directas** (RLS-only, sin `account_id = $1` en el WHERE): `usePaginatedQuery` (expenses/otros vía supabase-js), los RPCs de dashboard/reporting y los hooks que pegan a supabase.rpc(). Las rutas FastAPI están a salvo porque filtran por `account_id` explícito.

### Índices del hot path (sales/sale_items/purchases)
- `sales`: existe `idx_sales_account_id`, `sales_account_branch_idx (account_id,branch_id)`, `idx_sales_user_date (user_id,date DESC)`. **NO existe `(account_id, date DESC)`** — la query paginada `list_paginated_by_operation` filtra+ordena por `(account_id, date)` y hoy resuelve con `idx_sales_account_id` + sort en memoria (barato a 279 filas). A escala conviene el compuesto. Mismo caso en `purchases`. `idx_sales_user_date` es inútil para el path account-based (filtra por user_id, no account_id).
- `sale_items`: `idx_sale_items_sale (sale_id)` ✅ — el JOIN de la paginación de ventas está cubierto.
- `events` (outbox): `events_unprocessed_idx (occurred_at) WHERE processed_at IS NULL` ✅ excelente.
- `customer_account_movements` / `supplier_account_movements`: `(*_account_id, created_at DESC)` ✅ — la paginación de cta cte (K13) está bien indexada.

### Advisors de performance (178 total)
- **unindexed_foreign_keys (48)**: FKs sin índice cubridor en tablas del hot path — `sales.branch_id`, `purchases.branch_id`, `purchases.cost_center_id`, `stock_movements.branch_id`, `sales_orders.client_id/branch_id/created_by`, `sales_order_items.product_id/unit_id/account_id`, `payments_received.*` (client_id, customer_account_id, movement_id, created_by), `payments_made.*` (supplier_id, supplier_account_id, movement_id, created_by), `journal_lines.cost_center_id`, `notifications.branch_id`, `branch_stock.branch_id`. Impacto real: los DELETE/UPDATE de la fila padre hacen seq scan del hijo para validar la FK, y los JOINs por esas columnas no tienen índice.
- **unused_index (55)** + verificado idx_scan=0: `idx_expenses_account_id`, `expenses_account_branch_idx`, `idx_clients_company/user/user_name`, `idx_products_company/base_unit/sku_user/barcode_unique`, `idx_purchases_company/supplier_id/unit/user`, `idx_sales_unit`, `idx_stock_movements_number`. Muchos son legacy `company_id`/`user_id` (pre-multitenant C-19) — puro overhead de escritura y bloat, candidatos a DROP.
- **auth_rls_initplan (8)**: `product_attributes` (4 policies), `export_logs` (3), `wsaa_access_tickets` (1) re-evalúan `current_setting()`/`auth.*()` por fila. Tablas de bajo tráfico; las tablas calientes (sales/clients/etc.) ya usan `current_account_ids()` con `(SELECT auth.uid())` envuelto (initplan-optimizado) → bien.
- **multiple_permissive_policies (67)**: varias policies permisivas por (rol, acción) que se evalúan todas por fila. WARN, no crítico, pero suma CPU por query en tablas con múltiples policies SELECT.

---

## Hallazgos detallados

### P1 / ALTA — El patrón RLS `account_id IN (SELECT current_account_ids())` no escala (Seq Scan)
**Evidencia:** `pg_policies` (sales_account_select, clients_account_select, expenses_account_select, purchases_account_select todas con `qual = account_id IN (SELECT current_account_ids())`); EXPLAIN muestra `Seq Scan on expenses` + Memoize; contadores PROD (sales 679k / clients 909k / purchases 251k / expenses 145k seq scans). `current_account_ids()` es `STABLE SECURITY DEFINER`.
**Impacto:** costo de cada SELECT crece con el total global de la tabla, no con las filas de la cuenta. Con junio 2026 y crecimiento de cuentas, las lecturas Supabase-directas (dashboard, `usePaginatedQuery`, RPCs) degradan linealmente y saturan el pool (max_size=10) y el CPU de Postgres.
**Recomendación:**
1. En las rutas Supabase-directas del frontend, **filtrar siempre `.eq("account_id", accountId)` explícito** además de confiar en RLS — así el planner usa `idx_*_account_id`. (Los repos FastAPI ya lo hacen.)
2. Evaluar reescribir la policy a `account_id = ANY(current_account_ids())` o cachear el set en una GUC por request para evitar el semijoin por fila.
3. Priorizar los índices `(account_id, date DESC)` en sales/purchases/expenses para que el path paginado no dependa del sort en memoria.
**Riesgo si no:** a las pocas miles de filas por cuenta, dashboard y listados se vuelven lentos (>1–2 s) y el pool de 10 conexiones se agota bajo concurrencia moderada.

### P1 / ALTA — `SalesChart` grafica sólo la primera página de ventas (correctitud + fetch redundante)
**Evidencia:** `frontend/components/dashboard/sales-chart.tsx:8` `const { sales } = useSales()`; `useSales()` (`frontend/hooks/data/use-sales.ts:69,98-105`) inicia en `page=0, pageSize=25` y pega a `/sales?page=0&page_size=25`. El chart (`:11-21`) filtra `sales.filter(s => s.date === dateStr)` para los últimos 7 días sobre esas 25 filas.
**Impacto:** si en la cuenta hay >25 ventas más recientes que la ventana de 7 días (una jornada intensa de POS), el gráfico "Ventas últimos 7 días" **subvalúa o queda en cero** para días reales con ventas. Además dispara un fetch de 25 ventas sólo para dibujar 7 barras, y el cálculo `data`/`chartData` corre en cada render sin `useMemo`.
**Recomendación:** el chart debe consumir un RPC agregado por día (como `rpc_dashboard_kpi_summary` ya hace para los KPIs) — p. ej. `rpc_sales_last_7_days(account_id)` que devuelva 7 filas sumadas en la DB. Eliminar el filtrado en cliente y envolver la derivación en `useMemo`.
**Riesgo si no:** KPI visible incorrecto en producción (mismo tipo de bug que el revenue subvaluado 17,53% que ya se fixeó en `v3-reporting-invariants`).

### P2 / MEDIA — `GET /products` y `GET /clients` sin paginación ni límite
**Evidencia:** `backend/routers/products.py:22` `response_model=list[ProductOut]`; `backend/services/products.py:22` `return await repo.list_by_org(account_id)`; `product_repository.list_by_org` (`:33`) hace `SELECT * FROM v_products_with_stock WHERE account_id=$1 ORDER BY name` sin LIMIT. `clients` idéntico. `use-products.ts:59` y `use-clients.ts:50` traen la lista completa. PROD: 3.703 productos / 1.121 clientes en la cuenta mayor.
**Impacto:** payload de cientos de KB sin comprimir (no hay GZipMiddleware — `main.py` sólo agrega CORS), parseo pesado en cliente, y la tabla de productos se renderiza sin virtualización (sólo `low-stock-alert.tsx` usa virtualización). `v_products_with_stock` recalcula `SUM(branch_stock)` por producto en cada request.
**Recomendación:** paginar ambos endpoints con el helper `BaseRepository.paginate()` (ya existe), agregar `GZipMiddleware(minimum_size=1000)` en `main.py`, y virtualizar las tablas largas. El selector de productos del POS puede necesitar full-list — resolverlo con búsqueda server-side, no trayendo todo.
**Riesgo si no:** cold start de Render + payload grande = TTFB alto en la carga inicial de catálogo/clientes; empeora con cada producto nuevo.

### P2 / MEDIA — Bundle: `d3` + `recharts` sin code-splitting (`next/dynamic` ausente)
**Evidencia:** `frontend/package.json` incluye `d3 ^7.9.0`, `@types/d3`, `recharts 2.15.0`. Recharts importado estáticamente en `components/dashboard/sales-chart.tsx`, `app/(dashboard)/rentabilidad/page.tsx`, `reportes/comparativo/page.tsx`, `reportes/sucursal/page.tsx`, `components/ui/chart.tsx`. `d3` importado en 6 charts de `components/admin/charts/`. `grep next/dynamic` sobre `frontend/app` y `frontend/components` → **0 resultados**.
**Impacto:** d3 (~250 KB min) y recharts se incluyen en los bundles de ruta que los tocan sin lazy-load. Los charts de admin (d3) sólo los ve el admin pero pueden estar arrastrando peso a chunks compartidos.
**Recomendación:** `const SalesChart = dynamic(() => import(...), { ssr:false, loading: skeleton })` para los gráficos; los charts d3 de admin deben ir 100% lazy detrás de `next/dynamic`. Confirmar con `@next/bundle-analyzer` que d3 no está en el first-load JS de rutas no-admin.
**Riesgo si no:** first-load JS elevado en dashboard/reportes → peor LCP en mobile (target UMV: microemprendedores en celular).

### P2 / MEDIA — FKs del hot path sin índice cubridor (48 advisories)
**Evidencia:** advisor `unindexed_foreign_keys` sobre `sales.branch_id`, `purchases.branch_id`, `purchases.cost_center_id`, `stock_movements.branch_id`, `sales_orders.client_id/branch_id/created_by/fiscal_document_id`, `sales_order_items.product_id/unit_id/account_id`, `payments_received.*`, `payments_made.*`, `journal_lines.cost_center_id`, `notifications.branch_id`, `branch_stock.branch_id`.
**Impacto:** filtros/JOINs por sucursal (reportes por sucursal, `use-channel-margin`, cta cte por movimiento) hacen seq scan; los DELETE de branch/client/product padre escanean los hijos para validar la FK.
**Recomendación:** crear índices btree en las FKs de las tablas que ya tienen volumen o crecerán (branch_id, cost_center_id, client_id, *_account_id, movement_id). Priorizar `sales.branch_id`, `purchases.branch_id`, `stock_movements.branch_id`, `payments_received/made` FKs.
**Riesgo si no:** los reportes por sucursal (`reportes/sucursal`) y la cta cte se degradan a medida que crecen ventas/pagos.

### P3 / BAJA — 55 índices sin uso (idx_scan=0), varios legacy company_id/user_id
**Evidencia:** verificado idx_scan=0 en `idx_expenses_account_id`, `expenses_account_branch_idx`, `idx_clients_company/user/user_name`, `idx_products_company/base_unit/sku_user/barcode_unique`, `idx_purchases_company/supplier_id/unit/user`, `idx_sales_unit`, `idx_stock_movements_number`, etc.
**Impacto:** cada INSERT/UPDATE mantiene índices que nadie lee → overhead de escritura y bloat. Los `*_company_*` son residuo pre-C-19 (multitenant). Ojo: algunos (barcode_unique, sku) son UNIQUE y cumplen función de constraint aunque idx_scan=0 — NO dropear esos.
**Recomendación:** DROP de los índices legacy `company_id`/`user_id` no-unique confirmados sin uso, tras validar que ninguna query los referencia. Mantener los UNIQUE.
**Riesgo si no:** overhead menor de escritura; se acumula con el tiempo.

### P3 / BAJA — N+1 en inserción de `quote_items`
**Evidencia:** `backend/repositories/quote_repository.py:67-87` — `for item in items:` con un `INSERT ... SELECT` por línea (una round-trip por ítem).
**Impacto:** bajo (cotizaciones = baja frecuencia, pocos ítems). Latencia lineal en el número de líneas.
**Recomendación:** cuando se optimice, pasar a un solo `INSERT ... SELECT ... FROM unnest($items::jsonb[])` o `executemany`. No urgente.
**Riesgo si no:** despreciable hoy.

### P3 / BAJA — Sin capa de caché de lecturas (Redis sólo rate-limit)
**Evidencia:** `backend/core/redis_client.py` init sólo para rate-limiting; `grep redis backend/services backend/repositories` → 0. Los RPCs de dashboard/reporting pegan a Postgres en cada request.
**Impacto:** mitigado por React Query `staleTime` (2–5 min) en cliente. Sin caché server-side, cada usuario nuevo/refetch recomputa agregados.
**Recomendación:** opcional — cachear en Redis (Upstash) los resultados de `rpc_dashboard_kpi_summary` y reportes con TTL corto por (account_id, período). Bajo esfuerzo, alto retorno si el dashboard es la vista más visitada.
**Riesgo si no:** aceptable a la escala actual.

---

## Fortalezas (reconocimiento)

1. **Hot path transaccional en RPCs `SECURITY DEFINER`** (DEC-24 UoW): crear venta/compra, stock, cta cte y cierre de caja son atómicos en la DB, no en Python. Evita round-trips múltiples y condiciones de carrera.
2. **Outbox con `FOR UPDATE SKIP LOCKED` + índice parcial** `events_unprocessed_idx (occurred_at) WHERE processed_at IS NULL` — patrón de relay correcto y barato; no escanea eventos procesados.
3. **Pool asyncpg listo para pgBouncer transaction mode**: `statement_cache_size=0` evita el bug de prepared statements cacheados; min/max 2/10 razonable para Render free.
4. **JWT-passthrough** en una sola round-trip (`set_config` de ambos claims en un `SELECT`), no dos.
5. **Paginación de cta cte bien indexada**: `customer_account_movements` y `supplier_account_movements` con `(*_account_id, created_at DESC)`; el COUNT y el SELECT usan el mismo índice.
6. **React Query bien configurado**: `staleTime`/`gcTime` sensatos, `refetchOnWindowFocus:false`, retry que no reintenta 4xx, singleton de QueryClient por boundary, mutaciones sin retry (evita doble efecto).
7. **Paginación server-side real en ventas/compras/cta cte** vía FastAPI con envelope `{items,total,page,pages}` — el path account-based filtra `account_id` explícito y usa índice (verificado por EXPLAIN).
8. **`current_account_ids()` / `is_account_writer()` son `STABLE` con `(SELECT auth.uid())` envuelto** — initplan-optimizado, se evalúan una vez por query en las tablas calientes.
9. **RPC agregador de dashboard** (`rpc_dashboard_kpi_summary`) resuelve todos los KPIs del período + período anterior en una sola llamada, no N queries.

---

## Deuda técnica de performance (consolidada)
- Falta índice `(account_id, date DESC)` en `sales`, `purchases`, `expenses` para el path paginado a escala.
- Policies RLS con semijoin por fila (`IN (SELECT ...)`) — reescribir a `= ANY()` o GUC cacheada.
- `GET /products` y `GET /clients` sin paginar; sin GZip en FastAPI.
- `SalesChart` sobre página parcial de ventas (mover a RPC agregado).
- Sin `next/dynamic` — charts pesados (d3/recharts) sin code-splitting.
- 48 FKs del hot path sin índice cubridor.
- 55 índices sin uso (legacy company_id/user_id) — DROP tras validar.
- N+1 en `quote_items` insert.
- Sin caché server-side (Redis) de agregados de dashboard/reportes.
- Tablas largas sin virtualización (salvo low-stock-alert).

## Verificación de issues conocidos del área
- **K10 (Render cold start ~50s, pgBouncer sin SET ROLE):** CONFIRMADO. `database.py` usa `statement_cache_size=0` (compatible pgBouncer) y `get_service_conn` no hace SET ROLE (usa postgres BYPASSRLS). El cold start agrava el P2 de payloads no paginados/no comprimidos. Mitigación de ping a /health no verificable desde el repo (config de Render externa).
- **K13 (cta cte sin paginación estándar):** MATIZADO. Los repos SÍ tienen `list_movements_page` con envelope estándar y `paginate()`, y los índices `(*_account_id, created_at DESC)` cubren tanto el SELECT como el COUNT — la paginación de movimientos está bien resuelta a nivel DB. El COUNT(*) por request es barato porque usa el índice compuesto. No es un problema de performance.
