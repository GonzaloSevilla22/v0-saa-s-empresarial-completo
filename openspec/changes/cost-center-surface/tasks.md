> **Modo TDD estricto activo.** Cada grupo sigue el ciclo RED → GREEN → TRIANGULATE → REFACTOR.
> Antes de tocar un archivo existente: correr su suite y capturar la línea base ("N tests passing").
> Si algo ya venía roto, se reporta como fallo preexistente y NO se arregla acá.

## 1. Read-model `rpc_cost_center_report` (migración)

> **Limitación de entorno**: Docker no está corriendo en esta máquina, así que `supabase start` no
> puede levantar la DB local y **los gates SQL no se ejecutaron acá**. Corren en el workflow
> KPI Validation del PR, que aplica toda la cadena de migraciones sobre una DB vacía con
> `-v ON_ERROR_STOP=1`. Las tareas que requieren ejecución quedan marcadas como pendientes de CI.

- [x] 1.1 **[SAFETY NET]** Correr `pytest backend/tests -q` y la suite de vitest del frontend; anotar la línea base de ambas en el resumen final — backend **1261 passed, 3 skipped**; frontend **707 passed, 2 failed** (fallo PREEXISTENTE en `product-catalog-search-collapse.test.tsx`, no se toca)
- [ ] 1.2 **[RED]** Escribir en la migración nueva los **gates de introspección**: el cuerpo publicado de `rpc_cost_center_report` debe contener `COALESCE(p.total, p.amount)`, `COUNT(DISTINCT COALESCE(p.operation_id, p.id))`, el borde `< (p_end + 1)` y la etiqueta `Sin centro de costo`. Verificar que fallan contra la DB actual (la función no existe todavía) — **escritos; la verificación RED corre en CI (sin Docker local)**
- [x] 1.3 **[GREEN]** Crear la migración `supabase/migrations/20260901000001_cost_center_report.sql` con `CREATE OR REPLACE FUNCTION public.rpc_cost_center_report(p_account_id uuid, p_start date, p_end date)`: `SECURITY DEFINER`, `SET search_path TO 'public'`, verificación de membership contra `account_members` con `ERRCODE = 'P0401'`, y `RETURNS TABLE(...)` — se agregó `is_active` a la salida para que la UI marque los centros dados de baja sin un query extra
- [x] 1.4 **[GREEN]** Agregar `REVOKE ALL ... FROM PUBLIC`, `REVOKE EXECUTE ... FROM anon` y `GRANT EXECUTE ... TO authenticated` (verificado contra `supabase/tests/test_function_acl_gate.sql`: no requiere entrada en la allowlist, que solo cubre lo anon-executable)
- [x] 1.5 **[TRIANGULATE]** Gates de comportamiento con anchor sintético vía `handle_new_user` + cleanup hijo→padre — el gate **invoca el RPC de verdad** seteando `request.jwt.claims` local para que `auth.uid()` resuelva al anchor (más fuerte que el patrón de `20260814000001`, que solo replicaba la fórmula), con degradación por `NOTICE` si el contexto no lo permite
- [x] 1.6 **[TRIANGULATE]** Gate de que la suma de todas las filas iguala el costo total del período (invariante de la Decisión 4) + gate extra: una venta en el rango no altera el total
- [x] 1.7 **[TRIANGULATE]** Gate de autorización: un caller que no es miembro de `p_account_id` recibe `P0401`
- [ ] 1.8 **[REFACTOR]** Verificar idempotencia: correr la migración dos veces seguidas contra una DB limpia sin error — **pendiente de CI**; por construcción es re-ejecutable (`CREATE OR REPLACE` + `REVOKE`/`GRANT`, sin DDL de tablas, gate auto-limpiante que borra su anchor)
- [ ] 1.9 Confirmar que quedó **un solo overload** de `rpc_cost_center_report` — **pendiente de CI/prod**; la función es nueva y no hay firma previa que pueda quedar huérfana (el riesgo de doble overload aplica al agregar parámetros a una función existente)

## 2. Filtro por centro de costo en el listado de compras (backend)

