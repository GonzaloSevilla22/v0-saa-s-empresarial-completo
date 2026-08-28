# asyncpg-pool

## Purpose

Pool de conexiones asyncpg para el backend FastAPI. Gestiona el ciclo de vida del pool (startup/shutdown), envuelve cada request autenticado en una transacción explícita con los claims del JWT inyectados con alcance transaccional, adopta un rol de base de datos sin bypass de RLS para que las policies existentes se evalúen también para el backend, **comprueba que esa adopción efectivamente tomó antes de entregar la conexión** —rechazando el request si no puede comprobarlo—, y expone la dependencia `get_db_conn` para que los endpoints reciban conexiones ya configuradas.

## Requirements

### Requirement: Pool asyncpg con JWT-passthrough
El sistema SHALL mantener un pool de conexiones asyncpg con `min_size=2` y `max_size=10`, inicializado en el startup de la aplicación FastAPI y cerrado en el shutdown.

Cada request atendido con una conexión del pool SHALL ejecutarse dentro de una **transacción explícita**, y los claims del JWT del usuario SHALL inyectarse dentro de esa transacción con **alcance transaccional**, sobre el parámetro de configuración que las policies de seguridad a nivel de fila y las funciones de identidad de la base efectivamente consultan.

El alcance transaccional es normativo, no una preferencia de estilo: con un pooler en modo transacción, un parámetro con alcance de **sesión** puede quedar asentado en una conexión física distinta de aquella donde se ejecuta la consulta de negocio, y puede sobrevivir a la devolución de la conexión al pool y ser observado por el siguiente request. Un parámetro con alcance transaccional se deshace de forma automática al cerrar la transacción.

El sistema NOT SHALL inyectar parámetros de configuración que ningún consumidor lea: cada parámetro inyectado SHALL tener al menos un lector identificable en policies, funciones o código de aplicación.

Al terminar el request, la transacción SHALL cerrarse —confirmándose si el request tuvo éxito y deshaciéndose si falló— y la conexión SHALL devolverse al pool sin conservar parámetros de configuración del usuario atendido.

#### Scenario: Pool se inicializa en startup sin DATABASE_URL
- **WHEN** la app arranca sin la variable de entorno `DATABASE_URL` configurada
- **THEN** la app lanza un error claro en startup (`ValueError: DATABASE_URL required`) y no inicia

#### Scenario: Pool se inicializa en startup con DATABASE_URL válida
- **WHEN** la app arranca con `DATABASE_URL` configurada correctamente
- **THEN** el pool se crea con min_size=2, las 2 conexiones iniciales se establecen contra PostgreSQL y la app queda lista para recibir requests

#### Scenario: Pool se cierra limpiamente en shutdown
- **WHEN** la app recibe señal de shutdown (SIGTERM o KeyboardInterrupt)
- **THEN** el pool asyncpg se cierra (`await pool.close()`) antes de que el proceso termine, sin conexiones colgadas

#### Scenario: Los claims se inyectan dentro de una transacción y con alcance transaccional
- **WHEN** un request autenticado obtiene una conexión del pool
- **THEN** la conexión está dentro de una transacción explícita y los claims se han inyectado con alcance transaccional, antes de que se ejecute cualquier consulta de negocio

#### Scenario: Las funciones de identidad de la base ven al usuario del request
- **GIVEN** un request autenticado atendido con una conexión del pool
- **WHEN** se ejecuta una consulta que deriva la identidad del usuario desde los parámetros de sesión de la base
- **THEN** la identidad observada es la del usuario del request, de forma consistente en todas las consultas del mismo request

#### Scenario: Los claims no sobreviven al request
- **GIVEN** un request atendido y finalizado
- **WHEN** la misma conexión física se reutiliza para un request distinto
- **THEN** el request nuevo no observa los claims del anterior

#### Scenario: Un request fallido no deja trabajo parcial
- **GIVEN** un request que escribe en la base y luego falla antes de completarse
- **WHEN** el request termina con error
- **THEN** ninguna de sus escrituras queda persistida

#### Scenario: Una transacción ociosa no se acumula indefinidamente
- **GIVEN** un request cuya transacción queda ociosa más allá del límite configurado
- **THEN** la base aborta esa transacción, en lugar de retener la conexión y los bloqueos de forma indefinida

#### Scenario: Request sin autenticación no obtiene conexión DB
- **WHEN** un endpoint que usa `get_db_conn` recibe un request sin Bearer token
- **THEN** `get_current_user` lanza HTTP 401 antes de que se adquiera ninguna conexión del pool

### Requirement: El rol efectivo del camino de request no bypasea la seguridad a nivel de fila

Dentro de la transacción de cada request autenticado, el sistema SHALL adoptar, con alcance transaccional, un rol de base de datos que **no** tenga el atributo de bypass de seguridad a nivel de fila, de modo que las policies existentes se evalúen también para las consultas del backend y no sólo para el acceso directo desde el navegador.

