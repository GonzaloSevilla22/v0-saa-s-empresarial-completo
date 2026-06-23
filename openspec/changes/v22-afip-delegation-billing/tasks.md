## 0. Gate 0 — Sign-off del PO (BLOQUEANTE, governance CRÍTICO)

> Governance CRÍTICO (fiscal, dinero real, secreto que factura por todos los usuarios).
> NINGUNA tarea de implementación (grupos 1+) puede empezar hasta que el PO firme estas decisiones.
> El agente NO escribe código antes de este sign-off.

- [x] 0.1 OQ-1 — Certificado/CUIT representante: confirmar reusar `AliadataProd` (CUIT 20422662457, ya validado en prod) vs. CUIT/cert de empresa dedicado.
- [x] 0.2 OQ-2 — Reemplazo total del cert por usuario vs. conservarlo como opción avanzada/fallback (define el árbol de decisión de la factory).
- [x] 0.3 OQ-3 — Custodia de la private key de plataforma: env/secret manager (Render) vs. bucket de plataforma restringido (`service_role`). Definir ubicación + rotación + quién tiene acceso.
- [x] 0.4 OQ-4 — Estrategia ante delegación no autorizada: confirmar que NO se gatea la emisión por el flag (solo se advierte) y que el error de AFIP se trata como reintentable. Confirmar el código/forma del error esperado.
- [x] 0.5 OQ-5 — Botón "Enviar al ARCA" en la venta: ¿scope de este change o follow-up?
- [x] 0.6 OQ-6 — Transición de la cuenta del PO (CUIT 20422662457): confirmar que se representa a sí misma con el mismo cert representante; destino de los objetos ya subidos a `afip-certs`.
- [x] 0.7 Registrar el sign-off (decisiones + responsable + fecha) en engram y en `design.md` (Open Questions → Resueltas) antes de continuar.

## 1. Migración DB (aditiva; archivos en supabase/migrations/, aplica CI)

> TDD: tests de DB primero (RLS, default, CHECK) antes de dar por buena la migración.

- [x] 1.1 RED: test del flag `fiscal_profiles.delegacion_autorizada` (default FALSE; INSERT/UPDATE solo owner/admin vía RLS; SELECT aislado por cuenta).
- [x] 1.2 GREEN: escribir la migración que agrega `fiscal_profiles.delegacion_autorizada BOOLEAN NOT NULL DEFAULT FALSE` (no aplicar a mano — CI corre `supabase db push`).
- [x] 1.3 RED: test del esquema del TA de plataforma (según OQ resuelta de D5: tabla `platform_wsaa_tickets(ambiente PK, token, sign, expires_at, updated_at)` o equivalente) — una fila por ambiente, sin RLS por `account_id` (estado de plataforma).
- [x] 1.4 GREEN: escribir la migración del TA de plataforma; documentar el truncado/inerte de las filas per-CUIT viejas de `wsaa_access_tickets`.
- [x] 1.5 TRIANGULATE: caso default + caso member-rechazado + caso aislamiento por cuenta verdes.

## 2. Configuración del cert de plataforma (server-side, CRÍTICO)

- [x] 2.1 RED: test de `PlatformCredentialProvider` — resuelve cert + key + CUIT representante desde `settings`; falla/retorna "no configurado" cuando faltan; NUNCA loguea ni devuelve la key.
- [x] 2.2 GREEN: implementar el provider + entradas en `backend/core/config.py` (`afip_platform_cert`, `afip_platform_key`, `afip_platform_cuit`) según la ubicación elegida en OQ-3.
- [x] 2.3 TRIANGULATE: configurado (real) vs no configurado (señala stub) vs key ausente.
- [x] 2.4 Verificar que la key no aparece en logs ni en ninguna respuesta de la API (test de no-exposición).

## 3. WSFEAdapter — autenticación con cert de plataforma + Auth.Cuit = representado

> No reimplementar el ensamblado del FECAEDetRequest (RG 5616, Iva, numeración, Factura C ya existen y se preservan — tests de regresión deben seguir verdes).

- [x] 3.0 SAFETY NET: correr los tests existentes del adapter (`test_c27_wsfe_adapter.py`, `test_c31_*`) y capturar baseline verde. Reportar cualquier rojo pre-existente sin tocarlo.
- [x] 3.1 RED: test de que `WSFEAdapter` firma la TRA con el cert del **representante** (del provider), no con `{account_id}/afip.crt`.
- [x] 3.2 GREEN: cambiar `_get_wsaa_token`/`_sign_tra` para leer el material del `PlatformCredentialProvider`; retirar/reemplazar `_read_cert_from_storage` per-account.
- [x] 3.3 RED: test de que `Auth.Cuit` = `invoice_data.cuit_emisor` (representado) con `Token`/`Sign` del TA del representante, en `FECompUltimoAutorizado` y `FECAESolicitar`.
- [x] 3.4 GREEN: ajustar el armado del `Auth` (ya usa `cuit_emisor`; el cambio real es de dónde sale el TA). Verificar con dos CUIT representados distintos.
- [x] 3.5 TRIANGULATE: regresión RG 5616 (Code 10246), array Iva A/B, Factura C sin Iva, numeración `FECompUltimoAutorizado+1` — todos siguen verdes con el nuevo modelo de auth.
- [x] 3.6 REFACTOR: limpiar el constructor (`__init__`) — inyectar provider + ticket cache; sin lecturas de cert per-account.

