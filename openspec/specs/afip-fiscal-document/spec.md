# afip-fiscal-document — Spec (v21-fiscal-profile C-27; updated facturar-venta-afip)

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

El sistema SHALL exponer un port `FiscalDocumentPort.request_cae(invoice_data) -> CAEResponse` en la capa de dominio, con al menos dos implementaciones inyectables por DI: `WSFEAdapter` (real, autentica via WSAA para el ticket de acceso y solicita el CAE via WSFEv1, contra el ambiente del perfil de la cuenta) y `WSFEStubAdapter` (devuelve un CAE ficticio deterministico para tests y dev). El dominio y los services SHALL conocer unicamente `CAE`, `CAEDueDate`, `DocumentType` y codigos de error normalizados; el SOAP/XML de AFIP SHALL permanecer encapsulado en el adapter. El `WSFEAdapter` real SHALL apuntar a las URLs oficiales de AFIP, resueltas por `CAERequest.ambiente`: WSAA homologación `wsaahomo.afip.gob.ar`, WSAA producción `wsaa.afip.gob.ar`, WSFEv1 homologación `wswhomo.afip.gob.ar` (todas `.gob.ar`); y WSFEv1 **producción** `servicios1.afip.gov.ar` (con **`.gov.ar`**), porque el certificado TLS de ese server es válido únicamente para `servicios1.afip.gov.ar` — apuntar a `.gob.ar` da hostname mismatch (`SSLCertVerificationError`). El server WSFEv1 de producción además negocia una clave Diffie-Hellman corta, por lo que el cliente SOAP SHALL usar un security level de TLS reducido (`SECLEVEL=1`) que tolere ese handshake (`DH_KEY_TOO_SMALL`) SIN desactivar la verificación del certificado (hostname + CA se siguen validando). El `WSFEAdapter` real SHALL leer el certificado (`{account_id}/afip.crt`) y la clave privada (`{account_id}/afip.key`, PEM sin password) del bucket privado `afip-certs` server-side, y SHALL depender de la librería SOAP `zeep` (importada de forma lazy, de modo que el módulo y el `WSFEStubAdapter` funcionen aunque `zeep` no esté instalado).

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

### Requirement: Numeración autoritativa de ARCA vía FECompUltimoAutorizado

El sistema SHALL obtener el número de comprobante autorizable consultando a ARCA `FECompUltimoAutorizado(PtoVta, CbteTipo)` por cada par `(punto de venta, tipo de comprobante)` y solicitando `CbteDesde = CbteHasta = último + 1`, en lugar de confiar únicamente en `invoice_data.number`. El sistema SHALL reconciliar ese número autoritativo con el número reservado localmente por `rpc_next_document_number(point_of_sale_id, comprobante_type)` (ver requisito "Emision sincrona reserva numero..."): ante un desfasaje entre el número local reservado y el último autorizado por ARCA, el sistema SHALL detectar y manejar el desync (el error de ARCA por número fuera de secuencia es **Code 10016**) sin persistir un CAE contra un número incorrecto.

#### Scenario: Usa último + 1 de ARCA

- **GIVEN** un comprobante `pending_cae` para `(PtoVta=1, CbteTipo=6)` y `FECompUltimoAutorizado(1, 6)` devuelve `41`
- **WHEN** el `WSFEAdapter` arma la solicitud de CAE
- **THEN** pide `CbteDesde = CbteHasta = 42` (último + 1)

#### Scenario: Mismatch con el número local reservado se detecta y maneja

- **GIVEN** un comprobante con `number` local reservado `42` pero `FECompUltimoAutorizado` devuelve un último que implicaría un número distinto (desfasaje)
- **WHEN** el `WSFEAdapter` intenta solicitar el CAE
- **THEN** el desync se detecta/maneja (alineando con el número autoritativo de ARCA o registrando el error) y NO se persiste un CAE contra un número fuera de secuencia (Code 10016 de ARCA queda contemplado como rechazo manejado)

---

### Requirement: Caché del Ticket de Acceso WSAA

