## Why

Hoy la única forma de emitir un comprobante AFIP por una venta es marcar la opción de emisión **en el momento de confirmar la venta** en el POS, y ese flujo está **roto**: el POS hardcodea `comprobante_type: "factura_c"` (`frontend/app/(dashboard)/ventas/pos/page.tsx` L383) con un comentario falso ("backend resuelve el tipo"). El backend **no** resuelve el tipo — persiste el string que recibe. Resultado: una venta nunca se factura después de confirmada, y un emisor que no sea monotributista emitiría una Factura C ilegal.

El pipeline de emisión asíncrona (numeración → `pending_cae` → relay → CAE) **ya está construido y en producción** (C-27 + C-29 + `fiscal-receptor-iva-relay`). Lo que falta es: (1) **desacoplar** la emisión del momento de confirmar y exponer un botón **"Facturar"** que opere sobre cualquier venta confirmada sin comprobante, y (2) **resolver el tipo de comprobante en el backend** en vez de hardcodearlo. Es un cambio de cableado + fix de bug fiscal, no la construcción del pipeline.

## What Changes

- **Modelo de emisión unificado:** la venta se confirma **sin** comprobante. Un único botón **"Facturar"** emite el comprobante para **cualquier** `sales_order` confirmada con `fiscal_document_id IS NULL`. El mismo flujo cubre la venta recién confirmada (botón posterior) y la venta vieja (retroactivo) — son el mismo camino, no dos.
- **Nuevo endpoint backend** `POST /sales-orders/{id}/emit-invoice`: valida estado + idempotencia, resuelve el tipo en el service vía `resolve_invoice_type()`, arma el receptor desde la identidad fiscal del cliente (C-22) y dispara la emisión asíncrona reutilizando `rpc_emit_pending_cae`. Setea `sales_orders.fiscal_document_id`.
- **Tipo de comprobante resuelto en el BACKEND** (capa service), nunca por el usuario. Para emisor monotributista → `factura_c`.
- **El POS deja de emitir inline:** se quita/neutraliza el hardcode `factura_c` (ya no pasa `comprobante_type`, o pasa `null`). La confirmación de venta nunca más nace con comprobante.
- **Idempotencia fiscal:** si la orden ya tiene `fiscal_document_id`, el endpoint rechaza con **409**. El botón se deshabilita mientras hay emisión pendiente o ya facturada.
- **UI:** botón "Facturar" en el detalle/listado de la venta confirmada + `FiscalDocumentBadge` (pending → CAE + número de comprobante + PV) con Realtime. Hook de TanStack Query nuevo para el endpoint.
- **Alcance MVP: solo Factura C** (monotributista). Factura A/B (Responsable Inscripto) queda **fuera de alcance**, documentada como deuda en `design.md`.

## Capabilities

### New Capabilities
<!-- Ninguna capability nueva: se reutiliza la maquinaria fiscal existente. -->

### Modified Capabilities
- `afip-fiscal-document`: nuevo requirement — **emisión posterior/retroactiva de un comprobante para una `sales_order` confirmada** mediante un endpoint dedicado que resuelve el tipo en el backend (`resolve_invoice_type`), arma el receptor desde la identidad fiscal del cliente (C-22) y garantiza idempotencia fiscal (409 si la orden ya tiene `fiscal_document_id`). Reutiliza la emisión síncrona `pending_cae` + relay CAE existentes, sin tocar el pipeline.
- `sales-order`: el camino de confirmación **deja de emitir comprobantes inline**; la emisión se mueve a una acción explícita posterior ("Facturar") sobre la orden confirmada. Contrato de idempotencia vía la FK `sales_orders.fiscal_document_id`.

## Impact

- **Backend (nuevo):** `backend/routers/sales_orders.py` (ruta `POST /sales-orders/{id}/emit-invoice`), `backend/services/sales_orders.py` (lógica: validar estado/idempotencia + resolver tipo + armar receptor), `backend/schemas/sales_orders.py` (schema de respuesta de emisión), un repo method en `backend/repositories/sales_order_repository.py` o `fiscal_document_repository.py`.
- **Backend (reusado tal cual):** `backend/services/fiscal/invoice_type_resolver.py` (`resolve_invoice_type`), `wsfe_adapter.py` (receptor + IVA + threshold guard), `cae_relay_processor.py`, `fiscal_document_repository.claim_pending`, RPC `rpc_emit_pending_cae`, relay pg_cron.
- **DB:** evaluar una RPC nueva (p.ej. `rpc_emit_sale_invoice`) que valide la orden + idempotencia + resuelva receptor/tipo y llame a `rpc_emit_pending_cae` seteando `sales_orders.fiscal_document_id`. Para Factura C **no** se requieren columnas nuevas (la RPC y `fiscal_documents` ya soportan los parámetros). Sin columnas A/B (fuera de alcance).
- **Frontend:** `frontend/app/(dashboard)/ventas/pos/page.tsx` (quitar hardcode `factura_c`), botón "Facturar" + hook React Query nuevo, `FiscalDocumentBadge` (reusado) en el detalle/listado de ventas.
- **Datos:** lee `clients.tax_id` / `clients.iva_condition` / `clients.legal_name` (C-22) y `fiscal_profiles.iva_condition` (emisor). Sin cliente identificado → Factura C a consumidor final (DocTipo 99).
- **Gobernanza:** dominio **FISCAL = CRÍTICO** (dinero real / AFIP). Este change es solo planning; el apply requiere sign-off del PO.
- **Fuera de alcance (deuda):** Factura A/B — requiere columna `fiscal_documents.receptor_iva_condition` + alícuota de IVA por línea en `sales_order_items`. El guard del WSFEAdapter ya falla explícito si llega A/B sin desglose (comportamiento MVP aceptado).
