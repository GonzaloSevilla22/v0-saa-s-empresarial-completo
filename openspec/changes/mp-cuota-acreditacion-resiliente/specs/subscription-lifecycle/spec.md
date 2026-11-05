## ADDED Requirements

### Requirement: El cobro mensual se acredita aunque MercadoPago no notifique la cuota procesada

El sistema SHALL acreditar el cobro mensual aprobado de una suscripción autorizada con cuenta asignada sin depender de que MercadoPago emita la notificación `subscription_authorized_payment` en estado `processed`. Para eso SHALL correr un barrido programado, al menos una vez por hora, que reconcilia contra la API de MercadoPago (el preapproval y sus cuotas) cada suscripción autorizada cuyo período pagado ya alcanzó su fecha de cobro sin que se acreditara el cobro del ciclo, dentro de una ventana acotada posterior al vencimiento.

La selección del barrido SHALL basarse en el fin del período pagado de la cuenta, que sólo mueve un cobro acreditado, y nunca en una fecha que la propia reconciliación reescriba sin acreditar.

La acreditación SHALL usar una única definición compartida por el barrido, el webhook y el replay admin — la misma que ya aplica una cuota aprobada (período pagado, auditoría de facturación, correo de renovación) —, ser idempotente frente a cualquiera de esos caminos y frente a la notificación tardía de la cuota, y serializarse por suscripción para que caminos concurrentes no dupliquen el correo de renovación. Las suscripciones sin cuenta asignada quedan fuera del barrido y siguen en la cola de reconciliación manual.

#### Scenario: Cuota procesada sin notificación se acredita en el barrido siguiente

- **GIVEN** una suscripción autorizada con cuenta cuyo período pagado vence dentro del período de gracia desde su fecha de cobro
- **AND** MercadoPago cobró y aprobó la cuota del ciclo pero sólo notificó la cuota como `scheduled`
- **WHEN** corre el barrido de reconciliación
- **THEN** el período pagado de la cuenta pasa al siguiente ciclo del preapproval más el período de gracia
- **AND** se registra el cobro en la auditoría de facturación con el identificador del pago de MercadoPago y se encola un único correo de renovación
- **AND** la suscripción deja de ser seleccionada por el barrido

#### Scenario: Cuota todavía no procesada no acredita nada

- **GIVEN** una suscripción seleccionada por el barrido cuya cuota del ciclo sigue `scheduled` o en reintento
- **WHEN** corre el barrido
- **THEN** no se extiende el período pagado ni se registra un cobro
- **AND** la suscripción vuelve a ser seleccionada en la corrida siguiente

#### Scenario: Barrido y notificación concurrentes acreditan una sola vez

- **WHEN** el barrido y la notificación `processed`/`approved` de la misma cuota se procesan al mismo tiempo
- **THEN** queda un único evento de facturación, un único correo de renovación y una sola extensión del período pagado

#### Scenario: Error de MercadoPago en una suscripción no frena al resto

- **GIVEN** dos suscripciones seleccionadas por el barrido
- **WHEN** la API de MercadoPago falla para la primera
- **THEN** la segunda se reconcilia igual, la primera no recibe ninguna escritura y vuelve a ser seleccionada en la corrida siguiente

#### Scenario: Suscripción sin cuenta queda fuera del barrido

- **WHEN** corre el barrido y existe una suscripción `ambiguous` sin cuenta asignada
- **THEN** el barrido no la consulta ni la modifica

### Requirement: Reconciliar nunca extiende el período por un cobro ya acreditado

Al reconciliar las cuotas de un preapproval (barrido, webhook o replay admin), el sistema SHALL mover el fin del período pagado de la cuenta sólo a partir de una cuota aprobada cuyo cobro no estaba acreditado al comenzar la reconciliación. Reaplicar una cuota ya acreditada SHALL completar cualquier escritura que hubiera quedado pendiente (auditoría, correo) sin modificar el fin del período pagado.

#### Scenario: MercadoPago adelanta el próximo cobro antes de procesar la cuota nueva

- **GIVEN** una suscripción cuya última cuota acreditada es la del mes anterior
- **AND** el preapproval ya informa como próxima fecha de cobro la del mes siguiente, mientras la cuota del mes en curso sigue sin procesar
- **WHEN** se reconcilian sus cuotas
- **THEN** el fin del período pagado de la cuenta no cambia

#### Scenario: Replay admin sobre cuotas ya acreditadas

- **GIVEN** una suscripción con todas sus cuotas aprobadas ya acreditadas
- **WHEN** un administrador ejecuta "Replicar cuotas"
- **THEN** la respuesta las informa como ya aplicadas y el fin del período pagado de la cuenta no cambia

### Requirement: El panel admin muestra si el cobro del mes entró

La sección "Suscripciones recientes" de `/admin/pagos/ambiguas` SHALL mostrar, por suscripción, el fin del período pagado de la cuenta y la fecha del último cobro mensual acreditado (o una marca de "sin cobros" si no hay ninguno), para que el operador verifique sin consultar la base si el cobro del mes se acreditó. La acción "Replicar cuotas" SHALL seguir disponible como red manual. La sección SHALL ser legible en escritorio y en móvil y en tema claro y oscuro.

#### Scenario: Cobro del mes acreditado

- **GIVEN** una suscripción cuyo cobro de noviembre se acreditó
- **WHEN** el administrador abre `/admin/pagos/ambiguas`
- **THEN** la fila muestra la fecha de ese cobro como último cobro acreditado y el nuevo fin del período pagado

#### Scenario: Suscripción sin cobros acreditados

- **WHEN** una suscripción todavía no tiene ningún cobro acreditado
- **THEN** la fila lo indica explícitamente en lugar de dejar la celda vacía
