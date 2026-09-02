## ADDED Requirements

### Requirement: El conjunto de eventos en alcance del consumidor contable es único y está verificado por un gate

El conjunto de tipos de evento que producen asiento contable SHALL estar declarado en **dos** lugares —el filtro del despachador del relay y el filtro del propio helper de posteo— y los dos SHALL enumerar **exactamente el mismo conjunto**.

Este invariante SHALL verificarse con un **gate automático** que extraiga los dos conjuntos de las definiciones vigentes en la base de datos y los compare, y SHALL NOT quedar sostenido únicamente por un comentario en el código. Una divergencia entre los dos filtros produce un evento que nunca postea su asiento —o que el despachador enruta hacia un helper que lo ignora— **sin levantar ningún error**: el modo de falla no es detectable por observación casual y ya se materializó otras veces en el sistema.

El conjunto canónico SHALL constar de once tipos: `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PaymentReceivedReversed` y `PaymentMadeReversed`. Esta enumeración SHALL prevalecer sobre cualquier enumeración anterior más corta que aparezca en otros requirements de este mismo capability, que quedaron desactualizadas al incorporarse las ramas de borrado.

#### Scenario: Los dos filtros enumeran el mismo conjunto

- **WHEN** corre el gate del invariante sobre las definiciones vigentes
- **THEN** el conjunto del filtro del despachador y el del helper de posteo son iguales
- **AND** ambos contienen los once tipos canónicos

#### Scenario: Una divergencia introducida rompe el gate

- **GIVEN** un tipo agregado a uno solo de los dos filtros
- **WHEN** corre el gate
- **THEN** falla, nombrando el tipo que sobra o falta y en cuál de los dos filtros

#### Scenario: Un evento fuera del conjunto no postea asiento

- **WHEN** el relay procesa un evento de un tipo que no está en el conjunto canónico
- **THEN** el consumidor contable es un no-op para ese evento y el resto de los consumidores corre normalmente

### Requirement: La anulación de un cobro y la de un pago emiten su evento en la misma transacción que las compensaciones

El sistema SHALL emitir los eventos `PaymentReceivedReversed` y `PaymentMadeReversed` hacia el outbox **dentro de la misma transacción** que registra los contra-movimientos de cuenta corriente, caja y banco y que borra el documento del pago. La emisión SHALL ser un `INSERT` plano, sin manejador de excepciones: tragarse un evento fallido mientras la anulación commitea dejaría los libros de dinero compensados y el libro diario no, en silencio y de forma irrecuperable.

El payload SHALL llevar la cuenta, el identificador del pago anulado, el identificador de la cuenta corriente de la parte, el importe, el motivo cuando se informó, y el momento de la anulación — todo lo que el consumidor contable necesita para localizar el asiento vigente y revertirlo sin volver a consultar el documento, que ya no existe.

#### Scenario: El evento de anulación acompaña a las compensaciones

- **WHEN** se anula un cobro y la operación commitea
- **THEN** existe un evento `PaymentReceivedReversed` en el outbox, escrito en la misma transacción que los contra-movimientos

#### Scenario: El evento se revierte con una anulación fallida

- **WHEN** una anulación falla y revierte
- **THEN** no queda ningún evento de anulación en el outbox

#### Scenario: El payload basta para revertir el asiento

- **WHEN** el consumidor contable procesa un evento de anulación
- **THEN** encuentra en el payload el identificador del pago y la cuenta, y con ellos localiza el asiento vigente
- **AND** no necesita consultar el documento del pago, que ya fue borrado
