## Why

El campo "Stock Mínimo" del formulario de productos escribe `products.min_stock`, pero **todos** los consumidores reales de alertas de stock bajo (trigger `check_branch_low_stock` → email + productor `StockBelowMinimum` a la outbox → campana in-app) leen `branch_stock.min_stock`, que nace congelado en 0 y no se actualiza jamás tras la creación. Resultado: el usuario edita el mínimo, las alertas en pantalla (que leen `products.min_stock` vía la vista) responden, pero el email y la campana disparan sobre un valor viejo y frozen. Es una divergencia doble (write path y read path) que hace que las alertas de stock bajo — una feature en producción — mientan.

## What Changes

- **Write path**: al crear o editar un producto con `min_stock`, propagar el valor a `branch_stock.min_stock` de **todas** las filas de ese producto, en la misma transacción. Semántica adoptada por el PO (2026-07-04): "Stock Mínimo" del formulario aplica a **todas** las sucursales donde el producto existe (edición fina por sucursal queda fuera de alcance).
- **Read path**: realinear la vista `v_products_with_stock` para que el `min_stock` expuesto derive de `branch_stock` (no de `products.min_stock`), conservando el **nombre** de columna `min_stock` para no tocar frontend/hooks/tipos. Con esto `low-stock-alert.tsx` y el KPI `get_dashboard_critical_stock` quedan consistentes con el trigger.
- **Backfill one-shot** (idempotente, con gate de 0 divergencias): sincronizar `branch_stock.min_stock` desde el `products.min_stock` actual (dirección products→branch_stock: es lo que el usuario editó creyendo que funcionaba).
- **Deprecación** de `products.min_stock`: SQL `COMMENT` + nota en la KB. El DROP **NO** está en este change (columna legacy vive hasta un change destructivo posterior, como su hermana `products.stock`). El dual-write del importador (`rpc_bulk_upsert_products`) **se conserva** tal cual.

## Capabilities

### New Capabilities
<!-- Ninguna. Todo el comportamiento nuevo cae en capabilities existentes. -->

### Modified Capabilities
- `branch-stock`: se agrega el requisito de **propagación** de `min_stock` del producto a todas sus filas `branch_stock` (write path) y el **backfill** de reconciliación `products.min_stock` → `branch_stock.min_stock`. El requisito "Alerta de stock bajo por sucursal" queda reafirmado como el consumidor de verdad.
- `inventory-single-ledger`: el requisito "Vista de compatibilidad de stock total con security_invoker" se amplía para que `v_products_with_stock` exponga `min_stock` derivado de `branch_stock` (no de `products.min_stock`), manteniendo el nombre de columna y `security_invoker`.

## Impact

- **DB (migración `20260809000001_branch_min_stock_realign.sql`)**: nueva RPC de propagación `rpc_set_product_min_stock` (SECURITY DEFINER + guard `is_account_writer`); recreación de `v_products_with_stock` (`security_invoker = true`); backfill guarded + idempotente; `COMMENT` de deprecación en `products.min_stock`. Sin cambios en el trigger `check_branch_low_stock` salvo que se preserve intacto el productor `StockBelowMinimum` si hubiera que recrearlo (no se toca en este change).
- **Backend Python (`backend/repositories/product_repository.py`)**: `create()` y `update()` llaman a la propagación (RPC) tras escribir/actualizar `products.min_stock`, en la misma transacción asyncpg. `create()` la invoca **después** del delta de stock inicial para que la fila `branch_stock` recién creada reciba `min_stock`.
- **Frontend**: **sin cambios de componentes** — `low-stock-alert.tsx` ya lee `product.minStock` desde el hook (que consume la vista); al conservar el nombre de columna `min_stock` la realineación es puramente de lectura.
- **KB**: `knowledge-base/05_reglas_de_negocio.md` (RN-23, hoy stale: describe la alerta contra `products.stock`/`products.min_stock`) se actualiza a `branch_stock`; nota de deprecación de `products.min_stock`.
- **No afecta**: `rpc_bulk_upsert_products` (dual-write se conserva), `rpc_adjust_branch_stock`, `rpc_transfer_stock`, `rpc_apply_product_stock_delta` (siguen tocando solo `quantity`), el ledger `stock_movements`, dinero/fiscal. Governance: **MEDIO** (lógica de negocio de stock; aditivo + realineación de lectura).
