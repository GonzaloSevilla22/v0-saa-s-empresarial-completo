## MODIFIED Requirements

### Requirement: Persistencia del comprobante fiscal con maquina de estados de CAE

El sistema SHALL persistir cada comprobante emitido en la tabla `fiscal_documents` (`id` UUID PK, `account_id` UUID FK, `fiscal_profile_id` UUID FK, `point_of_sale_id` UUID FK `points_of_sale`, `comprobante_type` TEXT, `punto_de_venta` INTEGER (snapshot del `numero` del PV al emitir), `number` BIGINT, `client_id` UUID FK NULL, `total` NUMERIC, `status` TEXT NOT NULL, `cae` TEXT NULL, `cae_due_date` DATE NULL, `attempts` INTEGER NOT NULL DEFAULT 0, `next_attempt_at` TIMESTAMPTZ NULL, `last_error` TEXT NULL, `created_at` TIMESTAMPTZ). `status` MUST estar restringida por CHECK a `'pending_cae'`, `'authorized'`, `'rejected'`, `'voided'`. La tabla SHALL tener RLS por `account_id`.

`'voided'` es un estado TERMINAL que significa "el comprobante se anuló porque su venta se editó o se borró ANTES de que el pedido saliera hacia ARCA". NO es una nota de crédito: la nota de crédito revierte un comprobante que SÍ tuvo efecto fiscal. Un `voided` nunca llegó a ARCA, así que no deja rastro ante el organismo, y SHALL conservar su `punto_de_venta` y su `number` como rastro auditable local.

El catálogo de transiciones (`document_status_transitions`) SHALL admitir `pending_cae → voided` como única entrada a ese estado, marcada terminal y con motivo obligatorio, y NO SHALL admitir ninguna otra transición hacia o desde `voided` — en particular `authorized → voided` (un comprobante autorizado por ARCA se corrige con nota de crédito, nunca anulándolo) ni `voided → *`.

#### Scenario: Comprobante nace en pending_cae

- **WHEN** se emite un comprobante
- **THEN** la fila se persiste con `status = 'pending_cae'`, `cae = NULL`, `cae_due_date = NULL` y `attempts = 0`

#### Scenario: Estado invalido rechazado por la DB

- **WHEN** se intenta insertar un comprobante con `status = 'en_proceso'`
- **THEN** la base rechaza la fila por violación del CHECK de `status`

#### Scenario: un comprobante autorizado no se puede anular

- **GIVEN** un comprobante con `status = 'authorized'`
- **WHEN** se intenta transicionarlo a `voided`
- **THEN** la transición se rechaza por no existir en el catálogo, y el comprobante queda intacto

## ADDED Requirements

### Requirement: La venta es editable y borrable mientras su comprobante no haya salido hacia ARCA

El sistema SHALL permitir editar y borrar una venta cuando su comprobante fiscal todavía no salió hacia ARCA, y SHALL bloquear ambas acciones con `ERRCODE = 'P0423'` desde el instante en que el pedido salió, con o sin respuesta del organismo.

El predicado SHALL resolverse por consulta en el momento de la edición o del borrado, siguiendo `sales.operation_id → sales_orders.sale_operation_id → sales_orders.fiscal_document_id → fiscal_documents`. NO SHALL introducirse una columna denormalizada de "facturado" en `sales`: sería una segunda fuente de verdad capaz de desincronizarse del comprobante.

La venta SHALL considerarse editable y borrable cuando: (a) no tiene comprobante, (b) el comprobante está en `rejected` o `voided` — ninguno de los dos tuvo efecto fiscal —, o (c) el comprobante está en `pending_cae` y NO tiene marca de envío ni marca de congelamiento. En el caso (c) el comprobante SHALL anularse en la misma transacción (ver el requirement de anulación).

La venta SHALL quedar bloqueada cuando el comprobante está `authorized`, cuando tiene marca de envío, cuando está congelado, o cuando su fila está tomada por el relay en ese instante. El sistema SHALL distinguir esas causas con tokens de error propios, porque la acción que le queda al usuario es distinta en cada una: emitir una nota de crédito (autorizado), esperar o revisar en ARCA (enviado o congelado), reintentar en unos minutos (tomado por el relay — transitorio).

El predicado NO SHALL incluir `next_attempt_at`: ese campo conflaciona el lease de reclamo del relay con el backoff de reintentos, y usarlo dejaría una venta inmutable hasta una hora por un comprobante que nunca llegó a ARCA.

