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