El sistema SHALL cachear el Ticket de Acceso (TA) de WSAA (token + sign + expiración) por clave `(cuenta/CUIT + servicio 'wsfe' + ambiente)` y reusarlo mientras esté vigente, re-autenticando contra WSAA (`loginCms`) solo cuando el TA está expirado o próximo a expirar. La caché SHALL persistir **entre invocaciones del relay** (no in-process), de modo que el endpoint de usuario (`process-pending`), la máquina cron (`process-pending-cron`) y el fire-and-forget post-emisión (`process_doc_by_id_background`) — que corren en procesos/invocaciones separados — compartan el mismo TA. El reúso del TA vigente SHALL evitar el cooldown de WSAA (~10 min) que rechaza un nuevo `loginCms` con "el CUIT ya posee un TA válido".

#### Scenario: Reúso del TA vigente evita un nuevo loginCms

- **GIVEN** un TA vigente cacheado para `(CUIT, 'wsfe', ambiente)`
- **WHEN** se solicita un CAE para ese mismo CUIT y ambiente antes de que el TA expire
- **THEN** el adapter reusa el TA cacheado y NO ejecuta un nuevo `loginCms` (evita el cooldown ~10 min y el error "el CUIT ya posee un TA válido")

#### Scenario: TA expirado fuerza re-autenticación WSAA

- **GIVEN** un TA cacheado cuya `expiration` ya pasó (o está dentro del margen de refresco)
- **WHEN** se solicita un CAE para ese CUIT y ambiente
- **THEN** el adapter ejecuta un nuevo `loginCms` contra WSAA, obtiene un TA fresco y actualiza la caché

#### Scenario: La caché persiste entre invocaciones del relay

- **GIVEN** que `process-pending-cron` (proceso cron) obtuvo y cacheó un TA para un CUIT
- **WHEN** `process_doc_by_id_background` (otra invocación/proceso) procesa otro comprobante del mismo CUIT mientras el TA sigue vigente
- **THEN** reusa el TA cacheado (la caché no es in-process: sobrevive entre invocaciones del relay)

---

### Requirement: Dependencia supabase-py declarada

El sistema SHALL declarar la dependencia `supabase` (supabase-py) tanto en `backend/requirements.txt` como en la sección `dependencies` de `backend/pyproject.toml`, de modo que el `WSFEAdapter` real pueda leer el certificado y la clave del bucket privado `afip-certs` vía Supabase Storage server-side en producción. Sin esta dependencia el cert-upload responde 503 y el relay cae al stub en producción.

#### Scenario: supabase declarado en ambos archivos de dependencias

- **WHEN** se inspeccionan `backend/requirements.txt` y `backend/pyproject.toml`
- **THEN** `supabase` (supabase-py) aparece declarado en ambos
- **AND** `zeep` sigue declarado una sola vez en cada archivo (no se duplica)

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

---

### Requirement: Identificación del receptor en el comprobante (DocTipo/DocNro)

El `WSFEAdapter` real SHALL derivar `DocTipo` y `DocNro` del `FECAEDetRequest` a partir de los datos de identificación del receptor que viajan sobre `CAERequest`, en lugar de fijar `DocTipo = 99` de forma incondicional. El mapeo SHALL ser: CUIT → `DocTipo = 80`, DNI → `DocTipo = 96`, sin identificación → `DocTipo = 99` con `DocNro = 0`. Cuando se provee identificación, `DocNro` SHALL ser el número de documento sin guiones; cuando `DocTipo = 99`, `DocNro` SHALL ser `0` (un `DocTipo = 99` con `DocNro` no nulo es inconsistente y NO SHALL emitirse).

El sistema SHALL exigir la identificación del receptor cuando el `ImpTotal` del comprobante es igual o mayor al umbral vigente de ARCA para consumidor final (RG 5824/2026: `$10.000.000`, parametrizable). Por debajo del umbral, emitir sin identificar (`DocTipo = 99`) SHALL ser válido y SHALL permanecer como comportamiento por defecto. La identificación del receptor (CUIT/DNI) SHALL ser **opcional** por debajo del umbral: el sistema NO SHALL introducir un campo de receptor requerido en ningún formulario, schema o endpoint para emitir comprobantes bajo el umbral. Cuando el cliente (`client-fiscal-identity`) tiene identidad fiscal cargada, el receptor SHALL autocompletarse de ahí, sin volverlo obligatorio.