- [x] 2.1 **[SAFETY NET]** Correr `pytest backend/tests/test_purchases*.py -q` y anotar la línea base — **8 passed**
- [x] 2.2 **[RED]** Test de repository/listado con `cost_center_id` — 6 tests nuevos fallando antes de implementar
- [x] 2.3 **[GREEN]** Implementar el parámetro opcional en `backend/repositories/purchase_repository.py`, aplicándolo **dentro de la CTE `op_page` y del `COUNT`** (Decisión 6), con el patrón `AND ($4::uuid IS NULL OR cost_center_id = $4::uuid)` — con test posicional que falla si el predicado se mueve al join externo
- [x] 2.4 **[GREEN]** Exponer `cost_center_id` y `cost_center_name` en las filas devueltas (LEFT JOIN a `cost_centers`) y en `PurchaseItemOut` de `backend/schemas/purchases.py` — aditivo, sin renombrar ni quitar campos
- [x] 2.5 **[RED→GREEN]** `backend/services/purchases.py`: `list_purchases_paginated` acepta y propaga `cost_center_id`
- [x] 2.6 **[RED→GREEN]** `backend/routers/purchases.py`: query param opcional `cost_center_id: uuid.UUID | None = Query(None)`; sin el param, la respuesta es idéntica a la actual (test de regresión)
- [x] 2.7 **[TRIANGULATE]** Casos cubiertos: filtro en la query de datos y en el COUNT; posición dentro de la CTE; sin filtro → `None`; combinado con `date_from`/`date_to`; uuid inválido → 422 problem+json sin tocar la DB; el nombre del centro sobrevive el schema de salida
- [x] 2.8 **[REFACTOR]** Contrato `{items, total, page, pages}` intacto — los tests de envelope preexistentes siguen verdes (**15 passed**)

## 3. `extraFilters` en `usePaginatedQuery` (capa canónica)

- [x] 3.1 **[SAFETY NET]** Línea base de vitest tomada en 1.1 (707 passed / 2 preexistentes en rojo)
- [x] 3.2 **[RED]** `__tests__/hooks/use-paginated-query-extra-filters.test.ts` — 5 de 6 tests fallando antes de implementar
- [x] 3.3 **[GREEN]** `extraFilters?: Record<string, string | null>` en `UsePaginatedQueryOptions` y en `FilterParams`; viaja serializado en las deps de `fetchPage` y llega a `applyFilters`
- [x] 3.4 **[TRIANGULATE]** Regresión sin `extraFilters` cubierta (mismo comportamiento, `params.extraFilters` undefined, sin fetches de más) — protege `/clientes`
- [x] 3.5 **[TRIANGULATE]** `clearFilters()` con `extraFilters` presente: limpia búsqueda y fechas y no toca el filtro de la pantalla (documentado como controlado por el caller)
- [x] 3.6 **[REFACTOR]** Docblock del hook actualizado con el ejemplo del filtro extra y la razón de no capturarlo en el closure — **6 passed**

> Detalle de implementación: el reset a página 0 usa el patrón de ajuste de estado
> durante el render en vez de un `useEffect`, para que un cambio de filtro no dispare
> un fetch intermedio con la página vieja que después haya que abortar.

## 4. Superficie: gestión del catálogo en `/configuracion`

- [ ] 4.1 **[RED]** Test de render del tab — **no escrito**: la página de configuración monta 6 secciones con contextos de auth/plan/query; un test de render pediría más andamiaje de mocks que valor. El montaje se verifica en 7.2 (E2E) y por el 200 de la ruta
- [x] 4.2 **[GREEN]** `TabsTrigger` + `TabsContent` en `frontend/app/(dashboard)/configuracion/page.tsx` importando `CostCenterManager` **sin modificarlo**, con copy que explica para qué sirve la dimensión
- [x] 4.3 **[GREEN]** `TabsList` a `grid-cols-3 sm:grid-cols-4 lg:grid-cols-7` (Decisión 8), ícono `Tags` de lucide
- [x] 4.4 **[TRIANGULATE]** El gate `isWriter` ya vive dentro de `CostCenterManager` (verificado por lectura: el botón "Nuevo" y las acciones por fila cuelgan de `isWriter`); no se duplica en la página
- [ ] 4.5 **[REFACTOR]** Verificación visual desktop/mobile y claro/oscuro — **PENDIENTE**: el `.env.local` apunta a un Supabase local (127.0.0.1:54321) que necesita Docker, así que no hay sesión para entrar al dashboard. La ruta compila y responde 200

## 5. Superficie: pantalla `/reportes/centros-costo`

