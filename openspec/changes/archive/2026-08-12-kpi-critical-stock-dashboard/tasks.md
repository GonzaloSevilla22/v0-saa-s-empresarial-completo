> **Modo TDD estricto**: cada grupo sigue SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR.
> No se escribe código de producción sin un test que falle primero.
> Runners: SQL → `psql -v ON_ERROR_STOP=1 ... -f supabase/tests/<file>.sql` contra Supabase local (`npx supabase db reset`).
> Frontend → `pnpm -C frontend vitest run <archivo>` (ojo: `pnpm test -- --run <file>` **no** filtra).

## 1. Safety net y línea base

- [x] 1.1 `npx supabase db reset` local y correr los 4 gates de `KPI_Validation.yml` (`test_kpis.sql`, `test_kpis_edge_cases.sql`, `test_function_acl_gate.sql`, `test_idempotency.sql`) con `ON_ERROR_STOP=1`; anotar "N gates PASS" como línea base. Si alguno falla ANTES de tocar nada → reportar como fallo preexistente y parar.
- [x] 1.2 `pnpm -C frontend test` completo; anotar el total verde como línea base (referencia: 873).
- [x] 1.3 Confirmar contra el código actual (los números de línea pueden estar corridos por PRs #377/#379): predicado inline en `frontend/app/(dashboard)/dashboard/page.tsx` (`getLowStockProducts`), predicado gemelo en `frontend/components/branches/BranchStockTable.tsx`, y **cero callers** de `get_dashboard_critical_stock` en `frontend/` y `backend/` (grep).
- [x] 1.4 Medir el valor actual del KPI en prod (conteo viejo) vía MCP/SQL de solo lectura, para poder reportar el delta después (OQ3 del design). Solo lectura, sin escrituras.

## 2. RPC canónica por sucursal — RED (tests SQL primero)

- [x] 2.1 RED · `supabase/tests/test_kpis.sql` §3: cambiar el assert de firma a `identity_arguments = 'p_branch_id uuid'`. Correr → debe FALLAR (hoy la firma es 0-args).
- [x] 2.2 RED · `supabase/tests/test_kpis.sql` §4: reemplazar "ningún overload con argumentos" por allowlist de firmas (`{'p_branch_id uuid'}`), conservando el mensaje que documenta el vector IDOR y prohibiendo explícitamente `p_user_id uuid`. Correr → debe FALLAR.
- [x] 2.3 RED · `supabase/tests/test_kpis_edge_cases.sql`: agregar bloque de comportamiento que siembra una cuenta sintética (2 sucursales + productos) y simula sesión con `SET LOCAL request.jwt.claims` (`auth.uid()` lee `sub`), con cleanup hijo→padre por el email del anchor y no-op si el anchor no existe (patrón de las migraciones de limpieza `20260804000008` / `20260806000002`). Primer caso: **filtro por sucursal** — producto con `min_stock=5`, 0 unidades en A y 50 en B ⇒ `get_dashboard_critical_stock(<A>) = 1`. Correr → debe FALLAR.
- [x] 2.4 RED · Segundo caso en el mismo bloque: **agregado sin filtro** ⇒ `get_dashboard_critical_stock() = 1` (el faltante local no se tapa con el stock de B). Correr → debe FALLAR (hoy el agregado da 0).

## 3. RPC canónica por sucursal — GREEN (migración)

- [x] 3.1 GREEN · Crear `supabase/migrations/<timestamp > 20260907000001>_critical_stock_by_branch.sql` con, **en este orden y en el mismo archivo**: `DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock();` → `CREATE OR REPLACE FUNCTION public.get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public`. El DROP previo es obligatorio: `CREATE OR REPLACE` agregando parámetro crea un segundo overload (42725).
- [x] 3.2 GREEN · Cuerpo: guard `IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated' USING ERRCODE = 'insufficient_privilege'` + `SELECT COUNT(DISTINCT bs.product_id) FROM branch_stock bs JOIN products p ON p.id = bs.product_id WHERE bs.account_id IN (SELECT current_account_ids()) AND bs.min_stock > 0 AND bs.quantity <= bs.min_stock AND (p_branch_id IS NULL OR bs.branch_id = p_branch_id) AND p.deleted_at IS NULL AND COALESCE(p.stock_control_type,'tracked') NOT IN ('untracked','variant_only')`. Devolver `COALESCE(...,0)`.
- [x] 3.3 GREEN · Re-aplicar ACLs en el mismo archivo (DROP+CREATE las resetea): `REVOKE ALL ... FROM PUBLIC`, `REVOKE EXECUTE ... FROM anon`, `GRANT EXECUTE ... TO authenticated` sobre la firma nueva.
- [x] 3.4 GREEN · Gate `DO $$` al final de la migración: aborta si hay más de una firma de `get_dashboard_critical_stock`, si aparece `p_user_id`, o si el cuerpo pierde `min_stock > 0` / `auth.uid()` / lectura de `branch_stock`; `RAISE NOTICE` de éxito.
- [x] 3.5 GREEN · `npx supabase db reset` + correr 2.1-2.4 → los 4 asserts deben PASAR.

## 4. RPC — TRIANGULATE (resto de escenarios del spec)

- [x] 4.1 Caso `min_stock = 0` con `quantity = 0` ⇒ no cuenta (con y sin filtro de sucursal). Debe pasar sin tocar la migración; si falla, corregir el guard.
- [x] 4.2 Caso producto crítico en 3 sucursales ⇒ el agregado devuelve **1** (`COUNT(DISTINCT product_id)`, no pares producto-sucursal).
- [x] 4.3 Caso `stock_control_type` `untracked` y `variant_only` por debajo del umbral ⇒ no cuentan; `stock_control_type` NULL o valor legacy desconocido ⇒ **sí** cuenta (fail-open, espejo de `holdsOwnStock`).
- [x] 4.4 Caso producto con `deleted_at` no nulo por debajo del umbral ⇒ no cuenta.
- [x] 4.5 Caso tenancy: sesión de un **miembro** de la cuenta (no el `user_id` dueño de los productos) ⇒ mismo conteo que el owner; y `p_branch_id` de **otra** cuenta ⇒ 0.
- [x] 4.6 Caso sin sesión: `get_dashboard_critical_stock()` sin `auth.uid()` ⇒ `insufficient_privilege` (el bloque ya existente de `test_kpis_edge_cases.sql` §2 debe seguir pasando con la firma nueva, porque el parámetro tiene DEFAULT).
- [x] 4.7 Idempotencia: re-aplicar la migración sobre la misma DB (segunda pasada) no falla y deja el mismo estado; verificar también que sigue habiendo **una sola** firma.

## 5. Frontend — capa de acceso y hook (RED → GREEN → TRIANGULATE)

- [x] 5.1 SAFETY NET · Correr los tests existentes de los archivos que se van a tocar (`__tests__/KpiSummaryBlock.test.tsx`, `__tests__/lib/product-stock.test.ts`, `__tests__/branches.test.ts` si aplica) y anotar el baseline.
- [x] 5.2 RED · Test nuevo del hook/capa de acceso (`frontend/__tests__/hooks/use-critical-stock.test.tsx` o `__tests__/critical-stock.test.ts`, siguiendo el patrón de mocks de Supabase ya usado en el repo — `vi.hoisted` para los `createClient()` a nivel de módulo): la llamada pasa `p_branch_id` explícito (incluso `null`) y mapea el escalar a `number`. Debe FALLAR (no existe el módulo).
- [x] 5.3 GREEN · Crear `frontend/lib/reporting/critical-stock.ts` (llamada + mapeo, patrón `lib/reporting/kpi-summary.ts`) y `frontend/hooks/data/use-critical-stock.ts` (React Query: `queryKey: ["criticalStock", user?.id, branchId]`, `staleTime` 30-60 s, `enabled: !!user`). Sin `any`: tipar contra `database.types.ts`.
- [x] 5.4 TRIANGULATE · Casos: `branchId = null` ⇒ agregado; `branchId = "<uuid>"` ⇒ conteo de esa sucursal; **cambio** de `branchId` ⇒ nueva queryKey y re-fetch; error de la RPC ⇒ devuelve 0 + `console.error` sin propagar (degradación del design).
- [x] 5.5 Regenerar `frontend/lib/database.types.ts` con la firma nueva de la RPC (o actualizar a mano la entrada correspondiente si la regeneración trae ruido no relacionado).

## 6. Frontend — Tablero y dedup del predicado

- [x] 6.1 RED · Test del Tablero (`frontend/__tests__/DashboardCriticalStockCard.test.tsx` o el archivo de dashboard existente): con `?branch=<uuid>` la tarjeta "Productos en alerta" muestra el valor del KPI de **esa** sucursal, y al cambiar el parámetro vuelve a consultar. Debe FALLAR (hoy el valor sale del filtro inline sobre `products`).
- [x] 6.2 GREEN · En `frontend/app/(dashboard)/dashboard/page.tsx`: borrar `getLowStockProducts()` y la variable `lowStock`; mover/consumir `useCriticalStock(branchId)` (con `branchId` ya definido antes del uso) y alimentar la tarjeta. Mantener `KpiCard` con el mismo icono y color; mientras carga, mostrar `"—"` igual que las otras tres tarjetas.
- [x] 6.3 TRIANGULATE · Casos del Tablero: sin `?branch=` ⇒ agregado; estado de carga ⇒ `"—"`; error del KPI ⇒ 0 y el resto del Tablero sigue renderizando; grep de regresión ⇒ no queda ningún `stock <= minStock` inline en `app/(dashboard)/dashboard/`.
- [x] 6.4 RED→GREEN · `frontend/components/branches/BranchStockTable.tsx`: test que cubra fila crítica / fila sana / fila con `minStock = 0`; reemplazar el predicado inline por `isBelowThreshold(item.quantity, item.minStock)` de `lib/product-stock.ts`. Sin cambio de comportamiento visible.
- [x] 6.5 REFACTOR · Documentar en el docblock de `frontend/lib/product-stock.ts` que la RPC nueva (`get_dashboard_critical_stock(p_branch_id)`) es el espejo SQL del predicado, junto a las referencias ya existentes a `check_branch_low_stock` (RN-23). Sin cambios de comportamiento; correr los tests después de cada paso.

## 7. Verificación integral

- [x] 7.1 `npx supabase db reset` completo + los 4 gates SQL de `KPI_Validation.yml` en verde (incluye los asserts nuevos y los gates de comportamiento preexistentes).
- [x] 7.2 `pnpm -C frontend test` completo verde, con total ≥ baseline de 1.2 + los tests nuevos. Sin `any` introducido (`pnpm -C frontend lint` / typecheck limpio).
- [x] 7.3 Verificación manual del Tablero (`next dev`): con y sin `?branch=`, en **desktop y mobile** y en **tema claro y oscuro** — la tarjeta no cambia de layout ni de estilos, solo de valor. Revertir cualquier ensuciado de `next-env.d.ts` antes de commitear.
- [x] 7.4 Medir el KPI nuevo contra prod (misma consulta que 1.4, adaptada) y anotar el delta viejo→nuevo con su explicación (sube por faltantes locales antes ocultos, baja por `untracked`/`variant_only`/soft-deleted). Reportarlo en el PR (OQ3).
- [x] 7.5 `EXPLAIN` de la consulta del KPI sobre una cuenta con inventario real; si aparece seq scan costoso, agregar índice parcial `(account_id, branch_id) WHERE min_stock > 0` **en la misma migración** (no en una nueva).

## 8. Cierre

- [x] 8.1 Rama nueva off `main` + commit(s) `feat(stock): ...` / `fix(dashboard): ...` con co-autoría; PR con resumen del delta del KPI y de la semántica del agregado.
- [x] 8.2 Esperar checks verdes (incluido `validate-kpis`, no solo Vercel) y mergear. (PR #381, squash `8457d3b`, mergeado a `origin/main` 2026-08-12.)
- [ ] 8.3 Post-merge: verificar que la migración quedó aplicada en prod y que la RPC tiene **una sola** firma; marcar C-KPI-2 como hecho en `docs/plan-remediacion-kpis-2026-08-11.md`. (Verificación manual del PO — pendiente.)
- [x] 8.4 `mem_save` del resultado (delta real del KPI, decisiones D2/D3/D4 confirmadas o ajustadas) con `topic_key: opsx/kpi-critical-stock-dashboard/apply`.