#### Scenario: La identificación del receptor no es obligatoria bajo el umbral

- **GIVEN** una venta a un cliente sin CUIT/DNI cargado, con `total` menor al umbral
- **WHEN** se emite el comprobante
- **THEN** la emisión completa sin pedir identificación del receptor (se emite `DocTipo = 99`), y ningún campo de receptor es requerido en el formulario ni en el endpoint

#### Scenario: Receptor con CUIT emite DocTipo 80

- **GIVEN** un comprobante cuyo receptor tiene CUIT identificado
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** incluye `DocTipo = 80` y `DocNro` = el CUIT sin guiones

#### Scenario: Receptor con DNI emite DocTipo 96

- **GIVEN** un comprobante cuyo receptor tiene DNI identificado
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** incluye `DocTipo = 96` y `DocNro` = el DNI

#### Scenario: Consumidor final sin identificar bajo el umbral

- **GIVEN** un comprobante a consumidor final con `ImpTotal` menor al umbral vigente y sin datos de receptor
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** incluye `DocTipo = 99` y `DocNro = 0` (comportamiento por defecto, sin cambios)

#### Scenario: Total sobre el umbral exige identificación

- **GIVEN** un comprobante con `ImpTotal` igual o mayor al umbral vigente de ARCA y sin datos de receptor
- **WHEN** el sistema intenta solicitar el CAE
- **THEN** la emisión falla de forma explícita y accionable (el receptor SHALL identificarse) en lugar de enviar `DocTipo = 99`, que ARCA rechazaría

---

### Requirement: Persistencia y propagación del receptor y el desglose de IVA a través del relay

El comprobante SHALL persistir, además de los campos ya definidos, la identificación del receptor (`receptor_doc_tipo`, `receptor_doc_nro`) y el desglose de IVA (`neto`, `iva_amount`, `iva_alicuota_id`), todos NULLABLE. Los valores históricos NULL SHALL interpretarse como "consumidor final sin identificar, sin IVA discriminado" (idéntico al comportamiento actual). Las RPC de emisión (`rpc_emit_pending_cae` y `rpc_emit_subscription_payment_cae`) SHALL capturar y persistir esos campos al insertar el `pending_cae`; en particular, `rpc_emit_subscription_payment_cae` NO SHALL descartar los parámetros de receptor que recibe.

El relay SHALL propagar esos campos desde la fila persistida hasta `CAERequest`: las lecturas de la cola (`claim_pending`, `list_pending`, `list_pending_all`) SHALL devolver las columnas nuevas, y el `CAERelayProcessor` SHALL construir el `CAERequest` con la identificación del receptor y el desglose de IVA, de modo que el adapter pueda armar `DocTipo`/`DocNro` y el array `AlicIva` reales (no `IVA = 0` por defecto para tipo A/B).

#### Scenario: La emisión persiste receptor e IVA

- **WHEN** se emite un comprobante con receptor identificado y desglose de IVA
- **THEN** la fila `fiscal_documents` queda con `receptor_doc_tipo`, `receptor_doc_nro`, `neto`, `iva_amount` e `iva_alicuota_id` persistidos

#### Scenario: El relay propaga los campos al CAERequest

- **GIVEN** un comprobante `pending_cae` con receptor identificado e IVA persistidos
- **WHEN** el `CAERelayProcessor` lo procesa
- **THEN** el `CAERequest` que pasa al adapter incluye `cuit_receptor`/identificación del receptor y `neto`/`iva_amount`/`iva_alicuota_id`

#### Scenario: El flujo admin de suscripción ya no descarta el receptor

