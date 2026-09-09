# account-tenancy — Spec

> Capability: **account-tenancy** — garantías de integridad referencial y seguridad de tenancy mediante `account_id` como clave única de organización en las tablas ERP, incluyendo la dependency FastAPI que lo resuelve desde el JWT y la cleanup de columnas legacy.

## Purpose

Establecer `account_id` como la única clave de tenancy en todas las tablas ERP del backend Python, eliminando los filtros históricos por `user_id` y `company_id`. Incluye el backfill de NULLs en producción, la extensión de RLS a `suppliers`, el `get_account_id` dependency de FastAPI, y el plan de eliminación de columnas legacy en el paso 8. C-19.

## Requirements

### Requirement: Todas las tablas ERP tienen account_id sin NULLs

El sistema SHALL garantizar que ninguna fila en las tablas ERP (`sales`, `purchases`, `products`, `expenses`, `clients`, `stock_movements`, `suppliers`) tenga `account_id IS NULL` tras el backfill.

#### Scenario: Backfill completa sin filas huérfanas
- **WHEN** el script de backfill del paso 1 termina en producción
- **THEN** `SELECT COUNT(*) FROM <tabla> WHERE account_id IS NULL` = 0 para cada tabla ERP listada

#### Scenario: Inserción futura no puede ser sin account_id
- **WHEN** se intenta hacer INSERT en `sales`, `purchases`, `products`, `expenses` o `clients` sin `account_id`
- **THEN** la DB rechaza la operación (NOT NULL constraint o CHECK)

### Requirement: suppliers scoped por account_id con RLS

El sistema SHALL proteger las filas de `suppliers` mediante RLS basada en `account_id`, alineada con el resto de las tablas ERP.

#### Scenario: Usuario solo ve sus propios suppliers
- **GIVEN** dos tenants A y B, cada uno con suppliers propios
- **WHEN** el usuario de tenant A ejecuta `SELECT * FROM suppliers`
- **THEN** solo recibe los `suppliers` donde `account_id = ANY(current_account_ids())`; los suppliers del tenant B no aparecen

#### Scenario: Supplier sin account_id no es creatable post-migración
- **WHEN** se intenta INSERT en `suppliers` sin `account_id`
- **THEN** la DB rechaza la operación (NOT NULL constraint aplicada en paso 8)

### Requirement: account_id obtenido desde el request context en backend Python

El sistema SHALL proveer un dependency `get_account_id` en `core/deps.py` que retorna el `account_id` del tenant activo consultando `account_members` via la conexión JWT-passthrough del request. Ningún repositorio SHALL derivar `account_id` desde JWT claims directamente.

#### Scenario: Dependency retorna account_id del tenant activo
- **WHEN** un endpoint recibe `account_id: UUID = Depends(get_account_id)` con un JWT válido de un usuario miembro de una cuenta
- **THEN** `get_account_id` ejecuta `SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1` y retorna el UUID de la cuenta

#### Scenario: Usuario sin cuenta activa recibe 403
- **GIVEN** un JWT válido de un usuario sin ninguna fila en `account_members`
- **WHEN** el endpoint invoca `Depends(get_account_id)`
- **THEN** se lanza `HTTPException(status_code=403)` con mensaje "No active account found"

### Requirement: Columnas legacy de tenancy eliminadas de tablas ERP

El sistema SHALL eliminar `company_id` y `user_id` (como mecanismo de tenancy) de las tablas ERP (`sales`, `purchases`, `products`, `expenses`, `clients`) tras validar que no tienen consumidores activos. El campo `user_id` que sea FK a `auth.users` se conserva solo si tiene ese rol semántico distinto.

#### Scenario: tablas ERP no tienen columna company_id post-drop
- **WHEN** se consulta `information_schema.columns` para las tablas ERP listadas
- **THEN** ninguna de ellas tiene una columna llamada `company_id`

