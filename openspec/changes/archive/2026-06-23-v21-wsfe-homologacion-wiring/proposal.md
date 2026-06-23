# Proposal — v21-wsfe-homologacion-wiring (C-31, follow-up de C-27)

## Why

C-27 (`v21-fiscal-profile`) dejó el adaptador WSFE real (`WSFEAdapter` — WSAA + WSFEv1) escrito y testeado **con stub**, pero su **task 5.2 (E2E real de homologación contra AFIP/ARCA)** quedó bloqueada por un trámite externo: la homologación en ARCA del PO. **Ese trámite ya está hecho** (2026-06-22: el PO generó `clave_privada.key` + CSR `CN=aliadata, serialNumber=CUIT 20422662457`, creó el DN/certificado en WSASS homologación y autorizó el servicio `wsfe`; CUIT del PO = `20422662457`). Lo que falta es el **wiring de código** para poder correr ese E2E real: los endpoints de upload del certificado **no existen**, la UI sube **un solo archivo** cuando el adapter lee **dos** (`.crt` + `.key`), hay un **typo de URL** (`.gov.ar` en vez de `.gob.ar`) que rompería WSAA/WSFEv1, falta la dependencia opcional `zeep` (SOAP), y falta el **mecanismo de selección** del adapter real vs stub. Cerrar esto destraba la 5.2 sin cambiar el comportamiento de producción: la facturación CAE **sigue corriendo en modo Stub** hasta que una cuenta tenga cert + ambiente cargados — nada se bloquea.

## What Changes

- **Endpoints de upload del certificado (NUEVOS)** — el frontend ya invoca `POST /fiscal/profile/cert-upload-url` y `PUT /fiscal/profile/cert-path`, pero **no hay handler** en `backend/routers/fiscal.py`. Se agregan ambos en el router `fiscal` (3 capas: router → service → repository). `cert-upload-url` devuelve una **signed upload URL** server-side hacia el bucket privado `afip-certs` para una ruta canónica; `cert-path` persiste el path en `fiscal_profiles.certificado_afip_path`.
- **Upload de DOS archivos (cert + clave privada)** — el `WSFEAdapter` lee **dos** objetos del bucket privado `afip-certs`: `{account_id}/afip.crt` y `{account_id}/afip.key` (ambos PEM; la clave se carga con `load_pem_private_key(key, password=None)` → PEM sin password). La UI hoy sube un único archivo. El flujo nuevo SHALL llevar ambos archivos a esas rutas EXACTAS. **Decisión recomendada (OQ-1=A):** dos uploads separados (`.crt` y `.key`), que es lo que el PO ya tiene y lo que el adapter espera.
- **Fix del typo de URL en el adapter** — `backend/services/fiscal/wsfe_adapter.py` (líneas 29-30 y 33-34) usa `.gov.ar`; AFIP es `.gob.ar`. Se corrigen las 4 URLs: WSAA homo `wsaahomo.afip.gob.ar`, WSAA prod `wsaa.afip.gob.ar`, WSFEv1 homo `wswhomo.afip.gob.ar`, WSFEv1 prod `servicios1.afip.gob.ar`. **Sin este fix el E2E real falla** (DNS no resuelve / endpoint inexistente).
- **Dependencia `zeep` (SOAP, opcional)** — el `WSFEAdapter` real necesita `zeep` (más `cryptography`, ya transitivamente presente vía `PyJWT[crypto]`). Se agrega a `backend/requirements.txt` y a `backend/pyproject.toml`.
- **Selección stub-vs-real del adapter** — hoy `routers/fiscal.py` (`process_pending_cae`, `process_pending_cae_cron`) y `fiscal_profile_service.process_doc_by_id_background` instancian **siempre** `WSFEStubAdapter` (con `TODO: inject real adapter`). Se agrega una **factory de adapter por cuenta/ambiente**: usa `WSFEAdapter` real cuando la cuenta tiene `certificado_afip_path` presente; usa `WSFEStubAdapter` como fallback cuando no hay cert. **El default sigue siendo el stub** (cuentas sin cert no cambian de comportamiento).
- **Verificación del bucket `afip-certs`** — ✅ **ya existe en prod** (`gxdhpxvdjjkmxhdkkwyb`, privado, creado 2026-06-13 en C-27). No se crea nada nuevo; se verifican las Storage policies para que la ruta `.key` (segundo objeto) quede cubierta por las mismas policies scoped por `account_id` que ya cubren `.crt`.
- **Test E2E de homologación real (MANUAL, fuera del gate de CI)** — un test `@pytest.mark.integration` que ejecuta WSAA → WSFEv1 `FECAESolicitar` → CAE contra homologación de ARCA con el cert real del PO. **Excluido del gate de CI** (homologación intermitente + requiere cert real); lo corre el orquestador a mano con el cert del PO.

> **Governance CRÍTICO** (fiscal/AFIP, facturación/CAE reales, clave privada). Este proposal + design requieren **revisión y sign-off del PO antes del apply**. Las Open Questions están listadas abajo con un default recomendado por cada una; ninguna se resuelve sin la confirmación del PO.

## Capabilities

### New Capabilities

_(ninguna — no se introducen capabilities nuevas; el comportamiento se agrega sobre `fiscal-profile` y `afip-fiscal-document`)_

### Modified Capabilities

