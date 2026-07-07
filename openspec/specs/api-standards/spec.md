# api-standards

> Synced from change `v3-api-standards` — 2026-07-07

## Purpose

Contrato transversal de la API HTTP del backend FastAPI: formato de error uniforme RFC 7807 (`application/problem+json` con las extensiones `code` y `field`), paginación estándar (`?page&size` → envelope `{items, total, page, pages}`) y la convención del header `Idempotency-Key` para mutaciones no-idempotentes por naturaleza (crear venta, cobrar, emitir comprobante, cerrar caja). Es la capability que define las reglas de plataforma que el resto de los módulos del backend siguen. Se construye sobre mecanismos ya existentes (mapeo `sqlstate → HTTP status` de `backend/core/errors.py`, tabla `operation_idempotency` de DEC-06) sin cambiar comportamiento de negocio.

## Requirements

### Requirement: Errores uniformes en formato RFC 7807

El backend SHALL devolver todos los errores HTTP (4xx y 5xx) como un cuerpo `application/problem+json` conforme a RFC 7807, con los campos `type`, `title`, `status` y `detail`, más las extensiones `code` (código de negocio: el `P04xx` del RPC o un slug estable) y `field` (nombre del campo que falló, presente solo en errores de validación). El formato SHALL construirse sobre el mapeo `sqlstate → HTTP status` ya existente en `backend/core/errors.py` sin alterar los status resultantes. El `detail` de un error de negocio (RPC con `RAISE ... USING ERRCODE`) SHALL preservar el mensaje que escribe la función SQL; el `detail` de un 500 inesperado SHALL ser un mensaje genérico sin filtrar internals.

#### Scenario: Error de negocio de un RPC se serializa como problem+json
- **WHEN** un RPC lanza `RAISE ... USING ERRCODE = 'P0409'` (conflicto)
- **THEN** la respuesta tiene `status 409`, media type `application/problem+json`, y un body con `status: 409`, `code: "P0409"`, `title` legible y `detail` con el mensaje del RPC

#### Scenario: Error de validación de Pydantic incluye field
- **WHEN** un POST llega con un campo requerido faltante o inválido y Pydantic lanza `RequestValidationError`
- **THEN** la respuesta tiene `status 422`, media type `application/problem+json`, y por cada violación un `detail` con la extensión `field` apuntando al campo ofensor (no el shape default `{"detail":[{loc,msg,type}]}` de FastAPI)

#### Scenario: Error interno no filtra detalles internos
- **WHEN** un handler lanza una excepción no controlada
- **THEN** la respuesta tiene `status 500`, formato problem+json, `detail` genérico (sin stack trace ni SQL) y `code` estable de servidor

#### Scenario: Los headers CORS se preservan en respuestas de error
- **WHEN** una respuesta de error problem+json se emite para un origin permitido
- **THEN** los headers `access-control-allow-origin` y `access-control-allow-credentials` siguen presentes (el envelope 7807 no rompe el manejo de CORS de error existente)

### Requirement: Paginación estándar en todos los listados

El backend SHALL exponer todos los endpoints de listado con el contrato de paginación único `?page&size`, donde `page` es 0-based y `size` acotado por un máximo por endpoint, y SHALL responder con el envelope `{items, total, page, pages}` donde `items` es la página de resultados, `total` el total de filas que matchean el filtro, `page` la página devuelta y `pages` el total de páginas (`ceil(total/size)`). Los nombres de parámetro y de campos del envelope SHALL ser uniformes en todos los módulos; los shapes previos divergentes (`total_operations`, `total` suelto, listas planas de `limit/offset`) SHALL ser reemplazados.

#### Scenario: Un listado devuelve el envelope estándar
- **WHEN** se llama `GET /sales?page=0&size=25`
- **THEN** la respuesta es `{items: [...], total: N, page: 0, pages: ceil(N/25)}` con a lo sumo 25 elementos en `items`

#### Scenario: Página fuera de rango devuelve items vacío, no error
- **WHEN** se pide una `page` mayor que `pages`
- **THEN** la respuesta es `200` con `items: []`, el `total` correcto y `page`/`pages` consistentes (no un 404 ni un error)

#### Scenario: size respeta su cota máxima por endpoint
- **WHEN** se pide `size` mayor al máximo permitido del endpoint
- **THEN** la request es rechazada con `422` problem+json (validación de query param), sin ejecutar la query

### Requirement: Idempotencia por header Idempotency-Key en mutaciones no-idempotentes

El backend SHALL aceptar la clave de idempotencia por el header HTTP `Idempotency-Key` en toda mutación no-idempotente por naturaleza (crear venta, registrar cobro/pago, emitir comprobante fiscal, cerrar caja). La clave SHALL registrarse en la tabla `operation_idempotency` dentro de la misma transacción que la operación (atomicidad ya garantizada por el diseño existente, DEC-06); un reintento con la misma `(user_id, operation_kind, idempotency_key)` SHALL devolver el resultado de la operación previa sin re-ejecutar el efecto. Durante una ventana de compatibilidad, el backend MAY seguir aceptando `idempotency_key` en el body como fallback deprecado; el header SHALL tener precedencia si ambos están presentes.

#### Scenario: Reintento con la misma clave no duplica la operación
- **WHEN** se envía dos veces `POST /sales` con el mismo header `Idempotency-Key`
- **THEN** la segunda respuesta devuelve el mismo `operation_id` que la primera y no se crea una segunda venta

#### Scenario: El header tiene precedencia sobre el body
- **WHEN** una mutación llega con `Idempotency-Key` en el header y un `idempotency_key` distinto en el body
- **THEN** la operación usa la clave del header y el valor del body se ignora

#### Scenario: Cerrar caja es idempotente
- **WHEN** se llama dos veces `POST /cash/sessions/{id}/close` con el mismo `Idempotency-Key`
- **THEN** la sesión se cierra una sola vez y el segundo llamado devuelve el resultado del primero (requiere el `operation_kind` `cash_session_close` en el CHECK de `operation_idempotency`)

#### Scenario: Mutación sin clave de idempotencia es rechazada
- **WHEN** una mutación no-idempotente llega sin `Idempotency-Key` en el header ni `idempotency_key` en el body
- **THEN** la request es rechazada con `422` problem+json indicando que la clave de idempotencia es requerida