Un estado de comprobante que el sistema no conozca SHALL bloquear (allow-list, no deny-list): en este dominio, dejar pasar lo desconocido significa editar los importes de algo que quizá ya se facturó.

#### Scenario: venta con comprobante pendiente no enviado

- **GIVEN** una venta con un comprobante en `pending_cae` sin marca de envío
- **WHEN** se edita la operación
- **THEN** la edición se completa y el comprobante queda anulado

#### Scenario: venta con comprobante ya enviado a ARCA

- **GIVEN** una venta cuyo comprobante tiene marca de envío y todavía no tiene respuesta
- **WHEN** se intenta editarla o borrarla
- **THEN** la acción se rechaza con `P0423` y un mensaje que nombra esa causa ("ya se envió a ARCA")
- **AND** la venta, su comprobante y todos sus movimientos quedan intactos

#### Scenario: venta con CAE autorizado

- **GIVEN** una venta con un comprobante `authorized`
- **WHEN** se intenta editarla o borrarla
- **THEN** la acción se rechaza con `P0423` y el mensaje indica que corresponde emitir una nota de crédito y registrar una venta nueva

#### Scenario: comprobante rechazado o anulado no bloquea

- **GIVEN** una venta cuyo único comprobante quedó en `rejected`, o en `voided` por una edición anterior
- **WHEN** se edita la operación
- **THEN** la edición se completa sin tocar el comprobante

#### Scenario: la compra queda fuera

- **GIVEN** una compra
- **WHEN** se edita o se borra
- **THEN** este requirement no aplica: la compra no lleva CAE propio, el comprobante lo emite el proveedor y no existe vínculo entre `purchases` y `fiscal_documents`

### Requirement: Anulación del comprobante pendiente al editar o borrar su venta

El sistema SHALL anular (`voided`) el comprobante pendiente no enviado de una venta en la MISMA transacción en que la venta se edita o se borra, de modo que el relay no pueda facturar después importes que ya no existen.

La regla SHALL tener UNA sola definición, compartida por la edición y el borrado: dos copias divergirían y una de las dos terminaría anulando un comprobante ya enviado.

La anulación SHALL registrar la transición en el historial de estados del documento con un motivo que nombre la causa (edición o borrado de la venta), y NO SHALL desvincular el comprobante de su orden: el vínculo sobrevive para que la interfaz muestre el estado anulado y para el rastro de auditoría.

El número reservado localmente NO SHALL reutilizarse. El hueco resultante en la secuencia local es deliberado: ante ARCA el número autoritativo se pide en el envío, y reutilizarlo abriría la puerta a dos documentos distintos con el mismo número local.

**Exclusión mutua con los otros dos escritores del comprobante.** La anulación SHALL tomar el lock de la orden de venta ANTES de leer qué comprobante tiene, y SHALL leer ese vínculo de la fila bloqueada. Es lo que la excluye de la emisión, que toma ese mismo lock antes de crear el comprobante y vincularlo: sin ese lock, una emisión en curso es invisible para la edición, que concluye "no hay nada que anular" y deja vivo un comprobante por el importe viejo. El mismo lock fija el orden orden → comprobante, idéntico al de la emisión, de modo que no exista ciclo posible entre las dos (un deadlock crudo en el camino de dinero).

El lock del comprobante SHALL pedirse sin espera: el request de un usuario NO SHALL quedar bloqueado detrás de un round-trip del relay hacia ARCA. Si la fila está tomada, el rechazo SHALL ser transitorio y decirlo.

La condición que autoriza la anulación SHALL re-evaluarse bajo el lock, dentro de la misma sentencia que escribe el estado anulado, para que no exista forma de conservar la escritura habiendo perdido la comprobación. Si la re-evaluación falla —el relay marcó el envío en el intervalo—, la acción SHALL rechazarse con `P0423` sin haber tocado nada.

La anulación SHALL validar que la orden de venta pertenezca a la cuenta que se le declara, en el punto de paso obligado y no en cada llamador: es un punto de escritura con privilegios elevados que recibe la cuenta como parámetro, y esa validación es la única que un llamador futuro no puede omitir.

Un comprobante anulado NO SHALL ser reclamable ni marcable por el relay: los dos puntos de paso del relay ya filtran por `pending_cae`, y esa cláusula SHALL conservarse con gate propio porque es lo único que impide que un anulado llegue a ARCA.

Cuando el relay encuentre que el comprobante que estaba procesando fue anulado, el sistema SHALL tratarlo como un camino normal —dejar rastro informativo y continuar con el resto del lote—, y NO como un fallo del relay. Cualquier otro rechazo del mismo tipo SHALL seguir registrándose como error con su diagnóstico completo.

