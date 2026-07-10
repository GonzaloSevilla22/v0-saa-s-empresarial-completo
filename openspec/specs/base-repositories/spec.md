# base-repositories

## Purpose

Patrón base de acceso a datos para el backend FastAPI. Define `BaseRepository` como clase base tipada que recibe una conexión asyncpg ya configurada con JWT-passthrough y expone métodos (`fetch`, `fetchrow`, `execute`, `call_rpc`) para interactuar con PostgreSQL. Los repositorios concretos por dominio (introducidos en C-16) extienden esta clase; ninguno accede al pool directamente.

## Requirements

### Requirement: BaseRepository como clase base de acceso a datos
El sistema SHALL proveer una clase `BaseRepository` en `backend/repositories/base.py` que recibe una conexión asyncpg ya configurada con JWT-passthrough y expone métodos tipados para ejecutar queries y RPCs contra PostgreSQL. Ningún repositorio concreto SHALL acceder al pool directamente — siempre reciben una conexión ya inyectada via `get_db_conn`.

#### Scenario: BaseRepository.call_rpc ejecuta una RPC existente
- **WHEN** se llama `await repo.call_rpc("rpc_create_operation_aggregate", p_user_id=uid, p_items=[...])`
- **THEN** ejecuta `SELECT * FROM rpc_create_operation_aggregate(...)` usando la conexión asyncpg y retorna el resultado como `Record`

#### Scenario: BaseRepository.fetch retorna lista de filas
- **WHEN** se llama `await repo.fetch("SELECT id, name FROM products WHERE org_id = $1", org_id)`
- **THEN** retorna una `list[asyncpg.Record]` con todas las filas que matchean (lista vacía si no hay resultados)

#### Scenario: BaseRepository.fetchrow retorna None si no hay resultado
- **WHEN** se llama `await repo.fetchrow("SELECT * FROM products WHERE id = $1", uuid_inexistente)`
- **THEN** retorna `None` sin lanzar excepción

#### Scenario: BaseRepository.execute retorna status string
- **WHEN** se llama `await repo.execute("UPDATE products SET stock = $1 WHERE id = $2", 0, product_id)`
- **THEN** retorna el status string de PostgreSQL (e.g. `"UPDATE 1"`) sin lanzar excepción si la query fue válida

#### Scenario: Error de DB se propaga con contexto legible
- **WHEN** `call_rpc` recibe un nombre de RPC inexistente o parámetros inválidos
- **THEN** asyncpg lanza `asyncpg.PostgresError` que se propaga al caller sin ser swallowed; el router lo convierte en HTTP 500

### Requirement: Repositorios concretos extienden BaseRepository
El sistema SHALL definir el patrón que los repositorios concretos (introducidos en C-16) seguirán: una clase por dominio (e.g. `SalesRepository`, `ProductsRepository`) que extiende `BaseRepository`, sin constructor propio, instanciada en el endpoint vía dependency injection.

#### Scenario: Repositorio concreto se instancia con la conexión del request
- **WHEN** un endpoint recibe `conn: asyncpg.Connection = Depends(get_db_conn)`
- **THEN** puede instanciar `repo = SalesRepository(conn)` y llamar métodos de `BaseRepository` sin configuración adicional

#### Scenario: Dos repositorios en el mismo request comparten la misma conexión
- **WHEN** un endpoint instancia `SalesRepository(conn)` y `ProductsRepository(conn)` con la misma `conn`
- **THEN** ambos operan sobre la misma conexión (y por tanto dentro del mismo contexto de JWT-passthrough y transacción si se usa una)

### Requirement: call_rpc soporta parámetros posicionales para RPCs con arrays
El sistema SHALL soportar llamadas a RPCs que reciben parámetros de tipo array (`jsonb[]`, `uuid[]`) pasándolos como parámetros posicionales en el query string de asyncpg, no como named parameters. Esto aplica especialmente a `rpc_create_operation_aggregate` que recibe `p_items` como array JSONB.

#### Scenario: call_rpc con lista de items JSONB
- **WHEN** se llama `await repo.call_rpc("rpc_create_operation_aggregate", p_user_id=uid, p_org_id=org_id, p_items=json.dumps(items_list))`
- **THEN** el query resultante usa `$1`, `$2`, `$3` como placeholders posicionales y asyncpg serializa correctamente el array JSONB

