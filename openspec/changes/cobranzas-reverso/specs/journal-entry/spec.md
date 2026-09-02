## ADDED Requirements

### Requirement: Contra-asiento por anulación de un cobro de cuenta corriente

El consumidor contable SHALL postear, ante un evento `PaymentReceivedReversed`, un contra-asiento que revierta exactamente el asiento vigente del cobro anulado y SHALL marcar ese asiento original como `reversed`, sin postear ningún asiento nuevo de reemplazo.

El asiento original SHALL resolverse por **una sola convención de referencia** —tipo de documento `CustomerAccount` y referencia igual al identificador del cobro—, filtrando además por la cuenta del evento. El cobro tiene un único camino de alta, de modo que no aplica la resolución por dos convenciones que necesita la venta.

El contra-asiento SHALL invertir el lado de cada línea del original preservando importe, número de línea y centro de costo, SHALL referenciar el asiento original en `reversal_of`, y SHALL llevar su propio identificador de evento de origen, por ser la única entrada que ese evento produce.

Diferir la reversión contable **no** SHALL considerarse una opción para este camino: a diferencia del gasto y de la compra en efectivo —cuyos asientos no existían cuando se cablearon sus libros de dinero—, la rama contable del cobro está viva y todos los cobros registrados tienen su asiento posteado, de modo que omitir el contra-asiento dejaría al libro diario afirmando un ingreso que la aplicación declaró inexistente.

#### Scenario: Cobro con asiento posteado

- **WHEN** se procesa un `PaymentReceivedReversed` de un cobro con asiento `posted` de tipo `CustomerAccount`
- **THEN** se postea un contra-asiento con los lados invertidos línea por línea
- **AND** el contra-asiento referencia el asiento original en `reversal_of`
- **AND** el asiento original queda en estado `reversed`
- **AND** no se postea ningún asiento nuevo de reemplazo

#### Scenario: La contrapartida revertida respeta el ruteo original

- **GIVEN** un cobro bancario cuyo asiento debitó la cuenta de banco y acreditó deudores por ventas
- **WHEN** se anula
- **THEN** el contra-asiento acredita la cuenta de banco y debita deudores por ventas, por el mismo importe
- **AND** el ruteo no se recalcula: se invierte el asiento tal como quedó posteado

#### Scenario: Asiento original ausente

- **WHEN** se procesa un `PaymentReceivedReversed` y no existe asiento `posted` para esa referencia
- **THEN** el consumidor falla con el código de error `P0451`
- **AND** el evento queda pendiente para reintento sin abortar el lote

#### Scenario: El evento de anulación llega antes que el del cobro

- **GIVEN** un cobro cuyo evento de alta todavía no fue procesado por el consumidor contable
- **WHEN** se procesa primero su evento de anulación
- **THEN** el consumidor falla con `P0451` y el evento de anulación queda pendiente
- **AND** en un ciclo posterior, con el asiento original ya posteado, la anulación se procesa correctamente

#### Scenario: Reproceso del mismo evento

- **WHEN** un `PaymentReceivedReversed` ya consumido se vuelve a procesar
- **THEN** el consumidor no postea un segundo contra-asiento

### Requirement: Contra-asiento por anulación de un pago a proveedor

El consumidor contable SHALL postear, ante un evento `PaymentMadeReversed`, un contra-asiento que revierta exactamente el asiento vigente del pago anulado y SHALL marcar ese asiento original como `reversed`, resolviéndolo por la convención única de tipo de documento `SupplierAccount` y referencia igual al identificador del pago, filtrando por la cuenta del evento.

#### Scenario: Pago a proveedor con asiento posteado

- **WHEN** se procesa un `PaymentMadeReversed` de un pago con asiento `posted` de tipo `SupplierAccount`
- **THEN** se postea un contra-asiento con los lados invertidos línea por línea
- **AND** el asiento original queda en estado `reversed`
- **AND** el centro de costo de cada línea se preserva en la reversión

#### Scenario: Asiento original ausente

- **WHEN** se procesa un `PaymentMadeReversed` sin asiento `posted` para esa referencia
- **THEN** el consumidor falla con `P0451` y el evento queda pendiente para reintento

### Requirement: El contra-asiento de anulación se fecha en el momento de la anulación

El consumidor contable SHALL fechar el contra-asiento de una anulación en el momento en que se procesa, y SHALL NOT retrodatarlo a la fecha del asiento original. Es el mismo criterio que ya rige para los contra-asientos por borrado de venta y de compra: adoptar otro para este camino introduciría dos criterios de fecha dentro del mismo libro.

#### Scenario: Anulación de un cobro de un período anterior

- **WHEN** se anula un cobro registrado en un período contable anterior
- **THEN** el contra-asiento se postea con la fecha de la anulación
- **AND** el asiento original conserva su fecha y queda marcado `reversed`

### Requirement: Balance del contra-asiento de anulación

El consumidor contable SHALL validar que el contra-asiento de una anulación cumpla Σdébito = Σcrédito antes de darlo por posteado, fallando con el código de error `P0450` si no balancea, por el mismo mecanismo genérico que ya cubre a las demás ramas.

#### Scenario: Contra-asiento desbalanceado

- **WHEN** el contra-asiento de una anulación no balancea
- **THEN** el consumidor falla con `P0450`
- **AND** el evento queda pendiente para reintento

## MODIFIED Requirements

### Requirement: Preservación de las ramas contables existentes
La incorporación de las ramas de borrado y de las ramas de anulación de pago SHALL dejar intactas las ramas de evento ya existentes del consumidor contable, incluido el tratamiento fiscal de `SaleConfirmed` y el ruteo bancario de `PaymentReceived` y `PaymentMade`.

Toda reescritura del consumidor contable SHALL partir de su definición **viva** en la base de datos, verificada por hash antes de modificarla, y no del último archivo de migración: las dos han divergido al menos una vez en la historia del proyecto, y el consumidor concentra el mapeo contable de todos los caminos de negocio.

#### Scenario: Evento fuera del alcance de borrado
- **WHEN** se procesa cualquier evento distinto de los de borrado
- **THEN** su asiento se postea con el mismo resultado observable que antes del cambio

#### Scenario: Las ramas de alta de pago no cambian de comportamiento
- **WHEN** se procesa un `PaymentReceived` o un `PaymentMade` después de incorporar las ramas de anulación
- **THEN** su asiento se postea idéntico al que producía antes, con el mismo ruteo entre cuenta de caja y cuenta de banco

#### Scenario: La reescritura parte de la definición viva
- **WHEN** se modifica el consumidor contable
- **THEN** el punto de partida es su definición vigente en la base de datos, verificada por hash antes de escribir el cambio
