## MODIFIED Requirements

### Requirement: Adaptador WSFE detras de un ACL (port + impl real/stub)

El sistema SHALL exponer un port `FiscalDocumentPort.request_cae(invoice_data) -> CAEResponse` en la capa de dominio, con al menos dos implementaciones inyectables por DI: `WSFEAdapter` (real, autentica via WSAA para el ticket de acceso y solicita el CAE via WSFEv1, contra el ambiente del perfil de la cuenta) y `WSFEStubAdapter` (devuelve un CAE ficticio deterministico para tests y dev). El dominio y los services SHALL conocer unicamente `CAE`, `CAEDueDate`, `DocumentType` y codigos de error normalizados; el SOAP/XML de AFIP SHALL permanecer encapsulado en el adapter. El `WSFEAdapter` real SHALL apuntar a las URLs oficiales de AFIP, resueltas por `CAERequest.ambiente`: WSAA homologación `wsaahomo.afip.gob.ar`, WSAA producción `wsaa.afip.gob.ar`, WSFEv1 homologación `wswhomo.afip.gob.ar` (todas `.gob.ar`); y WSFEv1 **producción** `servicios1.afip.gov.ar` (con **`.gov.ar`**), porque el certificado TLS de ese server es válido únicamente para `servicios1.afip.gov.ar` — apuntar a `.gob.ar` da hostname mismatch (`SSLCertVerificationError`). El server WSFEv1 de producción además negocia una clave Diffie-Hellman corta, por lo que el cliente SOAP SHALL usar un security level de TLS reducido (`SECLEVEL=1`) que tolere ese handshake (`DH_KEY_TOO_SMALL`) SIN desactivar la verificación del certificado (hostname + CA se siguen validando).

**Modelo de delegación (este change).** El `WSFEAdapter` real SHALL autenticar contra WSAA usando **el certificado y la clave privada del representante de la plataforma** (capability `afip-platform-credential`), leídos de la ubicación fija server-side, y NO desde `{account_id}/afip.crt`/`{account_id}/afip.key`. En cada llamada a WSFEv1 (`FECompUltimoAutorizado`, `FECAESolicitar`) el adapter SHALL construir `Auth` con el `Token`/`Sign` del TA del representante y `Auth.Cuit` = **CUIT del emisor/representado** (de `fiscal_profiles.cuit`, viajando en `CAERequest.cuit_emisor`), de modo que AFIP valide que el representante está autorizado a facturar por ese CUIT. El adapter SHALL depender de la librería SOAP `zeep` (importada de forma lazy, de modo que el módulo y el `WSFEStubAdapter` funcionen aunque `zeep` no esté instalado).

Para que la solicitud de CAE sea **autorizable en producción** (no solo en homologación), el `WSFEAdapter` real SHALL, al construir cada `FECAEDetRequest`:

- (a) Incluir el campo `CondicionIVAReceptorId` (RG 5616/2024), derivado de la condición IVA del receptor (y/o de `DocTipo`). Para consumidor final el valor SHALL ser `5`. La **ausencia** de este campo provoca el rechazo de `FECAESolicitar` con **Code 10246**, por lo que el campo NO SHALL omitirse en producción.
- (b) Para comprobantes con IVA discriminado (tipo A/B), construir el array `Iva` con entradas `AlicIva {Id, BaseImp, Importe}` (IVA 21% → `Id = 5`) y mantener `ImpNeto`, `ImpIVA` e `ImpTotal` internamente consistentes (`ImpNeto + ImpIVA = ImpTotal` para el caso sin otros tributos ni conceptos no gravados). Para **comprobante tipo C** (monotributo) NO hay discriminación de IVA: el adapter SHALL **omitir** el array `Iva`, con `ImpIVA = 0` e `ImpNeto = ImpTotal`.
- (c) Obtener el número autorizable consultando `FECompUltimoAutorizado(PtoVta, CbteTipo)` y pidiendo `CbteDesde = CbteHasta = último + 1`, en lugar de confiar ciegamente en `invoice_data.number`.

Los datos de IVA y de condición del receptor necesarios para (a) y (b) SHALL viajar como **campos de dominio** sobre `CAERequest` (condición IVA del receptor + desglose neto/alícuotas), de modo que el adapter construya `CondicionIVAReceptorId` y el array `Iva` SIN filtrar estructuras SOAP/XML al dominio (se mantiene la frontera del ACL).

#### Scenario: El stub devuelve un CAE ficticio

