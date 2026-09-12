# account-membership-roles Specification

## Purpose

Pivot multi-rol de la membresía de cuenta (Modelo V3 §5): un catálogo cerrado y global de ocho roles (propietario, administrador, vendedor, cajero, depósito, compras, contable, observador), donde cada membresía puede tener varios roles activos a la vez, cada uno con autoría (quién lo asignó y cuándo) y vigencia opcional. El rol único heredado de la membresía ("owner"/"admin"/"member") se conserva como valor derivado por precedencia, mantenido automáticamente por la base, para que los consumidores existentes no cambien. La cuenta nunca queda sin un propietario activo mientras conserve miembros, toda asignación y revocación queda auditada, y la gestión de miembros y roles tiene su propia superficie en /organizacion/roles.

## Requirements

### Requirement: Catálogo de roles cerrado, global y consultable como datos

El sistema SHALL declarar el conjunto de roles asignables como un catálogo global de solo lectura almacenado como datos, y NOT como una lista repetida en restricciones, en código de aplicación o en la interfaz. El catálogo SHALL ser el mismo para todas las cuentas: una cuenta NOT SHALL poder definir roles propios ni redefinir el significado de un rol existente.

Cada entrada del catálogo SHALL declarar, además de su código, la etiqueta legible y la descripción que la interfaz muestra, un orden de presentación estable, y si el rol concede escritura sobre los datos de negocio. La condición de escritura SHALL ser un dato del catálogo, de modo que incorporar un rol nuevo NOT SHALL requerir reescribir la función que la RLS consulta.

El catálogo SHALL ser legible por cualquier miembro autenticado y NOT SHALL ser escribible por los roles de aplicación: sólo una migración SHALL poder alterarlo.

#### Scenario: El catálogo contiene los ocho roles del modelo de dominio

- **WHEN** se consulta el catálogo de roles
- **THEN** contiene exactamente ocho entradas: propietario, administrador, vendedor, cajero, depósito, compras, contable y observador
- **AND** cada una expone su etiqueta, su descripción, su orden de presentación y si concede escritura

#### Scenario: Un rol fuera del catálogo no puede asignarse

- **WHEN** se intenta asignar a una membresía un rol que no figura en el catálogo
- **THEN** la base rechaza la operación por integridad referencial, sin dejar la asignación registrada

#### Scenario: Los roles de aplicación no pueden alterar el catálogo

- **WHEN** un rol de aplicación intenta insertar, modificar o eliminar una entrada del catálogo
- **THEN** la operación es rechazada

#### Scenario: Sólo el rol observador no concede escritura

- **WHEN** se consulta qué entradas del catálogo conceden escritura
- **THEN** todas la conceden excepto la del rol observador

### Requirement: Una membresía admite varios roles simultáneos

El sistema SHALL permitir que una misma membresía tenga asignados varios roles a la vez, y SHALL evaluar los permisos sobre el **conjunto** de sus roles activos, NOT sobre un único rol. Una misma membresía NOT SHALL poder tener dos veces el mismo rol.

#### Scenario: Un encargado acumula tres roles

- **WHEN** a una membresía se le asignan los roles de vendedor, cajero y depósito
- **THEN** los tres quedan registrados y el miembro puede ejercer las acciones de los tres, sin necesidad de recibir un rol de mayor alcance

#### Scenario: El mismo rol no se asigna dos veces

- **GIVEN** una membresía que ya tiene asignado el rol de cajero
- **WHEN** se intenta asignarle nuevamente el rol de cajero
- **THEN** no se crea una segunda asignación

### Requirement: Toda asignación de rol registra quién la otorgó y cuándo

El sistema SHALL registrar, por cada asignación de rol, la identidad de quien la otorgó y el instante en que lo hizo. La autoría SHALL ser un dato de primera clase de la asignación, NOT un registro derivado ni reconstruible sólo desde el historial.

Cuando una asignación provenga del aprovisionamiento inicial de la cuenta y no de una acción humana, su autoría SHALL quedar explícitamente vacía en lugar de atribuirse a una persona que no la realizó.

#### Scenario: Una asignación hecha por una persona registra su autoría

- **WHEN** un miembro con autoridad asigna un rol a otro miembro
- **THEN** la asignación queda registrada con la identidad de quien la otorgó y el instante de la operación