## 4. Caché del TA — keyada por (representante + ambiente)

- [x] 4.0 SAFETY NET: baseline de `test_*wsaa_ticket_cache*` / `test_*ticket*`.
- [x] 4.1 RED: test de que la cache key es `"{representante_cuit}:wsfe:{ambiente}"` (una entrada por ambiente) y de que dos CUIT representados comparten el mismo TA.
- [x] 4.2 GREEN: ajustar la construcción de la key en `_get_wsaa_token` y la implementación del cache (D5) al esquema de plataforma.
- [x] 4.3 TRIANGULATE: reúso del TA vigente (no `loginCms`), TA expirado fuerza re-auth, persistencia entre invocaciones del relay.

## 5. Factory + 3 relay points — gate "platform cert configured?"

- [x] 5.0 SAFETY NET: baseline de `test_*adapter_factory*` y de los tests de los 3 relays (`process-pending`, `process-pending-cron`, `process_doc_by_id_background`).
- [x] 5.1 RED: test de `build_cae_adapter` — real cuando hay cert de plataforma configurado; stub cuando no; NO depende de `certificado_afip_path` por cuenta.
- [x] 5.2 GREEN: reemplazar `has_cert` (per-account) por el gate de config de plataforma; inyectar provider + ticket cache de plataforma.
- [x] 5.3 GREEN: actualizar los 3 relay points en `routers/fiscal.py` + `fiscal_profile_service.py` para construir el adapter con el gate de plataforma (no consultar `certificado_afip_path`).
- [x] 5.4 TRIANGULATE: cuenta con `certificado_afip_path = NULL` igual obtiene el adapter real cuando hay cert de plataforma; sin cert de plataforma → stub (default seguro).

## 6. Mapeo del error de delegación no autorizada

- [x] 6.1 RED: test de que el error de AFIP "representante no autorizado para <CUIT>" se normaliza a `error_code` de dominio (p. ej. `DELEGATION_NOT_AUTHORIZED`) con `error_detail` accionable, distinto de Code 10246/10016.
- [x] 6.2 GREEN: implementar el mapeo en la normalización de error del adapter; tratarlo como reintentable (no rechazo definitivo) según OQ-4.
- [x] 6.3 TRIANGULATE: delegación faltante → mensaje accionable + comprobante NO `authorized`; rechazo por datos → no muestra el mensaje de onboarding.

## 7. Backend — perfil fiscal: flag de delegación + deprecación de cert-upload

- [x] 7.1 RED: test del service/endpoint que persiste `delegacion_autorizada` (solo owner/admin; 403 para member); `GET /fiscal/profile` lo expone junto al CUIT representante.
- [x] 7.2 GREEN: extender `FiscalProfileCreate/Out` (Pydantic v2) + service + repo para el flag; exponer el CUIT representante (de config) en el `Out`.
- [x] 7.3 GREEN: deprecar `POST /fiscal/profile/cert-upload-url` y `PUT /fiscal/profile/cert-path` según OQ-2 (quitar del flujo o marcar deprecados/gated). Tests de que el flujo de delegación no los usa.
- [x] 7.4 TRIANGULATE: owner setea flag (ok) / member (403) / Out incluye flag + CUIT representante sin material criptográfico.

## 8. Frontend — guía de delegación reemplaza el upload (Next.js, sin any)

- [x] 8.1 Quitar/ocultar `CertUploadSection` y `SingleCertUpload` de `FiscalSettings.tsx`.
- [x] 8.2 Agregar la sección "Autorizá a EmprendeSmart en ARCA": paso a paso (CUIT representante visible, Administrador de Relaciones, servicio "Facturación Electrónica") + control para atestiguar `delegacion_autorizada`.
- [x] 8.3 Conservar `FiscalProfileForm` (CUIT/IVA/IIBB/ambiente) y `PointsOfSaleSection`; actualizar hooks (`use-fiscal-profile`) para el flag.
- [x] 8.4 (Si OQ-5 = en scope) Botón "Enviar al ARCA" en la venta — fuera de scope (OQ-5 = follow-up documentado).
- [x] 8.5 Verificar copy accionable cuando el relay devuelve `DELEGATION_NOT_AUTHORIZED`.

## 9. Validación E2E + cierre

- [ ] 9.1 E2E homologación (`@pytest.mark.integration`, manual, fuera del gate): facturar por un CUIT de prueba representado por el cert de plataforma; confirmar CAE.
- [x] 9.2 Confirmar regresión completa del gate `pytest -m "not integration"` verde — 586/586 passed.
- [ ] 9.3 Actualizar `CHANGES.md` (nuevo change V2.x) y la KB fiscal si corresponde.
- [ ] 9.4 Guardar el resultado del apply en engram (`opsx/v22-afip-delegation-billing/apply`).
- [x] 9.5 PR #211 abierto en feat/v22-afip-delegation-billing — HARD STOP (governance CRÍTICO, esperar sign-off PO).
