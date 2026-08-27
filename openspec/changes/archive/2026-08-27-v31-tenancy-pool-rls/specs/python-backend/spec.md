## ADDED Requirements

### Requirement: Separación explícita entre el contexto de conexión de request y el de servicio

El backend SHALL exponer dos contextos de conexión a base de datos, con contratos distintos y documentados:

- **Contexto de request**: para toda operación originada por un usuario autenticado. Inyecta los claims del usuario con alcance transaccional, opera dentro de una transacción explícita por request, y queda sujeto a la evaluación de las policies de seguridad a nivel de fila.
- **Contexto de servicio**: para operaciones de máquina sin usuario (recepción de avisos de pago, procesos programados, tareas en segundo plano). NOT SHALL inyectar claims de usuario ni quedar envuelto en la transacción de un request, porque opera de forma transversal a las cuentas por diseño.

Cada punto de entrada del backend SHALL declarar cuál de los dos contextos usa. Un endpoint que atiende a un usuario autenticado NOT SHALL usar el contexto de servicio.

#### Scenario: Un endpoint de usuario usa el contexto de request

- **WHEN** un usuario autenticado ejercita cualquier endpoint de negocio
- **THEN** la conexión proviene del contexto de request, con sus claims inyectados y dentro de su transacción

#### Scenario: El aviso de pago usa el contexto de servicio

- **WHEN** llega un aviso de pago del proveedor de cobros, sin usuario autenticado
- **THEN** la operación usa el contexto de servicio y se completa sin requerir claims de usuario

#### Scenario: Una tarea en segundo plano no reutiliza la conexión del request

- **GIVEN** un endpoint que agenda trabajo para después de responder
- **WHEN** ese trabajo se ejecuta
- **THEN** obtiene su propia conexión del contexto de servicio, sin depender de la conexión ni de la transacción del request que ya terminó

### Requirement: Las escrituras directas del backend son compatibles con las policies vigentes

Toda escritura que el backend ejecute sobre una tabla **sin** pasar por una función con privilegios de definidor SHALL contar con una policy de escritura que la habilite para el rol del camino de request. Antes de activar la evaluación de policies para el backend, el sistema SHALL disponer de un inventario verificado de las escrituras directas cruzado contra las policies existentes, y cada divergencia SHALL resolverse encaminando la escritura por una función con privilegios de definidor o incorporando la policy faltante.

Una divergencia detectada durante la activación en producción, en lugar de antes, NOT SHALL considerarse un resultado aceptable del procedimiento.

#### Scenario: El inventario precede a la activación

- **WHEN** se propone activar la evaluación de policies para el backend
- **THEN** existe un inventario verificado de escrituras directas cruzado contra las policies, sin divergencias abiertas

#### Scenario: Una escritura directa sin policy se detecta antes del corte

- **GIVEN** una tabla que el backend escribe directamente y que no tiene policy de escritura
- **WHEN** se ejecuta el inventario
- **THEN** la divergencia queda registrada y resuelta antes de la activación, en lugar de manifestarse como un error de permisos en producción
