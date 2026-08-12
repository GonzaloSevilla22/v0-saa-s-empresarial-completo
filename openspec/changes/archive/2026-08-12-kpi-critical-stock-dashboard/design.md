## Context

**Estado actual (verificado 2026-08-11/12 sobre el código de `main`)**

| Pieza | Qué hace hoy |
|---|---|
| `frontend/app/(dashboard)/dashboard/page.tsx:44-51` | `getLowStockProducts()` filtra `products` (del contexto → `v_products_with_stock`, stock **agregado** Σ `branch_stock`) con predicado **inline**: `stockControlType !== "untracked" && !== "variant_only" && minStock > 0 && stock <= minStock`. Alimenta la tarjeta `KpiCard "Productos en alerta"` (`:188-193`, solo `lowStock.length`). |
| `branchId` (`:56`) | Se lee de `?branch=` y se usa en `get_dashboard_financials` (`:80`) y en `KpiSummaryBlock` (`:169`) — **nunca** en `lowStock` (que además se calcula en `:54`, antes de existir `branchId`). |
| `get_dashboard_critical_stock()` | Firma **0-args**, `SECURITY DEFINER`. Definición vigente en `supabase/migrations/20260823000001_restore_critical_stock_kpi_invariants.sql`: cuenta sobre `v_products_with_stock` con `user_id = auth.uid() AND min_stock > 0 AND stock <= min_stock`. **Cero callers** en frontend y backend (grep verificado). |
| `frontend/lib/product-stock.ts` | Fuente única del predicado en el cliente: `holdsOwnStock`, `getStockStatus`, `isBelowThreshold` (`minStock <= 0` → `sin-umbral` → nunca crítico). |
| `frontend/components/branches/BranchStockTable.tsx:72` | Predicado **inline gemelo** correcto por sucursal: `item.minStock > 0 && item.quantity <= item.minStock`. |
| `supabase/tests/test_kpis.sql` §3-§4 | Gate de CI (KPI Validation, con `ON_ERROR_STOP` desde PR #328): exige que exista `get_dashboard_critical_stock` con `identity_arguments = ''` y que **no exista ningún overload con argumentos** (defensa contra el overload IDOR `(p_user_id uuid)`). |

**El problema real**: hay tres definiciones divergentes de "producto en alerta" — la inline del Tablero (agregada, excluye `untracked`/`variant_only`), la de la RPC (agregada, **no** excluye nada y filtra por `user_id`) y la operativa correcta por sucursal (`BranchStockTable`, trigger `check_branch_low_stock` RN-23, notificaciones). El Tablero muestra la peor de las tres: un producto con 0 unidades en Sucursal A y 50 en B **no aparece**, y filtrar por sucursal no cambia el número.

**Restricciones**

- La integración GitHub de Supabase auto-aplica migraciones al mergear → **idempotencia obligatoria**; timestamp posterior a `20260907000001`.
- `CREATE OR REPLACE` agregando un parámetro crea un **segundo overload** (error 42725 en runtime) → `DROP FUNCTION IF EXISTS` de la firma vieja en el mismo archivo, antes del `CREATE` (ya pasó con `rpc_close_cash_session`; lo atrapó `validate-kpis`).
- `DROP + CREATE` **resetea ACLs** → re-aplicar `REVOKE ... FROM anon` / `GRANT EXECUTE TO authenticated` en el mismo archivo (regla del backlog de advisors 0028).
- Regla de proyecto "reutilización antes que repetición": prohibido reescribir `stock <= minStock` en un tercer lugar.
- Governance LOW/MEDIUM: KPI de lectura. Sin dinero, sin permisos, sin escritura de datos.

## Goals / Non-Goals

**Goals:**

1. La tarjeta "Productos en alerta" del Tablero refleja la definición **operativa por sucursal** de criticidad, y **respeta el selector `?branch=`** como el resto del Tablero.
2. Sin selector, un faltante **local** es visible (no se tapa con el stock de otra sucursal).
3. Una sola definición canónica consumida, no recalculada: se borra el predicado inline del Tablero y se reutiliza `lib/product-stock.ts` allí donde el cálculo es en cliente.
4. La RPC canónica y la UI cuentan **lo mismo** (mismas exclusiones, mismo scope de tenancy).
5. El gate de CI sigue prohibiendo el overload IDOR después del cambio de firma.

**Non-Goals:**

- **No** se cambia la semántica de `LowStockAlert` (`/stock`) ni de `StockSemaphore`: la pantalla de stock es de **catálogo** y su lectura agregada es intencional. (Si el PO quiere también ahí la vista por sucursal, es otro change.)
- **No** se toca el trigger `check_branch_low_stock` (RN-23) ni las notificaciones de stock bajo: ya son per-branch y correctos.
- **No** se agregan pantallas, rutas ni entradas de menú. **Sin superficie frontend nueva** (cambia el contenido de una tarjeta existente).
- **No** se deprecia `v_products_with_stock` ni se toca `products.min_stock` (ya DEPRECATED por `branch-min-stock-realign`).
- **No** se agrega drill-down (lista de productos críticos por sucursal) en el Tablero: la tarjeta sigue siendo un contador.

## Decisions

### D1 — El conteo se resuelve en el servidor, extendiendo `get_dashboard_critical_stock`

**Decisión**: nueva firma `public.get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL) RETURNS bigint`, que cuenta **sobre `branch_stock`** (la fila per-branch), no sobre `v_products_with_stock`.

**Por qué**: la RPC ya es el artefacto canónico del KPI (existe, tiene gate de CI, tiene guards de seguridad restaurados) pero **nadie la llamaba**; el Tablero recalculaba. Consumirla cierra exactamente el gap de "enforcement de consumo" que describe el plan de remediación. Además el conteo por sucursal sobre `branch_stock` es una agregación pura: mandarla al cliente significaría traer N filas por producto × sucursal solo para contar.

**Alternativas consideradas**:
- *(a) Calcular en cliente con un hook sobre `branch_stock`* (extendiendo `useBranchStock`): reutilizaría `isBelowThreshold` de forma más literal, pero transfiere todo el inventario al browser para mostrar un número, y `useBranchStock` requiere un `branchId` concreto (no cubre el caso "todas las sucursales"). Descartada por costo y por dejar la RPC canónica muerta otra vez.
- *(b) Vista materializada / nueva vista `v_critical_stock_by_branch`*: agrega superficie de schema para un solo consumidor. Descartada (YAGNI).
- *(c) Dejar la RPC 0-args y agregar una segunda función `get_dashboard_critical_stock_by_branch`*: dos funciones para un concepto = la duplicación que este change viene a borrar. Descartada.

### D2 — Semántica del agregado (sin selector): "crítico en **alguna** sucursal con umbral"

**Decisión**: con `p_branch_id IS NULL`, el resultado es `COUNT(DISTINCT product_id)` sobre las filas de `branch_stock` que cumplen `min_stock > 0 AND quantity <= min_stock`. Un producto crítico en 3 sucursales cuenta **1**.

**Por qué**: la tarjeta responde "¿cuántos productos necesito reponer?". Contar filas (producto × sucursal) inflaría el número frente al de una sola sucursal y rompería la comparación mental al filtrar. Contar productos distintos mantiene la unidad ("productos"), es monótono respecto del filtro (el conteo de una sucursal nunca supera al agregado) y hace **visible el faltante local**, que es el objetivo del change.

**Consecuencia explícita y aceptada**: el número puede **subir** tras el deploy respecto del actual (faltantes locales que el agregado tapaba). No es una regresión; se documenta en el proposal para que el PO no lo lea como bug.

**Alternativa considerada**: contar pares (producto, sucursal) — más informativo para logística, pero cambia la unidad del KPI y descuadra con el rótulo "Productos en alerta". Descartada.

### D3 — Exclusiones alineadas con `holdsOwnStock` (y soft delete)

**Decisión**: la RPC excluye `COALESCE(p.stock_control_type, 'tracked') NOT IN ('untracked', 'variant_only')` y `p.deleted_at IS NULL`.

**Por qué**: hoy la RPC no excluye nada y la tarjeta sí excluye los dos tipos → dos números distintos para el mismo concepto. `untracked` (servicios) nunca se repone y `variant_only` (padre de catálogo) tiene stock en sus hijos, así que ambos serían ruido rojo. El `COALESCE(...,'tracked')` replica el **fail-open** documentado en `lib/product-stock.ts`: un valor legacy desconocido cuenta como inventario real y nunca se oculta un producto por un enum inesperado.

**Consecuencia**: el número puede **bajar** por este eje. Neto con D2, el delta final es empírico y se verifica en prod tras el deploy.

### D4 — Tenancy por cuenta (`current_account_ids()`), no por `user_id`

**Decisión**: el filtro pasa a `account_id IN (SELECT current_account_ids())`, el mismo helper canónico que ya usa `get_dashboard_financials` desde `20260610000001`.

**Por qué**: `branch_stock` es account-scoped; `products.user_id` es el dueño original. Un **miembro** de la cuenta (multi-usuario, C-05/C-06) leía 0 con el filtro por `user_id`. Se conserva el guard `IF auth.uid() IS NULL THEN RAISE ... insufficient_privilege`, que es lo que impide el uso anónimo.

**Nota de seguridad**: `p_branch_id` es un parámetro **de filtro**, no de identidad — no reabre el vector IDOR que motivó dropear `(p_user_id uuid)`, porque el scope sigue derivándose de `auth.uid()` vía `current_account_ids()`. Una sucursal de otra cuenta simplemente devuelve 0. El gate de CI debe seguir prohibiendo `p_user_id` **por nombre/firma**, no prohibir "cualquier argumento".

### D5 — Frontend: hook dedicado + capa de acceso canónica, sin tocar el layout

**Decisión**: `frontend/lib/reporting/critical-stock.ts` (mapeo/llamada a la RPC, patrón de `lib/reporting/kpi-summary.ts`) + `frontend/hooks/data/use-critical-stock.ts` (React Query, `queryKey: ["criticalStock", user?.id, branchId]`, `staleTime` ~30-60 s alineado con la volatilidad del stock, `enabled: !!user`). El Tablero consume `useCriticalStock(branchId)` y **borra** `getLowStockProducts()`.

**Por qué**: es el patrón ya establecido en el repo para KPIs por RPC (`useDashboardKpiSummary`), incluye `branchId` en la queryKey (re-fetch automático al cambiar `?branch=`) y no arrastra la carga de `products` para un contador.

**Presentación**: la tarjeta usa el mismo `KpiCard` con el mismo icono/color; mientras carga muestra `"—"`, exactamente como las otras tres tarjetas (`loadingKpis`). Cero clases nuevas, cero tokens nuevos → la verificación desktop/mobile + tema claro/oscuro es una comprobación de no-regresión, no un rediseño.

### D6 — El predicado en cliente queda en un solo lugar

**Decisión**: `isBelowThreshold` / `holdsOwnStock` (`lib/product-stock.ts`) siguen siendo la fuente única en TS; se reemplaza el inline gemelo de `BranchStockTable.tsx:72` por `isBelowThreshold(item.quantity, item.minStock)` y se documenta en el docblock de `product-stock.ts` que la RPC nueva es su espejo SQL (como ya se documentan `check_branch_low_stock` y la versión vieja de `get_dashboard_critical_stock`).

**Por qué**: el Tablero deja de calcular (D1/D5), así que la reutilización se materializa donde el cálculo **sí** ocurre en cliente. Sin esto, el change borraría un duplicado y dejaría el otro vivo.

**Sobre el "duplicado" SQL↔TS**: el predicado existe necesariamente en ambos lados (la DB lo evalúa para el KPI y el trigger; el cliente para pintar filas). No es duplicación evitable sino **espejo documentado**; lo que se elimina es la duplicación *dentro* de cada lado.

### D7 — El gate de CI cambia de "sin argumentos" a "firma exacta esperada"

**Decisión**: `supabase/tests/test_kpis.sql` §3 pasa a exigir `identity_arguments = 'p_branch_id uuid'`, y §4 pasa de "ningún overload con argumentos" a "ninguna firma fuera de la allowlist `{p_branch_id uuid}`", conservando el mensaje de error que documenta el vector IDOR de `(p_user_id uuid)`.

**Por qué**: si no se actualiza, el gate falla en el PR (§4 detecta la firma nueva como "overload inesperado") — y relajarlo a "no chequear" perdería la defensa contra la reintroducción del overload vulnerable. La migración lleva además su propio bloque `DO $$` con los mismos invariantes (guard `min_stock > 0`, `auth.uid()`, `SECURITY DEFINER`, lectura de `branch_stock`), que corre en cada reset de CI.

## Risks / Trade-offs

- **[El KPI cambia de valor sin que nadie haya tocado el stock]** → Es el fix, no un bug. Mitigación: documentado en el proposal y en el resumen del PR; se mide el delta contra prod (conteo viejo vs nuevo) durante el apply y se reporta al PO junto con el merge.
- **[El gate `test_kpis.sql` rompe el PR si se olvida actualizarlo]** → Mitigación: es una task explícita del plan y corre en `validate-kpis` en cada PR, así que el olvido se detecta antes del merge, no en prod.
- **[Segundo overload por `CREATE OR REPLACE` con parámetro nuevo → 42725]** → Mitigación: `DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock();` **antes** del `CREATE` en el mismo archivo + gate `DO $$` que aborta si aparece más de una firma.
- **[ACLs reseteadas por el DROP → `anon` con EXECUTE]** → Mitigación: `REVOKE ALL FROM PUBLIC` + `REVOKE EXECUTE FROM anon` + `GRANT EXECUTE TO authenticated` re-aplicados en el mismo archivo (regla advisors 0028).
- **[Ventana entre el deploy del frontend y la aplicación de la migración]** → El frontend llamaría una firma inexistente y la tarjeta mostraría error/0. Mitigación: la RPC se llama con `p_branch_id` **explícito** (incluso `null`), Supabase resuelve por nombre de parámetro, y el hook degrada a `0` con `console.error` en vez de romper el Tablero. La ventana real es de segundos (el mismo merge dispara migración + deploy).
- **[Performance: `branch_stock` sin índice para el predicado]** → El filtro es `account_id` + `min_stock > 0` sobre una tabla chica (productos × sucursales, decenas a miles de filas por cuenta) con índices de tenancy ya existentes. Mitigación: se mide con `EXPLAIN` durante el apply; si aparece seq scan costoso, se agrega índice parcial `(account_id, branch_id) WHERE min_stock > 0` en la misma migración.
- **[Trade-off aceptado: la tarjeta ya no depende de `products` del contexto]** → Deja de actualizarse "gratis" cuando el contexto refresca productos; pasa a depender de su propia `staleTime` / invalidación. Es el mismo trade-off que ya asumen los KPIs financieros y el Bloque Resumen.

## Migration Plan

1. **Migración SQL** `supabase/migrations/2026091<X>000001_critical_stock_by_branch.sql` (timestamp > `20260907000001`), idempotente y en este orden:
   `DROP FUNCTION IF EXISTS public.get_dashboard_critical_stock();` → `CREATE OR REPLACE FUNCTION ... (p_branch_id uuid DEFAULT NULL)` → `REVOKE`/`GRANT` → gate `DO $$` (una sola firma, guards presentes).
2. **`supabase/tests/test_kpis.sql`**: actualizar §3/§4 a la firma nueva (allowlist), conservando la prohibición explícita de `(p_user_id uuid)`.
3. **Frontend**: capa de acceso + hook + consumo en el Tablero + dedup en `BranchStockTable` + regenerar `database.types.ts`.
4. **Verificación**: `pnpm -C frontend test` (suite completa verde), gate `validate-kpis` verde en el PR, y verificación manual del Tablero con y sin `?branch=` en desktop/mobile y tema claro/oscuro.
5. **Rollback**: revertir el PR. La migración inversa es simétrica y trivial (`DROP` de la firma nueva + `CREATE` de la 0-args tal como está en `20260823000001`), pero no se necesita salvo que el frontend viejo quede desplegado — no es el caso, ambos viajan en el mismo merge.

## Open Questions

- **OQ1 (PO, no bloqueante)**: ¿la tarjeta debería mostrar además el nombre de la sucursal filtrada (p. ej. "Productos en alerta · Sucursal Centro")? Este change **no** lo incluye (sin cambio de presentación); es un ajuste cosmético de 1 línea si el PO lo pide.
- **OQ2 (no bloqueante)**: `/stock` (`LowStockAlert`, `StockSemaphore`) sigue con lectura agregada de catálogo. Queda como decisión de producto si esa pantalla también debe volverse per-branch; hoy es Non-Goal explícito.
- **OQ3 (verificable en apply)**: magnitud del delta del KPI en prod (sube por D2, baja por D3). Se mide antes del merge y se reporta; no bloquea el diseño.