El rol adoptado SHALL ser el mismo para el que están escritas las policies vigentes, para no requerir una superficie de permisos paralela. La adopción SHALL tener alcance transaccional: un cambio de rol con alcance de sesión NOT SHALL usarse, porque sobreviviría a la devolución de la conexión al pool.

La adopción del rol y la inyección de los claims SHALL ocurrir en el mismo punto y en la misma transacción, de modo que no puedan divergir.

#### Scenario: El usuario efectivo dentro de un request no bypasea las policies

- **WHEN** se inspecciona el rol efectivo desde dentro de un request autenticado
- **THEN** el rol efectivo es uno sin atributo de bypass de seguridad a nivel de fila

#### Scenario: Una consulta sin filtro de cuenta no devuelve datos de otra cuenta

- **GIVEN** dos cuentas distintas con datos propios y un request autenticado como miembro de la primera
- **WHEN** el backend ejecuta una consulta que omite el filtro por cuenta
- **THEN** el resultado no incluye filas de la segunda cuenta

#### Scenario: El cambio de rol no persiste entre requests

- **GIVEN** un request que adoptó el rol restringido y terminó
- **WHEN** la misma conexión física se reutiliza
- **THEN** el rol efectivo vuelve a ser el rol de conexión original, sin residuo del request anterior

### Requirement: Activación gradual y reversible del ciclo de vida de conexión

Los cambios en el ciclo de vida de la conexión SHALL desplegarse detrás de una palanca de configuración por entorno, apagada por defecto, de modo que el despliegue del código NOT SHALL alterar el comportamiento de producción hasta una activación explícita. Cada paso —el alcance transaccional de los claims y la adopción del rol restringido— SHALL poder activarse y revertirse de forma independiente, sin desplegar código nuevo y sin ninguna operación destructiva sobre datos.

#### Scenario: Desplegar el código no cambia el comportamiento

- **WHEN** se despliega la versión que incorpora el ciclo de vida nuevo con la palanca apagada
- **THEN** el comportamiento observable de la API es idéntico al anterior al despliegue

#### Scenario: Revertir es un cambio de configuración

- **GIVEN** la palanca activada en producción
- **WHEN** se apaga la palanca
- **THEN** el sistema vuelve al comportamiento anterior sin desplegar código y sin pérdida de datos

### Requirement: Configuración de base de datos vía entorno
El sistema SHALL leer `DATABASE_URL` y `REDIS_URL` desde variables de entorno via `pydantic-settings`. Ambas deben tener valores por defecto vacíos que causen un error explícito en startup si no están configuradas en producción.

#### Scenario: Settings carga DATABASE_URL desde entorno
- **WHEN** el proceso tiene `DATABASE_URL=postgresql://user:pass@host:5432/db` en el entorno
- **THEN** `settings.database_url` retorna ese valor sin modificación

#### Scenario: Settings en development usa .env file
- **WHEN** existe un archivo `.env` en la raíz con `DATABASE_URL=...`
- **THEN** `pydantic-settings` lo carga automáticamente y `settings.database_url` retorna el valor del archivo

### Requirement: La adopción del rol restringido se verifica antes de exponer la conexión

Cuando la adopción del rol restringido está activa, el sistema SHALL comprobar —después de adoptarlo y antes de entregar la conexión al código de negocio— que la adopción efectivamente tomó, y SHALL rechazar el request si no puede comprobarlo.

Emitir la adopción no equivale a que la adopción haya tenido efecto, y por eso la comprobación es normativa y no una precaución redundante. Los modos de falla que atrapa son los que dejan la adopción sin efecto sin levantar error: la membresía de rol que habilita la adopción puede haber sido revocada del lado de la base, y un statement puede ser tragado sin que el cliente reciba error alguno. El riesgo de que el cambio de rol se encamine a una conexión física distinta de aquella donde corren las consultas de negocio lo cierra la **transacción explícita** por request —materia de los requirements que fijan esa transacción y la adopción dentro de ella, no de esta comprobación—, que fija ambos statements sobre la misma conexión física; esta comprobación se apoya en esa co-locación, no la sustituye. En cualquiera de los casos que sí atrapa, sin comprobación el request correría con el rol de conexión original —que sí tiene el atributo de bypass de seguridad a nivel de fila— **creyendo estar sujeto a las policies y sin emitir señal alguna**. Un fallo de aislamiento silencioso es peor que la ausencia del mecanismo, porque además suprime la sospecha.

