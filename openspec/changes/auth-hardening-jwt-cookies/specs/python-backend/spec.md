## MODIFIED Requirements

### Requirement: Estructura de proyecto

El backend SHALL organizarse en: `backend/main.py` (punto de entrada FastAPI), `backend/routers/` (handlers HTTP), `backend/core/` (config, auth, guards, database, errors) y `backend/tests/` (suite pytest).

El backend NOT SHALL contener un módulo gestor de conexiones WebSocket ni un router de WebSocket: ese canal se retiró (ver la capability `realtime-websocket`).

#### Scenario: El árbol de directorios refleja las 3 capas más config y tests

- **WHEN** se inspecciona el repo bajo `backend/`
- **THEN** existen `backend/main.py`, `backend/routers/` (con un módulo por dominio, p. ej. `expenses.py`, `sales.py`), `backend/core/` (con `config.py`, `auth.py`, `guards.py`, `database.py`, `errors.py`) y `backend/tests/` (una suite pytest, p. ej. `test_auth.py`, `test_expenses.py`); además `backend/services/` y `backend/repositories/` completan la arquitectura de 3 capas (routers → services → repositories) que exige `data-api-endpoints`

#### Scenario: No existe módulo de gestión de conexiones WebSocket

- **WHEN** se inspecciona `backend/core/` y `backend/routers/`
- **THEN** no existe ningún módulo gestor de conexiones WebSocket ni ningún router de WebSocket

### Requirement: Routers de datos registrados en main.py
El sistema SHALL registrar los 8 routers de dominio (expenses, clients, products, branches, stock, sales, purchases, payments) en `backend/main.py` con sus prefijos correspondientes y el tag OpenAPI apropiado.

Routers registrados:
- `health.router`
- `expenses.router` (prefix `/expenses`)
- `clients.router` (prefix `/clients`)
- `products.router` (prefix `/products`)
- `branches.router` (prefix `/branches`)
- `stock.router` (prefix `/stock`)
- `sales.router` (prefix `/sales`)
- `purchases.router` (prefix `/purchases`)
- `payments.router` (prefix `/payments`) ← C-17

> El router `organizations` fue retirado en `remove-organizations-dead-code`: apuntaba a una tabla `organizations` inexistente en producción y sus dos endpoints devolvían HTTP 500 desde C-16.

> El router `ws` fue retirado en `auth-hardening-jwt-cookies`: autenticaba el handshake pero no autorizaba la sala, recibía el token por parámetro de consulta y no tenía ningún consumidor (ver la capability `realtime-websocket`).

#### Scenario: Todos los routers de datos responden tras startup
- **WHEN** la app arranca correctamente con pool inicializado (Redis es opcional)
- **THEN** `GET /docs` lista todos los endpoints de expenses, clients, products, branches, stock, sales, purchases y payments en la UI de Swagger

#### Scenario: No hay router de organizations registrado
- **WHEN** la app arranca y se inspecciona `GET /openapi.json`
- **THEN** no existe ninguna ruta bajo el prefijo `/organizations` ni el tag OpenAPI `organizations`

#### Scenario: No hay router de WebSocket registrado
- **WHEN** la app arranca y se inspecciona el registro de routers y `GET /openapi.json`
- **THEN** no existe ninguna ruta WebSocket ni ningún router de WebSocket incluido en la app

### Requirement: CORS configurado para el dominio Vercel
El sistema SHALL restringir CORS a una **allow-list de orígenes conocidos**, expresada por patrón para admitir el dominio de producción (con y sin `www`) y los despliegues de vista previa del proyecto, más el origen de desarrollo local cuando el entorno no es producción.

El sistema NOT SHALL reflejar un origen arbitrario, y NOT SHALL declarar que admite credenciales: ninguna credencial del usuario final viaja por cookie hacia el backend —toda autenticación es por encabezado de autorización— y declarar credenciales es lo que convierte una allow-list comodín en una reflexión de cualquier origen.

El valor comodín `"*"` SHALL estar prohibido cuando el entorno es producción, y el arranque SHALL fallar si se configura. Los cuerpos de error que se emiten fuera del middleware de CORS SHALL aplicar exactamente el mismo criterio de origen permitido que el middleware.

#### Scenario: Request desde el dominio de producción pasa CORS
- **WHEN** el frontend de producción hace un request a FastAPI con el header `Origin` de su dominio (con o sin `www`)
- **THEN** FastAPI incluye ese origen en `Access-Control-Allow-Origin` y el browser no bloquea la llamada

#### Scenario: Request desde un despliegue de vista previa pasa CORS
- **WHEN** un despliegue de vista previa del proyecto hace un request con su `Origin` de host variable
- **THEN** el patrón de la allow-list lo reconoce y la llamada no se bloquea

#### Scenario: Un origen ajeno no recibe autorización
- **WHEN** llega un preflight con un `Origin` que no pertenece a la allow-list
- **THEN** la respuesta no incluye `Access-Control-Allow-Origin` para ese origen ni declara que admite credenciales

#### Scenario: Los cuerpos de error no reflejan un origen ajeno
- **WHEN** un endpoint responde un error con formato de problema a una petición cuyo `Origin` no pertenece a la allow-list
- **THEN** ese cuerpo de error tampoco incluye encabezados de CORS para ese origen

#### Scenario: Request OPTIONS preflight retorna 200 con headers CORS
- **WHEN** el browser envía un preflight `OPTIONS /expenses` desde un origen permitido
- **THEN** FastAPI retorna HTTP 200 con los headers `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` correctos

#### Scenario: El comodín está prohibido en producción
- **GIVEN** el entorno declarado como producción y el origen permitido configurado como comodín
- **WHEN** se inicia la aplicación
- **THEN** el arranque falla con un error de configuración, en lugar de admitir cualquier origen