- **GIVEN** el `WSFEStubAdapter` inyectado
- **WHEN** se llama `request_cae` con datos de un comprobante valido
- **THEN** devuelve un `CAEResponse` con un `cae` ficticio deterministico y una `cae_due_date`, sin tocar la red

#### Scenario: El adaptador real resuelve ambiente desde el perfil

- **GIVEN** el `WSFEAdapter` real y un perfil con `ambiente = 'homologacion'`
- **WHEN** solicita un CAE
- **THEN** autentica via WSAA y pega al endpoint WSFEv1 de homologacion de ARCA (`wswhomo.afip.gob.ar`)

#### Scenario: El adaptador autentica con el cert de plataforma, no con uno por cuenta

- **GIVEN** el `WSFEAdapter` real procesando un comprobante de una cuenta cuyo `fiscal_profiles.certificado_afip_path` es NULL
- **WHEN** obtiene el TA de WSAA
- **THEN** firma la TRA con el certificado y la clave privada del **representante de la plataforma** (ubicación fija server-side)
- **AND** no intenta leer `{account_id}/afip.crt` ni `{account_id}/afip.key`

#### Scenario: Auth.Cuit es el CUIT del emisor representado

- **GIVEN** el `WSFEAdapter` real construyendo la solicitud de CAE para un emisor con CUIT `C`
- **WHEN** arma el bloque `Auth` de `FECAESolicitar`/`FECompUltimoAutorizado`
- **THEN** usa el `Token`/`Sign` del TA del representante y `Auth.Cuit = C` (el CUIT del emisor/representado, no el del representante)

#### Scenario: Dominios de los endpoints de AFIP

- **WHEN** se inspeccionan las URLs WSAA y WSFEv1 del `WSFEAdapter`
- **THEN** WSAA (homologación y producción) y WSFEv1 homologación usan `.gob.ar`
- **AND** WSFEv1 producción usa `servicios1.afip.gov.ar` (`.gov.ar`), por el hostname de su certificado TLS

#### Scenario: El service no conoce el SOAP de AFIP

- **WHEN** se inspecciona el service de emision
- **THEN** solo referencia el port `FiscalDocumentPort` y los tipos de dominio (`CAE`, `CAEDueDate`, `DocumentType`), nunca estructuras SOAP/XML

#### Scenario: El módulo importa aunque zeep no esté instalado

- **GIVEN** un entorno sin `zeep` instalado
- **WHEN** se importa el módulo del `WSFEAdapter` y se usa el `WSFEStubAdapter`
- **THEN** el import no falla; el `ImportError` de `zeep` solo se levanta si se ejecuta el camino real (`request_cae` del `WSFEAdapter`)

#### Scenario: CondicionIVAReceptorId presente para consumidor final

- **GIVEN** el `WSFEAdapter` real construyendo un `FECAEDetRequest` para un receptor consumidor final
- **WHEN** arma el cuerpo de `FECAESolicitar`
- **THEN** el `FECAEDetRequest` incluye `CondicionIVAReceptorId = 5`
- **AND** si ese campo se omitiera, ARCA rechazaría la solicitud con Code 10246

#### Scenario: Array Iva para comprobante A/B con IVA 21%

- **GIVEN** un comprobante tipo B con importes gravados al 21%
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** incluye el array `Iva` con una entrada `AlicIva {Id: 5, BaseImp, Importe}` (Id=5 = alícuota 21%)
- **AND** `ImpNeto + ImpIVA = ImpTotal` (totales consistentes), con `ImpIVA` igual a la suma de los `Importe` de las alícuotas

#### Scenario: Comprobante tipo C sin array Iva

- **GIVEN** un comprobante tipo C (emisor monotributista)
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** NO incluye el array `Iva`, con `ImpIVA = 0` e `ImpNeto = ImpTotal`

---

### Requirement: Selección del adaptador WSFE por cuenta (real vs stub)

El sistema SHALL seleccionar la implementación del `FiscalDocumentPort` mediante una factory cuyo gate es **"certificado de plataforma configurado"** (no el certificado por cuenta): SHALL usar `WSFEAdapter` (real, WSAA + WSFEv1) cuando el certificado del representante de la plataforma está configurado y es legible server-side (cert + key + CUIT representante); en cualquier otro caso SHALL usar `WSFEStubAdapter`. El `WSFEStubAdapter` SHALL permanecer como **default**, de modo que mientras el certificado de plataforma no esté configurado ninguna cuenta cambie de comportamiento. El `ambiente` (homologación/producción) NO es parámetro de la factory: lo resuelve el `WSFEAdapter` internamente a partir de `CAERequest.ambiente` (que proviene del perfil de la cuenta — D2). La selección real-vs-stub SHALL aplicarse en los tres puntos de relay: el endpoint de usuario (`process-pending`), el endpoint de máquina cron (`process-pending-cron`, cross-account, por documento/cuenta) y el fire-and-forget post-emisión (`process_doc_by_id_background`).

