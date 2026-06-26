## Why

Hoy el relay del CAE **pierde la identidad del receptor y el desglose de IVA** entre la emisión y la llamada a AFIP. El `CAERelayProcessor.process_document` arma el `CAERequest` solo con `account_id/comprobante_type/punto_de_venta/number/total/cuit_emisor/ambiente` ([cae_relay_processor.py:71-80](backend/services/fiscal/cae_relay_processor.py)), así que el `WSFEAdapter` hardcodea `DocTipo=99` (consumidor final sin identificar) en TODO comprobante ([wsfe_adapter.py:521](backend/services/fiscal/wsfe_adapter.py)) y, para Factura A/B, emite con `ImpNeto=total` / `ImpIVA=0` (un comprobante con IVA discriminado en cero — fiscalmente inválido).

El gap nace antes que el relay: ni `fiscal_documents` tiene columnas para el receptor (DocTipo/DocNro) ni para el IVA (neto, iva, alícuota), ni `rpc_emit_pending_cae` los captura; `rpc_emit_subscription_payment_cae` incluso **acepta `p_receptor_doc_tipo/p_receptor_doc_nro` y los descarta en el INSERT** ([20260724000002:179-189](supabase/migrations/20260724000002_v22_subscription_payment_invoicing.sql)).

No estalló en producción por dos coincidencias: el PO es monotributista (solo Factura C, sin IVA discriminado) y los montos son chicos — la RG 5824/2026 (vigente 12/02/2026) elevó el umbral de identificación obligatoria del consumidor final a **$10.000.000**. El sistema queda correcto para "monotributista → Factura C → consumidor final < $10M" y **roto fuera de ese caso**: (a) ventas ≥ $10M que ARCA exige identificar, y (b) cualquier emisor Responsable Inscripto (Factura A/B con IVA real).

## What Changes

- **Persistencia (DB).** `fiscal_documents` suma columnas para la identidad del receptor (`receptor_doc_tipo`, `receptor_doc_nro`) y el desglose de IVA (`neto`, `iva_amount`, `iva_alicuota_id`). Migración aditiva; valores históricos quedan NULL (= comportamiento actual: consumidor final sin identificar).
- **RPCs de emisión.** `rpc_emit_pending_cae` captura y persiste el receptor + el IVA al insertar el `pending_cae`. `rpc_emit_subscription_payment_cae` **deja de descartar** `p_receptor_doc_tipo/p_receptor_doc_nro` y los persiste (cierra el bug latente del flujo admin).
- **Relay.** `FiscalDocumentRepository.claim_pending` (y `list_pending`/`list_pending_all`) devuelven las columnas nuevas en su `RETURNING`/`SELECT`. `CAERelayProcessor.process_document` propaga esos campos al `CAERequest`.
- **Adapter.** `WSFEAdapter._call_wsfe` deja de hardcodear `DocTipo=99`: deriva el `DocTipo` (80=CUIT, 96=DNI, 99=sin identificar) y el `DocNro` de los datos del receptor, y usa el `neto`/`iva_amount`/`iva_alicuota_id` para el array `AlicIva` de Factura A/B en vez de asumir IVA=0. La regla de umbral (identificación obligatoria ≥ $10.000.000) se valida explícitamente.
- **Sin cambios** en el modelo de delegación (cert de plataforma, `Auth.Cuit`, TA por ambiente), ni en la numeración autoritativa (`FECompUltimoAutorizado`), ni en `CondicionIVAReceptorId` (RG 5616, ya resuelto).

## Capabilities

### New Capabilities
<!-- Ninguna: es una corrección de requisitos sobre la capability fiscal existente. -->

### Modified Capabilities
- `afip-fiscal-document`: el ciclo de emisión y el adaptador WSFE ahora **propagan e informan la identidad del receptor** (`DocTipo`/`DocNro` derivados de los datos del comprobante, no hardcodeados) y el **desglose de IVA** (neto/IVA/alícuota para el array `AlicIva` de Factura A/B). Se agrega la regla de identificación obligatoria del receptor cuando el total ≥ umbral ARCA vigente. Se preservan: delegación (cert de plataforma + `Auth.Cuit`), numeración por `FECompUltimoAutorizado`, `CondicionIVAReceptorId` (RG 5616), Factura C, máquina de estados `pending_cae → authorized/rejected`.

## Impact

- **DB / migraciones.** Nueva migración aditiva en `supabase/migrations/` (columnas en `fiscal_documents` + actualización de `rpc_emit_pending_cae` y `rpc_emit_subscription_payment_cae`). Aplica CI (`deploy.yml` → `supabase db push`); se escribe el `.sql`, no se aplica a mano. Reversible (DROP COLUMN / restaurar RPC anterior).
- **Backend (Python/FastAPI).** `backend/repositories/fiscal_document_repository.py` (RETURNING/SELECT), `backend/services/fiscal/cae_relay_processor.py` (CAERequest threading), `backend/services/fiscal/fiscal_document_port.py` (campos receptor en `CAERequest` — `receptor_iva_condition`/`neto`/`iva_amount`/`iva_alicuota_id` ya existen; agregar `receptor_doc_tipo`/`receptor_doc_nro`), `backend/services/fiscal/wsfe_adapter.py` (`DocTipo` derivado + array `AlicIva` real), `backend/schemas/fiscal.py` (propagar receptor en `EmitPendingCAERequest`).
- **Frontend (Next.js).** Opcional/menor: el flujo de emisión del usuario (POS / "Enviar al ARCA") puede pasar el receptor cuando el cliente tiene identidad fiscal (`client-fiscal-identity`, C-22). No bloqueante para esta corrección backend.
- **Seguridad / governance.** **CRÍTICO** (fiscal, dinero real, comprobantes ante ARCA). Requiere sign-off explícito del PO antes de implementar. Estrategia segura: el default sin datos de receptor sigue siendo `DocTipo=99` (comportamiento actual), de modo que ningún comprobante existente cambia salvo que se provea identificación.
- **Tests.** TDD pytest: casos para Factura C consumidor final (sin cambio), Factura B/C ≥ $10M con CUIT/DNI (DocTipo 80/96), Factura A/B con IVA discriminado real, y el regression del flujo admin de suscripción (receptor ya no se descarta). Los tests contra ARCA real quedan `@pytest.mark.integration` (manuales, fuera del gate).
