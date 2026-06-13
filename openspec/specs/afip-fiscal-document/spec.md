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

El sistema SHALL exponer un port `FiscalDocumentPort.request_cae(invoice_data) -> CAEResponse` en la capa de dominio, con al menos dos implementaciones inyectables por DI: `WSFEAdapter` (real, autentica via WSAA para el ticket de acceso y solicita el CAE via WSFEv1, contra el ambiente del perfil de la cuenta) y `WSFEStubAdapter` (devuelve un CAE ficticio deterministico para tests y dev). El dominio y los services SHALL conocer unicamente `CAE`, `CAEDueDate`, `DocumentType` y codigos de error normalizados; el SOAP/XML de AFIP SHALL permanecer encapsulado en el adapter.

#### Scenario: El stub devuelve un CAE ficticio

- **GIVEN** el `WSFEStubAdapter` inyectado
- **WHEN** se llama `request_cae` con datos de un comprobante valido
- **THEN** devuelve un `CAEResponse` con un `cae` ficticio deterministico y una `cae_due_date`, sin tocar la red

#### Scenario: El adaptador real resuelve ambiente desde el perfil

- **GIVEN** el `WSFEAdapter` real y un perfil con `ambiente = 'homologacion'`
- **WHEN** solicita un CAE
- **THEN** autentica via WSAA y pega al endpoint WSFEv1 de homologacion de ARCA

#### Scenario: El service no conoce el SOAP de AFIP

- **WHEN** se inspecciona el service de emision
- **THEN** solo referencia el port `FiscalDocumentPort` y los tipos de dominio (`CAE`, `CAEDueDate`, `DocumentType`), nunca estructuras SOAP/XML

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
