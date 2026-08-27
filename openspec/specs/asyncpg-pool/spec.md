# asyncpg-pool

## Purpose

Pool de conexiones asyncpg para el backend FastAPI. Gestiona el ciclo de vida del pool (startup/shutdown), envuelve cada request autenticado en una transacción explícita con los claims del JWT inyectados con alcance transaccional, adopta un rol de base de datos sin bypass de RLS para que las policies existentes se evalúen también para el backend, y expone la dependencia `get_db_conn` para que los endpoints reciban conexiones ya configuradas.

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