#### Scenario: Sin certificado de plataforma se usa el stub

- **GIVEN** un entorno donde el certificado de plataforma no está configurado
- **WHEN** la factory construye el adaptador para procesar cualquier comprobante
- **THEN** devuelve un `WSFEStubAdapter` (sin tocar AFIP) y el comportamiento no cambia

#### Scenario: Con certificado de plataforma se usa el adaptador real para todas las cuentas

- **GIVEN** un entorno con el certificado de plataforma + CUIT representante configurados
- **WHEN** la factory construye el adaptador para procesar el comprobante de una cuenta (con o sin `certificado_afip_path` propio)
- **THEN** devuelve un `WSFEAdapter` real que autenticará con el cert de plataforma y pondrá `Auth.Cuit` = CUIT del emisor de esa cuenta

#### Scenario: El gate ya no depende de certificado_afip_path por cuenta

- **GIVEN** dos cuentas, una con `certificado_afip_path` no nulo y otra con `NULL`
- **WHEN** el certificado de plataforma está configurado y la factory construye el adaptador para cada una
- **THEN** ambas obtienen el `WSFEAdapter` real (la decisión es la config de plataforma, no el cert por cuenta)

---

### Requirement: Caché del Ticket de Acceso WSAA

El sistema SHALL cachear el Ticket de Acceso (TA) de WSAA (token + sign + expiración) keyado por `(representante de la plataforma + servicio 'wsfe' + ambiente)` y reusarlo mientras esté vigente, re-autenticando contra WSAA (`loginCms`) solo cuando el TA está expirado o próximo a expirar. Dado que en el modelo de delegación el material criptográfico es **único** (el del representante), la caché SHALL tener efectivamente **una entrada por ambiente** (no una por CUIT representado): todos los CUIT comparten el mismo TA del representante para un ambiente dado. La caché SHALL persistir **entre invocaciones del relay** (no in-process), de modo que el endpoint de usuario (`process-pending`), la máquina cron (`process-pending-cron`) y el fire-and-forget post-emisión (`process_doc_by_id_background`) — que corren en procesos/invocaciones separados — compartan el mismo TA. El reúso del TA vigente SHALL evitar el cooldown de WSAA (~10 min) que rechaza un nuevo `loginCms` con "el CUIT ya posee un TA válido".

#### Scenario: Un único TA por ambiente compartido entre cuentas

- **GIVEN** dos cuentas A (CUIT C1) y B (CUIT C2) representadas por la plataforma, ambas en producción
- **WHEN** se solicita un CAE para A y luego para B mientras el TA del representante está vigente
- **THEN** ambas reusan el **mismo** TA cacheado para `(representante, 'wsfe', produccion)` — no se ejecuta un `loginCms` por cuenta

#### Scenario: Reúso del TA vigente evita un nuevo loginCms

- **GIVEN** un TA vigente cacheado para `(representante, 'wsfe', ambiente)`
- **WHEN** se solicita un CAE para cualquier CUIT representado en ese ambiente antes de que el TA expire
- **THEN** el adapter reusa el TA cacheado y NO ejecuta un nuevo `loginCms` (evita el cooldown ~10 min y el error "el CUIT ya posee un TA válido")

#### Scenario: TA expirado fuerza re-autenticación WSAA

- **GIVEN** un TA cacheado cuya `expiration` ya pasó (o está dentro del margen de refresco)
- **WHEN** se solicita un CAE en ese ambiente
- **THEN** el adapter ejecuta un nuevo `loginCms` contra WSAA (con el cert del representante), obtiene un TA fresco y actualiza la caché

#### Scenario: La caché persiste entre invocaciones del relay

- **GIVEN** que `process-pending-cron` (proceso cron) obtuvo y cacheó el TA del representante para un ambiente
- **WHEN** `process_doc_by_id_background` (otra invocación/proceso) procesa otro comprobante en el mismo ambiente mientras el TA sigue vigente
- **THEN** reusa el TA cacheado (la caché no es in-process: sobrevive entre invocaciones del relay)