#### Scenario: El rol del aprovisionamiento no atribuye autoría

- **WHEN** se crea una cuenta y su miembro fundador recibe el rol de propietario
- **THEN** la asignación registra el instante de creación de la membresía y no atribuye la autoría a ninguna persona

### Requirement: Un rol puede tener vencimiento y deja de conceder permisos al vencer

El sistema SHALL admitir que una asignación de rol tenga una fecha de vencimiento, y SHALL tratar como **activa** únicamente la asignación sin vencimiento o cuyo vencimiento sea posterior al instante de evaluación. Una asignación vencida NOT SHALL conceder ningún permiso.

El corte de permisos al vencer SHALL producirse por evaluación del vencimiento en cada autorización, y NOT SHALL depender de que un proceso programado haya corrido: la caída de ese proceso NOT SHALL conceder permisos de más.

La asignación vencida NOT SHALL eliminarse: permanece como constancia de que esa persona tuvo ese rol hasta esa fecha.

#### Scenario: Un acceso temporal deja de conceder permisos al vencer

- **GIVEN** una membresía con un rol asignado cuyo vencimiento ya pasó
- **WHEN** se resuelven sus roles activos
- **THEN** el rol vencido no figura entre ellos

#### Scenario: Un rol sin vencimiento es permanente

- **GIVEN** una membresía con un rol asignado sin fecha de vencimiento
- **WHEN** se resuelven sus roles activos
- **THEN** el rol figura entre ellos

#### Scenario: La asignación vencida se conserva como constancia

- **GIVEN** una asignación de rol cuyo vencimiento ya pasó
- **WHEN** se consulta el registro de asignaciones de esa membresía
- **THEN** la asignación vencida sigue presente, marcada como no activa

#### Scenario: El corte no depende del proceso programado

- **GIVEN** un rol vencido y el proceso programado de auditoría de vencimientos detenido
- **WHEN** el miembro intenta ejercer una acción que ese rol concedía
- **THEN** la acción es rechazada

### Requirement: El rol de propietario no admite vencimiento

El sistema SHALL rechazar toda asignación del rol de propietario que lleve fecha de vencimiento. Un propietario con vencimiento permitiría que una cuenta quedara sin dueño por el mero paso del tiempo, sin ninguna acción humana que auditar.

#### Scenario: Asignar propietario con vencimiento es rechazado

- **WHEN** se intenta asignar el rol de propietario con una fecha de vencimiento
- **THEN** la operación es rechazada y la asignación no se registra

### Requirement: Una cuenta con miembros nunca queda sin propietario activo

El sistema SHALL garantizar que toda cuenta que conserve al menos un miembro tenga al menos una asignación activa del rol de propietario. La garantía SHALL hacerse cumplir en la propia base, como punto de paso obligado de toda escritura sobre las asignaciones, y NOT SHALL depender de que la operación se realice a través de un procedimiento en particular.

La verificación SHALL realizarse al cierre de la transacción y NOT por cada fila, de modo que una transferencia de la propiedad —quitar el rol a una persona y otorgárselo a otra en la misma transacción— sea posible pese a atravesar un estado intermedio sin propietario.

Una cuenta que haya quedado **sin ningún miembro** SHALL satisfacer la garantía de forma vacua: no hay a quién exigirle el rol.

#### Scenario: Revocar el único propietario es rechazado

- **GIVEN** una cuenta con miembros en la que una sola membresía tiene el rol de propietario
- **WHEN** se intenta revocar esa asignación
- **THEN** la operación es rechazada y la cuenta conserva su propietario

#### Scenario: Transferir la propiedad en una sola transacción es posible

- **GIVEN** una cuenta con dos miembros, uno de ellos propietario
- **WHEN** en la misma transacción se revoca el rol de propietario al primero y se le asigna al segundo
- **THEN** la operación se completa y la cuenta queda con un propietario distinto

#### Scenario: La garantía no depende del procedimiento usado

- **WHEN** se intenta eliminar directamente la última asignación activa de propietario de una cuenta con miembros, sin pasar por ninguna operación de gestión de miembros
- **THEN** la escritura es rechazada igual

#### Scenario: Vaciar una cuenta por completo es posible

- **WHEN** se eliminan todas las membresías de una cuenta
- **THEN** la operación se completa, sin que la garantía de propietario la bloquee

