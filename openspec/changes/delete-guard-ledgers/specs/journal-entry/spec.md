## ADDED Requirements

### Requirement: Contra-asiento por borrado de una operación de venta
El consumidor contable SHALL postear, ante un evento `SaleOperationDeleted`, un contra-asiento que revierta exactamente el asiento vigente de la operación borrada y SHALL marcar ese asiento original como `reversed`, sin postear ningún asiento nuevo de reemplazo.

#### Scenario: Venta del formulario con asiento posteado
- **WHEN** se procesa un `SaleOperationDeleted` de una operación con asiento `posted` de tipo `SaleOperation`
- **THEN** se postea un contra-asiento con los lados invertidos línea por línea
- **AND** el contra-asiento referencia el asiento original en `reversal_of`
- **AND** el asiento original queda en estado `reversed`
- **AND** no se postea ningún asiento nuevo de reemplazo

#### Scenario: Venta del POS con asiento por orden
- **WHEN** se procesa un `SaleOperationDeleted` de una venta cuyo asiento vigente es de tipo `SalesOrder`
- **THEN** el consumidor resuelve el asiento original por la referencia de la orden
- **AND** postea el contra-asiento contra ese asiento

#### Scenario: Asiento original ausente
- **WHEN** se procesa un `SaleOperationDeleted` y no existe asiento `posted` para ninguna de las dos convenciones de referencia
- **THEN** el consumidor falla con el código de error `P0451`
- **AND** el evento queda pendiente para reintento sin abortar el lote

#### Scenario: Reproceso del mismo evento
- **WHEN** un `SaleOperationDeleted` ya consumido se vuelve a procesar
- **THEN** el consumidor no postea un segundo contra-asiento

### Requirement: Contra-asiento por borrado de una operación de compra
El consumidor contable SHALL postear, ante un evento `PurchaseDeleted`, un contra-asiento que revierta exactamente el asiento vigente de la compra borrada y SHALL marcar ese asiento original como `reversed`.

#### Scenario: Compra con asiento posteado
- **WHEN** se procesa un `PurchaseDeleted` de una compra con asiento `posted` de tipo `Purchase`
- **THEN** se postea un contra-asiento con los lados invertidos línea por línea
- **AND** el asiento original queda en estado `reversed`
- **AND** el centro de costo de cada línea se preserva en la reversión

### Requirement: Balance del contra-asiento de borrado
El consumidor contable SHALL validar que el contra-asiento de un borrado cumpla Σdébito = Σcrédito antes de darlo por posteado, fallando con el código de error `P0450` si no balancea.

#### Scenario: Contra-asiento desbalanceado
- **WHEN** el contra-asiento de un borrado no balancea
- **THEN** el consumidor falla con `P0450`
- **AND** el evento queda pendiente para reintento

### Requirement: Preservación de las ramas contables existentes
La incorporación de las ramas de borrado SHALL dejar intactas las ramas de evento ya existentes del consumidor contable, incluido el tratamiento fiscal de `SaleConfirmed`.

#### Scenario: Evento fuera del alcance de borrado
- **WHEN** se procesa cualquier evento distinto de los de borrado
- **THEN** su asiento se postea con el mismo resultado observable que antes del cambio
