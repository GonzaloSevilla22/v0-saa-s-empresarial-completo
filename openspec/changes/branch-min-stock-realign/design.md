## Context

El formulario de productos (`frontend/components/forms/product-form.tsx`, campo `minStock`) escribe `products.min_stock` vía el backend Python (`backend/repositories/product_repository.py`, `create()` líneas 35-68 y `update()` líneas 70-99). Ningún RPC escribe `branch_stock.min_stock` post-creación: `rpc_adjust_branch_stock`, `c21_apply_branch_stock_delta`, `rpc_transfer_stock` y `rpc_apply_product_stock_delta` tocan solo `quantity`. Las filas `branch_stock` se crean lazy vía deltas (`20260608000000_branch_stock.sql` líneas 317, 597, 840, 846, 955) con `INSERT (account_id, product_id, branch_id, quantity)` — **sin `min_stock` → nacen en 0**. Solo la reconciliación C-21 (`20260620000001:146-159`) sembró `min_stock` alguna vez.

Los consumidores de verdad de la alerta leen `branch_stock.min_stock`:
- Trigger `check_branch_low_stock` (`20260608000000_branch_stock.sql:983-1046`, recreado por `20260808000002_v3_notifications_producers.sql:166-240`): dispara solo `IF NEW.quantity < OLD.quantity AND NEW.min_stock > 0 AND NEW.quantity <= NEW.min_stock` → email_logs `low_branch_stock_alert` (dedupe 24h) + productor `StockBelowMinimum` a la outbox (notificación in-app).

En cambio, la vista `v_products_with_stock` (`20260620000001:205-260`, `security_invoker`, lista explícita de columnas) expone `p.min_stock` (línea ~241) y computa `stock` como subconsulta correlacionada `COALESCE((SELECT SUM(bs.quantity) FROM branch_stock bs WHERE bs.product_id = p.id), 0)`. Los consumidores de pantalla (`low-stock-alert.tsx` líneas 45-49/126, KPI `get_dashboard_critical_stock` en `20260623000001:92` con `WHERE stock <= min_stock`) leen esa vista. Resultado: la pantalla responde al valor editado, el email/campana no.

**Decisión PO (2026-07-04)**: "Stock Mínimo" del formulario aplica a **todas** las sucursales del producto (propagación uniforme). Edición fina por sucursal = follow-up, fuera de alcance.

**Constraints**: la columna `products.min_stock` NO se dropea en este change (legacy, como `products.stock`). El dual-write del importador (`rpc_bulk_upsert_products`, `20260623000001:353-571`) se conserva. Migración base estricta después de `20260808000003`; usar `20260809000001_branch_min_stock_realign.sql`. Prod = `gxdhpxvdjjkmxhdkkwyb`. Governance MEDIO.

## Goals / Non-Goals

**Goals:**
- Que editar/crear el `min_stock` del producto realinee el umbral real de la alerta (`branch_stock.min_stock`) de todas sus filas, en la misma transacción.
- Que los consumidores de pantalla (vista) y el trigger converjan en el mismo valor de umbral, sin cambios de frontend.
- Backfill idempotente que sincronice el estado histórico (`products.min_stock` → `branch_stock.min_stock`) con gate de 0 divergencias.
- Deprecar `products.min_stock` (COMMENT + KB) sin dropearla.

**Non-Goals:**
- DROP de `products.min_stock` (change destructivo posterior).
- Edición fina de `min_stock` por sucursal (UI per-branch).
- Tocar el dual-write del importador, el ledger `stock_movements`, o dinero/fiscal.
- Reescribir componentes de frontend (realineación pura de lectura al conservar el nombre de columna).

## Decisions

### (a) Mecanismo de propagación: RPC `rpc_set_product_min_stock` (SECURITY DEFINER + guard), NO UPDATE directo en el repo

**Decisión**: nueva RPC `rpc_set_product_min_stock(p_product_id uuid, p_min_stock int)` con `SECURITY DEFINER`, guard `is_account_writer(account_id)`, que hace `UPDATE branch_stock SET min_stock = p_min_stock WHERE product_id = p_product_id AND account_id = <cuenta del producto>`. El repositorio la invoca desde su transacción asyncpg tras escribir `products.min_stock`.

