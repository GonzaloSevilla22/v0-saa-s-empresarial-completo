## ADDED Requirements

### Requirement: Un plan de suscripción por tier pago

El sistema SHALL mantener en MercadoPago un `preapproval_plan` por cada tier pago (`inicial`, `avanzado`, `pro`), con recurrencia mensual y monto en ARS tomado de `plan_limits.price_monthly`.

El plan es un objeto de catálogo reutilizable: se crea una vez y todas las suscripciones de ese tier lo referencian. Su identificador SHALL persistirse del lado del sistema para poder asociar cada suscripción a su tier sin depender de heurísticas sobre el monto o la descripción.

Un tier sin plan de suscripción registrado NOT SHALL ofrecerse como destino de upgrade.

#### Scenario: Cada tier pago tiene su plan registrado
- **WHEN** se consulta la configuración de suscripciones del sistema
- **THEN** existe exactamente un identificador de plan de MercadoPago vigente por cada tier pago

#### Scenario: El monto del plan proviene de la base, no del código
- **WHEN** se crea o actualiza el plan de un tier
- **THEN** el monto recurrente es el `price_monthly` de ese tier en `plan_limits`
- **AND** la moneda es ARS y la recurrencia es mensual

#### Scenario: Un tier sin plan no se ofrece
- **GIVEN** un tier pago para el cual no hay un plan de suscripción registrado
- **WHEN** el usuario intenta iniciar el upgrade a ese tier
- **THEN** la operación se rechaza con un error explícito y no se crea ninguna suscripción

### Requirement: La suscripción se crea con referencia a la cuenta que la paga

El sistema SHALL crear la suscripción (`preapproval`) del lado del servidor, referenciando el plan del tier elegido y llevando una referencia externa que identifique de forma inequívoca la cuenta y el tier contratados.

Esa referencia externa es la que permite atribuir a una cuenta los cobros mensuales que llegarán meses después. Una suscripción SHALL NOT crearse sin ella.

La creación SHALL persistir la suscripción antes de devolverle al usuario la URL de autorización, de modo que una notificación de MercadoPago que llegue de inmediato encuentre la fila a la cual aplicarse.

#### Scenario: Alta de suscripción persiste antes de redirigir
- **WHEN** un usuario autenticado inicia el upgrade a un tier pago
- **THEN** se registra una suscripción con estado inicial pendiente, su identificador de MercadoPago, la cuenta, el tier y la referencia externa
- **AND** recién entonces se devuelve al usuario la URL de autorización

#### Scenario: La referencia externa identifica cuenta y tier
- **WHEN** se crea una suscripción
- **THEN** su referencia externa permite recuperar la cuenta y el tier contratado sin consultar ninguna otra fuente

#### Scenario: Sin referencia externa no hay suscripción
- **WHEN** la creación de la suscripción no puede componer la referencia externa
- **THEN** la operación falla y no se crea ninguna suscripción en MercadoPago

### Requirement: Una sola suscripción viva por cuenta

El sistema SHALL admitir como máximo una suscripción en estado pendiente o autorizado por cuenta, garantizado por la base de datos y no solo por la lógica de aplicación.

Las suscripciones canceladas o pausadas SHALL conservarse como historial: una cuenta que cancela y vuelve a suscribirse tiene varias filas, de las cuales a lo sumo una está viva.

#### Scenario: La base rechaza una segunda suscripción viva
- **GIVEN** una cuenta con una suscripción en estado autorizado
- **WHEN** se intenta registrar una segunda suscripción pendiente o autorizada para esa misma cuenta
- **THEN** la base de datos rechaza la operación

#### Scenario: Resuscribirse tras cancelar es posible
- **GIVEN** una cuenta cuya única suscripción está cancelada
- **WHEN** el usuario contrata nuevamente
- **THEN** se registra una suscripción nueva y la cancelada permanece como historial

### Requirement: Los estados de la suscripción reflejan los de MercadoPago

El sistema SHALL representar el estado de una suscripción con los mismos valores que expone MercadoPago para un `preapproval`: pendiente de autorización, autorizada, pausada y cancelada.

