## Why

La facturación electrónica AFIP **funciona en homologación** (CAE real `86250464989491` obtenido el 2026-06-23 contra ARCA `wswhomo`, wiring de C-31 `v21-wsfe-homologacion-wiring`), pero el `WSFEAdapter` **todavía no produce solicitudes de CAE válidas para producción**. Un E2E real de homologación destapó 5 huecos concretos: sin ellos, `FECAESolicitar` es rechazado por ARCA en producción y los comprobantes nunca salen de `pending_cae`. Esto bloquea el corte a facturación real (governance **CRÍTICO**: fiscal/AFIP, dinero real, clave privada).

Follow-up directo de **C-27 `v21-fiscal-profile`** (perfil fiscal + multi-PV + relay `pg_cron` + `WSFEAdapter`) y **C-31 `v21-wsfe-homologacion-wiring`** (cert upload + adapter factory, archivado 2026-06-23). Cada hueco es un requisito separado y testeable; nada de esto cambia la transacción de emisión — el alcance vive en el camino relay/adapter.

## What Changes

Los 5 huecos detectados en el E2E real (cada uno = una capability testeable):

- **`CondicionIVAReceptorId` en `FECAEDetRequest`** (prioridad máxima). Su ausencia provoca **Code 10246** (rechazo de `FECAESolicitar`) — obligatorio por **RG 5616/2024**. Para consumidor final el id es **5**. El adapter debe mapear la condición IVA del receptor (y/o `DocTipo`) al `CondicionIVAReceptorId` correcto. Hoy el dict **no tiene** esa key.
- **Array `Iva` (`AlicIva`)** cuando hay importes gravados (IVA 21% → `AlicIva` Id=5), con `ImpNeto`/`ImpIVA`/`ImpTotal` internamente consistentes. Hoy el adapter hardcodea `ImpNeto = total`, `ImpIVA = 0` y no envía array `Iva`. Para **comprobante tipo C** (monotributo) NO hay discriminación de IVA: sin array `Iva`, `ImpIVA=0`, `ImpNeto=ImpTotal`.
- **Numeración autoritativa de ARCA** vía `FECompUltimoAutorizado(PtoVta, CbteTipo)`: pedir `CbteDesde = CbteHasta = último + 1` en vez de confiar en `invoice_data.number`. Reconciliar con el número ya reservado localmente por `rpc_next_document_number` (el desync es **Code 10016**).
- **Caché del Ticket de Acceso (TA) de WSAA**: el TA dura ~12h y WSAA rechaza un nuevo `loginCms` dentro de un cooldown (~10 min) con "el CUIT ya posee un TA válido". Cachear (token+sign+expiración) por cuenta/CUIT + ambiente y reusar hasta cerca del vencimiento. La caché in-process **no alcanza** (relay `pg_cron` + workers/background = invocaciones separadas): debe sobrevivir entre invocaciones.
- **Declarar `supabase-py`** en `backend/requirements.txt` **y** `backend/pyproject.toml`: el adapter lee cert/key del bucket privado `afip-certs` vía Supabase Storage server-side, pero `supabase` no está declarado → en prod el cert-upload da 503 y el relay cae al stub. (`zeep` ya está en ambos — no se duplica.)

## Capabilities

### New Capabilities
<!-- Ninguna capability nueva: el ciclo del comprobante fiscal ya existe (afip-fiscal-document). Este change endurece requisitos existentes y agrega requisitos de producción sobre esa misma capability. -->

### Modified Capabilities
- `afip-fiscal-document`: el requisito "Adaptador WSFE detras de un ACL (port + impl real/stub)" se EXTIENDE para exigir, en la solicitud de CAE de producción, `CondicionIVAReceptorId`, el array `Iva` (con la rama tipo-C sin IVA) y la numeración autoritativa vía `FECompUltimoAutorizado`. Se AGREGAN tres requisitos nuevos a la misma capability: numeración autoritativa de ARCA, caché del TA de WSAA, y la dependencia `supabase-py` declarada.

## Impact

- **Spec deltas**: `afip-fiscal-document` — 1 requisito MODIFIED (ACL del adaptador WSFE) + 3 requisitos ADDED (numeración ARCA, caché TA, dependencia supabase-py).
- **Código afectado** (camino relay/adapter — la transacción de emisión NO se toca):
  - `backend/services/fiscal/wsfe_adapter.py` — `_call_wsfe` (huecos 1, 2, 3: `CondicionIVAReceptorId`, array `Iva`, `FECompUltimoAutorizado`) y `_get_wsaa_token`/`_call_wsaa` (hueco 4: caché TA).
  - `backend/services/fiscal/fiscal_document_port.py` — nuevos campos de dominio en `CAERequest` (condición IVA del receptor + desglose IVA neto/alícuotas) para que el adapter construya `CondicionIVAReceptorId` y el array `Iva` sin filtrar SOAP al dominio (se mantiene la frontera del ACL).
  - `backend/services/fiscal/adapter_factory.py` — inyección del store de caché del TA (hueco 4).
  - `backend/requirements.txt` y `backend/pyproject.toml` — agregar `supabase` (hueco 5).
  - **Store de caché del TA** — Redis (Upstash, `redis>=5.0` ya es dep) o una tabla Postgres (decisión PO; ver design.md "Open Questions").
- **Relay** (`backend/routers/fiscal.py`): los 3 puntos (`process-pending` user-JWT, `process-pending-cron` cron cross-account, `process_doc_by_id_background` fire-and-forget) comparten la caché del TA — clave para el hueco 4 dado que cron + background son invocaciones de proceso separadas.
- **Governance CRÍTICO**: ninguna línea de producción se escribe sin sign-off explícito del PO (ver tasks.md, Gate 0). El E2E real contra ARCA queda como `@pytest.mark.integration` (manual, fuera del gate de CI).
- **Sin migraciones de datos** salvo, eventualmente, una tabla de caché del TA si el PO elige el store Postgres (queda como Open Question).
