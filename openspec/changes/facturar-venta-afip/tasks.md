> **Gobernanza: FISCAL = CRÍTICO.** No iniciar el apply sin sign-off explícito del PO. Cerrar OQ-1/OQ-2/OQ-3 de `design.md` antes de empezar. Modelo TDD obligatorio (RED → GREEN → TRIANGULATE → REFACTOR). `pytest` corre desde la RAÍZ del repo (no desde `backend/`).

## 0. Pre-condiciones (sign-off PO)

- [x] 0.1 Confirmar con el PO el alcance MVP (solo Factura C / monotributista) y cerrar OQ-1 (bloquear botón si emisor RI), OQ-2 (ruta `POST /sales-orders/{id}/emit-invoice`) y OQ-3 (código de éxito 200 con `status`)
- [x] 0.2 Confirmar que el `fiscal_profile` de las cuentas objetivo es `monotributista` (la deuda A/B de D8 no se aborda en este change)

## 1. DB — RPC de emisión por venta (migración mínima)

- [x] 1.1 Crear migración `supabase/migrations/20260801000001_emit_sale_invoice.sql` con la RPC `SECURITY DEFINER` `rpc_emit_sale_invoice(p_sales_order_id uuid, p_point_of_sale_id uuid DEFAULT NULL)` que: (a) `SELECT … FOR UPDATE` la orden y valida cuenta + `status='confirmed'` + `fiscal_document_id IS NULL` (sino `P0404`/`P0409`); (b) lee `fiscal_profiles.iva_condition` (emisor) y, si hay `client_id`, `clients.iva_condition`/`clients.tax_id` (receptor); (c) resuelve tipo (monotributista→`factura_c`) y deriva receptor (CUIT→80, DNI→96, sin id→99/0); (d) llama `rpc_emit_pending_cae(...)` con neto/iva en NULL; (e) `UPDATE sales_orders SET fiscal_document_id` en el mismo commit
- [x] 1.2 `REVOKE ALL` de PUBLIC/anon, `GRANT EXECUTE` a `authenticated`; `COMMENT ON FUNCTION` describiendo la idempotencia fiscal y el reuso de `rpc_emit_pending_cae`
- [x] 1.3 NO agregar columnas A/B (`receptor_iva_condition`, alícuota por línea) — deuda D8, fuera de alcance
- [ ] 1.4 (Manual / PO) Aplicar con `npx supabase db push` (NUNCA el MCP `apply_migration`). No correr en el apply automático

## 2. Backend — schema, repo, service, router (TDD por capa)

- [x] 2.1 (RED) Tests de service `tests/test_emit_invoice.py`: resolución de tipo (monotributista→factura_c) vía `resolve_invoice_type`; receptor consumidor final cuando no hay cliente; 409 cuando la orden ya tiene `fiscal_document_id`; rechazo si `status != 'confirmed'`
- [x] 2.2 (GREEN) Schema Pydantic v2 `EmitInvoiceOut` en `backend/schemas/sales_orders.py` (`fiscal_document_id`, `comprobante_type`, `status`, opcional `punto_de_venta`/`number`) — sin `comprobante_type` de entrada (no se acepta del cliente)
- [x] 2.3 (GREEN) Método de repo `emit_sale_invoice` en `sales_order_repository.py` que invoca `rpc_emit_sale_invoice` y devuelve el resultado; sin lógica de negocio
- [x] 2.4 (GREEN) `emit_invoice()` en `backend/services/sales_orders.py`: `require_role(['user','admin'])`, valida con `resolve_invoice_type`, llama al repo, mapea `PostgresError` (P0404→404, P0409→409, P0401→403) vía `_map_postgres_error`
- [x] 2.5 (TRIANGULATE) Segundo caso por comportamiento (al menos happy path + un edge): cliente con PV id→pasa al repo; RI emisor→403 (OQ-1)
- [x] 2.6 (GREEN) Ruta `POST /sales-orders/{sales_order_id}/emit-invoice` en `backend/routers/sales_orders.py` (solo validación + DI)
- [x] 2.7 (RED→GREEN) Test de router (TestClient): 200 con `status='pending_cae'` en happy path; 409 en orden ya facturada; 403 sin rol writer
- [x] 2.8 (REFACTOR) Limpiado: sin `service_role`, sin `any`, sin lógica en el router

## 3. Frontend — quitar hardcode + botón Facturar + badge

- [x] 3.1 Quitar el hardcode `comprobante_type: "factura_c"` y el `point_of_sale_id` del opt-in en `frontend/app/(dashboard)/ventas/pos/page.tsx`: el POS deja de pasar `comprobante_type` (la venta nace sin comprobante). También se removió el UI de opt-in (checkbox de emisión) que ya no aplica.
- [x] 3.2 Hook TanStack Query `useEmitInvoice` en `frontend/hooks/data/use-sales-orders.ts` que llama `POST /sales-orders/{id}/emit-invoice`; invalida la query de la venta al éxito; tipos explícitos (sin `any`)
- [x] 3.3 Componente `EmitInvoiceButton` en `frontend/components/fiscal/EmitInvoiceButton.tsx` (PascalCase): visible solo si `fiscal_document_id IS NULL`; deshabilitado en pending y mientras la mutación está in-flight; bloqueado con mensaje si el emisor no es monotributista (OQ-1)
- [x] 3.4 Reutiliza `FiscalDocumentBadge` + Realtime en `EmitInvoiceButton` (pending → CAE + número + PV); `last_error` surfaceado vía toast de error al emitir
- [x] 3.5 Página `/ventas/ordenes` con listado de SalesOrders + EmitInvoiceButton por fila confirmada sin comprobante; accesibilidad del botón (loading, disabled, error con aria-label)

## 4. Verificación

- [x] 4.1 Suite backend: 69/69 passed (test_emit_invoice + test_c29 + test_c27_invoice_type_resolver); gate `pytest -m "not integration"` verde desde la raíz
- [ ] 4.2 Smoke manual local: confirmar una venta sin comprobante → "Facturar" → badge pending → (relay) autorizado (manual PO — requiere migración aplicada)
- [ ] 4.3 Verificar idempotencia: segundo "Facturar" sobre la misma venta → 409, sin segundo comprobante (manual PO)

## 5. E2E AFIP (manual, fuera del gate de CI)

- [x] 5.1 Test de integración `@pytest.mark.integration` creado en `backend/tests/test_emit_invoice.py::test_e2e_afip_emit_factura_c_homologacion` (manual, excluido del gate de CI). Requiere certificado/credenciales del PO y trámite ARCA — no bloquea el merge del resto