La comprobación SHALL leer el **rol efectivo** de la sesión —el que las policies evalúan—, no el rol con el que se estableció la conexión, que informaría el valor original aunque la adopción hubiese tomado. La comprobación SHALL realizarse sobre la misma conexión y dentro de la misma transacción en la que correrán las consultas de negocio del request: una comprobación hecha fuera de ese alcance no prueba nada bajo un pooler en modo transacción, que es exactamente el escenario que la motiva. La comprobación NOT SHALL adelantarse a la adopción que verifica ni realizarse después de haber entregado la conexión.

El criterio SHALL ser de **igualdad estricta** contra el rol restringido esperado. El sistema NOT SHALL aceptar el request por descarte —"cualquier rol distinto del rol de conexión original"—: toda respuesta que no sea exactamente el rol esperado, **incluida una respuesta vacía o ausente**, SHALL tratarse como comprobación fallida. Un criterio negativo dejaría pasar la respuesta ausente de un intermediario que se come el resultado, que es el caso que la comprobación existe para atrapar.

Ante una comprobación fallida el sistema SHALL fallar **cerrado**: SHALL rechazar el request señalando indisponibilidad temporal del servicio —no un error de autorización, porque el cliente no hizo nada mal— y NOT SHALL entregar la conexión. Ninguna consulta de negocio SHALL ejecutarse jamás sobre una conexión que se cree sujeta a las policies sin estarlo, y el request rechazado NOT SHALL degradarse a un éxito parcial ni continuar con el rol privilegiado. El mensaje de rechazo SHALL ser opaco: NOT SHALL revelar el rol efectivo observado ni ningún otro detalle interno de la sesión de base de datos.

Una comprobación fallida SHALL registrarse con el nivel de severidad más alto disponible, incluyendo el rol efectivo observado y el identificador del sujeto del request, de modo que la presencia de un fallo sea imposible de pasar por alto.

La comprobación SHALL ejecutarse una sola vez por conexión de request entregada —no una vez por consulta— y SHALL costar a lo sumo un intercambio adicional con la base por conexión entregada. SHALL existir únicamente donde existe la adopción que verifica: con la adopción desactivada, el sistema NOT SHALL emitir comprobación alguna ni pagar el intercambio adicional, y los caminos previos SHALL quedar idénticos. La comprobación SHALL aplicar únicamente a las conexiones obtenidas por el contexto de request, que es donde ocurre la adopción; toda conexión obtenida por el contexto de servicio —el que por diseño conserva el bypass para operar sin identidad de usuario— SHALL quedar fuera de su alcance, y la comprobación NOT SHALL poder rechazarla.

#### Scenario: La adopción se comprueba antes de entregar la conexión

- **GIVEN** un request autenticado con la adopción del rol restringido activa
- **WHEN** la adopción toma correctamente
- **THEN** el rol efectivo se comprueba una sola vez, después de la adopción y antes de que la conexión quede disponible para el código de negocio, y el request continúa con normalidad

#### Scenario: Una adopción que no tomó rechaza el request sin entregar la conexión

- **GIVEN** un request autenticado con la adopción activa
- **WHEN** el rol efectivo resulta ser el rol de conexión original, con atributo de bypass de seguridad a nivel de fila
- **THEN** el request se rechaza con indisponibilidad del servicio y ninguna consulta de negocio llega a ejecutarse sobre esa conexión

#### Scenario: Una respuesta que no es exactamente el rol esperado también rechaza

- **GIVEN** un request autenticado con la adopción activa
- **WHEN** la comprobación devuelve una respuesta ausente o vacía en lugar de un nombre de rol
- **THEN** el request se rechaza igual que si el rol observado hubiese sido el privilegiado, porque el criterio es de igualdad estricta y no de descarte

#### Scenario: El mensaje de rechazo no revela el estado interno de la sesión

- **GIVEN** un request rechazado por comprobación fallida
- **WHEN** el cliente recibe la respuesta
- **THEN** el mensaje no contiene el rol efectivo observado ni ningún otro detalle de la sesión de base de datos

#### Scenario: Un rechazo por comprobación fallida deja rastro operativo

- **GIVEN** un request rechazado por comprobación fallida
- **WHEN** se inspeccionan los registros operativos del período
- **THEN** el rechazo aparece registrado con la severidad más alta disponible, con el rol efectivo observado y el sujeto del request, de modo que sea imposible de pasar por alto

#### Scenario: Sin adopción de rol no hay comprobación ni costo adicional

- **GIVEN** un request autenticado con la adopción del rol restringido desactivada
- **WHEN** obtiene una conexión del pool
- **THEN** no se emite ninguna comprobación del rol efectivo ni ningún intercambio adicional con la base, y el comportamiento observable es el mismo que el de un ciclo de vida de conexión sin comprobación

#### Scenario: El camino de conexión de servicio queda fuera de la comprobación

- **GIVEN** una operación que obtiene su conexión por el contexto de servicio, con todas las palancas activadas
- **WHEN** obtiene su conexión
- **THEN** no adopta el rol restringido, la comprobación no se le aplica y no puede rechazarla

