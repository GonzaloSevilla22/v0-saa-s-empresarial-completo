# afip-fiscal-document — Delta (v21-wsfe-homologacion-wiring C-31)

## ADDED Requirements

### Requirement: Selección del adaptador WSFE por cuenta (real vs stub)

El sistema SHALL seleccionar la implementación del `FiscalDocumentPort` por cuenta mediante una factory: SHALL usar `WSFEAdapter` (real, WSAA + WSFEv1) cuando la cuenta tiene certificado cargado (`fiscal_profiles.certificado_afip_path IS NOT NULL`) y un cliente con `service_role` disponible para leer el certificado; en cualquier otro caso SHALL usar `WSFEStubAdapter`. El `WSFEStubAdapter` SHALL permanecer como **default**, de modo que las cuentas sin certificado no cambien de comportamiento. El `ambiente` (homologación/producción) NO es parámetro de la factory: lo resuelve el `WSFEAdapter` internamente a partir de `CAERequest.ambiente` (que proviene del perfil de la cuenta — D2). La selección real-vs-stub SHALL aplicarse en los tres puntos de relay: el endpoint de usuario (`process-pending`), el endpoint de máquina cron (`process-pending-cron`, cross-account, por documento/cuenta) y el fire-and-forget post-emisión (`process_doc_by_id_background`).

#### Scenario: Cuenta sin certificado usa el stub

- **GIVEN** una cuenta cuyo `fiscal_profiles.certificado_afip_path` es NULL
- **WHEN** la factory construye el adaptador para procesar su comprobante
- **THEN** devuelve un `WSFEStubAdapter` (sin tocar AFIP) y el comportamiento de esa cuenta no cambia

#### Scenario: Cuenta con certificado usa el adaptador real

- **GIVEN** una cuenta con `certificado_afip_path` no nulo y un cliente `service_role` disponible
- **WHEN** la factory construye el adaptador para procesar su comprobante
- **THEN** devuelve un `WSFEAdapter` real que leerá el cert del bucket y autenticará contra el ambiente del perfil

#### Scenario: El default es el stub cuando no hay service_role

- **GIVEN** una cuenta con certificado pero sin cliente `service_role` disponible en ese contexto
- **WHEN** la factory construye el adaptador
- **THEN** devuelve el `WSFEStubAdapter` (fallback seguro: nunca intenta una llamada real sin poder leer el cert)

---

## MODIFIED Requirements

### Requirement: Adaptador WSFE detras de un ACL (port + impl real/stub)

El sistema SHALL exponer un port `FiscalDocumentPort.request_cae(invoice_data) -> CAEResponse` en la capa de dominio, con al menos dos implementaciones inyectables por DI: `WSFEAdapter` (real, autentica via WSAA para el ticket de acceso y solicita el CAE via WSFEv1, contra el ambiente del perfil de la cuenta) y `WSFEStubAdapter` (devuelve un CAE ficticio deterministico para tests y dev). El dominio y los services SHALL conocer unicamente `CAE`, `CAEDueDate`, `DocumentType` y codigos de error normalizados; el SOAP/XML de AFIP SHALL permanecer encapsulado en el adapter. El `WSFEAdapter` real SHALL apuntar a las URLs oficiales de AFIP bajo el dominio **`.gob.ar`** (WSAA homologación `wsaahomo.afip.gob.ar`, WSAA producción `wsaa.afip.gob.ar`, WSFEv1 homologación `wswhomo.afip.gob.ar`, WSFEv1 producción `servicios1.afip.gob.ar`), resueltas por `CAERequest.ambiente`. El `WSFEAdapter` real SHALL leer el certificado (`{account_id}/afip.crt`) y la clave privada (`{account_id}/afip.key`, PEM sin password) del bucket privado `afip-certs` server-side, y SHALL depender de la librería SOAP `zeep` (importada de forma lazy, de modo que el módulo y el `WSFEStubAdapter` funcionen aunque `zeep` no esté instalado).

#### Scenario: El stub devuelve un CAE ficticio

- **GIVEN** el `WSFEStubAdapter` inyectado
- **WHEN** se llama `request_cae` con datos de un comprobante valido
- **THEN** devuelve un `CAEResponse` con un `cae` ficticio deterministico y una `cae_due_date`, sin tocar la red

#### Scenario: El adaptador real resuelve ambiente desde el perfil

- **GIVEN** el `WSFEAdapter` real y un perfil con `ambiente = 'homologacion'`
- **WHEN** solicita un CAE
- **THEN** autentica via WSAA y pega al endpoint WSFEv1 de homologacion de ARCA (`wswhomo.afip.gob.ar`)

#### Scenario: Las URLs del adaptador usan el dominio .gob.ar

- **WHEN** se inspeccionan las URLs WSAA y WSFEv1 del `WSFEAdapter` para ambos ambientes
- **THEN** las cuatro usan el dominio `.gob.ar` y ninguna usa `.gov.ar`

#### Scenario: El service no conoce el SOAP de AFIP

- **WHEN** se inspecciona el service de emision
- **THEN** solo referencia el port `FiscalDocumentPort` y los tipos de dominio (`CAE`, `CAEDueDate`, `DocumentType`), nunca estructuras SOAP/XML

#### Scenario: El módulo importa aunque zeep no esté instalado

- **GIVEN** un entorno sin `zeep` instalado
- **WHEN** se importa el módulo del `WSFEAdapter` y se usa el `WSFEStubAdapter`
- **THEN** el import no falla; el `ImportError` de `zeep` solo se levanta si se ejecuta el camino real (`request_cae` del `WSFEAdapter`)
