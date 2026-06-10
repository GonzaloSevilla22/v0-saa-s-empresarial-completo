# Tasks — v20-sale-items-migration (C-20)

> Governance ALTO. **No escribir código hasta la aprobación explícita del PO de esta propuesta.** El Grupo 9 (DROP del header plano) es un checkpoint separado que requiere su propia aprobación del PO ("dale"), igual que C-19.
> Migraciones SQL: SIEMPRE `npx supabase db push` (CLI). NUNCA el MCP `apply_migration`. Proyecto prod: `gxdhpxvdjjkmxhdkkwyb`.
> TDD estricto en apply: cada comportamiento test-first (pytest + pytest-asyncio en backend; tests de hook según el patrón existente del frontend).

## 0. Pre-flight y decisiones del PO

- [x] 0.1 PO resolvió OQs (2026-06-10): OQ1=POR CUENTA (tabla `account_feature_flags`), OQ2=DOBLE ESCRITURA, OQ3=CONSERVAR. Actualizado en design.md.
- [x] 0.2 Baseline de tests del backend capturado: **60 passing** (3.20s). No hay fallos pre-existentes.
- [x] 0.3 Verificar en prod (read-only) los conteos de referencia: `sales` con `product_id`, `purchases` con `product_id`, filas de `sale_items`/`purchase_items` con `variant_id NOT NULL`

## 1. Schema de los ítems (Migración A — no destructiva)

- [x] 1.1 Migración SQL: `ALTER TABLE sale_items` → `variant_id` DROP NOT NULL; ADD COLUMN `product_id uuid REFERENCES products(id)`, `account_id uuid`, `unit_id uuid REFERENCES units_of_measure(id)`; `ALTER COLUMN quantity TYPE numeric(15,4)`
- [x] 1.2 Migración SQL: mismos `ALTER` en `purchase_items`
- [x] 1.3 Índice único parcial `CREATE UNIQUE INDEX ... ON sale_items (sale_id, product_id) WHERE product_id IS NOT NULL` (idempotencia del backfill; no choca con filas de variantes que tienen `product_id IS NULL`); equivalente en `purchase_items (purchase_id, product_id)`
- [x] 1.4 Índices para los JOINs/RLS: `(sale_id)`, `(account_id)` en `sale_items`; `(purchase_id)`, `(account_id)` en `purchase_items`
- [x] 1.5 RLS: políticas por `account_id` en `sale_items`/`purchase_items` (espejo de las de `sales`/`purchases`, usando `current_account_ids()`); habilitar RLS si no estaba
- [ ] 1.6 Correr `get_advisors` (security + performance) tras la migración; resolver hallazgos

## 2. Backfill idempotente

- [x] 2.1 Test (SQL/pytest): tras backfill, `count(sale_items WHERE product_id NOT NULL) == count(sales WHERE product_id NOT NULL)`; re-ejecutar no duplica
- [x] 2.2 Test: las 2 ventas con `quantity` fraccional quedan con `quantity` exacto (no truncado) en `sale_items`
- [x] 2.3 Test: las 23+18 filas de variantes preexistentes (`product_id IS NULL`) quedan intactas
- [x] 2.4 Backfill `sale_items` desde `sales` (`INSERT ... SELECT ... WHERE product_id IS NOT NULL AND NOT EXISTS (...)`), mapeando `price=amount`, `subtotal=COALESCE(total, amount*quantity)`, `variant_id=NULL`, copiando `account_id`/`unit_id`
- [x] 2.5 Backfill simétrico `purchase_items` desde `purchases`
- [x] 2.6 Query de validación post-backfill (ventas y compras) — incluir en la migración como assertion o como check manual documentado

## 3. RPC versionado de ventas + feature flag

- [x] 3.1 Test (pytest): con flag `on`, crear venta → existe fila `sale_items` con `sale_id`=venta, `product_id` correcto, `variant_id NULL`
- [x] 3.2 Test: idempotencia preservada en v2 (misma `idempotency_key` → 1 venta, 1 `sale_items`, segunda llamada replay sin tocar stock)
- [x] 3.3 Test: con flag `off`, el camino legacy se ejecuta (no rompe nada existente)
- [x] 3.4 Migración SQL: `rpc_create_sale_operation_v2(...)` (misma firma de 7 args) que inserta header + `sale_items` en la misma transacción; preserva normalización de unidad, guards de variante, stock y `stock_movements` (DEC-07 intacto). Decisión OQ2: escribe columnas flat en paralelo (doble escritura)
- [x] 3.5 Migración SQL: wrapper `rpc_create_sale_operation(...)` que despacha a v2 o legacy según `account_feature_flags(account_id, 'sale_items_rpc_v2')`; `DROP FUNCTION IF EXISTS` de firma 7-args previa; `REVOKE`/`GRANT` explícitos
- [x] 3.6 Flag default OFF por cuenta; cutover: `INSERT INTO account_feature_flags VALUES ('<account_id>', 'sale_items_rpc_v2', true)`

## 4. RPC versionado de compras

- [x] 4.1 Test (pytest): con flag `on`, crear compra → fila `purchase_items` correcta
- [x] 4.2 Test: idempotencia y stock preservados en v2 de compras
- [x] 4.3 Migración SQL: `rpc_create_purchase_operation_v2(...)` + wrapper con el mismo flag `sale_items_rpc_v2` (conmutan juntos, simplicidad operacional)