- **GIVEN** una Factura C de suscripción emitida con `receptor_doc_tipo = 80` y un CUIT de receptor
- **WHEN** se persiste y luego se relaya al CAE
- **THEN** el comprobante conserva `DocTipo = 80` y el CUIT del receptor hasta la solicitud a ARCA (no se pierde en el INSERT)

#### Scenario: Comprobante histórico sin datos mantiene el comportamiento previo

- **GIVEN** un comprobante `pending_cae` previo a esta migración (columnas de receptor/IVA en NULL)
- **WHEN** el relay lo procesa
- **THEN** se emite como consumidor final sin identificar (`DocTipo = 99`, sin array `Iva` para tipo C), igual que antes del cambio

---

### Requirement: Array Iva real para Factura A/B desde el desglose persistido

Para comprobantes con IVA discriminado (tipo A/B), el `WSFEAdapter` SHALL construir el array `Iva` (`AlicIva {Id, BaseImp, Importe}`) a partir del `neto`, `iva_amount` e `iva_alicuota_id` propagados por el relay, manteniendo `ImpNeto + ImpIVA = ImpTotal`. El adapter NO SHALL asumir `ImpIVA = 0` cuando el comprobante es tipo A/B y el desglose está disponible. Para comprobante tipo C (emisor monotributista) se mantiene la omisión del array `Iva` (`ImpIVA = 0`, `ImpNeto = ImpTotal`), sin cambios.

#### Scenario: Factura B con IVA discriminado desde el desglose

- **GIVEN** un comprobante tipo B con `neto`, `iva_amount` (21%) e `iva_alicuota_id = 5` persistidos
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** incluye el array `Iva` con `AlicIva {Id: 5, BaseImp: neto, Importe: iva_amount}` y `ImpNeto + ImpIVA = ImpTotal`

#### Scenario: Factura A/B sin desglose no se emite con IVA en cero silenciosamente

- **GIVEN** un comprobante tipo A/B sin desglose de IVA disponible
- **WHEN** el sistema intenta solicitar el CAE
- **THEN** el comprobante NO se emite con `ImpIVA = 0` de forma silenciosa: el desglose es requerido para tipo A/B (falla explícita o se completa antes de emitir)

#### Scenario: Factura C mantiene la omisión del array Iva

- **GIVEN** un comprobante tipo C (emisor monotributista)
- **WHEN** el `WSFEAdapter` arma el `FECAEDetRequest`
- **THEN** NO incluye el array `Iva`, con `ImpIVA = 0` e `ImpNeto = ImpTotal` (sin cambios)

---

### Requirement: Emisión posterior de comprobante para una SalesOrder confirmada

El sistema SHALL proveer una acción dedicada para emitir el comprobante fiscal de una `sales_order` ya confirmada, mediante el endpoint `POST /sales-orders/{id}/emit-invoice` respaldado por una RPC `SECURITY DEFINER` (p.ej. `rpc_emit_sale_invoice`). La emisión SHALL ser válida tanto para una venta recién confirmada como para una venta histórica: es el mismo camino. El endpoint SHALL operar únicamente sobre órdenes con `status = 'confirmed'` y `fiscal_document_id IS NULL`. El tipo de comprobante SHALL resolverse en el backend (capa service vía `resolve_invoice_type`, espejado en la RPC) y NUNCA aceptarse desde el cliente. La emisión SHALL reutilizar la maquinaria existente: reserva de número + INSERT en `pending_cae` vía `rpc_emit_pending_cae`, sin tocar AFIP en el request (el CAE lo obtiene el relay asíncrono). Al emitir, la RPC SHALL setear `sales_orders.fiscal_document_id` con el comprobante creado, dentro del mismo commit que la inserción del `pending_cae`.

#### Scenario: Emite Factura C para venta confirmada de emisor monotributista

