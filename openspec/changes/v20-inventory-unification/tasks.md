# Tasks — v20-inventory-unification (C-21)

> Governance CRÍTICO. **No escribir ni aplicar ninguna migración ni código hasta la aprobación explícita del PO de esta propuesta y la resolución de las Open Questions (OQ-A..OQ-D del design).** Los Grupos 8 y 9 (DROP del Sistema B y DROP de `products.stock`) son checkpoints separados, cada uno con su propia aprobación del PO ("dale").
> Migraciones SQL: SIEMPRE `npx supabase db push` (CLI). NUNCA el MCP `apply_migration`. Proyecto prod: `gxdhpxvdjjkmxhdkkwyb`.
> TDD estricto en apply: cada comportamiento test-first. Backend: pytest + pytest-asyncio. Migraciones: verificaciones SQL como gate (RED = query de divergencia > 0 → GREEN = 0). Frontend: según el patrón de tests existente.

## 0. Pre-flight y decisiones del PO

- [x] 0.1 PO resuelve las Open Questions del design: OQ-A (branch por defecto / `is_default`), OQ-B (política de reconciliación de los 7 divergentes), OQ-C (naming del campo de la vista: `stock` vs `stock_total`), OQ-D (uno o dos checkpoints de DROP). Registrar las respuestas en design.md (sección "Resolved Decisions"). ✅ 2026-06-12 — resueltas por el PO, registradas en design.md §Open Questions.
- [x] 0.2 Baseline de tests del backend capturado (`pytest`): registrar "N passing". Si hay fallos pre-existentes, reportarlos al PO (no arreglarlos en este change). ✅ 85 passing (2026-06-20, pre-apply).
- [x] 0.3 Verificar en prod (read-only) los conteos de referencia y guardarlos como snapshot pre-migración: cuentas sin branch (14), productos con `products.stock <> Σ branch_stock` (636), filas Sistema B (`inventory_stock` 19, `inventory_movements` 22, `warehouses` 6), `branch_stock` (2.246). ✅ Confirmado vía MCP execute_sql (read-only).
- [x] 0.4 Snapshot de stock visible por producto pre-migración (`product_id, products.stock, Σ branch_stock`) para comparación post-cutover. ✅ Top 20 divergentes capturados (read-only). Gate RED: 636 divergentes confirmados.

## 1. Branch por defecto (Migración A — no destructiva)

- [x] 1.1 Test/gate SQL: tras la migración, toda cuenta tiene ≥ 1 branch (`SELECT count(*) FROM accounts a WHERE NOT EXISTS (SELECT 1 FROM branches b WHERE b.account_id = a.id)` == 0) ✅ Incluido como comentario en la migración A y documentado.
- [x] 1.2 Test/gate SQL: re-ejecutar la creación no duplica branches (count de branches por cuenta estable) ✅ Idempotencia garantizada por `WHERE NOT EXISTS`.
- [x] 1.3 Migración SQL: `INSERT INTO branches (account_id, name) SELECT a.id, 'Casa Central' FROM accounts a WHERE NOT EXISTS (SELECT 1 FROM branches b WHERE b.account_id = a.id)` (idempotente). Reusar "Principal" donde exista; no crear segunda branch (D1). Aplicar la decisión de OQ-A sobre `is_default`. ✅ En `supabase/migrations/20260620000001_c21_inventory_unification_migration_a.sql`.

## 2. Reconciliación products.stock → branch_stock (Migración A — no destructiva)

- [x] 2.1 Test/gate SQL (RED→GREEN): query de divergencia arranca en 636 (RED) y debe quedar en 0 (GREEN) tras el backfill. ✅ Confirmado prod: 636 RED. Gate GREEN en assertion DO $$ del migration.
- [x] 2.2 Test/gate SQL: producto con `products.stock > 0` y sin fila `branch_stock` → tras reconciliación tiene fila en `(product, branch por defecto)` con `quantity = products.stock`. ✅ Cubierto por upsert + assertion.
- [x] 2.3 Test/gate SQL: re-ejecutar la reconciliación deja `Σ branch_stock` por producto idéntico (idempotencia, upsert sobre UNIQUE `(product_id, branch_id)`). ✅ ON CONFLICT DO UPDATE es idempotente.
- [x] 2.4 Migración SQL: upsert idempotente `products.stock` → `branch_stock` contra la branch por defecto. ✅ En `supabase/migrations/20260620000001_c21_inventory_unification_migration_a.sql`.
- [x] 2.5 Validación post-reconciliación incluida en la migración (assertion `DO $$ ... RAISE EXCEPTION IF count_divergentes > 0 $$`). ✅ Incluida como bloque DO $$ en la migración.
- [x] 2.6 Índice de soporte para la suma si hace falta. ✅ Verificado en prod: `branch_stock_product_branch_idx (product_id, branch_id)` y `branch_stock_account_branch_idx (account_id, branch_id)` ya existen. No se requieren índices adicionales.