#### Scenario: call_rpc sin parámetros llama la RPC sin argumentos
- **WHEN** se llama `await repo.call_rpc("rpc_get_system_stats")`
- **THEN** ejecuta `SELECT * FROM rpc_get_system_stats()` sin ningún placeholder

### Requirement: BaseRepository provee soft delete centralizado
El sistema SHALL exponer en `BaseRepository` un método `soft_delete(table, row_id, account_id, deleted_by)` que ejecuta un `UPDATE <table> SET deleted_at = now(), deleted_by = $deleted_by WHERE id = $row_id AND account_id = $account_id AND deleted_at IS NULL` y retorna si la fila fue afectada. Los repositorios de maestros SHALL usar este método en lugar de emitir `DELETE` físico o de repetir la lógica de soft delete por dominio. El método SHALL respetar la invariante de JWT-passthrough: usa la conexión ya configurada, sin re-inyectar claims.

#### Scenario: soft_delete marca la fila sin eliminarla
- **WHEN** se llama `await repo.soft_delete("clients", client_id, account_id, user_id)` sobre una fila activa
- **THEN** la fila queda con `deleted_at` seteado y `deleted_by = user_id`, y el método reporta que una fila fue afectada

#### Scenario: soft_delete sobre una fila ya borrada es no-op
- **WHEN** se llama `soft_delete` sobre una fila cuyo `deleted_at` ya no es nulo
- **THEN** ninguna fila es afectada (la cláusula `deleted_at IS NULL` la excluye) y el método lo reporta como no afectada

#### Scenario: soft_delete respeta el aislamiento por cuenta
- **WHEN** se llama `soft_delete` con un `account_id` que no es dueño de la fila
- **THEN** ninguna fila es afectada

### Requirement: Lecturas de maestros excluyen filas soft-deleteadas por defecto
El sistema SHALL proveer en `BaseRepository` un mecanismo único para excluir filas con `deleted_at IS NOT NULL` de las lecturas de maestros (RN-B1), de modo que los repositorios concretos de maestros no repitan el predicado `deleted_at IS NULL` en cada query. El mecanismo SHALL permitir, de forma explícita, incluir filas borradas cuando un caso de uso lo requiera (por ejemplo un reporte de auditoría), sin que ese sea el comportamiento por defecto.

#### Scenario: El listado de un maestro no incluye filas borradas
- **WHEN** un repositorio de maestro lista sus filas usando el mecanismo del `BaseRepository`
- **THEN** las filas con `deleted_at IS NOT NULL` quedan excluidas sin que el repositorio concreto tenga que escribir el filtro

#### Scenario: Un caso de uso puede pedir explícitamente las filas borradas
- **WHEN** un repositorio solicita explícitamente incluir filas borradas
- **THEN** el resultado incluye también las filas con `deleted_at IS NOT NULL`

### Requirement: BaseRepository provee paginación estándar centralizada

El sistema SHALL exponer en `BaseRepository` un helper de paginación que, dado un `SELECT` base, un `COUNT(*)` equivalente para el mismo filtro, y los parámetros `page` (0-based) y `size`, calcule el `offset` (`page * size`), ejecute ambas queries sobre la conexión ya inyectada (JWT-passthrough, sin re-inyectar claims) y retorne el envelope estándar `{items, total, page, pages}` donde `pages = ceil(total / size)`. Los repositorios concretos de listados SHALL usar este helper en lugar de repetir el cálculo de `offset`/`pages` y de armar el envelope a mano. El helper SHALL ser compatible con el filtro de soft delete (`not_deleted_clause`) ya existente en `BaseRepository`.

#### Scenario: El helper arma el envelope de una página
- **WHEN** un repositorio pide la página `page=1`, `size=25` de un listado con 60 filas que matchean el filtro
- **THEN** el helper ejecuta el SELECT con `OFFSET 25 LIMIT 25`, el COUNT sobre el mismo filtro, y retorna `{items: [...25 filas...], total: 60, page: 1, pages: 3}`

#### Scenario: total 0 produce pages 0 sin dividir por cero
- **WHEN** el filtro no matchea ninguna fila
- **THEN** el helper retorna `{items: [], total: 0, page: <page pedida>, pages: 0}` sin lanzar excepción

#### Scenario: El helper respeta el aislamiento y el JWT-passthrough
- **WHEN** el helper ejecuta el SELECT y el COUNT paginados
- **THEN** ambas queries corren sobre la misma conexión ya configurada del request (la RLS org-based sigue activa; el helper no abre conexiones nuevas ni re-inyecta claims)
