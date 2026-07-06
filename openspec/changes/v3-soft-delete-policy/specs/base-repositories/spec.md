## ADDED Requirements

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
