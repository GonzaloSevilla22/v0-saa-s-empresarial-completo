# python-backend — Spec

## Purpose

Servicio FastAPI independiente del frontend Next.js. Corre como proceso separado, expone una API HTTP + WebSocket, y se integra con Supabase como fuente de verdad de la base de datos.

## Requirements

### Requirement: Estructura de proyecto

El backend SHALL organizarse en: `backend/main.py` (punto de entrada FastAPI), `backend/routers/` (handlers HTTP y WebSocket), `backend/core/` (config, auth, ws_manager) y `backend/tests/` (suite pytest).

### Requirement: Configuración via entorno

Toda configuración sensible (secrets, URLs) SHALL cargarse desde variables de entorno usando `pydantic-settings`, sin valores hard-codeados en código fuente.

### Requirement: Health check

`GET /health` SHALL retornar `{"status": "ok"}` con HTTP 200, sin autenticación requerida.

### Requirement: Ejecutable con uvicorn

El servicio SHALL poder iniciarse con `uvicorn backend.main:app --reload` desde la raíz del proyecto.

### Requirement: Tests cubren happy path y error path

Cada router SHALL tener al mínimo 1 test de happy path y 1 test de error (auth fallida, input inválido).

### Requirement: Routers de datos registrados en main.py
El sistema SHALL registrar los 9 routers de dominio (expenses, clients, products, branches, stock, sales, purchases, organizations, payments) en `backend/main.py` con sus prefijos correspondientes y el tag OpenAPI apropiado.

Routers registrados:
- `health.router`
- `ws.router`
- `expenses.router` (prefix `/expenses`)
- `clients.router` (prefix `/clients`)
- `products.router` (prefix `/products`)
- `branches.router` (prefix `/branches`)
- `stock.router` (prefix `/stock`)
- `sales.router` (prefix `/sales`)
- `purchases.router` (prefix `/purchases`)
- `organizations.router` (prefix `/organizations`)
- `payments.router` (prefix `/payments`) ← C-17

#### Scenario: Todos los routers de datos responden tras startup
- **WHEN** la app arranca correctamente con pool inicializado (Redis es opcional)
- **THEN** `GET /docs` lista todos los endpoints de expenses, clients, products, branches, stock, sales, purchases, organizations y payments en la UI de Swagger

### Requirement: Service-role pool initialization (C-17)

El módulo `backend/core/database.py` SHALL exponer `get_service_conn()` como dependencia FastAPI que provee una conexión asyncpg usando el pool regular (usuario `postgres` con BYPASSRLS), separado del pool con JWT-passthrough para usuarios autenticados.

#### Scenario: Service pool es inicializado al startup

- **WHEN** la aplicación FastAPI arranca
- **THEN** `init_pool()` inicializa el pool compartido y `get_service_conn()` retorna una conexión válida sin JWT-passthrough

#### Scenario: Solo el router de payments usa get_service_conn

- **WHEN** cualquier router distinto de `payments` es llamado
- **THEN** usa `get_db_conn` (JWT-passthrough pool), no `get_service_conn`

#### Scenario: Exception handler global captura errores asyncpg
- **WHEN** cualquier endpoint lanza `asyncpg.PostgresError` no manejado explícitamente
- **THEN** el exception handler registrado en `main.py` lo convierte en respuesta HTTP con código y mensaje apropiado según `core/errors.py`

### Requirement: CORS configurado para el dominio Vercel
El sistema SHALL configurar CORS en FastAPI para aceptar requests del dominio frontend (`NEXT_PUBLIC_FRONTEND_URL` de entorno, con fallback a `*` en desarrollo). Solo métodos HTTP seguros y con credenciales para los dominios permitidos.

#### Scenario: Request desde Vercel con Origin correcto pasa CORS
- **WHEN** el frontend en `https://empresarial.vercel.app` hace un request a FastAPI con el header `Origin: https://empresarial.vercel.app`
- **THEN** FastAPI incluye `Access-Control-Allow-Origin: https://empresarial.vercel.app` en la respuesta y el browser no bloquea la llamada

#### Scenario: Request OPTIONS preflight retorna 200 con headers CORS
- **WHEN** el browser envía un preflight `OPTIONS /expenses`
- **THEN** FastAPI retorna HTTP 200 con los headers `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` correctos
