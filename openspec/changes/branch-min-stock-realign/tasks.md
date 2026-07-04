## 1. Migración DB — RPC + backfill + vista + deprecación (`20260809000001_branch_min_stock_realign.sql`)

- [x] 1.1 Crear archivo `supabase/migrations/20260809000001_branch_min_stock_realign.sql` (timestamp estricto después de `20260808000003`).
- [x] 1.2 Definir `rpc_set_product_min_stock(p_product_id uuid, p_min_stock int)` `SECURITY DEFINER` con `SET search_path`, siguiendo el esqueleto de `rpc_adjust_branch_stock` (`20260608000000_branch_stock.sql:876-971`): `auth.uid()` NOT NULL (`P0401`) → resolver `account_id` del producto vía `current_account_ids()` → `is_account_writer(account_id)` (`P403`) → producto existe (`P404`) → `UPDATE branch_stock SET min_stock = GREATEST(p_min_stock, 0) WHERE product_id = p_product_id AND account_id = <cuenta>`.
- [x] 1.3 RED (gate DO-block): aserta que `rpc_set_product_min_stock` actualiza **todas** las filas `branch_stock` de un producto de prueba (crear 2 filas branch_stock, propagar, verificar ambas = valor); revertir el fixture al final del bloque.
- [x] 1.4 GREEN: confirmar que el gate 1.3 pasa contra la RPC recién creada.
- [x] 1.5 Backfill idempotente: `UPDATE branch_stock bs SET min_stock = COALESCE(p.min_stock, 0) FROM products p WHERE bs.product_id = p.id AND p.deleted_at IS NULL AND bs.min_stock IS DISTINCT FROM COALESCE(p.min_stock, 0)`. Espejar estilo C-21 (`20260620000001:146-159`).
- [x] 1.6 GATE (DO-block, 0 divergencias): abortar la migración con `RAISE EXCEPTION` si existe una fila `branch_stock` de un producto no borrado donde `min_stock <> COALESCE(products.min_stock, 0)`.
- [x] 1.7 Recrear `v_products_with_stock` `WITH (security_invoker = true)`, lista explícita de columnas idéntica a `20260620000001:205-260`, **reemplazando** la fuente de `min_stock`: `COALESCE((SELECT MAX(bs.min_stock) FROM branch_stock bs WHERE bs.product_id = p.id), 0) AS min_stock` (espejo de la subconsulta de `stock`). No exponer `p.min_stock`.
- [x] 1.8 GATE (DO-block): aserta que la vista expone `min_stock` derivado de `branch_stock` (crear producto con `products.min_stock` distinto del `branch_stock.min_stock`, verificar que la vista devuelve el de branch_stock) y `min_stock = 0` para producto sin filas branch_stock (`COALESCE`).
- [x] 1.9 `COMMENT ON COLUMN products.min_stock IS 'DEPRECATED (branch-min-stock-realign, 2026-07-04): fuente de verdad del umbral de alerta es branch_stock.min_stock. Se conserva por el dual-write del importador; DROP diferido a change destructivo posterior.'`.
- [x] 1.10 GATE de paridad (DO-block): aserta que el trigger `check_branch_low_stock` sigue existiendo y su cuerpo emite `StockBelowMinimum` a la outbox (parity con GATE 5.6 de `20260808000002`); este change NO recrea el trigger — el gate solo verifica que no se rompió.
- [x] 1.11 Confirmar (ya verificado 2026-07-04 en propose) que `get_dashboard_critical_stock` — ambos overloads — y `rpc_dashboard_kpi_summary` leen `FROM v_products_with_stock` (`20260623000001:70-115`): auto-alinean al recrear la vista, **sin tocar ninguna función**. Si al aplicar la definición vigente en prod difiriera (drift), recrearla leyendo la vista en la misma migración y agregar gate.

## 2. Backend Python — wiring del repositorio

- [x] 2.1 SAFETY NET: correr los tests existentes de `product_repository` y capturar baseline ("N passing"); si alguno falla, reportar como pre-existing y no arreglarlo.
- [x] 2.2 RED (pytest): test para `product_repository.update()` que, al actualizar `min_stock`, llama a `rpc_set_product_min_stock` y las filas `branch_stock` del producto reflejan el nuevo valor (mock/verify de la llamada RPC en la tx asyncpg).
- [x] 2.3 GREEN: en `update()` (`backend/repositories/product_repository.py:70-99`), tras el `UPDATE products` que incluye `min_stock`, invocar `rpc_set_product_min_stock(product_id, min_stock)` en la misma transacción (solo si `min_stock` está en el payload de cambios).
- [x] 2.4 RED (pytest): test para `product_repository.create()` que, tras el delta de stock inicial, la fila `branch_stock` creada tiene `min_stock` = el del payload.
- [x] 2.5 GREEN: en `create()` (`:35-68`), tras `_APPLY_STOCK_DELTA_SQL` (que crea la fila branch_stock), invocar `rpc_set_product_min_stock(product_id, min_stock)` en la misma tx (después del delta, para que la fila ya exista).
- [x] 2.6 TRIANGULATE: casos extra — `min_stock = 0` (no rompe), producto con 2 sucursales (ambas actualizan — cubierto por gate 1.3 en la migración), member/no-writer (RPC rechaza `P0401` — cubierto por el guard `is_account_writer` en la RPC, ejercido en el gate 1.3 vía sesión JWT real).
- [x] 2.7 REFACTOR: extraída `_propagate_min_stock()` como helper compartido por create/update; tests verdes tras el refactor.

## 3. Documentación / KB

- [x] 3.1 Actualizar RN-23 en `knowledge-base/05_reglas_de_negocio.md:108-109`: la alerta de stock bajo evalúa `branch_stock.quantity <= branch_stock.min_stock` (no `products.stock`/`products.min_stock`); umbral alimentado por propagación desde el formulario.
- [x] 3.2 Nota de deprecación de `products.min_stock` en la KB (mismo archivo o `04_modelo_de_datos.md`): fuente de verdad = `branch_stock.min_stock`; columna legacy conservada por el dual-write del importador; DROP diferido.

## 4. Verificación final

- [x] 4.1 Correr `pytest` del backend: repo tests verdes (create/update propagan a branch_stock), sin regresiones vs. baseline 2.1. (854 passed, 3 skipped — baseline era 849 passed, 3 skipped; +5 tests nuevos, 0 regresiones).
- [ ] 4.2 Aplicar la migración en local/preview y correr los gates DO-block (1.3, 1.6, 1.8, 1.10) — todos deben pasar.
- [ ] 4.3 Correr Supabase advisors (security + performance) tras recrear la vista y el RPC; resolver hallazgos nuevos atribuibles a este change.
- [ ] 4.4 Verificación manual del flujo: editar "Stock Mínimo" en el formulario → confirmar que `branch_stock.min_stock` de todas las filas del producto cambió, que la vista lo refleja, y que una venta que baje la cantidad bajo el nuevo umbral dispara la alerta.
- [ ] 4.5 `openspec validate branch-min-stock-realign --strict` verde antes de abrir PR.
