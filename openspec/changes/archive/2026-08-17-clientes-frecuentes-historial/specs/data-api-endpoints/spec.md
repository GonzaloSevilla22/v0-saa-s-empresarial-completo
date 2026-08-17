## ADDED Requirements

### Requirement: Endpoints REST de actividad e historial de clientes
El router `clients` SHALL exponer dos endpoints de lectura adicionales: `GET /clients/activity`, que devuelve el listado paginado de clientes con sus agregados de actividad, y `GET /clients/{client_id}/purchases`, que devuelve el historial de compras paginado de un cliente.

Ambos endpoints SHALL responder con el envelope estándar `PageOut[T]` (`{items, total, page, pages}`, `page` en base 0), SHALL validar sus parámetros con Pydantic v2, SHALL aplicar el aislamiento por organización del usuario autenticado y SHALL excluir los clientes borrados de forma lógica conforme a `soft-delete-policy`. Sus errores SHALL emitirse en formato RFC 7807.

`GET /clients/activity` SHALL aceptar los parámetros opcionales `search` (coincidencia parcial sobre nombre o email), `activity_status` (filtro por estado de actividad), `sort` (uno de `name`, `last_purchase`, `total_spent`, `purchase_count`), `sort_dir` (`asc` o `desc`), `page` y `size`.

#### Scenario: Listado de actividad paginado
- **WHEN** se solicita `GET /clients/activity` con `page=0` y `size=25` en una organización con 60 clientes
- **THEN** la respuesta contiene 25 elementos, `total` 60, `page` 0 y `pages` 3

#### Scenario: Filtro por estado de actividad
- **WHEN** se solicita `GET /clients/activity` con `activity_status=inactivo`
- **THEN** todos los elementos devueltos tienen estado `inactivo` y `total` refleja únicamente ese subconjunto

#### Scenario: Búsqueda por nombre o email
- **WHEN** se solicita `GET /clients/activity` con un valor de `search`
- **THEN** se devuelven los clientes cuyo nombre o email contienen ese valor, sin distinción de mayúsculas

#### Scenario: Parámetro de orden inválido
- **WHEN** se solicita `GET /clients/activity` con un valor de `sort` fuera del conjunto admitido
- **THEN** el sistema responde con un error de validación RFC 7807 y no ejecuta la consulta

#### Scenario: Historial de compras paginado
- **WHEN** se solicita `GET /clients/{client_id}/purchases` para un cliente de la organización
- **THEN** la respuesta usa el envelope estándar con una operación de venta por elemento

#### Scenario: Aislamiento por organización
- **WHEN** se solicita cualquiera de los dos endpoints con credenciales de otra organización
- **THEN** no se devuelve ningún dato de la organización ajena

#### Scenario: Cliente borrado lógicamente
- **WHEN** un cliente tiene `deleted_at` no nulo
- **THEN** no aparece en `GET /clients/activity`

### Requirement: Compatibilidad del listado plano de clientes
El endpoint existente `GET /clients` SHALL conservar su contrato actual, devolviendo la lista plana de clientes de la organización sin envelope de paginación y sin agregados de actividad.

Los endpoints de actividad e historial SHALL agregarse como recursos independientes y NO SHALL alterar la forma de respuesta de `GET /clients`, del que dependen las pantallas que lo usan como origen de datos de selectores.

#### Scenario: Consumidores de selectores no se ven afectados
- **WHEN** una pantalla solicita `GET /clients` para poblar un selector de clientes
- **THEN** recibe la lista plana de clientes con el mismo esquema que antes del cambio
