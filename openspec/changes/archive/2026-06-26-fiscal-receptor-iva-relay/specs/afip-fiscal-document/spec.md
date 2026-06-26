## ADDED Requirements

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