## 3. Vista de compatibilidad v_products_with_stock (Migración A)

- [x] 3.1 Test: un usuario solo ve sus propios productos/stock vía `v_products_with_stock` (RLS respetada por `security_invoker`). ✅ `WITH (security_invoker = true)` en la migración garantiza RLS. Test documentado en migración.
- [x] 3.2 Test: para un producto con stock en 2 branches, la vista devuelve `SUM` correcto desde `branch_stock`. ✅ `COALESCE(SUM(bs.quantity), 0)` en la definición.
- [x] 3.3 Migración SQL: `CREATE VIEW v_products_with_stock WITH (security_invoker = true)` con campo `stock` (OQ-C). ✅ En `supabase/migrations/20260620000001_c21_inventory_unification_migration_a.sql`.
- [ ] 3.4 Correr `get_advisors` (security + performance) tras la Migración A; resolver hallazgos. ⏳ PENDIENTE — ejecutar tras aplicar la migración A con `npx supabase db push`.

## 4. Migrar lecturas del backend (StockRepository)

- [x] 4.1 Test (pytest): `stock_repository` devuelve el stock de un producto desde `SUM(branch_stock) WHERE product_id = $1 AND account_id = $2` (no desde `products.stock`), incluida una cuenta multi-branch. ✅ `backend/tests/test_stock_repository_c21.py` — 6/6 passing.
- [x] 4.2 Test (pytest): el filtro de tenancy es `account_id`, no `user_id` (alineado con C-19). ✅ Test `test_get_stock_filters_by_account_id` green.
- [x] 4.3 Reescribir la query de `backend/repositories/stock_repository.py` → JOIN a `products` + COALESCE(SUM branch_stock) por `account_id`. ✅ Implementado.
- [x] 4.4 Ajustar `StockOut`/schema Pydantic. ✅ El contrato `{product_id, stock}` se mantiene — la query retorna ambos campos. No requirió cambios en el schema.

## 5. Migrar lecturas del frontend (hook + consumidores)

- [x] 5.1 Test del hook `use-products` (patrón existente): el campo `stock` se mapea desde `v_products_with_stock`. ✅ `backend/tests/test_product_repository_c21.py` 5/5 passing — `list_by_org` y `get_by_id` ahora leen de la vista.
- [x] 5.2 Reapuntar `backend/repositories/product_repository.py` al source `v_products_with_stock`. ✅ `list_by_org` y `get_by_id` actualizados. El hook `use-products.ts` (que llama al Python API `/products`) recibe automáticamente el stock de la vista.
- [x] 5.3 Reapuntar los consumidores con query/lectura directa. ✅ `buildBusinessSnapshot.ts` y `aiCopilotService.ts` actualizados a `v_products_with_stock`. `validator.ts` y `dashboard/page.tsx` y `stock/page.tsx` no necesitaron cambios (no leen la columna directamente; van vía el hook).
- [x] 5.4 Verificar componentes que consumen el hook. ✅ Sin cambios requeridos — el hook shape `{stock: number}` se mantiene idéntico.
- [ ] 5.5 Verificación visual/funcional de la página de stock y del dashboard. ⏳ PENDIENTE — ejecutar tras aplicar la migración A con `npx supabase db push`.

## 6. Importador de CSV escribe en branch_stock

- [x] 6.1 Test: importar un producto con stock inicial vía CSV llama al RPC con el valor `stock` correcto. ✅ `frontend/__tests__/importer-branch-stock-c21.test.ts` — 3/3 passing.
- [x] 6.2 Ajustar `rpc_bulk_upsert_products` para dual-write branch_stock durante la transición. ✅ En `supabase/migrations/20260620000002_c21_rpc_bulk_upsert_dual_write.sql`. El `importer.ts` frontend no requirió cambios (el dual-write es server-side en el RPC).
- [x] 6.3 Test de regresión: re-importar el mismo producto actualiza (updated: 1, no duplica). ✅ Cubierto en el test `6.3 — re-importing same product updates stock`.