### Requirement: El rol único heredado se conserva como valor derivado de las asignaciones

El sistema SHALL conservar el rol único preexistente de la membresía como un valor **derivado** del conjunto de roles activos, mantenido automáticamente por la base ante cualquier cambio en las asignaciones. Ese valor derivado SHALL expresarse en el vocabulario heredado, para que todo consumidor que hoy lo lee —la función de escritura de la RLS, la emisión de claims, la consulta de rol propio y la interfaz— siga obteniendo la misma respuesta sin modificarse.

La derivación SHALL aplicar precedencia: propietario si existe una asignación activa de propietario; si no, administrador si existe una asignación activa de administrador; si no, el valor de solo lectura.

Las asignaciones SHALL ser la única fuente de verdad: NOT SHALL existir ningún camino de escritura que altere el valor derivado sin pasar por ellas.

#### Scenario: El valor derivado refleja la asignación de mayor precedencia

- **GIVEN** una membresía con asignaciones activas de administrador y de vendedor
- **WHEN** se consulta su rol único heredado
- **THEN** vale administrador

#### Scenario: Revocar una asignación actualiza el valor derivado

- **GIVEN** una membresía cuya única asignación activa es la de administrador
- **WHEN** se revoca esa asignación y se le asigna el rol de observador
- **THEN** el valor derivado pasa a ser el de solo lectura

#### Scenario: No existe escritura directa del valor derivado

- **WHEN** se intenta modificar el rol de una membresía sin alterar sus asignaciones
- **THEN** el valor derivado vuelve a reflejar las asignaciones vigentes, sin conservar el valor escrito directamente

### Requirement: Las membresías existentes reciben su asignación equivalente sin ambigüedad

El sistema SHALL trasladar cada membresía preexistente a una asignación equivalente en el nuevo modelo, conservando el instante en que la membresía fue creada como instante de asignación. El traslado SHALL ser idempotente: ejecutarlo más de una vez NOT SHALL duplicar asignaciones ni alterar las ya existentes.

Tras el traslado, la cantidad de membresías con al menos una asignación activa SHALL ser igual a la cantidad total de membresías: ninguna SHALL quedar sin rol.

#### Scenario: Cada membresía preexistente queda con su rol equivalente

- **WHEN** se aplica el traslado sobre las membresías existentes
- **THEN** cada una queda con una asignación activa equivalente a su rol previo, fechada en el instante de creación de la membresía

#### Scenario: Reaplicar el traslado no duplica

- **WHEN** el traslado se ejecuta por segunda vez
- **THEN** no se crean asignaciones nuevas ni se modifican las existentes

#### Scenario: Ninguna membresía queda sin rol

- **WHEN** se cuentan las membresías sin ninguna asignación activa tras el traslado
- **THEN** el resultado es cero

### Requirement: Asignar y revocar roles queda auditado

El sistema SHALL registrar en la bitácora de auditoría toda asignación y toda revocación de un rol, identificando la cuenta, quién la realizó, la membresía afectada, el rol y —cuando corresponda— el vencimiento pactado.

El sistema SHALL registrar también el vencimiento de una asignación temporal, una sola vez por asignación vencida, mediante un barrido periódico idempotente. Ese barrido NOT SHALL eliminar asignaciones ni alterar permisos: su única función es dejar constancia.

Estos registros de auditoría NOT SHALL generar notificaciones en la interfaz.

#### Scenario: Una asignación deja registro de auditoría

- **WHEN** un miembro con autoridad asigna un rol a otro miembro
- **THEN** queda un registro de auditoría que identifica la cuenta, el autor, la membresía afectada y el rol asignado

#### Scenario: Una revocación deja registro de auditoría

- **WHEN** se revoca un rol a un miembro
- **THEN** queda un registro de auditoría de la revocación con su autor

#### Scenario: El vencimiento se registra una sola vez

- **GIVEN** una asignación cuyo vencimiento ya pasó y cuyo vencimiento ya fue registrado
- **WHEN** el barrido periódico vuelve a ejecutarse
- **THEN** no se agrega un segundo registro para esa asignación

#### Scenario: El barrido no altera permisos

- **WHEN** el barrido periódico procesa asignaciones vencidas
- **THEN** ninguna asignación es eliminada y ningún permiso cambia como consecuencia del barrido

