## ADDED Requirements

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