El estado SHALL actualizarse a partir de las notificaciones recibidas, y NOT SHALL inferirse del paso del tiempo ni de la existencia de cobros. MercadoPago es la fuente de verdad del estado de la suscripción.

#### Scenario: La autorización del pagador activa la suscripción
- **GIVEN** una suscripción registrada en estado pendiente
- **WHEN** llega la notificación de que el pagador la autorizó
- **THEN** la suscripción pasa a estado autorizado y se registra su fecha de próximo cobro

#### Scenario: La cancelación en MercadoPago se refleja localmente
- **WHEN** llega una notificación indicando que la suscripción quedó cancelada
- **THEN** la suscripción local pasa a estado cancelado, sin importar si la canceló el usuario, el vendedor o MercadoPago por cobros fallidos

#### Scenario: El estado no se infiere localmente
- **GIVEN** una suscripción autorizada cuya fecha de próximo cobro ya pasó y sobre la cual no llegó ninguna notificación
- **WHEN** se consulta su estado
- **THEN** sigue siendo autorizado

### Requirement: El cobro mensual aprobado extiende el período pagado

El sistema SHALL extender el fin del período pagado de la cuenta cada vez que un cobro mensual de la suscripción resulta aprobado, dejándolo en la fecha del próximo cobro más un período de gracia.

Cada cobro aprobado SHALL registrarse en la auditoría de facturación con el identificador del pago de MercadoPago, reutilizando la idempotencia por identificador de pago que ya existe.

#### Scenario: Cobro aprobado extiende el vencimiento
- **GIVEN** una cuenta con una suscripción autorizada
- **WHEN** llega la notificación de un cobro mensual aprobado
- **THEN** el fin del período pagado de la cuenta pasa a la nueva fecha de próximo cobro más el período de gracia
- **AND** se registra el cobro en la auditoría de facturación con el identificador del pago

#### Scenario: El mismo cobro notificado dos veces se acredita una sola vez
- **GIVEN** un cobro mensual ya acreditado
- **WHEN** vuelve a llegar una notificación para el mismo identificador de pago
- **THEN** no se registra un segundo evento de facturación ni se extiende dos veces el período pagado

#### Scenario: El plan de la cuenta no cambia en una renovación
- **WHEN** se acredita un cobro mensual de una suscripción vigente
- **THEN** el tier de la cuenta permanece igual y solo se corre la fecha de vencimiento

### Requirement: El cobro fallido avisa sin degradar de inmediato

El sistema SHALL notificar el cobro fallido de una suscripción sin degradar el plan de la cuenta mientras MercadoPago siga reintentando.

MercadoPago reintenta un cobro rechazado hasta cuatro veces dentro de una ventana de diez días y cancela la suscripción tras tres cuotas rechazadas consecutivas. El sistema NOT SHALL implementar su propia política de reintentos: mientras la suscripción siga viva, el acceso se sostiene con el período de gracia ya acreditado.

El estado de reintento informado por MercadoPago SHALL persistirse para que el usuario y el soporte puedan ver que hay un cobro en curso.

#### Scenario: Cobro rechazado avisa y no degrada
- **GIVEN** una cuenta con plan pago vigente y una suscripción autorizada
- **WHEN** llega la notificación de un cobro rechazado que será reintentado
- **THEN** se emite el aviso de cobro fallido
- **AND** el tier de la cuenta no cambia
- **AND** el fin del período pagado no se adelanta

#### Scenario: El reintento en curso queda visible
- **WHEN** se recibe una notificación de cobro en reintento
- **THEN** la suscripción registra que hay un reintento en curso y cuándo se espera el siguiente

#### Scenario: El sistema no reintenta por su cuenta
- **WHEN** un cobro es rechazado
- **THEN** el sistema no invoca ninguna operación de cobro contra MercadoPago

### Requirement: La cancelación detiene el cobro y difiere la degradación

El sistema SHALL cancelar la suscripción en MercadoPago cuando el usuario solicita dar de baja, y SHALL mantener el plan contratado activo hasta el fin del período efectivamente pagado.

La degradación diferida SHALL apoyarse en el barrido de cancelaciones que ya existe en producción, sin duplicar esa lógica.

