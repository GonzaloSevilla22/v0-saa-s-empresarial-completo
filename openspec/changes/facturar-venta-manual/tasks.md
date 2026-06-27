## 0. Gate de gobernanza (FISCAL = CRÍTICO)

- [x] 0.1 Aprobación humana del PO sobre `proposal.md` + `design.md` — otorgada vía invocación de `/opsx:apply facturar-venta-manual` (2026-06-27). Gate firmado. **Restricción vigente:** el `db push` a prod (`gxdhpxvdjjkmxhdkkwyb`) y el deploy NO se ejecutan en este apply — quedan para el merge (CI) con confirmación del PO.
- [x] 0.2 Open Questions del design confirmadas con el PO (2026-06-27): (a) **retirar "Enviar al ARCA" de inmediato**; (b) **ocultar/avisar "Facturar"** cuando ya hay `fiscal_documents`; (c) promote+emit en uno o dos pasos → diferida a apply (decisión técnica).

## 1. DB — RPC + índice (migración Supabase)

- [x] 1.1 Crear archivo de migración `supabase/migrations/<timestamp>_promote_legacy_sale_to_order.sql` con header (CHANGE, GOVERNANCE: CRÍTICO, APPLY con `npx supabase db push`, ROLLBACK documentado).
- [x] 1.2 Agregar índice único parcial `CREATE UNIQUE INDEX IF NOT EXISTS sales_orders_sale_operation_id_uq ON public.sales_orders (sale_operation_id) WHERE sale_operation_id IS NOT NULL` (D2).
- [x] 1.3 Implementar `rpc_promote_legacy_sale_to_order(p_operation_id uuid)` `SECURITY DEFINER SET search_path = public`: guards (auth.uid, tenencia → P0404, is_account_writer → P0401), resolución de branch `COALESCE(sales.branch_id, c26_default_branch)` → P0422 si nula (D4, D5).
- [x] 1.4 En la RPC: short-circuit de idempotencia — `SELECT id FROM sales_orders WHERE sale_operation_id = p_operation_id`; si existe, devolver `{sales_order_id, replayed: true}` sin insertar (D2).
- [x] 1.5 En la RPC: INSERT `sales_orders` (`status='confirmed'`, `payment_method='other'`, `sale_operation_id`, `total = Σ subtotales`, `fiscal_document_id = NULL`, `created_by = auth.uid()`) + reconstrucción de `sales_order_items` desde `sale_items` con fallback al header plano vía COALESCE; líneas de servicio (`product_id NULL`) sin error (D1, D3).
- [x] 1.6 Verificar que la RPC NO descuenta `branch_stock`, NO inserta `cash_movement`, NO inserta `SaleConfirmed` en `events`, y NO invoca `_c29_confirm_order_core` (D1 — side-effect-free).
- [x] 1.7 `REVOKE ALL ... FROM PUBLIC, anon` + `GRANT EXECUTE ... TO authenticated`; `COMMENT ON FUNCTION` explicando la materialización fiscal side-effect-free.
- [x] 1.8 Bloque `DO $$ ... $$` de gates SQL RED→GREEN con ROLLBACK total (patrón C-29 §3.4): idempotencia (segunda promoción no duplica), no-side-effect (stock/caja/events sin cambios), línea de servicio promovida, tenencia ajena rechazada.
- [ ] 1.9 Aplicar la migración con `npx supabase db push` al proyecto `gxdhpxvdjjkmxhdkkwyb` (NUNCA el MCP `apply_migration`). Verificar objetos creados (RPC + índice) post-push. **BLOQUEADA — límite duro del apply: el db push queda para el merge (CI) + confirmación del PO.**

## 2. Backend — repository (TDD)

- [x] 2.1 RED: test pytest+pytest-asyncio para `SalesRepository.promote_to_order(operation_id)` — happy path (devuelve `sales_order_id`) — falla porque el método no existe.
- [x] 2.2 GREEN: implementar `SalesRepository.promote_to_order` en `backend/repositories/sales_repository.py` llamando `SELECT public.rpc_promote_legacy_sale_to_order($1::uuid)`; test pasa.
- [x] 2.3 TRIANGULATE: segundo caso — promoción idempotente (`replayed=true`) y caso de error Postgres propagado (P0404/P0401). Generalizar si "fake it" se rompe.

