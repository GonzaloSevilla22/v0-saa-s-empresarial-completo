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
