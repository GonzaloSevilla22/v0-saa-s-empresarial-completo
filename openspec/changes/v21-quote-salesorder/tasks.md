## 1. Preparación y datado de la migración

- [x] 1.1 Ejecutar `ls supabase/migrations/ | sort | tail -1` y confirmar el último timestamp real (esperado `20260701000002`). Datar la nueva migración POR ENCIMA: `20260702000001_c29_quote_salesorder.sql` (NUNCA con fecha real 20260617… — rompe el history).
- [x] 1.2 Releer las fuentes de verdad antes de escribir SQL: `modelo-dominio-aliadata-v2.md` §3.3/§5.5/§5.9, `knowledge-base/09` DEC-06/DEC-20, RN-97 en `knowledge-base/05`. Confirmar firmas reales de `c28_register_cash_movement`, `c21_apply_branch_stock_delta`, `c26_default_branch`, `rpc_emit_pending_cae`, `rpc_next_document_number`.

## 2. Migración SQL — schema (RED para la capa DB)

- [x] 2.1 `ADD COLUMN IF NOT EXISTS` nullable a `public.events` (OQ-5 RESUELTO — PO 2026-06-17): `account_id uuid`, `event_type text`, `aggregate_type text`, `aggregate_id uuid`, `payload jsonb`, `occurred_at timestamptz default now()`, `processed_at timestamptz`. No DROP: solo ADD COLUMN para no romper el stub existente ni el índice de `20260517000003`. Agregar también policy SELECT `account_id IN (SELECT current_account_ids())`.
- [x] 2.2 Crear `quotes` (`id`, `account_id`, `branch_id` null, `client_id` null, `status` CHECK `draft|sent|accepted|expired|rejected`, `valid_until` date null, `total numeric(15,2)`, `created_by`, `created_at`) + índice `(account_id, created_at DESC)`.
- [x] 2.2b Crear `quote_items` (`id`, `quote_id` FK, `product_id` null, `account_id`, `quantity numeric(15,4)`, `unit_id` null, `price`, `subtotal`) + índice `(quote_id)`.
- [x] 2.3 Crear `sales_orders` (`id`, `account_id`, `branch_id` NOT NULL (OQ-3 RESUELTO — DEC-19), `client_id` null, `source_quote_id` FK→quotes null, `status` CHECK `draft|confirmed|canceled`, `payment_method` CHECK `cash|other`, `total numeric(15,2)`, `sale_operation_id uuid` null, `fiscal_document_id` FK→fiscal_documents null, `created_by`, `created_at`) + índices `(account_id, created_at DESC)`, `(source_quote_id)`. El RPC `rpc_quick_sale`/`rpc_accept_quote` resuelve `branch_id` via `c26_default_branch` cuando no se pasa explícitamente.
- [x] 2.3b Crear `sales_order_items` (`id`, `sales_order_id` FK, `product_id` null, `account_id`, `quantity numeric(15,4)`, `unit_id` null, `price`, `subtotal`) + índice `(sales_order_id)`.
- [x] 2.4 RLS: habilitar en las 4 tablas. Política SELECT en las 4 con `account_id IN (SELECT current_account_ids())` (NUNCA `= ANY(...)` — gotcha SETOF). NO crear INSERT/UPDATE en `sales_orders`/`sales_order_items` (escritura solo por RPC definer, D2).
- [x] 2.5 RLS: en `quotes` y `quote_items` SÍ crear políticas INSERT (`WITH CHECK is_account_writer(account_id)`) y UPDATE (`USING … IN (SELECT current_account_ids()) WITH CHECK is_account_writer`) — escritura directa del repo (D3). `quote_items` desnormaliza `account_id`.

## 3. Migración SQL — RPCs SECURITY DEFINER (GREEN para la capa DB)

- [x] 3.1 `rpc_accept_quote(p_quote_id)`: guard `is_account_writer`; valida estado `draft|sent` y `valid_until >= now()`; crea `sales_orders` (`status='draft'`, `source_quote_id`) + copia `quote_items`→`sales_order_items`; transiciona quote a `accepted`. Atómico. `REVOKE FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated`.
- [x] 3.2 `rpc_confirm_sales_order(p_idempotency_key, p_sales_order_id, p_payment_method, p_cash_session_id, p_comprobante_type, p_point_of_sale_id, p_branch_id, p_canal)`: implementar el hot path completo en UNA transacción (via helper interno _c29_confirm_order_core) —
  - guard `is_account_writer`; claim idempotencia (`operation_idempotency`, `operation_kind='sale'`, `ON CONFLICT DO NOTHING` + replay si 0);
  - resolver `v_gate_branch` de la orden; validar branch operativa (P0422 si cerrada);
  - por línea: lock producto `FOR UPDATE`, gate per-branch `branch_stock`, `c21_apply_branch_stock_delta(-qty)`, `stock_movements` `reference_type='sale'`, e insertar fila puente `sales` + `sale_items` (mecánica v2, D4);
  - si `payment_method='cash'`: exigir `p_cash_session_id` (P0400 si falta) e invocar `c28_register_cash_movement(session, total, 'sale', sales_order_id)` (D6);
  - si `p_comprobante_type` no nulo: `rpc_emit_pending_cae(...)` y guardar `fiscal_document_id` (D7);
  - `INSERT INTO events` hecho `SaleConfirmed` (D8);
  - transicionar orden a `confirmed`, guardar `sale_operation_id`. `REVOKE`/`GRANT`.