**Rationale**: todas las escrituras de stock del repositorio ya pasan por RPCs SECURITY DEFINER (`rpc_apply_product_stock_delta`, `rpc_adjust_branch_stock`) — es el patrón dominante y deliberado del proyecto (writer-gated por `is_account_writer`, no "SECURITY DEFINER para arreglar permisos"). Un RPC centraliza el guard, mantiene la consistencia con el resto del write-path de stock, y funciona con o sin RLS en el path del caller (JWT-passthrough). Alternativa descartada: UPDATE directo en la tx asyncpg (RLS org-based activa por JWT-passthrough) — rompería la simetría con las demás escrituras de stock, duplicaría la lógica de guard en Python, y dejaría el chequeo de writer fuera de la DB. Esqueleto de referencia: `rpc_adjust_branch_stock` (`20260608000000_branch_stock.sql:876-971`) — `auth.uid()` → `current_account_ids()` → `is_account_writer(account_id)` → validar → actuar; ERRCODEs `P0401`/`P403`/`P404`/`P400`.

**Interacción con filas branch_stock inexistentes**: las filas `branch_stock` de un producto pueden no existir aún (lazy). La RPC **actualiza las filas existentes**. Para que la fila recién creada de un producto nuevo reciba `min_stock`, `product_repository.create()` invoca la propagación **después** del delta de stock inicial (que crea la fila `branch_stock`). Así la primera fila queda sembrada. Filas creadas *más tarde* por otros deltas (compra en una sucursal sin fila previa) nacen en 0 hasta la próxima edición de `min_stock` que re-propague — se acepta este comportamiento y se documenta; NO se sobre-ingenierían los RPCs lazy (constraint de no over-engineering; el costo de tocar 5 INSERTs lazy no compensa dado que la próxima edición converge y el DROP de la columna legacy está diferido).

### (b) Vista: `min_stock` derivado de `branch_stock`, conservando el nombre de columna

**Decisión**: recrear `v_products_with_stock` `WITH (security_invoker = true)`, lista explícita de columnas, **reemplazando** la fuente de `min_stock`: en vez de `p.min_stock`, exponer `COALESCE((SELECT MAX(bs.min_stock) FROM branch_stock bs WHERE bs.product_id = p.id), 0) AS min_stock`. Subconsulta correlacionada que espeja exactamente la de `stock` (mínimo riesgo, mantiene `security_invoker`). Se conserva el **nombre** `min_stock`.

**Rationale**: con propagación "aplica a todas", el valor es uniforme entre filas, así que `MAX(bs.min_stock)` es seguro y determinista (equivale a cualquier fila). Conservar el nombre de columna hace que ningún consumidor de frontend cambie. Se reemplaza la fuente (no se mantiene `p.min_stock` en paralelo) para que **todos** los consumidores de pantalla se alineen con el trigger sin ambigüedad. Alternativa descartada: exponer la min_stock de la branch default en vez de `MAX` — requiere un JOIN a `branches`/lógica de default, más superficie de error; con uniformidad `MAX` es equivalente y más simple.

**KPI del dashboard — VERIFICADO (2026-07-04)**: `get_dashboard_critical_stock` (ambos overloads, definición vigente en `20260623000001:70-115`) y `rpc_dashboard_kpi_summary` leen `FROM public.v_products_with_stock WHERE ... stock <= min_stock` — es decir, leen de la **vista**. Al cambiar la fuente de `min_stock` en la vista, el KPI auto-alinea **sin tocar ninguna función**.

### (c) Backfill: dirección products→branch_stock, one-shot, idempotente, con gate

**Decisión**: `UPDATE branch_stock bs SET min_stock = p.min_stock FROM products p WHERE bs.product_id = p.id AND p.deleted_at IS NULL AND bs.min_stock IS DISTINCT FROM COALESCE(p.min_stock, 0)` dentro de la migración, seguido de un gate DO-block que aborta si queda alguna divergencia (`branch_stock.min_stock <> products.min_stock` para producto no borrado con fila existente). Espeja el estilo de la reconciliación C-21 (`20260620000001:146-159`).