#### Scenario: suppliers no tiene company_id post-drop
- **WHEN** se consulta `information_schema.columns` para `suppliers`
- **THEN** la columna `company_id` no existe (reemplazada por `account_id`)

### Requirement: Las funciones internas con privilegio de definidor no son ejecutables por los roles de aplicación

El sistema SHALL mantener toda función `SECURITY DEFINER` de uso **interno** —la que existe para ser invocada desde otra función y no como comando de la API— fuera del alcance de ejecución de los roles de aplicación (`anon` y `authenticated`), salvo entrada explícita y justificada en una allowlist.

La regla no es cosmética. Una función con privilegio de definidor que recibe el tenant **como parámetro**, en lugar de resolverlo de la sesión, delega la verificación de permiso en su llamador. Ese contrato es correcto entre funciones, y se vuelve una **primitiva de escritura entre tenants** en el momento en que la función queda expuesta en la API de datos: cualquier usuario autenticado puede invocarla con la cuenta de otro tenant y escribir en sus libros, saltándose todos los guards de la RPC pública equivalente. La superficie de la API de datos expone toda función ejecutable por el rol de sesión, sin importar su nombre ni la intención con que se escribió.

La reafirmación de permisos que acompaña a cada redefinición de función SHALL enumerar explícitamente los roles de aplicación al revocar (no solo el pseudo-rol público), porque el proyecto hospedado otorga el permiso de ejecución a esos roles de forma directa: una revocación limitada al pseudo-rol público puede dejar la función abierta en producción aunque el entorno local se vea limpio. Por el mismo motivo, la verificación del estado real de permisos SHALL hacerse contra **producción**, y no únicamente contra el entorno de integración continua.

#### Scenario: Un helper interno no es invocable desde la API de datos

- **GIVEN** una función con privilegio de definidor cuyo nombre sigue la convención de helper interno
- **WHEN** un usuario autenticado intenta invocarla directamente por la API de datos
- **THEN** la invocación es rechazada por falta de permiso de ejecución

#### Scenario: Escribir en los libros de otro tenant es imposible por el atajo del helper

- **GIVEN** un usuario del tenant A que conoce el identificador de cuenta del tenant B
- **WHEN** intenta invocar directamente un helper interno informando la cuenta de B
- **THEN** la invocación es rechazada y los libros de B quedan sin cambios

#### Scenario: La revocación enumera los roles de aplicación

- **WHEN** una migración redefine un helper interno y reafirma sus permisos
- **THEN** la revocación nombra explícitamente `anon` y `authenticated` además del pseudo-rol público, y no va seguida de una concesión a `authenticated`

### Requirement: Un gate permanente impide que un helper interno vuelva a quedar expuesto

El sistema SHALL verificar en cada corrida de integración continua que ninguna función `SECURITY DEFINER` de nombre interno quedó ejecutable por el rol `authenticated`, y SHALL fallar el pipeline cuando aparezca una fuera de la allowlist. El gate SHALL correr contra la base resultante de aplicar **todas** las migraciones, no contra el texto de los archivos.

El gate existente cubre hoy dos invariantes —funciones de disparador con privilegio de definidor expuestas a cualquier rol de aplicación, y funciones con privilegio de definidor expuestas a `anon`— y deja fuera el caso de una función común expuesta a `authenticated`. Ese punto ciego SHALL cerrarse extendiendo el mismo gate, no creando uno paralelo.

La regla de mantenimiento de la allowlist SHALL ser la misma que ya rige el gate: **achicarla** siempre es válido, porque una entrada sobrante no falla; **agregar** una entrada SHALL exigir justificación escrita en el pull request que explique por qué ese helper necesita ser invocable desde el rol de aplicación. Las entradas preexistentes al gate SHALL incorporarse a la allowlist con su justificación, de modo que el gate nazca en verde y cumpla su función desde ese momento en adelante, en lugar de bloquear el pipeline con deuda histórica.

#### Scenario: Una redefinición que concede ejecución a authenticated falla el pipeline