### Requirement: La gestión de miembros y sus roles tiene superficie propia

El sistema SHALL ofrecer, en la pantalla de gestión de roles ya existente y **sin cambiar su ruta ni los accesos que llevan a ella**, la administración completa de la membresía: listar los miembros de la cuenta con el conjunto de roles de cada uno y el vencimiento de los temporales, asignar un rol, asignar un rol con vencimiento, revocar un rol y quitar a un miembro de la cuenta.

La pantalla SHALL mostrar las etiquetas y descripciones del catálogo, NOT una lista de roles codificada en la interfaz. SHALL distinguir visualmente una asignación vencida de una vigente. SHALL ofrecer un estado vacío comprensible cuando la cuenta tenga un solo miembro.

Las acciones de gestión SHALL exponerse únicamente a quien tiene autoridad para ejecutarlas, y su resultado SHALL reflejarse sin recargar la página.

La superficie SHALL verificarse en resolución de escritorio y de móvil, y en tema claro y oscuro, antes de considerarse completa.

#### Scenario: El listado muestra todos los roles de cada miembro

- **GIVEN** un miembro con tres roles asignados
- **WHEN** se abre la pantalla de gestión de roles
- **THEN** se muestran los tres, con su etiqueta del catálogo

#### Scenario: Un rol temporal muestra su vencimiento

- **GIVEN** un miembro con un rol asignado con fecha de vencimiento futura
- **WHEN** se abre la pantalla de gestión de roles
- **THEN** la asignación se muestra junto con la fecha hasta la que rige

#### Scenario: Una asignación vencida se distingue de una vigente

- **GIVEN** un miembro con una asignación vencida y otra vigente
- **WHEN** se abre la pantalla de gestión de roles
- **THEN** la vencida se distingue visualmente de la vigente

#### Scenario: Los accesos existentes a la pantalla siguen funcionando

- **WHEN** se navega a la gestión de roles desde la pantalla de invitación o desde la de configuración
- **THEN** se llega a la misma pantalla, en la misma ruta que antes del cambio

#### Scenario: Quien no tiene autoridad no ve las acciones de gestión

- **GIVEN** un miembro sin autoridad para gestionar roles
- **WHEN** abre la pantalla de gestión de roles
- **THEN** ve el listado de miembros y sus roles, sin controles para asignar, revocar ni quitar

### Requirement: La invitación de un miembro admite el conjunto de roles con que se incorpora

El sistema SHALL permitir que una invitación declare el conjunto de roles con el que el invitado se incorporará, y al aceptarse SHALL crear la membresía con exactamente ese conjunto. Una invitación sin roles declarados SHALL resolver al rol de solo lectura.

Los errores de la invitación —cupo de usuarios agotado, invitación pendiente duplicada, falta de autoridad para invitar— SHALL expresarse con códigos de error del espacio propio del dominio, conservando el texto que la interfaz ya muestra.

#### Scenario: Se invita con varios roles y se aceptan todos

- **WHEN** se invita a una persona declarando los roles de vendedor y cajero, y ésta acepta
- **THEN** su membresía queda creada con ambos roles activos

#### Scenario: Una invitación sin roles resuelve a solo lectura

- **WHEN** se acepta una invitación que no declara ningún rol
- **THEN** la membresía queda creada con el rol de observador

#### Scenario: El cupo de usuarios se informa con un código del dominio

- **GIVEN** una cuenta que alcanzó el cupo de usuarios de su plan
- **WHEN** se intenta invitar a otra persona
- **THEN** la operación es rechazada con un código de error del dominio y el mismo texto que la interfaz ya mostraba

### Requirement: El cupo comercial cuenta miembros, no roles

El sistema SHALL comparar contra el límite de usuarios del plan la cantidad de **miembros** de la cuenta, NOT la cantidad de asignaciones de rol. Un miembro con varios roles SHALL contar como uno.

#### Scenario: Un miembro con varios roles consume un solo lugar del cupo

- **GIVEN** una cuenta cuyo plan admite dos usuarios y que tiene un miembro con cuatro roles
- **WHEN** se invita a una segunda persona
- **THEN** la invitación es aceptada, porque la cuenta consume un lugar de los dos disponibles