- [x] 3.3 `rpc_quick_sale(p_idempotency_key, p_client_id, p_items, p_payment_method, p_cash_session_id, p_comprobante_type, p_point_of_sale_id, p_branch_id, p_canal)`: crea `sales_orders` + `sales_order_items` y llama internamente a `_c29_confirm_order_core` (helper) en una sola transacción idempotente; devuelve `sales_order_id` + `operation_id`.
- [x] 3.4 Bloque `DO $$ … $$` con gates SQL (RED→GREEN): (a) CHECK payment_method; (b) CHECK status; (c) CHECK quantity > 0. Con RAISE NOTICE de resultado.
- [x] 3.5 Encabezado de migración con CHANGE/ERRCODEs/GOVERNANCE/APPLY (`npx supabase db push`, NUNCA MCP)/ROLLBACK (DROP de los 3 RPCs + helper + 4 tablas en orden inverso de FKs) + bloque VERIFICATION post-push.

## 4. Backend FastAPI — schemas (Pydantic v2)

- [x] 4.1 `backend/schemas/quotes.py`: `QuoteItemIn/Out`, `QuoteIn`, `QuoteOut`, enum `QuoteStatus`, `QuoteTransitionIn`. Sin `any`; validación de no-vacío y montos > 0.
- [x] 4.2 `backend/schemas/sales_orders.py`: enums `PaymentMethod` (`cash|other`), `ComprobanteType` (null permitido); `SalesOrderItemIn/Out`, `SalesOrderOut`, `ConfirmIn`, `QuickSaleIn` (con validación cross-field: `cash` ⇒ `cash_session_id` requerido), `AcceptQuoteOut`.

## 5. Backend FastAPI — repositories (TDD: test primero)

- [x] 5.1 RED: `backend/tests/test_c29_quote_salesorder.py` — tests de repository que verifican que cada método invoca el RPC correcto con los args correctos (mock asyncpg, patrón `test_c28_cash_session.py`): `accept_quote`→`rpc_accept_quote`, `confirm`→`rpc_confirm_sales_order`, `quick_sale`→`rpc_quick_sale`; CRUD de quotes vía INSERT/SELECT.
- [x] 5.2 GREEN: `backend/repositories/quote_repository.py` (CRUD directo + `accept` vía RPC) y `backend/repositories/sales_order_repository.py` (`confirm`/`quick_sale` vía `SELECT rpc_…`, `list`/`get` vía SELECT). JWT-passthrough (heredar de `BaseRepository`); `_jsonb` helper como en cash repo.

## 6. Backend FastAPI — services (TDD)

- [x] 6.1 RED: tests de service — `accept` con rol insuficiente → 403; `confirm` propaga P0409 stock como 409; `quick_sale` feliz devuelve `sales_order_id`; validación `cash` sin session → error.
- [x] 6.2 GREEN: `backend/services/quotes.py` y `backend/services/sales_orders.py` con `require_role(auth, ["user","admin"])` (guards SOLO en el service, NUNCA en routers), mapeo de payload y manejo de `HTTPException`.

## 7. Backend FastAPI — routers (TDD)

- [x] 7.1 RED: tests de endpoint HTTP (async_client) — `POST /quotes` 201, `POST /quotes/{id}/accept`, `POST /sales-orders/{id}/confirm`, `POST /sales-orders/quick-sale`, listados; token member → 403 en rutas de escritura.
- [x] 7.2 GREEN: `backend/routers/quotes.py` y `backend/routers/sales_orders.py` (validación + DI únicamente, patrón `routers/cash.py`); registrar ambos en `backend/main.py`.
- [x] 7.3 TRIANGULATE: agregar el caso idempotencia (doble quick-sale misma key → `replayed=true`, sin duplicar) y el caso comprobante (`comprobante_type` → orden con `fiscal_document_id`).

## 8. Tests de invariante del dominio (los obligatorios del scope)

- [x] 8.1 quickSale de 2 uds → `branch_stock` −2 (verificable contra la lógica del RPC; integración o smoke).
- [x] 8.2 venta con stock 0 → error "stock insuficiente" (P0409), orden no confirmada.
- [x] 8.3 `Quote.accept()` → crea `SalesOrder` con los mismos ítems (producto, cantidad, precio).
- [x] 8.4 `SalesOrder.confirm()` falla a mitad → rollback total (cero efectos en stock, caja, numeración, outbox).
- [x] 8.5 Correr la suite completa: `cd backend && pytest -q` verde + coverage de los módulos nuevos.

## 9. Frontend (mínimo / diferible según apply)

- [x] 9.1 Hooks React Query: `use-quotes` (CRUD + accept) y `use-sales-orders` (confirm + quickSale), con invalidación de la query de ventas/stock. Componentes en PascalCase, sin `any`.
- [ ] 9.2 (Opcional) Pantalla POS de quickSale reusando el formulario de venta existente; (opcional) vista de presupuestos.

## 10. Deploy y validación en prod

- [ ] 10.1 PR a `main` (feature branch + PR obligatorio); CI aplica la migración y deploya. Verificar `gh pr checks` verde (ignorar "Supabase Preview" rojo — no bloqueante).
- [ ] 10.2 Smoke transaccional contra `gxdhpxvdjjkmxhdkkwyb` (BEGIN…RAISE→ROLLBACK): quickSale −2, stock 0 → P0409, accept→SalesOrder, confirm a mitad → rollback total. Gate de validación clave.
- [ ] 10.3 Actualizar CHANGES.md (marcar C-29) y `mem_save` del cierre del change.