- **GIVEN** un helper interno que hasta ahora estaba revocado
- **WHEN** una migración lo redefine reafirmando permisos con el patrón de concesión a `authenticated`
- **THEN** el gate falla e identifica la función por nombre y firma

#### Scenario: El gate nace en verde

- **WHEN** el gate se agrega al pipeline sobre el estado actual del esquema
- **THEN** pasa, porque los helpers ya expuestos están enumerados en la allowlist con su justificación

#### Scenario: Revocar un helper de la allowlist no rompe el gate

- **WHEN** un cambio posterior revoca un helper que figuraba en la allowlist
- **THEN** el gate sigue pasando y la entrada sobrante puede eliminarse sin urgencia

#### Scenario: El gate no interfiere con la API pública

- **WHEN** se agrega un comando nuevo de la API con privilegio de definidor y concesión a `authenticated`
- **THEN** el gate no lo reporta, porque su nombre no sigue la convención de helper interno

### Requirement: Las funciones que recorren el outbox completo integran una lista curada y no son alcanzables desde los roles de aplicación

El sistema SHALL mantener enumerada, en una lista curada verificada por integración continua, toda función con privilegio de definidor que **lea o actualice** la tabla de eventos del outbox, y SHALL fallar el pipeline cuando aparezca una que no esté en la lista.

El gate vigente ya cubre los helpers internos por convención de nombre, y **excluye deliberadamente** a los comandos públicos de la API, porque enumerarlos a todos produciría una allowlist inmantenible. Esa exclusión dejó un punto ciego preciso: una función que **sí** es un comando público por su nombre, pero cuyo cuerpo recorre el outbox de todos los inquilinos, no cae en ningún radar. Es exactamente donde vivía la fuga: dos comandos del relay, ejecutables por el rol autenticado, que devolvían y cerraban eventos de cualquier cuenta.

El criterio de la lista SHALL ser leer o actualizar la tabla de eventos, y SHALL NOT ser insertar en ella: producir un evento propio es lo que hacen todos los productores legítimos del sistema y no permite leer ni cerrar los eventos de nadie más. Ese recorte es lo que mantiene la lista corta y por lo tanto legible — una lista que nadie lee es un gate apagado.

Cada entrada de la lista SHALL declarar si la función puede ser ejecutable por los roles de aplicación y, en caso afirmativo, por qué. Una función que recorre el outbox por diseño de relay SHALL NOT ser ejecutable por ningún rol de aplicación. Una función que actualiza un evento propio como parte de una operación de negocio ya verificada por cuenta SHALL poder serlo, con su justificación escrita.

La regla de mantenimiento SHALL ser la misma que rige la lista cerrada de helpers de dinero: la lista **sólo crece**, y agregar una entrada SHALL exigir justificación escrita en el pull request.

El gate SHALL correr contra la base resultante de aplicar **todas** las migraciones, no contra el texto de los archivos, y la verificación del estado real de permisos SHALL hacerse además contra **producción**, porque el entorno hospedado concede la ejecución a los roles de aplicación de forma directa y no a través del pseudo-rol público.

#### Scenario: Una función nueva que recorre el outbox y no está en la lista falla el pipeline

- **GIVEN** una migración que agrega una función con privilegio de definidor cuyo cuerpo consulta la tabla de eventos
- **WHEN** corre el gate de integración continua
- **THEN** el gate falla e identifica la función por nombre y firma, indicando que debe declararse en la lista con su veredicto

#### Scenario: Reexponer una función del relay falla el pipeline

- **GIVEN** una función del relay declarada en la lista como no expuesta
- **WHEN** una migración posterior le concede ejecución al rol autenticado
- **THEN** el gate falla e identifica esa función

#### Scenario: Un productor de eventos no es reportado

- **GIVEN** un comando de negocio con privilegio de definidor que sólo inserta un evento propio en el outbox
- **WHEN** corre el gate
- **THEN** no lo reporta, porque insertar no permite leer ni cerrar eventos ajenos