#### Scenario: Cancelar detiene el cobro en MercadoPago
- **WHEN** el usuario confirma la baja de su suscripción
- **THEN** la suscripción queda cancelada en MercadoPago y no se le vuelve a cobrar

#### Scenario: El acceso se mantiene hasta el fin del período pagado
- **GIVEN** un usuario que cancela con período pagado hasta una fecha futura
- **WHEN** se consulta su plan efectivo antes de esa fecha
- **THEN** sigue siendo el tier contratado

#### Scenario: La degradación la ejecuta el barrido existente
- **GIVEN** una cuenta cancelada cuyo período pagado ya venció
- **WHEN** corre el barrido de cancelaciones ya existente
- **THEN** la cuenta queda en `gratis` y el hecho se registra en la auditoría de facturación

#### Scenario: Cancelar sin suscripción viva no rompe
- **GIVEN** una cuenta sin suscripción en estado pendiente ni autorizado
- **WHEN** se solicita la baja
- **THEN** la operación se rechaza con un error explícito y no se modifica ningún estado

### Requirement: La suscripción cancelada por impago degrada por el mismo camino

El sistema SHALL tratar la cancelación originada en cobros fallidos con el mismo mecanismo que una baja solicitada por el usuario, programando la degradación al fin del período pagado.

El motivo registrado en la auditoría SHALL distinguir la baja voluntaria del impago, para que el historial permita entender por qué una cuenta perdió su plan.

#### Scenario: Cancelación por impago programa la degradación
- **WHEN** llega la notificación de que MercadoPago canceló la suscripción por cobros fallidos
- **THEN** la cuenta queda programada para degradar al fin de su período pagado
- **AND** la auditoría registra el impago como motivo

#### Scenario: El motivo distingue impago de baja voluntaria
- **WHEN** se consulta la auditoría de facturación de una cuenta degradada
- **THEN** el motivo permite distinguir si la baja fue solicitada por el usuario o causada por cobros fallidos

### Requirement: Aviso de vencimiento próximo del plan pago

El sistema SHALL avisar a los responsables de una cuenta con plan pago antes de que su período pagado venza, de modo que un cobro que no va a prosperar no los tome por sorpresa.

El aviso SHALL emitirse por correo y SHALL deduplicarse por cuenta y por vencimiento, para que un barrido recurrente no genere un aviso diario.

#### Scenario: Aviso previo al vencimiento
- **GIVEN** una cuenta con plan pago cuyo período vence dentro de la ventana de aviso
- **WHEN** corre el barrido de avisos
- **THEN** se encola un aviso de vencimiento próximo para los responsables de la cuenta

#### Scenario: El barrido repetido no duplica el aviso
- **GIVEN** una cuenta que ya recibió el aviso para un vencimiento determinado
- **WHEN** el barrido vuelve a correr antes de esa fecha
- **THEN** no se encola un segundo aviso para el mismo vencimiento

#### Scenario: Las cuentas sin plan pago no reciben el aviso
- **GIVEN** una cuenta en plan `gratis` o con exención de cortesía vigente
- **WHEN** corre el barrido de avisos
- **THEN** no se encola ningún aviso de vencimiento para esa cuenta

### Requirement: Aislamiento por cuenta de los datos de suscripción

El sistema SHALL restringir la lectura de una suscripción a los miembros de la cuenta a la que pertenece, y SHALL reservar su escritura al backend.

Ningún usuario SHALL poder crear, modificar ni eliminar una fila de suscripción directamente: los estados provienen exclusivamente de las notificaciones de MercadoPago procesadas por el backend.

#### Scenario: Un miembro lee la suscripción de su cuenta
- **WHEN** un miembro de una cuenta consulta la suscripción de esa cuenta
- **THEN** obtiene la fila correspondiente

#### Scenario: No se leen suscripciones ajenas
- **WHEN** un usuario consulta la suscripción de una cuenta de la que no es miembro
- **THEN** no obtiene ninguna fila

#### Scenario: El navegador no puede escribir el estado de la suscripción
- **WHEN** un usuario intenta modificar directamente el estado o la fecha de próximo cobro de una suscripción
- **THEN** la operación es rechazada