#### Scenario: la anulación queda en el historial con su motivo

- **WHEN** una edición anula el comprobante pendiente de su venta
- **THEN** el historial del documento registra la transición `pending_cae → voided` con el motivo que nombra la edición

#### Scenario: la emisión estaba en curso al editar

- **GIVEN** una emisión abierta que ya creó el comprobante y todavía no commiteó
- **WHEN** entra la edición de esa venta
- **THEN** la edición espera el lock de la orden, ve el comprobante recién creado y lo anula
- **AND** no queda ningún comprobante pendiente vivo sobre la venta editada

#### Scenario: el relay tiene la fila tomada

- **GIVEN** el relay con la fila del comprobante tomada y sin commitear
- **WHEN** se intenta editar la venta
- **THEN** la edición se rechaza con `P0423` y un token transitorio, sin quedarse esperando
- **AND** el comprobante sigue `pending_cae`, sin ninguna transición registrada
- **AND** liberada la fila, el mismo pedido de edición funciona

#### Scenario: el relay había reclamado el comprobante sin marcarlo

- **GIVEN** un comprobante pendiente con el lease del relay puesto y sin marca de envío
- **WHEN** se edita la venta
- **THEN** la anulación procede
- **AND** el relay ya no puede enviarlo: marcar el envío se rechaza y el reclamo no devuelve filas

#### Scenario: la orden pertenece a otra cuenta

- **WHEN** se invoca la anulación declarando una cuenta que no es la de la orden
- **THEN** la operación se rechaza con `P0404` y no se escribe ni el estado ni el historial

#### Scenario: el relay salteó un comprobante anulado

- **GIVEN** un comprobante que se anuló mientras el relay lo procesaba
- **WHEN** el relay intenta marcar el envío
- **THEN** el envío no sale, el lote continúa, y el evento queda registrado como un caso normal y no como un fallo

### Requirement: Re-emisión del comprobante después de una anulación

El sistema SHALL permitir volver a emitir el comprobante de una orden cuyo comprobante anterior quedó en `rejected` o en `voided`, produciendo un comprobante NUEVO con un número NUEVO y re-apuntando la orden a él.

La habilitación SHALL expresarse como allow-list de los estados que no tuvieron efecto fiscal (`rejected`, `voided`), y NO como deny-list de los que sí: con una deny-list, un estado futuro desconocido —o un vínculo ilegible— habilitaría una SEGUNDA factura real, que es el peor resultado posible de este dominio.

El comprobante anulado SHALL conservarse con su punto de venta y su número: es el rastro de que ese número se consumió.

#### Scenario: volver a facturar después de anular

- **GIVEN** una orden cuyo comprobante quedó `voided` al editar la venta
- **WHEN** se emite de nuevo
- **THEN** se crea un comprobante nuevo en `pending_cae` con número mayor al anulado, y la orden apunta al nuevo

#### Scenario: no se puede facturar dos veces sobre un pendiente vivo

- **GIVEN** una orden con un comprobante `pending_cae` vivo
- **WHEN** se intenta emitir de nuevo
- **THEN** la emisión se rechaza por conflicto de estado, sin crear ningún comprobante

## REMOVED Requirements

### Requirement: La operación con comprobante fiscal emitido es inmutable

**Reason**: el pedido del PO ("las ventas se puedan modificar, sólo si ésta no tiene el CAE, es decir no se envió al ARCA aún") deroga el predicado de este requirement. Decía que una venta con comprobante en `pending_cae` **o** `authorized` no puede editarse, y su propio nombre afirma que basta con que el comprobante esté *emitido*. Con la marca previa al envío (`fiscal-riesgos-residuales`, R1) el sistema sabe el instante EXACTO en que el pedido salió hacia ARCA, así que "emitido" e "inmutable" dejaron de ser lo mismo: un comprobante emitido que todavía no salió se puede anular sin ninguna consecuencia fiscal.

**Migration**: lo reemplaza el requirement "La venta es editable y borrable mientras su comprobante no haya salido hacia ARCA", que conserva sin cambios todo lo que sigue siendo verdad —el bloqueo con `P0423` antes de cualquier reversa, la resolución del vínculo por consulta y la prohibición de denormalizar "facturado", que `rejected` no bloquea, el mensaje que nombra el camino de la nota de crédito, y la exclusión de la compra— y agrega los casos que este requirement no distinguía. El bloqueo de una venta ya enviada o autorizada NO se relaja: cambia sólo el caso "pendiente sin enviar", que pasa de rechazo a anulación del comprobante.
