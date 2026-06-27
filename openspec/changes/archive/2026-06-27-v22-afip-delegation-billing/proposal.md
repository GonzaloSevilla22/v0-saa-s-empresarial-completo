## Why

Hoy la facturación electrónica con CAE (construida en C-27 `fiscal-profile` + C-31 `afip-fiscal-document`) usa un modelo de **certificado por usuario**: cada cuenta tiene que generar un CSR, tramitar su propio certificado en ARCA, autorizar el web service `wsfe` para ese certificado, y subir el `.crt` + `.key` al bucket privado `afip-certs` en `{account_id}/afip.crt|afip.key`. Es demasiada fricción para un microemprendedor — un trámite técnico que la mayoría no va a completar. El PO (decisión 2026-06-23, engram #331) decidió migrar al **modelo de delegación**, igual que Xubio / Facturante / TusFacturas: la plataforma tiene UN solo certificado y factura por cuenta de cada usuario, que solo debe autorizar a EmprendeSmart como su representante en ARCA (~5 clicks) y registrar su punto de venta.

## What Changes

- **BREAKING (modelo de autenticación AFIP).** El `WSFEAdapter` deja de leer un certificado por cuenta (`{account_id}/afip.crt`) y pasa a autenticar SIEMPRE con **el certificado de la plataforma** (el "representante"). En cada `FECAESolicitar`/`FECompUltimoAutorizado` setea `Auth.Cuit` = CUIT del **emisor/usuario** (el "representado", de `fiscal_profiles.cuit`). AFIP valida que el certificado de la plataforma esté autorizado para representar a ese CUIT.
- **Factory.** `build_cae_adapter` reemplaza la lógica "¿la cuenta tiene cert? (`certificado_afip_path IS NOT NULL`)" por "¿hay certificado de plataforma configurado?". `WSFEStubAdapter` sigue siendo el **default seguro** cuando no hay certificado de plataforma configurado (ningún cambio de comportamiento para ese caso).
- **Caché del TA WSAA.** El TA pasa a estar keyado por `(certificado de plataforma + ambiente)` — efectivamente **un TA por ambiente**, compartido entre todos los CUIT representados, en vez de uno por CUIT/cuenta. La tabla `wsaa_access_tickets` (per-CUIT) se reconcilia/migra a este esquema.
- **Configuración del certificado de plataforma.** El certificado + la clave privada de la plataforma viven **server-side en UNA ubicación fija** (env/secret manager o un bucket/secret restringido leído solo por el backend), NUNCA per-account, NUNCA expuestos al cliente. Es el secreto más sensible de toda la plataforma (puede facturar por cualquier usuario): governance **CRÍTICO**.
- **Deprecación del upload de cert por usuario.** Los endpoints `POST /fiscal/profile/cert-upload-url` y `PUT /fiscal/profile/cert-path` quedan deprecados para el flujo de delegación (no se usan en el camino feliz). `fiscal_profiles.certificado_afip_path` deja de ser relevante para la mayoría de las cuentas.
- **Onboarding de delegación (perfil fiscal).** El perfil mantiene CUIT + condición IVA + ambiente + puntos de venta, y suma un flag de **"delegación autorizada"** (el usuario atestigua que completó la relación en ARCA — AFIP no expone una forma fácil de verificarlo, así que el sistema intenta facturar y muestra el error si la delegación falta). El sistema debe comportarse de forma clara **antes** de que el usuario autorice: el `FECAESolicitar` falla con error de autorización → se mapea a un mensaje accionable "Autorizá a EmprendeSmart (CUIT X) en ARCA → Administrador de Relaciones → Facturación Electrónica".
- **UI / onboarding.** Se oculta/elimina la sección de upload de certificado en `FiscalSettings.tsx`. Se reemplaza por una guía paso a paso de la delegación en ARCA + el CRUD de PV ya existente. Se conservan CUIT + condición IVA + ambiente.
- **(Open Question, posible scope o follow-up)** El botón "Enviar al ARCA" en una venta (intento original de `producto-facturacion-afip-ux`).

## Capabilities

### New Capabilities
- `afip-platform-credential`: Configuración y custodia del certificado/CUIT representante de la plataforma (single secret server-side), su resolución por ambiente, el flag de "delegación autorizada" por cuenta, y el mapeo del error de delegación faltante a un mensaje accionable de onboarding.

### Modified Capabilities
- `afip-fiscal-document`: El adaptador WSFE autentica con el certificado de plataforma (no per-account) y setea `Auth.Cuit` = CUIT del emisor/representado por comprobante; la factory selecciona real-vs-stub según "certificado de plataforma configurado" (no per-account cert); la caché del TA WSAA pasa a keyearse por `(plataforma + ambiente)` (~1 entrada por ambiente). Se preservan sin cambios: TLS de producción (`servicios1.afip.gov.ar` + `SECLEVEL=1`), `CondicionIVAReceptorId` (RG 5616), array `Iva`, numeración por `FECompUltimoAutorizado`, Factura C para monotributistas.
- `fiscal-profile`: Se deprecan los endpoints/UI de upload del certificado por usuario; se agrega el flag "delegación autorizada" al perfil y el onboarding de la relación ARCA. Se conservan CUIT + condición IVA + ambiente + multi-PV.

## Impact

- **Backend (Python/FastAPI).** `backend/services/fiscal/wsfe_adapter.py` (carga del cert de plataforma + `Auth.Cuit` = representado), `backend/services/fiscal/adapter_factory.py` (gate "platform cert configured?"), `backend/services/fiscal/wsaa_ticket_cache.py` (clave por plataforma+ambiente), `backend/services/fiscal/fiscal_profile_service.py` y `backend/routers/fiscal.py` (3 relay points + endpoints cert-upload deprecados), `backend/core/config.py` (config del cert de plataforma).
- **DB / migraciones.** Reconciliación de `wsaa_access_tickets` (de per-CUIT a per-ambiente); columna/flag de delegación en `fiscal_profiles`. Migraciones escritas en `supabase/migrations/`, aplicadas por CI (`deploy.yml`), no a mano.
- **Frontend (Next.js).** `frontend/components/settings/FiscalSettings.tsx` (quitar `CertUploadSection`, agregar guía de delegación ARCA), hooks de perfil fiscal asociados.
- **Seguridad / governance.** CRÍTICO: la clave privada del certificado de plataforma es el secreto más sensible del sistema. Requiere sign-off explícito del PO (Gate 0) antes de cualquier implementación. Dinero real / fiscal.
- **Cuenta del PO.** Ya tiene un cert per-user (`AliadataProd`, CUIT 20422662457) con cadena de producción validada; hay que definir cómo transiciona al modelo de delegación (Open Question).
- **No cambia.** Los campos de CAE de producción ya resueltos (RG 5616, array Iva, numeración, Factura C) y el ciclo de vida `pending_cae → authorized/rejected` con relay `pg_cron`.
