## 1. Migración: RPC escribe sale_items

- [x] 1.1 Crear `supabase/migrations/20260721000001_c29_write_sale_items.sql` con `CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(...)` reproduciendo el cuerpo vigente (de `20260702000001`) sin cambios salvo el agregado.
- [x] 1.2 Insertar el `INSERT INTO public.sale_items (...)` justo después del `INSERT INTO sales ... RETURNING id INTO v_new_sale_id` del bloque con producto. Línea de servicio (ELSE) sin ítem.
- [x] 1.3 Re-aplicar `REVOKE ALL ... FROM PUBLIC, anon, authenticated` y el `COMMENT` (paridad con el original).

## 2. Backfill idempotente de ventas sin ítem

- [x] 2.1 En la misma migración, DML: `INSERT INTO sale_items (...) SELECT ... FROM sales s WHERE s.product_id IS NOT NULL AND NOT EXISTS (...)`, con `price = s.amount`, `subtotal = COALESCE(s.total, s.amount*s.quantity)`, `variant_id = NULL`.
- [x] 2.2 Alcance verificado read-only: 11 ventas (9 legacy + 2 C-29); el SELECT excluye servicios (`product_id IS NULL`) y no toca filas de variantes.

## 3. Tests (TDD)

- [x] 3.1 Test de migración (patrón parsing, igual que test_events_reconcile): `backend/tests/migrations/test_c29_write_sale_items.py` asegura el INSERT a sale_items en el bloque de producto (entre sales y stock_movements) con variant_id NULL.
- [x] 3.2 Test: backfill idempotente (NOT EXISTS) y solo product_id NOT NULL.
- [x] 3.3 Test: sin DDL destructivo + REVOKE preservado.
- [x] 3.4 GREEN: 8/8 nuevos; suite c29 + sale_items + migrations 133 passed sin regresión.

## 4. Aplicar y verificar en prod

- [x] 4.1 PO aprobó. `npx supabase db push` aplicó solo `20260721000001` (dry-run + migration list confirmaron que era la única pendiente).
- [x] 4.2 Gate: `ventas_sin_sale_items = 0`. Verificado además `pg_get_functiondef` → el core en vivo contiene el INSERT a `sale_items`.
- [x] 4.3 Spot-check de las 2 ventas C-29: ahora tienen sale_items coherente (qty/price/subtotal cuadran, variant_id NULL). E2E POS desde la app queda post-deploy (igual que el smoke del fix anterior).

## 5. Cierre

- [ ] 5.1 Feature branch + PR + merge si checks pasan.
- [ ] 5.2 `/opsx:archive c29-write-sale-items` (sync spec `sale-line-items`).
- [ ] 5.3 Nota al PO: este change desbloquea el C-20 Grupo 10 (DROP header plano) como decisión separada.
