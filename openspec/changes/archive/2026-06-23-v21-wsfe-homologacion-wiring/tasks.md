# Tasks — v21-wsfe-homologacion-wiring (C-31, follow-up de C-27)

> **Governance CRÍTICO (fiscal/AFIP, clave privada).** Requiere sign-off del PO sobre el proposal + las 5 Preguntas Abiertas ANTES de empezar el apply.
> **Strict TDD (apply phase):** cada comportamiento empieza con un test RED antes del código GREEN. Tests del gate = puros/mockeados; el E2E real de homologación va marcado `@pytest.mark.integration` y se corre A MANO (ver §7). Tests desde la raíz: `python -m pytest backend/tests`.

## 0. PO sign-off (gate de inicio — NO escribir código antes)

- [x] 0.1 Confirmar con el PO las 5 Preguntas Abiertas del proposal (formato de upload=A, seguridad de la `.key`, activación auto del adapter, E2E fuera del gate, cómo llega el cert al test) y registrar la decisión
- [x] 0.2 Confirmar baseline de tests fiscal en verde antes de tocar nada: `python -m pytest backend/tests -m "not integration" -k fiscal` → capturar "N passing" (safety net; si algo falla, reportar como pre-existing, no arreglar)

## 1. Fix de URL del adapter (.gov.ar → .gob.ar)

- [x] 1.1 RED: test puro que aserta que las 4 URLs de `_WSAA_URLS` + `_WSFEV1_URLS` terminan en `.gob.ar` y ninguna contiene `.gov.ar` (sin red) — debe fallar contra el código actual
- [x] 1.2 GREEN: corregir las 4 constantes en `backend/services/fiscal/wsfe_adapter.py` (líneas ~29-30 y ~33-34): `wsaahomo.afip.gob.ar`, `wsaa.afip.gob.ar`, `wswhomo.afip.gob.ar`, `servicios1.afip.gob.ar`
- [x] 1.3 TRIANGULATE: agregar caso que verifica que ambos ambientes (homologacion/produccion) de ambos diccionarios resuelven al host correcto; tests verdes

## 2. Dependencia zeep (SOAP, opcional)

- [x] 2.1 RED: test que importa el módulo `wsfe_adapter` y construye `WSFEStubAdapter` sin `zeep` instalado → debe pasar (el import es lazy); y un test que aserta que el camino real levanta `ImportError` claro si falta `zeep` (mock del import)
- [x] 2.2 GREEN: agregar `zeep>=4.2,<5` a `backend/requirements.txt` y a `backend/pyproject.toml` (`[project].dependencies`); si el apply detecta que `cryptography` no es dep directa, agregarla explícita (validado por import en test)
- [x] 2.3 Verificar que `python -m pytest backend/tests -m "not integration"` sigue verde con/ sin `zeep` instalado (import lazy intacto)

## 3. Schemas Pydantic v2 (upload del cert)

- [x] 3.1 RED: tests de validación de `CertUploadUrlRequest` (`filename`, `content_type`, `kind` Literal `'cert'|'key'`) — `kind` inválido → ValidationError; y de `CertPathUpdate` (`path` requerido)
- [x] 3.2 GREEN: definir en `backend/schemas/fiscal.py` los schemas `CertUploadUrlRequest`, `CertUploadUrlOut` (`uploadUrl`, `path`) y `CertPathUpdate`
- [x] 3.3 TRIANGULATE: caso happy-path (kind=cert y kind=key válidos) + caso borde (kind ausente) verdes

## 4. Service de upload del cert (signed URL + persistir path)

- [x] 4.1 RED: test del service `create_cert_upload_url(...)` con Storage client mockeado: deriva el path canónico del `account_id` (`{account_id}/afip.crt` para cert, `{account_id}/afip.key` para key), NUNCA del cliente; devuelve `uploadUrl` + `path`; guard `require_role` owner/admin (member → 403)
- [x] 4.2 GREEN: implementar `create_cert_upload_url` en `backend/services/fiscal/fiscal_profile_service.py` (genera signed upload URL server-side al bucket privado `afip-certs`, scoped por `account_id`)
- [x] 4.3 RED: test del service `set_cert_path(...)` que persiste `certificado_afip_path` vía el `upsert` existente del repo (reusar; ya cubre el campo con COALESCE) y NO devuelve contenido del cert
- [x] 4.4 GREEN: implementar `set_cert_path` (delegando al repo); TRIANGULATE: member → 403, path válido → persistido

## 5. Endpoints del router fiscal (cert-upload-url + cert-path)

- [x] 5.1 RED: test de endpoint `POST /fiscal/profile/cert-upload-url` (kind=cert y kind=key) — 200 con `uploadUrl`+`path` scoped a la cuenta del JWT; kind inválido → 422; member → 403; un usuario de A no puede inducir un path de B
- [x] 5.2 GREEN: agregar el handler `POST /fiscal/profile/cert-upload-url` en `backend/routers/fiscal.py` (router → service → repo; sin lógica en el router)
- [x] 5.3 RED: test de endpoint `PUT /fiscal/profile/cert-path` — persiste el path; la respuesta no incluye contenido del cert/key; member → 403
- [x] 5.4 GREEN: agregar el handler `PUT /fiscal/profile/cert-path`
- [x] 5.5 Verificar el invariante de seguridad (OQ-2): `GET /fiscal/profile` NUNCA devuelve contenido del `.crt`/`.key` ni la ruta del `.key`; la `.key` no se loguea (test que aserta que el path de la key no aparece en ninguna respuesta de la API)