- `fiscal-profile`: se modifica **"Certificado AFIP en Storage privado"** (ahora son **dos** objetos PEM — `.crt` + `.key` — en rutas canónicas `{account_id}/afip.crt|afip.key`, la `.key` es el secreto más sensible y nunca se devuelve en ningún GET) y **"UI de configuración fiscal"** (la UI sube **dos** archivos: certificado y clave privada). Se agrega un requirement nuevo **"API de upload del certificado AFIP"** (los endpoints `cert-upload-url` + `cert-path` que el frontend ya consume).
- `afip-fiscal-document`: se modifica **"Adaptador WSFE detras de un ACL (port + impl real/stub)"** (URLs correctas `.gob.ar`; el adapter real requiere `zeep`; rutas `.crt`/`.key`). Se agrega un requirement nuevo **"Selección del adaptador WSFE por cuenta (real vs stub)"** (factory: real cuando hay cert+ambiente, stub como fallback/default).

## Impact

- **Backend** (`backend/`):
  - `routers/fiscal.py` — 2 endpoints nuevos (`POST /fiscal/profile/cert-upload-url`, `PUT /fiscal/profile/cert-path`); cablear la factory de adapter en `process_pending_cae` y `process_pending_cae_cron`.
  - `services/fiscal/wsfe_adapter.py` — fix de las 4 URLs `.gov.ar` → `.gob.ar`.
  - `services/fiscal/fiscal_profile_service.py` — service de cert-upload (signed URL + persistir path) + factory `build_cae_adapter(...)` (real/stub por cuenta); cablear factory en `process_doc_by_id_background`.
  - `repositories/fiscal_profile_repository.py` — método para persistir `certificado_afip_path` (reusar `upsert` existente, que ya cubre el campo).
  - `schemas/fiscal.py` — Pydantic v2: `CertUploadUrlRequest` (`filename`, `content_type`, `kind` ∈ {`cert`,`key`}), `CertUploadUrlOut` (`uploadUrl`, `path`), `CertPathUpdate` (`path`).
  - `requirements.txt` + `pyproject.toml` — agregar `zeep` (SOAP, opcional para el adapter real).
  - `tests/` — tests unit (endpoints, factory, fix de URL, parseo de rutas) en el gate; **1 test `@pytest.mark.integration` (E2E homologación) excluido del gate**.
- **Frontend** (`frontend/`):
  - `components/settings/FiscalSettings.tsx` — `CertUploadSection`: pasar de un input a **dos** controles (certificado `.crt`/`.pem` y clave privada `.key`/`.pem`), cada uno con su `kind`; el body de `cert-upload-url` incluye `kind`. Sin `any`; componente PascalCase ya cumple.
  - `hooks/data/use-fiscal-profile.ts` — sin cambios de tipo necesarios (el path sigue siendo string); el flujo de upload vive en el componente.
- **Storage** (Supabase `gxdhpxvdjjkmxhdkkwyb`): bucket `afip-certs` **ya existe** (privado). Verificar que las policies INSERT/SELECT/UPDATE scoped por `account_id` cubran ambos objetos (`.crt` y `.key`). La lectura del cert para firmar WSAA usa `service_role` server-side aislado (D7 / DEC-13 — única excepción de `service_role` del proyecto).
- **DB**: sin migración nueva (la columna `certificado_afip_path` y las tablas ya existen de C-27).
- **Producción**: **sin cambio de comportamiento** hasta que una cuenta cargue cert + `ambiente`. La factory mantiene el stub como default. No bloquea nada.
- **Desbloquea**: cierre de C-27 task 5.2 (E2E homologación real). Habilita el cutover por cuenta a facturación real (operación del PO, no código), por D2/PA-22.

## Preguntas Abiertas / PO Sign-off (Governance CRÍTICO)

> Cada pregunta trae un **default recomendado**. Ninguna se aplica sin confirmación del PO antes del apply.

1. **Formato de upload del certificado.** (A) **dos uploads separados** — `.crt` y `.key` (es lo que el PO ya tiene y lo que el adapter lee de `{account_id}/afip.crt|afip.key`; cero conversión server-side) vs (B) **un solo `.p12`** que el backend parte en cert+key PEM server-side (UX de un archivo, pero requiere export password y split con `cryptography`). **Recomendado: A.** La UI se ajusta a dos controles como parte de este change.
2. **Seguridad del upload de la clave privada.** La `.key` es el secreto más sensible del sistema. Se confirma que va **solo** al bucket privado `afip-certs` vía signed PUT generada server-side, **nunca** se expone client-side más allá del PUT, **nunca** se loguea y **nunca** se devuelve en ningún GET (`/fiscal/profile` solo devuelve el path). **Recomendado: confirmar este invariante como requirement duro.**
3. **Activación del adapter real.** ¿Automática cuando `cert presente + ambiente='homologacion'`, o detrás de un toggle explícito por cuenta? **Recomendado: automática cuando hay cert + ambiente; stub como fallback cuando no hay cert** (sin toggle adicional — menos superficie de error, y el `ambiente` ya es el toggle homologación/producción que existe en el perfil).
4. **Alcance del E2E.** El E2E real de homologación (WSAA → WSFEv1 `FECAESolicitar` → CAE) SHALL ir marcado `@pytest.mark.integration` y **excluido del gate de CI** (homologación es intermitente y necesita cert real). **Recomendado: confirmar.** Lo corre el orquestador a mano con el cert del PO.
5. **Cómo llega el cert al bucket para el primer test.** Vía el **nuevo upload de la UI** (preferido — valida el flujo completo end-to-end) **o** el orquestador coloca los archivos del PO directamente en el bucket vía tooling para el primer E2E. **Recomendado: ambos quedan disponibles** — el primer E2E puede usar colocación directa para aislar el adapter, y un segundo pase valida el flujo de UI real.