**Rationale**: dirección products→branch_stock porque `products.min_stock` es lo que el usuario editó creyendo que funcionaba — es la intención real. La cláusula `IS DISTINCT FROM` hace el UPDATE idempotente (converge, no re-escribe filas ya sincronizadas). El gate garantiza convergencia observable. No cumulativo, no toca `quantity`.

### (d) Fuente de datos de `low-stock-alert.tsx`: sin cambios de frontend

**Decisión**: **realineación pura de lectura, sin reescritura de componentes**. Al conservar el nombre de columna `min_stock` en la vista, `use-products` sigue exponiendo `product.minStock` con el mismo shape, y `low-stock-alert.tsx` (que lee `product.minStock` / `product.stock`, severidad líneas 45-49/126) no requiere ningún cambio. Se confirma explícitamente: no se renombra nada, no hay touch points de frontend nuevos. Si en apply se detectara que el mapeo camelCase del hook rompe, se enumeraría el touch point; se espera que no.

## Risks / Trade-offs

- [Filas branch_stock lazy futuras nacen en `min_stock = 0`] → Mitigación: la propagación en `create()` siembra la primera fila; ediciones posteriores re-propagan a todas las filas existentes (incluidas las lazy nuevas). Documentado como comportamiento aceptado; el DROP diferido de la columna legacy no lo agrava.
- [Recrear el trigger `check_branch_low_stock` perdería el productor `StockBelowMinimum`] → Mitigación: este change **NO toca el trigger**. Si por alguna razón hubiera que recrearlo, hacerlo desde la versión viva `20260808000002_v3_notifications_producers.sql:166-240`, preservando el productor `StockBelowMinimum`. Gate de paridad en tasks (aserta que el trigger sigue emitiendo `StockBelowMinimum`).
- [`MAX(bs.min_stock)` divergiría si hubiera min_stock no uniforme entre filas] → Mitigación: la propagación garantiza uniformidad; el backfill deja 0 divergencias antes de que la vista cambie de fuente. La edición fina por sucursal (que rompería la uniformidad) está fuera de alcance.
- [El KPI `get_dashboard_critical_stock` podría leer `products` directamente] → Descartado por verificación (2026-07-04): ambos overloads y `rpc_dashboard_kpi_summary` leen `v_products_with_stock` (`20260623000001:70-115`) → auto-alinean sin cambio.
- [Regresión en performance de la vista por la nueva subconsulta correlacionada] → Mitigación: espeja el patrón de la subconsulta de `stock` ya en producción; `branch_stock(product_id)` ya está indexado (FK). Correr advisors tras recrear la vista.

## Migration Plan

1. Migración `20260809000001_branch_min_stock_realign.sql` (una sola tx donde sea posible): (a) crear `rpc_set_product_min_stock`; (b) backfill guarded + gate 0-divergencias; (c) recrear `v_products_with_stock` con `min_stock` derivado de `branch_stock`; (d) `COMMENT ON COLUMN products.min_stock IS 'DEPRECATED ...'`.
2. Wiring backend: `product_repository.create()` (llamar propagación tras el delta inicial) y `update()` (llamar propagación tras UPDATE de `products.min_stock`).
3. KB: actualizar RN-23 (`knowledge-base/05_reglas_de_negocio.md:108-109`) a `branch_stock`; nota de deprecación de `products.min_stock`.
4. Verificación: `pytest` del repo (create/update propagan a branch_stock); advisors de Supabase tras cambio de vista/RPC.
5. **Rollback**: `DROP FUNCTION rpc_set_product_min_stock`; recrear `v_products_with_stock` con `p.min_stock` como fuente (versión previa). El backfill no requiere rollback (converge; `branch_stock.min_stock` sigue siendo válido y el trigger ya lo usaba).

## Open Questions

- Ninguna bloqueante. (La duda sobre la fuente de `get_dashboard_critical_stock` quedó resuelta por verificación: lee la vista → auto-alinea; ver Decisión (b).) Follow-up registrado fuera de este change: edición fina de `min_stock` por sucursal (extendería `rpc_set_product_min_stock` con `p_branch_id` opcional).
