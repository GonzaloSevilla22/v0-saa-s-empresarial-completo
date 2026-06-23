# Design — v21-wsfe-homologacion-wiring (C-31, follow-up de C-27)

## Context

C-27 (`v21-fiscal-profile`, archivado 2026-06-12) entregó el adaptador WSFE real (`WSFEAdapter` — WSAA + WSFEv1) **escrito y testeado con stub**, pero su **task 5.2 (E2E homologación real)** quedó bloqueada por el trámite de ARCA del PO. Ese trámite ya está completo (memoria engram #316, 2026-06-22): el PO tiene `clave_privada.key` (RSA 2048, sin password) y `certificado.crt` (X.509 de WSASS), con `wsfe` autorizado, CUIT `20422662457`. Hoy la facturación CAE corre en **modo Stub** en prod.

Estado actual verificado leyendo el código (no asumido):

- **`backend/routers/fiscal.py`** — NO existen handlers para `POST /fiscal/profile/cert-upload-url` ni `PUT /fiscal/profile/cert-path`, pero el frontend `frontend/components/settings/FiscalSettings.tsx` (`CertUploadSection`, líneas ~278-296) los invoca. Hoy esos POST/PUT devuelven 404 → la UI de upload **no funciona**.
- **`backend/services/fiscal/wsfe_adapter.py`** — `_get_wsaa_token` (líneas ~123-128) lee DOS objetos del bucket privado `afip-certs`: `f"{invoice_data.account_id}/afip.crt"` y `f"{invoice_data.account_id}/afip.key"`; `_sign_tra` (línea ~179) carga la key con `load_pem_private_key(key, password=None)` (→ PEM sin password). La UI sube UN solo archivo.
- **Typo de URL** — `_WSAA_URLS` y `_WSFEV1_URLS` (líneas ~28-35) usan `.gov.ar`. AFIP usa `.gob.ar`.
- **`zeep`** no está en `backend/requirements.txt` ni en `backend/pyproject.toml`. El import es lazy en `_get_wsaa_token` (líneas ~114-121) y lanza `ImportError` con instrucción de instalar.
- **Selección de adapter** — `routers/fiscal.py` (`process_pending_cae` línea ~169, `process_pending_cae_cron` línea ~207) y `fiscal_profile_service.process_doc_by_id_background` (línea ~237) instancian SIEMPRE `WSFEStubAdapter()` con `TODO: inject real adapter`.
- **Bucket `afip-certs`** — ✅ **EXISTE en prod** (`gxdhpxvdjjkmxhdkkwyb`, `public=false`, creado 2026-06-13 en C-27, verificado vía `storage.buckets`). Gap #5 del briefing ya está cerrado: no se crea bucket nuevo.

Constraints del proyecto (heredadas): FastAPI **3 capas** (router → service → repository), **Pydantic v2**, **asyncpg JWT-passthrough** (NUNCA `service_role` salvo la lectura del cert server-side — D7 / DEC-13, única excepción del proyecto), **ERRCODEs de 5 chars**, tests desde la raíz `python -m pytest backend/tests`. Frontend Next.js 16 App Router + React 19, **sin `any`**, componentes **PascalCase**. Governance **CRÍTICO** (fiscal/AFIP). Marker `integration` ya definido en `pyproject.toml` (`[tool.pytest.ini_options].markers`).

## Goals / Non-Goals

**Goals:**

- Hacer existir los endpoints de upload del cert (`cert-upload-url` + `cert-path`) que el frontend ya consume, con el flujo de **signed PUT** server-side al bucket privado.
- Conseguir que cert (`.crt`) y clave privada (`.key`) lleguen a las rutas EXACTAS `{account_id}/afip.crt` y `{account_id}/afip.key` que el adapter lee, ambos PEM, la `.key` sin password.
- Corregir las 4 URLs de AFIP (`.gov.ar` → `.gob.ar`) para que el E2E real resuelva.
- Agregar `zeep` como dependencia del adapter real (en `requirements.txt` + `pyproject.toml`).
- Diseñar la **factory de adapter** que activa `WSFEAdapter` real cuando hay cert+ambiente, manteniendo el `WSFEStubAdapter` como default cuando no hay cert (sin romper prod).
- Dejar el test E2E de homologación real marcado `@pytest.mark.integration` y excluido del gate.

**Non-Goals:**

- **NO** cambiar el comportamiento de producción para cuentas sin cert (siguen en stub).
- **NO** hacer el cutover de ninguna cuenta a producción (`ambiente='produccion'`) — eso es operación del PO por D2/PA-22, no código.
- **NO** migrar IA/OCR ni nada a Python (DEC-15).
- **NO** introducir el formato `.p12` (OQ-1=B) en este change si el PO confirma A (default).
- **NO** crear tablas ni migraciones (las de C-27 ya existen).
- **NO** correr el E2E real dentro del gate de CI (homologación intermitente + cert real).

## Decisions

### W1 — Upload en DOS objetos PEM separados (`.crt` + `.key`), no `.p12` (OQ-1 = A)

El `WSFEAdapter` ya está escrito para leer `{account_id}/afip.crt` y `{account_id}/afip.key` por separado, y el PO **ya tiene** los dos PEM (`clave_privada.key`, `certificado.crt`). El endpoint `cert-upload-url` recibe `kind ∈ {cert, key}` y mapea a la ruta canónica server-side:

- `kind=cert` → path `{account_id}/afip.crt`
- `kind=key`  → path `{account_id}/afip.key`

El frontend **no decide la ruta** (la deriva el backend del `account_id` del JWT) — esto evita que un cliente apunte a la ruta de otra cuenta. La UI pasa de un input a **dos** controles de upload (certificado y clave privada), cada uno enviando su `kind`.

**Alternativa rechazada (OQ-1=B):** subir un `.p12` y partirlo server-side en cert+key PEM con `cryptography`. UX de un archivo, pero suma un export password, un paso de split, y un punto de fallo más en material criptográfico sensible. Reservado como fallback si el PO lo pide explícitamente.

### W2 — Signed upload URL generada server-side; la `.key` nunca vuelve al cliente

`POST /fiscal/profile/cert-upload-url` (router → service) genera una **signed upload URL** de Supabase Storage para el path canónico del bucket privado `afip-certs`, scoped al `account_id` del JWT. El frontend hace `PUT` directo a esa URL con el archivo (cert o key). Luego `PUT /fiscal/profile/cert-path` persiste `certificado_afip_path` en `fiscal_profiles` (vía el `upsert` ya existente del repo, que ya cubre el campo con `COALESCE`).

Invariantes duros (governance CRÍTICO, OQ-2):

- La `.key` viaja **solo** en el body del signed PUT al bucket privado. **Nunca** se loguea, **nunca** se devuelve en ningún GET. `GET /fiscal/profile` (`FiscalProfileOut`) sigue devolviendo solo el **path**, jamás el contenido.
- La lectura del cert/key para firmar WSAA usa `service_role` **solo** server-side, aislada en `WSFEAdapter._read_cert_from_storage` (D7 / DEC-13).
- `certificado_afip_path` guarda únicamente la ruta del objeto `.crt` (marcador de "cert cargado"); la `.key` se infiere por convención de path (`afip.crt` ↔ `afip.key` en el mismo prefijo `{account_id}/`). El adapter ya construye ambas rutas; no se persiste el path de la `.key` para no exponerlo en la API.

**Para decidir si una cuenta tiene cert (factory, W4):** se usa `fiscal_profiles.certificado_afip_path IS NOT NULL`. El upload del `.crt` (kind=cert) es el que dispara el `cert-path` PUT que setea ese campo; el upload de la `.key` (kind=key) **no** toca el campo (la `.key` no se refleja en la API). El flujo de UI debe subir AMBOS; el campo se setea con el `.crt`.

**Alternativa rechazada:** subir el archivo al backend (multipart) y que el backend lo reenvíe a Storage. Hace pasar el material criptográfico por la memoria/logs del backend; el signed PUT directo lo evita.

### W3 — Fix de las 4 URLs `.gov.ar` → `.gob.ar`

Cambio mecánico en `wsfe_adapter.py`:

| Constante | Ambiente | Old (typo) | New (correcto) |
|---|---|---|---|
| `_WSAA_URLS` | homologacion | `https://wsaahomo.afip.gov.ar/ws/services/LoginCms?WSDL` | `https://wsaahomo.afip.gob.ar/ws/services/LoginCms?WSDL` |
| `_WSAA_URLS` | produccion | `https://wsaa.afip.gov.ar/ws/services/LoginCms?WSDL` | `https://wsaa.afip.gob.ar/ws/services/LoginCms?WSDL` |
| `_WSFEV1_URLS` | homologacion | `https://wswhomo.afip.gov.ar/wsfev1/service.asmx?WSDL` | `https://wswhomo.afip.gob.ar/wsfev1/service.asmx?WSDL` |
| `_WSFEV1_URLS` | produccion | `https://servicios1.afip.gov.ar/wsfev1/service.asmx?WSDL` | `https://servicios1.afip.gob.ar/wsfev1/service.asmx?WSDL` |

Test RED: una aserción pura sobre las 4 constantes que verifica que todas terminan en `.gob.ar` y ninguna contiene `.gov.ar` (sin red). Es la prueba más barata y atrapa regresiones de typo.

### W4 — Factory `build_cae_adapter(...)`: real cuando hay cert + ambiente; stub como default (OQ-3 = auto)

Función fábrica en `fiscal_profile_service.py` (o un módulo `adapter_factory.py` dentro de `services/fiscal/`):

```
def build_cae_adapter(*, has_cert: bool, service_client=None) -> FiscalDocumentPort:
    if has_cert and service_client is not None:
        return WSFEAdapter(supabase_service_client=service_client)
    return WSFEStubAdapter()
```

- El `ambiente` (homologacion/produccion) **ya** viaja en `CAERequest.ambiente` (del doc, que lo toma del perfil) y lo resuelve el adapter internamente — no es un parámetro de la factory; el toggle homologación/producción es el `ambiente` del perfil (D2). La factory solo decide **stub vs real** según haya o no cert.
- En el relay cross-account (`process_all_pending_documents` / cron), la decisión **por documento/cuenta** se hace consultando `certificado_afip_path` de la cuenta del doc. El `WSFEAdapter` resuelve ambiente y rutas por `account_id` internamente, así que la misma instancia real puede servir varias cuentas — pero **solo** se usa la real para cuentas con cert; las demás caen al stub.
- **Default = stub.** Cuentas sin `certificado_afip_path` no cambian de comportamiento. Esto preserva prod intacto.

**Alternativa rechazada (OQ-3=toggle explícito):** un flag por cuenta `usar_afip_real`. Suma estado y una forma de quedar mal configurado (cert presente pero flag off, o flag on sin cert). El `ambiente` del perfil ya es el toggle de homologación/producción; agregar otro multiplica los estados inválidos. La presencia de cert es señal suficiente y sin ambigüedad.

### W5 — `zeep` opcional, agregado a deps; import lazy se mantiene

`zeep` se agrega a `backend/requirements.txt` (deps de prod efectivas en Render) y a `backend/pyproject.toml` (`[project].dependencies`). `cryptography` ya está disponible transitivamente vía `PyJWT[crypto]` (requirements) / `python-jose[cryptography]` (pyproject), y el adapter ya la importa — no se agrega aparte salvo que el apply detecte que falta como dep directa (en cuyo caso se agrega `cryptography` explícita; decisión del apply, validada por import en test).

El import de `zeep` se mantiene **lazy** dentro de `_get_wsaa_token`/`_call_wsaa`/`_call_wsfe` (ya está así), de modo que el módulo importa aunque `zeep` no esté instalado (importante: el stub y los tests del gate no requieren `zeep`).

Pin: usar un rango conservador (p. ej. `zeep>=4.2,<5`) consistente con el estilo `>=` del resto de `requirements.txt`. El apply fija la versión exacta probada.

### W6 — Test E2E homologación real: `@pytest.mark.integration`, fuera del gate (OQ-4 = sí)

El test que ejecuta WSAA → WSFEv1 `FECAESolicitar` → CAE contra homologación de ARCA con el cert real va marcado `@pytest.mark.integration`. El gate de CI corre `pytest -m "not integration"` (o equivalente; el apply confirma el invocador exacto del gate). Lo corre el orquestador a mano con el cert del PO (`pytest -m integration backend/tests/...`), tras colocar el cert (OQ-5: vía UI o colocación directa en el bucket).

Los tests **del gate** para este change son puros / mockeados: fix de URL (aserción sobre constantes), factory (stub vs real según `has_cert`), endpoints de upload (signed URL mockeada, validación de `kind`, scoping del path por `account_id`, que la `.key` no se devuelva).

## Risks / Trade-offs

- **[La `.key` es el secreto más sensible del sistema; una fuga compromete la firma fiscal del emisor.]** → Mitigación: signed PUT directo al bucket privado (nunca pasa por logs/memoria del backend), lectura solo server-side con `service_role` aislado (D7), path derivado del `account_id` del JWT (no del cliente), `.key` nunca devuelta por la API. Requirement duro en el spec (OQ-2).
- **[Activar el adapter real para una cuenta mal configurada (cert inválido / ambiente equivocado) podría intentar facturar contra el servicio equivocado.]** → Mitigación: el adapter resuelve URL por `ambiente` del perfil (D2); el default sigue siendo homologación; el cutover a producción es operación explícita del PO (cambiar `ambiente` + cert real). El relay es idempotente con backoff y captura errores → `pending_cae`/`rejected`, no rompe la venta.
- **[`zeep` agrega peso al deploy de Render (free tier, cold start ~50s).]** → Mitigación: `zeep` es relativamente liviano; el import es lazy (solo se carga cuando una cuenta con cert pide CAE real). Aceptable.
- **[El E2E de homologación es intermitente (ARCA homo se cae seguido).]** → Mitigación: fuera del gate (`@pytest.mark.integration`); manual; no bloquea CI ni merges.
- **[Governance CRÍTICO: facturación real.]** → Mitigación: el PO revisa y mergea el propose; las OQs se resuelven antes del apply; ningún corte a producción real de AFIP sin aprobación humana explícita (PA-22 delimita: producción es trámite del PO, no del código). El default de este change deja prod en stub.

## Migration Plan

1. **Sin migración de DB** — `certificado_afip_path` y las tablas ya existen (C-27). Verificar (read-only) que las Storage policies de `afip-certs` cubran `.crt` y `.key` con el mismo scoping por `account_id`; si la policy fuera por nombre de objeto exacto, ajustarla a prefijo `{account_id}/` (tarea de migración menor de Storage, solo si la verificación lo exige).
2. **Backend** — agregar endpoints + service de upload + factory; fix de URLs; agregar `zeep`. Tests del gate verdes.
3. **Frontend** — `CertUploadSection` a dos controles (cert + key). `pnpm build` / typecheck OK (sin `any`).
4. **Deploy** — backend a Render, frontend a Vercel. **Sin cambio de comportamiento** (toda cuenta sigue en stub hasta cargar cert).
5. **E2E homologación (manual, orquestador + PO)** — colocar el cert del PO (UI o directo en bucket), correr `pytest -m integration`, validar que obtiene un CAE real de homologación. Cierra C-27 task 5.2.
6. **Rollback** — los endpoints nuevos son aditivos; la factory cae al stub si algo falla; revertir es quitar los endpoints/factory y volver al stub fijo. El fix de URL y `zeep` son inertes mientras no haya cert.

## Open Questions

Las 5 Preguntas Abiertas para el PO están en `proposal.md` (§"Preguntas Abiertas / PO Sign-off") con su default recomendado: (1) formato de upload = A (dos PEM), (2) seguridad de la `.key` = invariante duro, (3) activación del adapter = auto por cert+ambiente con stub fallback, (4) E2E `@pytest.mark.integration` fuera del gate = sí, (5) cómo llega el cert al primer test = ambos (UI + colocación directa). **Ninguna se aplica sin sign-off del PO antes del apply** (governance CRÍTICO).