- **GIVEN** una `sales_order` con `status = 'confirmed'` y `fiscal_document_id IS NULL`, y un `fiscal_profile` con `iva_condition = 'monotributista'` y un PV activo
- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice`
- **THEN** se crea un `fiscal_documents` con `comprobante_type = 'factura_c'` en `status = 'pending_cae'` y número reservado, y `sales_orders.fiscal_document_id` referencia ese comprobante, sin que el request llame a AFIP

#### Scenario: El tipo lo resuelve el backend, no el cliente

- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice` (el payload no incluye ni puede forzar `comprobante_type`)
- **THEN** el backend determina el tipo vía `resolve_invoice_type(emisor_iva_condition, receptor_iva_condition)` y para emisor monotributista emite `factura_c`

#### Scenario: La emisión es asíncrona y no bloquea esperando el CAE

- **GIVEN** una orden confirmada facturable
- **WHEN** se emite el comprobante
- **THEN** el endpoint responde con el `fiscal_document_id` en `status = 'pending_cae'` sin esperar el CAE; el CAE lo obtiene el relay (`CAERelayProcessor` vía `pg_cron`) posteriormente

---

### Requirement: Idempotencia fiscal de la emisión por venta

El sistema SHALL impedir la doble emisión de comprobante para una misma `sales_order`. Si la orden ya tiene `fiscal_document_id IS NOT NULL`, el endpoint SHALL rechazar la solicitud con HTTP 409 (mapeado desde el error de dominio `P0409`). La validación de unicidad SHALL ejecutarse bajo lock (`SELECT … FOR UPDATE` sobre la orden) para serializar solicitudes concurrentes sobre la misma orden.

#### Scenario: Segunda emisión sobre una orden ya facturada devuelve 409

- **GIVEN** una `sales_order` que ya tiene `fiscal_document_id` asignado
- **WHEN** se invoca `POST /sales-orders/{id}/emit-invoice` nuevamente
- **THEN** el sistema responde 409 Conflict y NO crea un segundo comprobante

#### Scenario: Solicitudes concurrentes sobre la misma orden no duplican comprobante

- **GIVEN** una orden confirmada sin comprobante
- **WHEN** llegan dos solicitudes de emisión concurrentes para la misma orden
- **THEN** exactamente una crea el comprobante y setea `fiscal_document_id`; la otra recibe 409 (serializadas por el lock de fila)

---

### Requirement: Receptor del comprobante derivado de la identidad fiscal del cliente (SalesOrder)

El sistema SHALL construir la identificación del receptor a partir de la identidad fiscal del cliente de la venta (capability `client-fiscal-identity`, C-22): `clients.tax_id` e `clients.iva_condition`. Si el cliente está identificado con CUIT, el receptor SHALL derivarse como DocTipo 80; con DNI, DocTipo 96. Si la venta no tiene cliente, o el cliente no tiene `tax_id`, el comprobante SHALL emitirse a consumidor final con DocTipo 99 / DocNro 0 (default válido). El guard de umbral de identificación obligatoria del receptor (`afip_consumidor_final_threshold`, RG 5824/2026) del `WSFEAdapter` SHALL respetarse sin cambios: por encima del umbral, una venta sin receptor identificado SHALL fallar explícitamente en lugar de emitir un comprobante inválido.

#### Scenario: Venta sin cliente emite a consumidor final

- **GIVEN** una `sales_order` confirmada sin `client_id`, por debajo del umbral de identificación obligatoria
- **WHEN** se emite el comprobante
- **THEN** el receptor se resuelve como DocTipo 99 / DocNro 0 (consumidor final) y la emisión procede

#### Scenario: Cliente con CUIT se emite como receptor identificado

- **GIVEN** una `sales_order` con `client_id` cuyo `clients.tax_id` es un CUIT
- **WHEN** se emite el comprobante
- **THEN** el receptor se persiste con DocTipo 80 y el número de documento sin guiones

#### Scenario: Venta sobre el umbral sin receptor identificado falla explícito

- **GIVEN** una venta cuyo total alcanza o supera `afip_consumidor_final_threshold` y no tiene cliente identificado
- **WHEN** se intenta emitir el comprobante
- **THEN** el guard del `WSFEAdapter` rechaza la emisión (RECEPTOR_REQUIRED) y no se emite un comprobante inválido