## 5. Vista de compatibilidad

- [ ] 5.1 Test: un usuario solo ve sus propias ventas vía `v_sales_flat` (RLS respetada por `security_invoker`)
- [ ] 5.2 Test: para una venta backfilleada, `v_sales_flat.product_id/amount/quantity/total` provienen del `sale_items`
- [ ] 5.3 Migración SQL: `CREATE VIEW v_sales_flat WITH (security_invoker = true) AS SELECT ... JOIN sale_items`; idem `v_purchases_flat`
- [ ] 5.4 Correr `get_advisors` y confirmar que las vistas no aparecen como `security_definer`/sin invoker

## 6. Migrar lecturas del backend (repositories)

- [ ] 6.1 Test (pytest): `sales_repository.list_paginated_by_operation` devuelve `product_id/quantity/amount` desde `JOIN sale_items` (incluida una venta legacy backfilleada)
- [ ] 6.2 Reescribir el SELECT paginado de `sales_repository.py` para `JOIN sale_items si ON si.sale_id = s.id`; alias `si.price AS amount`, `si.subtotal AS total`
- [ ] 6.3 Test + reescritura simétrica en `purchase_repository.py` (incluye revisar `delete_by_id`/`delete_by_operation`: leen `product_id` para revertir stock → tomar el `product_id` del ítem)
- [ ] 6.4 Verificar que los schemas Pydantic (`SaleOut`/`PurchaseOut`) siguen exponiendo los mismos campos al frontend (sin cambio de contrato del API en este paso)

## 7. Migrar lecturas del frontend (hooks)

- [ ] 7.1 Test del hook `use-sales` (patrón existente): `mapSale` produce `productId/quantity/unitPrice` correctos con el nuevo shape del API
- [ ] 7.2 Ajustar `frontend/hooks/data/use-sales.ts` si el shape del row del API cambió (idealmente NO, porque el repo mantiene los mismos nombres de columna)
- [ ] 7.3 Test + ajuste simétrico de `frontend/hooks/data/use-purchases.ts`

## 8. Migrar Edge Functions de IA

- [ ] 8.1 `ai-insights/index.ts`: cambiar `.from('sales').select('amount, quantity, ... product_id ...')` a `.from('v_sales_flat')` (mismos nombres de columna; cambio mínimo) — líneas ~98–142
- [ ] 8.2 `ai-precio/index.ts`: cambiar `.from('sales').select('amount, quantity, date').eq('product_id', ...)` a `.from('v_sales_flat')` — líneas ~198–248
- [ ] 8.3 Validar cada EF en preview (corrida real); deploy de las EFs

## 9. Cutover de ventas y compras (operacional)

- [ ] 9.1 Smoke test en prod con cuenta de prueba: flag `on`, crear venta y compra, verificar filas en `sale_items`/`purchase_items` y que el dashboard de margen por canal sigue correcto
- [ ] 9.2 `app.sale_items_rpc_v2 = 'on'` global; período de observación (logs, advisors, ningún error en el hot path)
- [ ] 9.3 Actualizar el RPC `rpc_dashboard_channel_margin` para que el COGS lea producto/cantidad desde `sale_items`/`v_sales_flat` (spec `sales-channel` MODIFIED) — con su test

## 10. ⚠️ CHECKPOINT PO — DROP del header plano (Migración B, BREAKING)

> **Requiere aprobación explícita del PO antes de aplicar.** No incluir en el primer push.

- [ ] 10.1 Pre-DROP guard: query que falla si alguna función/vista fuera de la lista esperada referencia `sales.product_id/amount/quantity/total/unit_id` o equivalentes de `purchases` (`pg_get_functiondef`, `pg_views`)
- [ ] 10.2 Confirmar v2 `on` estable y vista de compat en uso; aprobación del PO
- [ ] 10.3 Migración B: `ALTER TABLE sales DROP COLUMN product_id, amount, quantity, total, unit_id` (los que correspondan); equivalentes en `purchases`. Incluir en la migración el SQL inverso de rollback documentado (ADD COLUMN + backfill desde el ítem), como hizo C-19
- [ ] 10.4 v2 deja de escribir columnas flat (si OQ2 = doble escritura); ajustar `v_sales_flat`/`v_purchases_flat` si hace falta (la vista sobrevive: se computa desde el ítem)
- [ ] 10.5 Correr `get_advisors`; regenerar `database.types.ts` (`supabase gen types typescript`) con el nuevo esquema
- [ ] 10.6 Decisión OQ3: retirar o conservar `v_sales_flat`/`v_purchases_flat`

## 11. Cierre

- [ ] 11.1 Suite completa verde (backend pytest + tests de hooks)
- [ ] 11.2 PR(s) a `main` (nunca commit directo a main); el PO mergea
- [ ] 11.3 `/opsx:archive v20-sale-items-migration` → sincroniza specs `sale-line-items` y `sales-channel`
- [ ] 11.4 Marcar C-20 `[x]` en CHANGES.md y actualizar el estado de Fase 6 en CLAUDE.md/AGENTS.md