## 3. Backend — service (TDD)

- [x] 3.1 RED: test para `services/sales.promote_to_order` — guard `require_role(["user","admin"])` rechaza rol insuficiente — falla (no existe).
- [x] 3.2 GREEN: implementar `promote_to_order` en `backend/services/sales.py` con guard + mapeo Postgres→HTTP (espejo de `_map_postgres_error`: P0401→403, P0400→400, P0404→404, P0409/P0422→409); test pasa.
- [x] 3.3 TRIANGULATE: casos de mapeo de errores (403 sin permiso, 404 operación inexistente, 409 conflicto) + happy path devuelve el dict del repo.

## 4. Backend — schema + router (TDD)

- [x] 4.1 RED: definir `PromoteToOrderOut` (Pydantic v2: `sales_order_id: UUID`, `sale_operation_id: UUID`, `replayed: bool`) en `backend/schemas/sales.py`; test de validación del schema.
- [x] 4.2 RED: test del endpoint `POST /sales/{operation_id}/promote-to-order` (FastAPI TestClient / httpx async) — 200 con el schema esperado — falla (ruta no existe).
- [x] 4.3 GREEN: agregar la ruta en `backend/routers/sales.py` (validación + DI únicamente; delega a `sales_service.promote_to_order`); test pasa.
- [x] 4.4 TRIANGULATE: tests de status codes (403/404/409) vía el endpoint; verificar que el router no contiene lógica de negocio.

## 5. Frontend — hook + UI

- [x] 5.1 Crear hook React Query `usePromoteToOrder(operationId)` en `frontend/hooks/data/` → `POST /sales/{operation_id}/promote-to-order` vía `pythonClient`; invalida queries de ventas. Sin `any` (tipos explícitos).
- [x] 5.2 Cablear el botón "Facturar" en `frontend/components/ventas/sale-operations-list.tsx`: al click, `usePromoteToOrder` → obtener `sales_order_id` → renderizar `EmitInvoiceButton` (reuso, ya gatea confirmed + fiscal_document_id NULL + bloqueo RI) con `FiscalDocumentBadge` para el estado del comprobante (D7).
- [x] 5.3 Retirar el botón "Enviar al ARCA" de `SaleOperationsList` (reemplazado por "Facturar"). Estado post-promoción en `promotedMap` (por sesión); ventas sin `operationId` muestran "Sin operación — no facturable".
- [x] 5.4 Manejo de errores en la UI (toasts): promoción fallida → toast.error; éxito con replay → toast.info; errores de emisor RI / sin perfil fiscal gestionados por `EmitInvoiceButton` (reutilizado sin cambios).

## 6. Verificación E2E + cierre

- [ ] 6.1 Smoke en prod-like: cargar una venta manual en `/ventas` → "Facturar" → verificar que se materializa una `sales_orders` confirmada con `sale_operation_id` y que el comprobante queda con `sales_orders.fiscal_document_id` (reconciliado, no huérfano). **BLOQUEADA — límite duro del apply: requiere DB real post-merge.**
- [ ] 6.2 Verificar idempotencia: doble clic en "Facturar" no duplica la orden (una sola fila en `sales_orders`). **BLOQUEADA — requiere DB real post-merge.**
- [ ] 6.3 Verificar no-side-effect: tras promover, `branch_stock`, caja y `events` quedan sin cambios respecto del estado previo a la promoción. **BLOQUEADA — requiere DB real post-merge.**
- [x] 6.4 Confirmar suite pytest verde (coverage del nuevo código) y build frontend OK. **19/19 tests nuevos verdes; 780 totales OK; 1 pre-existing failure ajena al change; tsc sin errores.**
- [ ] 6.5 `/opsx:archive facturar-venta-manual` para sincronizar specs + cerrar; marcar el change en CHANGES.md. **Pendiente: ejecutar post-merge.**