#### Scenario: El gate nace en verde

- **WHEN** el gate se agrega al pipeline sobre el estado actual del esquema
- **THEN** pasa, porque todas las funciones que hoy recorren el outbox están declaradas con su veredicto y las que quedan expuestas tienen su justificación escrita

#### Scenario: El gate se verifica también contra producción

- **WHEN** se audita el estado real de permisos después de desplegar
- **THEN** la verificación se hace contra la base de producción y no únicamente contra la de integración continua, porque las concesiones directas a los roles de aplicación pueden diferir entre ambas

### Requirement: `anon` no tiene privilegios de escritura a nivel tabla sobre las tablas de negocio

El sistema SHALL revocar de `anon`, a nivel de TABLA, los privilegios de INSERT, UPDATE, DELETE y TRUNCATE sobre toda tabla base de los schemas `public` y `community` —ambos servidos por la misma API de datos (PostgREST)—, salvo entrada explícita y justificada en una allowlist calificada por schema. El privilegio de SELECT no está alcanzado por este requirement.

El proyecto hospedado otorga por defecto, a nivel de tabla, los cuatro privilegios de escritura a `anon` sobre toda tabla nueva de `public` y de `community` — la RLS es hoy la única pared contra una escritura de ese rol. Esa pared depende de que cada tabla tenga, para siempre, una policy de escritura correcta: una tabla que naciera sin ninguna, o con una policy que evaluara a verdadero sin ninguna sesión, quedaría escribible sin autenticación por la API de datos, sin que ningún otro mecanismo lo evitara. El privilegio a nivel de tabla es una segunda pared, independiente de que la RLS esté bien escrita, y SHALL revocarse aunque hoy ninguna policy tenga ese defecto.

Una entrada de la allowlist SHALL requerir, además de su propia policy de escritura satisfacible sin sesión, un llamador real que escriba ahí como `anon` — ninguna de las dos condiciones sola basta. La ausencia de la primera hace innecesaria la segunda: sin una policy satisfacible sin sesión, conservar el privilegio de tabla no habilita ningún camino que la RLS no bloquee ya.

La revocación SHALL extenderse a las tablas que el rol propietario de las migraciones cree después de este requirement, en `public` y en `community`, mediante el privilegio por defecto de ese rol sobre cada schema — sin esto, una tabla nueva reabre el hueco que el barrido sobre las tablas existentes cerró. Este alcance está acotado al rol propietario de las migraciones: una tabla creada en cualquiera de los dos schemas por un rol distinto (por ejemplo, uno con privilegios administrativos sobre el proyecto hospedado que no sea el rol propietario) queda fuera de esta garantía salvo que ese otro rol también tenga su propio privilegio por defecto endurecido explícitamente.

#### Scenario: `anon` no puede escribir en una tabla de negocio por más que la RLS falle

- **GIVEN** una tabla de negocio de `public` o de `community`, fuera de la allowlist, con o sin policy de escritura
- **WHEN** `anon` intenta un INSERT, UPDATE, DELETE o TRUNCATE directo contra esa tabla
- **THEN** la operación es rechazada por falta de privilegio a nivel de tabla, sin llegar a evaluarse ninguna policy de RLS

#### Scenario: El rechazo se identifica como de capa de tabla, no de RLS

- **GIVEN** el mismo intento de escritura de `anon`
- **WHEN** se inspecciona el mensaje del rechazo
- **THEN** el mensaje corresponde a la ausencia del privilegio de tabla y no al texto que produce una policy de RLS al rechazar una fila, aunque ambos casos compartan el mismo código de error

#### Scenario: Una tabla nueva nace sin el privilegio

- **GIVEN** una migración posterior que crea una tabla nueva en `public` o en `community`
- **WHEN** la tabla se crea con el rol propietario de las migraciones
- **THEN** la tabla nace sin INSERT/UPDATE/DELETE/TRUNCATE para `anon`, sin que la migración tenga que revocarlo explícitamente

