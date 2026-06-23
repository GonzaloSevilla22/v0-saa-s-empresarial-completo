## MODIFIED Requirements

### Requirement: Adaptador WSFE detras de un ACL (port + impl real/stub)

El sistema SHALL exponer un port `FiscalDocumentPort.request_cae(invoice_data) -> CAEResponse` en la capa de dominio, con al menos dos implementaciones inyectables por DI: `WSFEAdapter` (real, autentica via WSAA para el ticket de acceso y solicita el CAE via WSFEv1, contra el ambiente del perfil de la cuenta) y `WSFEStubAdapter` (devuelve un CAE ficticio deterministico para tests y dev). El dominio y los services SHALL conocer unicamente `CAE`, `CAEDueDate`, `DocumentType` y codigos de error normalizados; el SOAP/XML de AFIP SHALL permanecer encapsulado en el adapter. El `WSFEAdapter` real SHALL apuntar a las URLs oficiales de AFIP bajo el dominio **`.gob.ar`** (WSAA homologación `wsaahomo.afip.gob.ar`, WSAA producción `wsaa.afip.gob.ar`, WSFEv1 homologación `wswhomo.afip.gob.ar`, WSFEv1 producción `servicios1.afip.gob.ar`), resueltas por `CAERequest.ambiente`. El `WSFEAdapter` real SHALL leer el certificado (`{account_id}/afip.crt`) y la clave privada (`{account_id}/afip.key`, PEM sin password) del bucket privado `afip-certs` server-side, y SHALL depender de la librería SOAP `zeep` (importada de forma lazy, de modo que el módulo y el `WSFEStubAdapter` funcionen aunque `zeep` no esté instalado).

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

## ADDED Requirements

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

### Requirement: Dependencia supabase-py declarada

El sistema SHALL declarar la dependencia `supabase` (supabase-py) tanto en `backend/requirements.txt` como en la sección `dependencies` de `backend/pyproject.toml`, de modo que el `WSFEAdapter` real pueda leer el certificado y la clave del bucket privado `afip-certs` vía Supabase Storage server-side en producción. Sin esta dependencia el cert-upload responde 503 y el relay cae al stub en producción.

#### Scenario: supabase declarado en ambos archivos de dependencias

- **WHEN** se inspeccionan `backend/requirements.txt` y `backend/pyproject.toml`
- **THEN** `supabase` (supabase-py) aparece declarado en ambos
- **AND** `zeep` sigue declarado una sola vez en cada archivo (no se duplica)