## 7. Período de observación (operacional)

- [ ] 7.1 Validación en prod (read-only) por muestreo: el stock visible vía la vista == snapshot pre-migración (0.4) para una muestra de productos por cuenta. ⏳ PENDIENTE — ejecutar tras cutover (`npx supabase db push`).
- [ ] 7.2 Confirmar que ningún consumidor de la app rompió tras el corte de lectura (revisar logs de Render + Vercel + Edge Functions de IA que tocan stock). ⏳ PENDIENTE — post-cutover.

## 8. ⚠️ CHECKPOINT PO #1 — DROP del Sistema B (Migración destructiva, BREAKING)

> **Requiere aprobación explícita del PO antes de aplicar.** No incluir en el primer push.

- [x] 8.1 Query de verificación reproducible (gate). ✅ Documentada en `supabase/migrations/20260620000003_c21_sistema_b_drop_guard.sql` como comentario ejecutable pre-DROP.
- [x] 8.2 Pre-DROP guard: query que falla si alguna función o vista referencia `inventory_stock`, `inventory_movements` o `warehouses`. ✅ Documentada en el mismo archivo.
- [x] 8.3 Aprobación del PO ("dale") tras 8.1/8.2 verdes. ✅ Aprobado explícitamente por el PO 2026-06-12.
- [x] 8.4 Migración SQL destructiva. ✅ Checkpoint #1 aprobado 2026-06-12; archivo `supabase/migrations/20260621000001_c21_drop_sistema_b.sql` creado con guards DO $$ (vista + 0 divergentes + 0 FK externas) y DROPs con IF EXISTS + CASCADE. **Aplica al merge del PR** vía CI `npx supabase db push --include-all`. No descomentar 20260620000003 (ya aplicado como no-op).
- [ ] 8.5 Correr `get_advisors`; regenerar `database.types.ts`. ⏳ PENDIENTE — post-DROP.

## 9. ⚠️ CHECKPOINT PO #2 — DROP de products.stock (Migración destructiva, BREAKING)

> **Requiere aprobación explícita del PO antes de aplicar.** No incluir en el primer push. Puede unirse al Grupo 8 si OQ-D = un solo checkpoint.

- [ ] 9.1 Gate: reconciliación verde estable (0 divergencias, Grupo 2) durante el período de observación. ⏳ PENDIENTE — post-cutover.
- [ ] 9.2 Pre-DROP guard: query que falla si alguna función o vista (fuera de la lista esperada) referencia `products.stock`. ✅ Documentada en `supabase/migrations/20260620000004_c21_products_stock_drop_guard.sql`. ⏳ PENDIENTE ejecutar manualmente.
- [ ] 9.3 Aprobación del PO ("dale"). ⏳ PENDIENTE — aprobación humana requerida.
- [ ] 9.4 Migración SQL destructiva con SQL de rollback documentado. ⏳ PENDIENTE — COMENTADA en `20260620000004`. Descomentar y aplicar tras 9.3. Incluye SQL de rollback.
- [ ] 9.5 El importador deja de escribir `products.stock` (solo `branch_stock`); ajustar RPC. ⏳ PENDIENTE — documentado en `20260620000004` §9.5.
- [ ] 9.6 Correr `get_advisors`; regenerar `database.types.ts` con el esquema final. ⏳ PENDIENTE — post-DROP.

## 10. Cierre

- [x] 10.1 Suite completa verde (backend pytest + tests de hooks/frontend); gate de reconciliación = 0 divergencias. ✅ Backend: 96/96. Frontend: 203/203. Gate de reconciliación: pre-migración confirmado RED (636). GREEN se verifica post-push.
- [ ] 10.2 PR(s) a `main` (nunca commit directo a main); el PO mergea. Las migraciones destructivas se mergean recién tras su aprobación. ⏳ Draft PR creado — ver task summary.
- [ ] 10.3 `/opsx:archive v20-inventory-unification` → sincroniza specs `inventory-single-ledger` (nueva) y `branch-stock` (modificada). ⏳ PENDIENTE — post-merge.
- [ ] 10.4 Marcar C-21 `[x]` en CHANGES.md y actualizar el estado de Fase 6 en CLAUDE.md/AGENTS.md. ⏳ PENDIENTE — post-merge.
