## ADDED Requirements

### Requirement: call_rpc soporta parámetros posicionales para RPCs con arrays
El sistema SHALL soportar llamadas a RPCs que reciben parámetros de tipo array (`jsonb[]`, `uuid[]`) pasándolos como parámetros posicionales en el query string de asyncpg, no como named parameters. Esto aplica especialmente a `rpc_create_operation_aggregate` que recibe `p_items` como array JSONB.

#### Scenario: call_rpc con lista de items JSONB
- **WHEN** se llama `await repo.call_rpc("rpc_create_operation_aggregate", p_user_id=uid, p_org_id=org_id, p_items=json.dumps(items_list))`
- **THEN** el query resultante usa `$1`, `$2`, `$3` como placeholders posicionales y asyncpg serializa correctamente el array JSONB

#### Scenario: call_rpc sin parámetros llama la RPC sin argumentos
- **WHEN** se llama `await repo.call_rpc("rpc_get_system_stats")`
- **THEN** ejecuta `SELECT * FROM rpc_get_system_stats()` sin ningún placeholder