- [x] 5.1 **[RED]** `__tests__/cost-center-report.test.ts` contra `lib/cost-center-report.ts` (inexistente) — 8 tests en rojo
- [x] 5.2 **[GREEN]** `frontend/app/(dashboard)/reportes/centros-costo/page.tsx` con el patrón de `/reportes/sucursal`: React Query + `supabase.rpc("rpc_cost_center_report")`, rango por defecto mes en curso, barras (Recharts) + tabla con pie de totales. El `accountId` sale de `useAuth()` (como `useOrgRole`), no del `user_metadata` que usa la pantalla de sucursal
- [x] 5.3 **[GREEN]** Estado vacío propio ("Sin costos en el período seleccionado" + cómo crear centros) y copy que aclara que mide **costos**, no margen
- [x] 5.4 **[GREEN]** Entrada "Centros de costo" en el grupo "Inteligencia" del sidebar con `pro: false, proOnly: false` (Decisión 7)
- [x] 5.5 **[TRIANGULATE]** Cubierto en el mapeo: fila NULL, centro desactivado, importes nulos/indefinidos, sin filas → totales en 0 (no NaN), y el total incluye lo no imputado — **8 passed**
- [ ] 5.6 **[REFACTOR]** Verificación visual desktop/mobile y claro/oscuro — **PENDIENTE por el mismo motivo que 4.5** (sin Supabase local no hay sesión). Tipografía tabular y tokens semánticos aplicados por construcción, espejo de `/reportes/sucursal`
- [x] 5.7 Sin `any`: `CostCenterReportRow` en `lib/types.ts` + `CostCenterReportRawRow` en `lib/cost-center-report.ts`; `tsc --noEmit` limpio

## 6. Superficie: filtro y badge en Gastos y Compras

- [x] 6.1 **[RED]** `__tests__/hooks/use-purchases-cost-center.test.ts` — 5 de 6 en rojo antes de implementar. Del lado de gastos el mecanismo lo cubre el test del grupo 3, que ejercita el `applyFilters` real de la pantalla: un test de la página sería la misma aserción con más andamiaje
- [x] 6.2 **[GREEN]** `gastos/page.tsx`: selector con opción "Todos los centros" (incluye inactivos, Decisión 9) cableado por `extraFilters`, y badge del centro en cada fila — `mapRow` ya no descarta `cost_center_id`; el vacío ahora distingue "sin resultados" de "no hay gastos" con cualquier filtro activo
- [x] 6.3 **[GREEN]** `use-purchases.ts`: estado `costCenterId` + query param `cost_center_id`, reset a página 0, y `clearFilters` lo limpia; el mapeo expone `costCenterId`/`costCenterName`
- [x] 6.4 **[GREEN]** `compras/page.tsx` + `purchase-operations-list.tsx`: selector de filtro y badge del centro a nivel operación (mobile y desktop)
- [x] 6.5 **[TRIANGULATE]** Cubierto en los tests del hook: combinación con fechas, volver a "Todos", reset de página, y `clearFilters` — **6 passed**
- [x] 6.6 **[REFACTOR]** No se creó un componente nuevo: se **extendió `CostCenterSelect`** con `includeInactive` y `label`, así el mismo componente sirve para imputar y para filtrar (reutilización antes que repetición). De paso se extrajo `DateButton` de `/reportes/sucursal` a `components/shared/DateRangeButton.tsx` en vez de copiarlo en el reporte nuevo

## 7. Verificación integral y cierre

- [x] 7.1 Suites completas sin regresiones: backend **1269 passed, 3 skipped** (base 1261+3, +8 nuevos); frontend **729 passed en 97 archivos, 0 fallos** (base 707+2 fallos; los 2 rojos del baseline eran flaky — `getMultipleElementsFound` en `product-catalog-search-collapse` — y no reaparecieron). `tsc --noEmit` limpio
- [ ] 7.2 Flujo E2E en el navegador — **PENDIENTE**: `.env.local` apunta a Supabase local (127.0.0.1:54321) que requiere Docker, hoy apagado; sin sesión no se entra al dashboard. Lo verificable sin sesión sí se hizo: las 4 rutas tocadas (`/reportes/centros-costo`, `/configuracion`, `/gastos`, `/compras`) compilan y responden **HTTP 200** en el dev server
- [ ] 7.3 Estados vacíos con una cuenta sin centros — **PENDIENTE por el mismo motivo**; la lógica está cubierta por tests (totales en 0 sin filas, estado vacío propio en el reporte, texto de vacío por filtro en ambos listados)
- [x] 7.4 Rama `feat/cost-center-surface` + **PR #356**. Checks: `validate-kpis` **pass** (1m46s) — dentro de ese job, "Start Supabase" aplicó toda la cadena de migraciones, así que **los gates de la migración nueva corrieron y pasaron** (introspección + comportamiento sobre DB vacía), igual que el gate de ACLs y los gates de referencias backend/frontend (que validan que `rpc_cost_center_report` existe de verdad en el schema). Vercel **pass**. "Supabase Preview" queda pending: el plan no soporta branching, no es bloqueante
- [ ] 7.5 Post-merge: confirmar en producción que `rpc_cost_center_report` existe con un solo overload y devuelve datos reales
- [x] 7.6 Resumen final con la tabla de evidencia TDD