## 6. Factory de adapter (real vs stub) + cableado del relay

- [x] 6.1 RED: tests de `build_cae_adapter(...)`: `has_cert=True` + service_client → `WSFEAdapter`; `has_cert=False` → `WSFEStubAdapter`; `has_cert=True` sin service_client → `WSFEStubAdapter` (fallback seguro)
- [x] 6.2 GREEN: implementar `build_cae_adapter` en `backend/services/fiscal/` (módulo nuevo `adapter_factory.py` o función en `fiscal_profile_service.py`)
- [x] 6.3 RED: tests que verifican que `process_pending_cae` (endpoint usuario), `process_pending_cae_cron` (cron, por documento/cuenta) y `process_doc_by_id_background` consultan `certificado_afip_path` y eligen el adapter vía la factory (cuenta con cert → real; sin cert → stub), default stub preservado
- [x] 6.4 GREEN: cablear la factory en los 3 puntos de `backend/routers/fiscal.py` (líneas ~169, ~207) y `backend/services/fiscal/fiscal_profile_service.py` (`process_doc_by_id_background`, línea ~237), reemplazando el `WSFEStubAdapter()` fijo y los TODOs; TRIANGULATE: cuenta con cert vs sin cert dispara distinta implementación

## 7. E2E homologación real (MANUAL — `@pytest.mark.integration`, FUERA del gate de CI)

> **Esta es la task de homologación manual.** El gate de CI corre `pytest -m "not integration"` y la SALTEA. La corre el orquestador a mano con el cert del PO: `python -m pytest -m integration backend/tests/...`. Necesita el cert real (OQ-5: vía UI o colocación directa en el bucket) + ARCA homo arriba (intermitente).

- [x] 7.1 Escribir el test `@pytest.mark.integration` que ejecuta el flujo real: leer cert+key del bucket → WSAA `loginCms` (ticket de acceso) → WSFEv1 `FECAESolicitar` → aserta que devuelve un CAE real de homologación (CUIT emisor `20422662457`, ambiente `homologacion`)
- [x] 7.2 Colocar el cert real del PO: subir `certificado.crt` a `{account_id}/afip.crt` y `clave_privada.key` a `{account_id}/afip.key` (vía la UI nueva o colocación directa en el bucket — OQ-5)
- [x] 7.3 Correr A MANO `python -m pytest -m integration` y validar que obtiene un CAE válido de homologación; documentar el resultado → **cierra C-27 task 5.2** — VALIDADO 2026-06-23 vía script local `backend/.afip-homo/run_homo_e2e.py` (gitignoreado): CAE real `86250464989491`, vto 2026-07-03, PV=1, Factura B nº 1, CUIT 20422662457, ambiente homologacion. (El E2E reveló gaps del adapter para facturar de verdad en prod → follow-up aparte.)
- [x] 7.4 Confirmar que el invocador del gate de CI excluye `integration` (no se rompió el gate)

## 8. Frontend — CertUploadSection a dos controles (cert + key)

- [x] 8.1 Modificar `frontend/components/settings/FiscalSettings.tsx` (`CertUploadSection`): pasar de un input único a **dos** controles de upload — certificado (`.crt`/`.pem`, `kind='cert'`) y clave privada (`.key`/`.pem`, `kind='key'`); cada upload envía su `kind` a `cert-upload-url` y hace PUT a la signed URL; sin `any`
- [x] 8.2 Asegurar que el `.crt` (kind=cert) dispara el `PUT /fiscal/profile/cert-path` que setea `certificado_afip_path`; la `.key` no toca el campo (no se refleja en la API); el contenido de la `.key` no se expone client-side más allá del PUT
- [x] 8.3 Verificar typecheck/build del frontend (`pnpm build` o equivalente) — sin `any`, componentes PascalCase intactos

## 9. Storage policies + verificación final

- [x] 9.1 Verificar (read-only) que las Storage policies de `afip-certs` (bucket ya existente en prod `gxdhpxvdjjkmxhdkkwyb`) cubren INSERT/SELECT/UPDATE para ambos objetos (`.crt` y `.key`) scoped por prefijo `{account_id}/`; si una policy fuera por nombre exacto, ajustarla a prefijo (migración menor de Storage solo si la verificación lo exige)
- [x] 9.2 `python -m pytest backend/tests -m "not integration"` verde (gate completo, sin el E2E real)
- [x] 9.3 Confirmar que el comportamiento de prod NO cambia para cuentas sin cert (default stub) — smoke del relay con una cuenta sin `certificado_afip_path`
- [x] 9.4 Conventional commit + PR; reportar al PO para review/merge (governance CRÍTICO) — PR #205 mergeado a main (commit `25e25b9`) + hardening post-review (`54eb7e3`)
