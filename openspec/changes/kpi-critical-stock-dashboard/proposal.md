## Why

La tarjeta **"Productos en alerta"** del Tablero cuenta stock **agregado** (Σ `branch_stock` vía `v_products_with_stock`) e **ignora el selector de sucursal** `?branch=`: una sucursal con 0 unidades queda invisible si otra tiene stock, y el número no cambia al filtrar por sucursal aunque el resto del Tablero (KPIs financieros, Bloque Resumen) sí lo respeta. Además el predicado de criticidad está **duplicado inline** en `dashboard/page.tsx:44-51` en vez de usar los helpers canónicos de `lib/product-stock.ts` (F4 del plan `docs/plan-remediacion-kpis-2026-08-11.md`, C-KPI-2, ✅ CONFIRMADO).

El canon operativo ya existe y está bien definido (`branch_stock.quantity <= branch_stock.min_stock` con `min_stock = 0` ≡ "sin umbral" ≡ nunca crítico, RN-23); lo que falta es **enforcement de consumo**: el Tablero recalcula por su cuenta en vez de consumir la definición canónica.

## What Changes

- **RPC `get_dashboard_critical_stock` pasa a ser consciente de sucursal**: nueva firma `get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL)` que cuenta **sobre `branch_stock`** (fila por sucursal), no sobre el agregado de la vista.
  - Con `p_branch_id` → criticidad **de esa sucursal**: `quantity <= min_stock AND min_stock > 0`.
  - Sin `p_branch_id` → **agregado consciente de sucursal**: `COUNT(DISTINCT product_id)` de los productos críticos en **alguna** sucursal con umbral. Un faltante local ya no se tapa con el stock de otra sucursal.
  - **BREAKING (contrato interno de la RPC)**: se dropea la firma 0-args en la misma migración (gotcha 42725: `CREATE OR REPLACE` agregando parámetro crearía un segundo overload). Cero callers hoy en frontend/backend (verificado por grep), por eso el impacto es nulo fuera del gate de CI.
- **Alineación de exclusiones con la UI**: la RPC deja de contar productos `untracked` / `variant_only` (no sostienen stock propio — espejo de `holdsOwnStock`) y productos soft-deleted (`deleted_at IS NOT NULL`). Hoy la RPC los contaba y la tarjeta no: dos números distintos para el mismo concepto.
- **Alineación de tenancy**: el filtro pasa de `user_id = auth.uid()` a `account_id IN (SELECT current_account_ids())`, el helper canónico que ya usa `get_dashboard_financials`. Hoy un **miembro** de una cuenta ajena al `user_id` dueño de los productos leería 0.
- **Frontend**: hook nuevo `useCriticalStock(branchId)` (React Query, mismo patrón que `useDashboardKpiSummary`) + capa de acceso canónica; la tarjeta "Productos en alerta" lo consume y **re-fetchea al cambiar `?branch=`**. Se **borra el predicado inline duplicado** (`getLowStockProducts`) de `dashboard/page.tsx`.
- **Reutilización**: `isBelowThreshold` / `holdsOwnStock` de `lib/product-stock.ts` quedan como fuente única del predicado en el cliente; se reemplaza también el predicado inline gemelo de `BranchStockTable.tsx` (`item.minStock > 0 && item.quantity <= item.minStock`) por `isBelowThreshold`, y se documenta el espejo SQL ↔ TS.
- **Gate de CI**: `supabase/tests/test_kpis.sql` §3/§4 valida hoy "existe la 0-args" y "no existe ningún overload con argumentos". Se actualiza para la firma nueva **conservando el guard anti-IDOR** (la firma `(p_user_id uuid)` sigue prohibida explícitamente).
- **Sin superficie frontend nueva**: no hay pantallas, rutas ni entradas de menú nuevas. Cambia el **contenido** de una tarjeta ya montada en `/dashboard` (`KpiCard` "Productos en alerta"), que pasa a respetar el `BranchFilter` que ya vive en esa misma cabecera. La presentación (layout, tokens, tipografía) no se toca; solo se agrega estado de carga coherente con las otras tarjetas.

## Capabilities

### New Capabilities

Ninguna. El comportamiento cae dentro de una capability existente.

### Modified Capabilities

- `branch-stock`: se agrega el requirement de **KPI de stock crítico por sucursal** (definición canónica sobre `branch_stock`, semántica del agregado "crítico en alguna sucursal", exclusión de productos sin stock propio y soft-deleted, scope por cuenta) y el requirement de **consumo del canon en el Tablero** (la tarjeta respeta `?branch=` y no recalcula el predicado).

## Impact

**Código afectado**

- `supabase/migrations/<nuevo timestamp > 20260907000001>_critical_stock_by_branch.sql` — DROP de la firma 0-args + CREATE de `(p_branch_id uuid DEFAULT NULL)` + REVOKE/GRANT re-aplicados (DROP+CREATE resetea ACLs) + gate `DO $$` de invariantes. Idempotente (la integración GitHub de Supabase la auto-aplica al mergear).
- `supabase/tests/test_kpis.sql` — asserts de firma actualizados (nueva firma esperada; `p_user_id` sigue prohibida).
- `frontend/app/(dashboard)/dashboard/page.tsx` — se borra `getLowStockProducts()`; la tarjeta consume el hook nuevo.
- `frontend/hooks/data/use-critical-stock.ts` (nuevo) + capa de acceso en `frontend/lib/reporting/` (patrón `kpi-summary.ts`).
- `frontend/components/branches/BranchStockTable.tsx` — predicado inline → `isBelowThreshold`.
- `frontend/lib/product-stock.ts` — solo documentación del espejo con la RPC nueva (sin cambio de comportamiento).
- `frontend/lib/database.types.ts` — regenerar la firma de la RPC.

**No afectado (fuera de alcance, verificado)**

- `LowStockAlert` de `/stock` y `StockSemaphore` siguen operando sobre el catálogo agregado (esa pantalla es de catálogo, no de sucursal); no se cambia su semántica en este change.
- Trigger `check_branch_low_stock` (RN-23) y notificaciones de stock bajo: ya son per-branch y correctos; se usan como referencia, no se tocan.

**Riesgos**

- El número de la tarjeta **puede subir** tras el deploy (faltantes locales antes ocultos) o **bajar** (productos `untracked`/`variant_only`/soft-deleted que la RPC contaba). Es la corrección buscada, no una regresión — se documenta para que el PO no lo lea como bug.
- Governance: LOW/MEDIUM (KPI de lectura, sin dinero ni permisos). La migración toca una función `SECURITY DEFINER` → se re-aplican ACLs explícitas y se conserva el guard de autenticación.
