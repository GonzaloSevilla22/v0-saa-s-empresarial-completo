# Proposal — v21-fiscal-profile (C-27)

## Why

En Argentina la facturación electrónica es la condición de existencia del producto: sin comprobante válido la PyME usa EmprendeSmart *además de* su facturador, no *en lugar de* (DEC-22). Hoy el sistema no tiene perfil fiscal de la organización (CUIT, condición IVA, punto de venta, certificado AFIP), no tiene numeración de comprobantes sin huecos (requisito duro de AFIP/ARCA) ni ningún canal hacia el web service de facturación (WSFE/WSAA). C-22 ya dio identidad fiscal a los clientes y C-26 dio a `Branch` su rol de Aggregate Root con punto de venta vinculable — es el momento de construir el emisor: `FiscalProfile`, `DocumentSequence` y el adaptador WSFE detrás de un ACL, con CAE asíncrono para no atar el hot path de la venta al uptime de AFIP.

## What Changes

- **`FiscalProfile` por cuenta** (entidad dentro de `Account`/`Organization`): tabla `fiscal_profiles` (`id` UUID PK, `account_id` FK `accounts` UNIQUE, `cuit` NOT NULL, `iva_condition`, `iibb_condition`, `punto_de_venta`, `certificado_afip_path` referencia a Storage, `ambiente` `('homologacion'|'produccion')` por cuenta, `created_at`). Una organización tiene a lo sumo un perfil fiscal (UNIQUE `account_id`).
- **`AFIPConfiguration.ambiente` por cuenta (PA-22 — restricción dura)**: el adaptador real apunta a **homologación de ARCA**; el cutover a producción por cuenta es subir el certificado real + dar de alta el punto de venta WSFE, **sin re-trabajo de código**. C-27 valida end-to-end en homologación (WSAA ticket de acceso, WSFEv1 CAE, numeración sin huecos, manejo de errores).
- **`DocumentSequence` — numeración AFIP sin huecos**: tabla `document_sequences` (`fiscal_profile_id` FK, `comprobante_type`, `punto_de_venta`, `last_number`, UNIQUE `(fiscal_profile_id, punto_de_venta, comprobante_type)`). `next()` toma un lock serializado con `SELECT … FOR UPDATE` (agregado pequeño, lock corto) y **JAMÁS dentro de la transacción larga de la venta**.
- **Adaptador WSFE (AFIP/ARCA) detrás de un ACL** — port `FiscalDocumentPort.requestCAE(invoice_data) → CAEResponse` en la capa de dominio; dos implementaciones inyectables: real (homologación) y stub (tests/dev). El dominio conoce `CAE`, `CAEDueDate`, `DocumentType`; nunca el SOAP de AFIP.
- **CAE asíncrono (DEC-22)**: el comprobante se persiste con `status = 'pending_cae'` en la transacción de la venta; un proceso en background pide el CAE vía el adaptador y actualiza a `'authorized'` (o `'rejected'` con el detalle del error); reintento con backoff ante error transitorio de AFIP.
- **UI `/configuracion/fiscal`**: formulario de perfil fiscal (CUIT, condición IVA, IIBB, punto de venta, ambiente) + upload del certificado AFIP a Storage (**bucket PRIVADO**).
- **Backend Python**: `FiscalProfileRepository` + router `fiscal`; servicio del adaptador WSFE (port + impl real/stub); worker/relay del CAE asíncrono.

## Capabilities

### New Capabilities

- `fiscal-profile`: perfil fiscal de la organización (CUIT, condición IVA/IIBB, punto de venta, certificado AFIP en Storage privado, `ambiente` por cuenta), su persistencia con RLS por `account_id`, su API y su UI.
- `document-sequence`: numeración de comprobantes fiscales sin huecos por `(fiscal_profile, punto_de_venta, comprobante_type)`, con lock serializado corto fuera de la transacción de venta.
- `afip-fiscal-document`: emisión de comprobantes con CAE asíncrono — persistencia con `status = 'pending_cae'`, adaptador WSFE detrás de un ACL (port + impl real homologación / stub), y el ciclo de obtención del CAE en background con reintento por backoff.

### Modified Capabilities

_(ninguna — todo el comportamiento es nuevo; C-22 `client-fiscal-identity` y C-26 `branches` quedan como dependencias, no se modifican sus requirements)_

## Impact

- **DB (migración nueva, no destructiva)**: `CREATE TABLE fiscal_profiles` + RLS por `account_id` + UNIQUE `account_id`; `CREATE TABLE document_sequences` + RLS + UNIQUE `(fiscal_profile_id, punto_de_venta, comprobante_type)`; `CREATE TABLE fiscal_documents` (comprobante emitido: tipo, punto de venta, número, cliente, total, `status`, `cae`, `cae_due_date`, error) + RLS; RPC `rpc_next_document_number` (lock corto `SELECT FOR UPDATE` + UPDATE-then-INSERT por el gotcha upsert-vs-CHECK del proyecto); RPC/función de emisión que reserva número y persiste `pending_cae`. Migración vía `npx supabase db push` (CLI), proyecto prod `gxdhpxvdjjkmxhdkkwyb`.
- **Storage**: bucket privado para certificados AFIP (`.crt`/`.key`) con policies INSERT/SELECT/UPDATE scoped por `account_id`; el `service_role` (solo en el backend/Edge, nunca cliente) lee el certificado para firmar el WSAA.
- **Backend** (`backend/`): `fiscal_profile_repository.py`, `routers/fiscal.py`, schemas Pydantic v2 (`FiscalProfileCreate/Update/Out`), `services/fiscal/` con el port `FiscalDocumentPort` + `WSFEAdapter` (real) y `WSFEStubAdapter` (tests), el resolvedor de tipo de comprobante (A/B/C), el mecanismo de CAE asíncrono (decisión de diseño D-async), tests pytest (TDD).
- **Frontend** (`frontend/`): página `/configuracion/fiscal` (Server Component + Server Action / llamada al backend), hook `use-fiscal-profile`, componente de upload de certificado a Storage; `database.types.ts` regenerado.
- **Edge Functions / Realtime**: sin migración de IA/OCR (DEC-15); el server-push del cambio `pending_cae → authorized` se resuelve con el patrón tabla→Realtime ya vigente (DEC-16), sin WebSocket Python.
- **Desbloquea**: C-29 (`v21-quote-salesorder` — `quickSale()` emite `FiscalDocument` con numeración por punto de venta) y el resto de la facturación V2.1.
- **Governance: CRÍTICO** (facturación real). Este proposal + design requieren revisión y merge del PO antes del apply; las Open Questions del design (OQ-1..OQ-n) deben resolverse primero. PA-22 ya está resuelta (homologación + ambiente por cuenta) y NO se re-pregunta.
