## Context

La facturación electrónica con CAE ya está construida y validada en producción a nivel de protocolo:

- **C-27 `fiscal-profile`**: perfil fiscal (CUIT, condición IVA, ambiente), multi-PV, ciclo `pending_cae → authorized/rejected`, relay `pg_cron`.
- **C-31 `afip-fiscal-document` (PR #205) + hardening (PR #210)**: `WSFEAdapter` real con WSAA + WSFEv1, TLS de producción resuelto (`servicios1.afip.gov.ar` + `SECLEVEL=1`), `CondicionIVAReceptorId` (RG 5616), array `Iva`, numeración por `FECompUltimoAutorizado`, Factura C, caché del TA (`wsaa_access_tickets`). CAE real de homologación obtenido (86250464989491).

El modelo actual es **cert por usuario**: cada cuenta tramita su certificado, autoriza `wsfe`, y sube `.crt`+`.key` a `afip-certs/{account_id}/`. La factory `build_cae_adapter(has_cert=...)` decide real-vs-stub según `fiscal_profiles.certificado_afip_path`. El TA se cachea por `(account_id, cuit, ambiente)`.

**Disparador del cambio** (engram #331, 2026-06-23): el PO sufrió el "Error interno del servidor" al subir su cert y comparó con Xubio ("solo poníamos el PV y dábamos enviar"). Decisión de producto: migrar al **modelo de delegación** (Xubio / Facturante / TusFacturas): la plataforma tiene UN certificado representante y factura por cuenta de cada usuario, que solo autoriza a EmprendeSmart en ARCA + carga su PV.

**Restricciones del proyecto**: Backend FastAPI 3 capas (routers→services→repositories), asyncpg JWT-passthrough, `service_role` solo para lecturas aisladas de cert/TA. SOAP vía `zeep` (lazy import) encapsulado en el adapter (ACL). Strict TDD (pytest, gate `-m "not integration"`; ARCA real = `@pytest.mark.integration`, manual). Migraciones aplicadas por CI (`deploy.yml` corre `supabase db push` al mergear a main) — se escriben los archivos, no se aplican a mano. Frontend Next.js, sin `any`, componentes PascalCase. **Governance CRÍTICO** (fiscal, dinero real): propose/design only; no se escribe código hasta sign-off del PO.

## Goals / Non-Goals

**Goals:**

- Que un microemprendedor pueda facturar tras (1) cargar CUIT + condición IVA + PV en la app y (2) autorizar a EmprendeSmart en ARCA (~5 clicks, una vez). Sin CSR, sin cert, sin upload.
- `WSFEAdapter` autentica con el cert de plataforma (un TA por ambiente) y factura por cada usuario vía `Auth.Cuit = <CUIT representado>`.
- Mantener el `WSFEStubAdapter` como default seguro (sin cert de plataforma configurado → nadie toca AFIP).
- Conservar intacto todo lo de producción ya resuelto (TLS, RG 5616, array Iva, numeración, Factura C).
- Mensaje accionable cuando la cuenta aún no autorizó la delegación.

**Non-Goals:**

- NO se reimplementa el ensamblado del `FECAEDetRequest` (RG 5616, Iva, numeración, Factura C ya están y se preservan).
- NO se migran IA/OCR a Python (DEC-15).
- NO se construye una verificación programática de la relación de delegación en ARCA (AFIP no expone un endpoint simple; se usa "intentar y exponer el error").
- NO se decide en este propose el destino físico final del secreto de plataforma ni el destino del per-user cert — son Open Questions para el sign-off (Gate 0).
- El botón "Enviar al ARCA" en la venta queda como Open Question (scope aquí vs follow-up).

## Decisions

### D1 — Certificado representante: reusar `AliadataProd` (CUIT 20422662457) para el MVP

**Decisión (recomendada, a confirmar en Gate 0):** usar el certificado de producción `AliadataProd` (CUIT 20422662457) que el PO ya creó y validó contra ARCA producción, como representante de la plataforma para el MVP.

**Por qué:** ya existe, ya tiene cadena de producción validada (CAE real obtenido), y es el CUIT del PO (que además factura las suscripciones). Evita el trámite de sacar un CUIT/cert de empresa nuevo para arrancar.

**Alternativa:** un CUIT/cert de empresa dedicado (separar la identidad fiscal "EmprendeSmart S.A./persona jurídica" de la del PO). Mejor a largo plazo (límites de responsabilidad, branding fiscal), pero agrega trámite. → **Open Question OQ-1** para el PO.

### D2 — `Auth.Cuit` = representado; TA del representante (delegación AFIP)

El `WSFEAdapter` firma la TRA de WSAA con el cert del **representante** (obtiene UN TA por ambiente) y, en cada `FECompUltimoAutorizado`/`FECAESolicitar`, arma `Auth = {Token, Sign (del representante), Cuit = <CUIT del emisor representado>}`. AFIP valida que el representante esté habilitado para ese CUIT en el Administrador de Relaciones.

**Cambio mínimo en el código actual:** hoy `auth["Cuit"] = int(invoice_data.cuit_emisor...)` ya usa el CUIT del emisor — eso **no cambia**. Lo que cambia es de dónde sale el material que firma el TA: de `{account_id}/afip.crt` → cert de plataforma. `CAERequest.cuit_emisor` sigue siendo el CUIT representado. No se necesita un campo nuevo en `CAERequest` para el representante (el cert representante lo resuelve el adapter desde config).

### D3 — Carga del cert de plataforma: config server-side, no per-account

El `WSFEAdapter.__init__` deja de depender de `supabase_service_client` para leer `{account_id}/afip.crt`. En su lugar, el adapter resuelve el material del representante desde una fuente de plataforma. **Recomendado:** un proveedor inyectable (`PlatformCredentialProvider`) que lee de `settings` (env/secret) — desacopla el adapter de la fuente concreta y es testeable. La fuente concreta (env var con el PEM, secret manager de Render, o un bucket restringido de plataforma leído con `service_role`) es **OQ-3** (dónde vive la private key).

`_read_cert_from_storage(path)` (per-account) se reemplaza/retira; `_sign_tra(cert, key, ambiente)` queda igual (ya recibe cert+key como `bytes`).

### D4 — Factory: gate "platform cert configured?"

`build_cae_adapter` reemplaza el parámetro `has_cert` (per-account) por la presencia de config de plataforma:

- `platform_cert configurado` (cert + key + CUIT representante legibles) → `WSFEAdapter` real (inyectando el `PlatformCredentialProvider` + el ticket cache de plataforma).
- en otro caso → `WSFEStubAdapter` (default seguro).

Los 3 relay points (`process-pending`, `process-pending-cron`, `process_doc_by_id_background`) dejan de consultar `certificado_afip_path` por cuenta para decidir el adapter; consultan la config de plataforma una vez. `CAERequest.cuit_emisor`/`ambiente` siguen viniendo del perfil de cada cuenta/doc.

### D5 — Caché del TA: keyada por (plataforma + ambiente)

La key del TA pasa de `"{cuit}:wsfe:{ambiente}"` (por cuenta) a `"{representante_cuit}:wsfe:{ambiente}"` — efectivamente **una entrada por ambiente** (el CUIT del representante es constante). Como el cert es único, todos los CUIT representados comparten el TA del representante.

**Reconciliación de `wsaa_access_tickets`** (hoy PK `(account_id, cuit, ambiente)`): opciones — (a) reusar la tabla poniendo `account_id = <cuenta de plataforma sentinel>` y `cuit = <representante>`; (b) nueva tabla `platform_wsaa_tickets(ambiente PK, token, sign, expires_at)`; (c) limpiar la tabla y reutilizar el esquema con una fila por ambiente. **Recomendado (b)** por claridad semántica (es estado de plataforma, no de cuenta) y para no arrastrar RLS por `account_id` sobre un secreto de plataforma. La migración escribe el DDL; CI lo aplica. Las filas per-CUIT viejas quedan inertes (se pueden truncar).

### D6 — Flag de delegación: atestación, no verificación ("attempt-and-surface")

`fiscal_profiles.delegacion_autorizada BOOLEAN DEFAULT FALSE`. Es una atestación del usuario para UX (mostrar "pendiente/autorizado"), no un gate duro: la verdad la da AFIP. El sistema **intenta** facturar y, si AFIP rechaza por "no autorizado a representar", mapea el error a un mensaje accionable. No se bloquea la emisión `pending_cae` por el flag (el comprobante igual nace y el relay lo intenta); el flag puede usarse para advertir en la UI antes de intentar.

### D7 — Mapeo del error de delegación

En `_call_wsfe`/normalización de error, distinguir el código/detalle de AFIP de "el CUIT representante no está autorizado a representar a <CUIT>" de un rechazo por datos (Code 10246, Code 10016). Mapear a `error_code` de dominio (p. ej. `DELEGATION_NOT_AUTHORIZED`) con `error_detail` accionable. Tratarlo como **reintentable** (el usuario puede autorizar y reintentar) en vez de rechazo definitivo, para que el relay lo reintente tras la autorización. El código exacto de AFIP para este caso se confirma en homologación durante apply (es de la familia de errores de autenticación/Token, no de validación de comprobante).

### D8 — UI: guía de delegación reemplaza el upload

`FiscalSettings.tsx`: se elimina/oculta `CertUploadSection` y `SingleCertUpload`. Se agrega una sección "Autorizá a EmprendeSmart en ARCA" con el paso a paso (CUIT representante visible, link a ARCA Administrador de Relaciones, servicio "Facturación Electrónica") + un control para atestiguar (`delegacion_autorizada`). Se conservan `FiscalProfileForm` (CUIT/IVA/IIBB/ambiente) y `PointsOfSaleSection`. El botón "Enviar al ARCA" en la venta (intento `producto-facturacion-afip-ux`) es **OQ-5**.

## Risks / Trade-offs

- **[CRÍTICO — la private key de plataforma es ahora el secreto que factura por todos]** → vive solo server-side, nunca en el cliente, nunca logueada, nunca en respuestas; lectura restringida al backend (env/secret/`service_role` aislado). Rotación y custodia definidas en Gate 0. Un leak permite emitir comprobantes a nombre de cualquier usuario representado.
- **[No hay verificación previa de la delegación]** → se acepta "attempt-and-surface": el primer intento real confirma o falla con mensaje accionable. Riesgo de fricción (el usuario cree que autorizó y no). Mitigación: copy claro + reintento del relay tras autorizar.
- **[Cooldown de WSAA ~10 min con un TA único]** → con un solo TA por ambiente el riesgo de "el CUIT ya posee un TA válido" baja (menos logins), pero un bug que invalide la caché provocaría reintentos de `loginCms` del único CUIT representante → throttling global de toda la plataforma. Mitigación: respetar el margen de refresco (30 min) y el reúso de cache; alertar si hay logins repetidos.
- **[Límites/cuotas de AFIP por representante]** → todo el volumen de la plataforma pasa por un CUIT representante. Verificar que ARCA no imponga cuotas que un solo representante sature (Open Question operativa, no de este propose).
- **[Migración de la cuenta del PO]** → ya tiene cert per-user y cadena validada; transición definida en Gate 0 (probable: se representa a sí misma con el mismo cert que es el candidato a representante).
- **[Coexistencia per-user vs delegación]** → si se conserva el per-user cert como fallback avanzado, la factory necesita un árbol de decisión (plataforma > per-account > stub) más complejo. Recomendado para el MVP: reemplazo total, per-user deprecado. → OQ-2.

## Migration Plan

1. **Gate 0 — sign-off del PO** (bloqueante, antes de cualquier código): resolver OQ-1..OQ-5.
2. Migración DB: `fiscal_profiles.delegacion_autorizada` + tabla/esquema del TA de plataforma (D5). Archivos en `supabase/migrations/`; aplica CI.
3. Config del cert de plataforma (D3) en el entorno (Render secret/env). Sin exponer al cliente.
4. Adapter + factory + cache (D2/D4/D5) con TDD; los tests reales contra ARCA quedan `@pytest.mark.integration` (manual, fuera del gate).
5. Frontend: guía de delegación (D8); quitar upload.
6. **Rollback:** el `WSFEStubAdapter` sigue siendo el default; si el cert de plataforma no se configura o se desconfigura, el sistema cae al stub (no factura real, pero no rompe). El per-user cert puede reactivarse si se conservó (según OQ-2). Las migraciones son aditivas (columna nueva + tabla nueva), reversibles.
7. Validación E2E en homologación con un CUIT de prueba representado por el cert de plataforma antes de habilitar producción.

## Open Questions — RESUELTAS (Gate 0 sign-off, 2026-06-23, PO: GonzaloSevilla22)

- **OQ-1 ✅ RESUELTA:** Reusar `AliadataProd` (CUIT 20422662457, cert ya validado en producción) como representante de la plataforma para el MVP. No se crea un CUIT/cert de empresa dedicado en esta fase.
- **OQ-2 ✅ RESUELTA:** Conservar el per-user cert como opción avanzada/fallback oculto (no eliminar los code paths de cert por usuario). El flujo de delegación es el default; el per-user queda gateado detrás del flag avanzado. Los endpoints de cert-upload se marcan deprecados (no expuestos en la UI de delegación, pero el código permanece).
- **OQ-3 ✅ RESUELTA:** La private key de plataforma vive en **variables de entorno del backend** (`AFIP_PLATFORM_CERT` = PEM del certificado, `AFIP_PLATFORM_KEY` = PEM de la clave privada, `AFIP_PLATFORM_CUIT` = CUIT del representante). Leídas solo server-side por el backend (Render secrets). NUNCA en respuestas de API ni en logs. **Governance CRÍTICO — rotación: reusar las variables de entorno del secret manager de Render; nunca comitear material criptográfico real.**
- **OQ-4 ✅ RESUELTA:** NO se gatea la emisión por el flag `delegacion_autorizada`. La emisión siempre se intenta (strategy "attempt-and-surface"). Si AFIP rechaza por "no autorizado a representar", el error se mapea a `DELEGATION_NOT_AUTHORIZED` con mensaje accionable. El comprobante NO queda `authorized`; el error es reintentable (el relay lo reintenta después de que el usuario autorice en ARCA). El flag `delegacion_autorizada` es solo UX (advertencia pre-intento).
- **OQ-5 ✅ RESUELTA:** El botón "Enviar al ARCA" en la venta queda **OUT OF SCOPE** de este change (follow-up en `producto-facturacion-afip-ux`). No se implementa aquí.
- **OQ-6 ✅ RESUELTA:** La cuenta del PO (CUIT 20422662457) transiciona automáticamente: el mismo cert que es el representante de la plataforma se usa para representarse a sí mismo. No requiere trámite extra ni migración de datos. Los objetos ya subidos a `afip-certs/{account_id}/` quedan inertes (no se eliminan; la factory dejará de consultarlos para ese usuario una vez configurado el cert de plataforma).