#### Scenario: Una entrada de la allowlist exige policy Y llamador real

- **WHEN** se evalúa si una tabla de `public` o de `community` debe entrar a la allowlist
- **THEN** entra sólo si tiene una policy de escritura satisfacible sin sesión Y un llamador real que escriba ahí como `anon`; la ausencia de cualquiera de las dos condiciones revoca el privilegio

#### Scenario: El privilegio de lectura no se ve afectado

- **GIVEN** una tabla a la que se le revocó el privilegio de escritura por este requirement
- **WHEN** `anon` intenta un SELECT permitido por su propia policy de lectura
- **THEN** la lectura no se ve afectada por esta revocación

### Requirement: La membresía de cuentas sólo se consulta para el propio usuario

El sistema SHALL restringir `get_account_ids_for_user(p_user_id uuid)` — el helper `SECURITY DEFINER` que bypassea la RLS de `account_members` para que sus propias policies no recursen — a devolver membresía únicamente cuando `p_user_id` corresponde a la sesión que lo invoca (`p_user_id IS NOT DISTINCT FROM auth.uid()`) o a un contexto `service_role`; para cualquier otro `p_user_id` SHALL devolver cero filas, nunca un error.

El helper es invocable como RPC de PostgREST (ejecutable por `anon` y `authenticated`, condición que este requirement no cambia — ver el requirement "`anon` no tiene privilegios de escritura a nivel tabla…" de más arriba, que no alcanza a funciones) porque su único caller real, la policy `account_members_same_account_select`, lo invoca siempre con el propio `auth.uid()`. Sin este requirement, al ser `SECURITY DEFINER`, cualquier sesión autenticada (o `anon`) puede pedir la membresía de un `p_user_id` ajeno y obtenerla, bypasseando la RLS de `account_members` para enumerar las cuentas de un tercero con sólo conocer su `user_id`.

La respuesta SHALL ser silenciosa (cero filas) y no un error: el único caller real es una policy de `SELECT`, que no puede fallar sin romper toda lectura de `account_members` para el rol consultante.

#### Scenario: Un usuario no puede resolver la membresía de otro

- **GIVEN** dos usuarios A y B, cada uno miembro de una cuenta distinta
- **WHEN** A invoca `get_account_ids_for_user(B)` (por ejemplo vía `.rpc('get_account_ids_for_user', {p_user_id: B})`)
- **THEN** la función devuelve cero filas, nunca la cuenta de B

#### Scenario: Un usuario sí resuelve su propia membresía

- **GIVEN** un usuario A miembro de una cuenta
- **WHEN** A invoca `get_account_ids_for_user(A)`
- **THEN** la función devuelve la cuenta de A, igual que antes de este requirement

#### Scenario: Sin sesión, la función no filtra membresía ajena

- **GIVEN** una conexión sin `auth.uid()` resuelto (sin claims de sesión, y sin ser `service_role`)
- **WHEN** se invoca `get_account_ids_for_user(p_user_id)` con cualquier `p_user_id`
- **THEN** la función devuelve cero filas

#### Scenario: `service_role` conserva el comportamiento sin filtrar

- **GIVEN** un contexto `service_role` (jobs administrativos)
- **WHEN** se invoca `get_account_ids_for_user(p_user_id)` con el `user_id` de un tercero
- **THEN** la función devuelve la membresía de ese `user_id`, igual que antes de este requirement

#### Scenario: La policy de `account_members` sigue funcionando sin cambios

- **GIVEN** la policy `account_members_same_account_select`, que invoca el helper siempre con el propio `auth.uid()` del rol consultante
- **WHEN** un usuario autenticado hace `SELECT * FROM account_members`
- **THEN** ve exactamente las filas de sus propias cuentas, ni una fila menos ni una fila de otro usuario
