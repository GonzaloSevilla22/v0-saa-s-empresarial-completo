# afip-fiscal-document — Spec (v21-fiscal-profile C-27)

## Purpose

Ciclo de vida del comprobante fiscal electronico con CAE de AFIP: emision sincrona que reserva numero y persiste `pending_cae` sin tocar AFIP, mas proceso de background idempotente (`CAERelayProcessor` via `pg_cron`) que obtiene el CAE con backoff. El port `FiscalDocumentPort` (con `WSFEAdapter` real y `WSFEStubAdapter` para tests) encapsula el SOAP/XML de AFIP del dominio. Tambien provee la funcion pura `resolve_invoice_type` para determinar el tipo de comprobante (A/B/C). Depende de `fiscal-profile` y `document-sequence`.

## Requirements

### Requirement: Persistencia del comprobante fiscal con maquina de estados de CAE

El sistema SHALL persistir cada comprobante emitido en la tabla `fiscal_documents` (`id` UUID PK, `account_id` UUID FK, `fiscal_profile_id` UUID FK, `point_of_sale_id` UUID FK `points_of_sale`, `comprobante_type` TEXT, `punto_de_venta` INTEGER (snapshot del `numero` del PV al emitir), `number` BIGINT, `client_id` UUID FK NULL, `total` NUMERIC, `status` TEXT NOT NULL, `cae` TEXT NULL, `cae_due_date` DATE NULL, `attempts` INTEGER NOT NULL DEFAULT 0, `next_attempt_at` TIMESTAMPTZ NULL, `last_error` TEXT NULL, `created_at` TIMESTAMPTZ). `status` MUST estar restringida por CHECK a `'pending_cae'`, `'authorized'`, `'rejected'`. La tabla SHALL tener RLS por `account_id`.

#### Scenario: Comprobante nace en pending_cae

- **WHEN** se emite un comprobante
- **THEN** la fila se persiste con `status = 'pending_cae'`, `cae = NULL`, `cae_due_date = NULL` y `attempts = 0`

#### Scenario: Estado invalido rechazado por la DB

- **WHEN** se intenta insertar un comprobante con `status = 'en_proceso'`
- **THEN** el INSERT falla por violacion del CHECK constraint

#### Scenario: Miembro de otra cuenta no ve el comprobante

- **GIVEN** dos cuentas A y B con comprobantes propios
- **WHEN** un miembro de A consulta `fiscal_documents`
- **THEN** solo recibe los comprobantes de A (RLS aisla)

---

### Requirement: Emision sincrona reserva numero y persiste pending_cae sin tocar AFIP

El sistema SHALL emitir el comprobante en una transaccion corta que resuelve el punto de venta efectivo (ver capability `fiscal-profile`, "Seleccion del punto de venta en la emision"), reserva el numero via `rpc_next_document_number(point_of_sale_id, comprobante_type)` y persiste la fila con `status = 'pending_cae'`, SIN llamar a AFIP dentro de esa transaccion. La obtencion del CAE SHALL ocurrir fuera de la transaccion de emision (y, cuando exista, fuera de la transaccion de la venta — C-29).

#### Scenario: La emision no depende del uptime de AFIP

- **GIVEN** el web service de AFIP esta caido
- **WHEN** se emite un comprobante
- **THEN** la emision completa correctamente con `status = 'pending_cae'` y el numero reservado, sin error de AFIP

#### Scenario: El numero se reserva en la emision por punto de venta

- **WHEN** se emite un comprobante de tipo `'factura_b'` para el punto de venta P1 (`numero = 1`)
- **THEN** el comprobante toma el siguiente numero de la secuencia `(P1, 'factura_b')`, queda persistido con ese `number`, `point_of_sale_id = P1` y `punto_de_venta = 1`

---

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

---

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

### Requirement: Obtencion del CAE en background con reintento por backoff

El sistema SHALL obtener el CAE de los comprobantes `pending_cae` mediante un proceso de background idempotente que, por cada comprobante: llama `request_cae` via el adapter; al exito actualiza `status = 'authorized'`, `cae`, `cae_due_date`; al rechazo definitivo actualiza `status = 'rejected'`, `last_error`; ante error transitorio incrementa `attempts` y reprograma `next_attempt_at` con backoff. El proceso SHALL ser idempotente: reprocesar un comprobante ya `authorized` no SHALL alterarlo.

#### Scenario: Comprobante autorizado al obtener el CAE

- **GIVEN** un comprobante en `pending_cae` y el adapter devuelve un CAE valido
- **WHEN** el proceso de background lo procesa
- **THEN** `status` pasa a `'authorized'`, se persisten `cae` y `cae_due_date`

#### Scenario: Reintento con backoff ante error transitorio de AFIP

- **GIVEN** un comprobante en `pending_cae` y el adapter falla con un error transitorio
- **WHEN** el proceso lo procesa
- **THEN** `attempts` se incrementa, `next_attempt_at` se reprograma a futuro con backoff y `status` sigue en `'pending_cae'`

#### Scenario: Rechazo definitivo de AFIP

- **GIVEN** un comprobante en `pending_cae` y el adapter devuelve un rechazo definitivo
- **WHEN** el proceso lo procesa
- **THEN** `status` pasa a `'rejected'` y `last_error` guarda el detalle

#### Scenario: Reprocesar un comprobante autorizado es idempotente

- **GIVEN** un comprobante ya `authorized` con CAE
- **WHEN** el proceso de background vuelve a recorrerlo
- **THEN** no lo modifica (no pide un nuevo CAE ni cambia el estado)

---

### Requirement: Resolucion del tipo de comprobante (A/B/C) como funcion pura

El sistema SHALL determinar el tipo de comprobante mediante un Domain Service puro `resolve_invoice_type(emisor_iva_condition, receptor_iva_condition) -> DocumentType`, sin I/O: emisor RI + receptor RI → comprobante A; emisor RI + receptor consumidor final/monotributista/exento → comprobante B; emisor monotributista → comprobante C.

#### Scenario: RI a RI emite factura A

- **WHEN** emisor `'responsable_inscripto'` factura a receptor `'responsable_inscripto'`
- **THEN** el resolvedor devuelve tipo A

#### Scenario: RI a consumidor final emite factura B

- **WHEN** emisor `'responsable_inscripto'` factura a receptor `'consumidor_final'`
- **THEN** el resolvedor devuelve tipo B

#### Scenario: Monotributista emite factura C

- **WHEN** emisor `'monotributista'` factura a cualquier receptor
- **THEN** el resolvedor devuelve tipo C
