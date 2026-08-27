# python-backend — Spec

## Purpose

Servicio FastAPI independiente del frontend Next.js. Corre como proceso separado, expone una API HTTP + WebSocket, y se integra con Supabase como fuente de verdad de la base de datos.
## Requirements
### Requirement: Estructura de proyecto

El backend SHALL organizarse en: `backend/main.py` (punto de entrada FastAPI), `backend/routers/` (handlers HTTP y WebSocket), `backend/core/` (config, auth, ws_manager) y `backend/tests/` (suite pytest).

#### Scenario: El árbol de directorios refleja las 3 capas más config y tests

- **WHEN** se inspecciona el repo bajo `backend/`
- **THEN** existen `backend/main.py`, `backend/routers/` (con un módulo por dominio, p. ej. `expenses.py`, `sales.py`, `ws.py`), `backend/core/` (con `config.py`, `auth.py`, `ws_manager.py`, `guards.py`, `database.py`, `errors.py`) y `backend/tests/` (una suite pytest, p. ej. `test_auth.py`, `test_expenses.py`); además `backend/services/` y `backend/repositories/` completan la arquitectura de 3 capas (routers → services → repositories) que exige `data-api-endpoints`

### Requirement: Configuración via entorno

Toda configuración sensible (secrets, URLs) SHALL cargarse desde variables de entorno usando `pydantic-settings`, sin valores hard-codeados en código fuente.

#### Scenario: `Settings` carga desde variables de entorno con `pydantic-settings`

- **WHEN** el proceso arranca y se instancia `settings = Settings()` en `backend/core/config.py`
- **THEN** `Settings` hereda de `pydantic_settings.BaseSettings` con `model_config = SettingsConfigDict(env_file=".env")`, y cada secreto (`supabase_jwt_secret`, `service_role_key`, `mercadopago_webhook_secret`, `afip_platform_key`, etc.) se resuelve desde la variable de entorno homónima en mayúsculas, sin ningún secreto de producción escrito en el código fuente (los defaults del código son placeholders de dev, p. ej. `"dev-secret"`)

### Requirement: Health check

`GET /health` SHALL retornar `{"status": "ok"}` con HTTP 200, sin autenticación requerida.

#### Scenario: GET /health responde sin token

- **WHEN** se hace `GET /health` sin header `Authorization`
- **THEN** `backend/routers/health.py` responde HTTP 200 con body `{"status": "ok"}`, porque el endpoint no declara ninguna dependencia de `get_current_user`

### Requirement: Ejecutable con uvicorn

El servicio SHALL poder iniciarse con `uvicorn backend.main:app --reload` desde la raíz del proyecto.

#### Scenario: `uvicorn backend.main:app --reload` levanta la app

- **WHEN** se ejecuta `uvicorn backend.main:app --reload` desde la raíz del repo, con `uvicorn[standard]` instalado (declarado en `backend/pyproject.toml`) y `backend/main.py` exponiendo el objeto `app` de FastAPI
- **THEN** el proceso arranca sin errores de import, ejecuta el `lifespan` (`init_pool`, `init_service_pool`, `init_redis`) y sirve la API en el puerto por defecto

### Requirement: Tests cubren happy path y error path

Cada router SHALL tener al mínimo 1 test de happy path y 1 test de error (auth fallida, input inválido).

#### Scenario: Un router de dominio cubre happy path y error path

- **WHEN** se revisa `backend/tests/test_expenses.py` (router `expenses`)
- **THEN** existen tests de happy path (`test_get_expenses_ok`, `test_create_expense_ok`) y tests de error (`test_create_expense_member_forbidden`, `test_delete_expense_member_forbidden`, que ejercitan el guard `require_role` con un rol insuficiente), el mismo patrón que siguen `test_clients.py`, `test_products.py`, `test_sales.py` y `test_purchases.py` para sus respectivos routers

### Requirement: Routers de datos registrados en main.py
El sistema SHALL registrar los 8 routers de dominio (expenses, clients, products, branches, stock, sales, purchases, payments) en `backend/main.py` con sus prefijos correspondientes y el tag OpenAPI apropiado.

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
- `payments.router` (prefix `/payments`) ← C-17

> El router `organizations` fue retirado en `remove-organizations-dead-code`: apuntaba a una tabla `organizations` inexistente en producción y sus dos endpoints devolvían HTTP 500 desde C-16.

#### Scenario: Todos los routers de datos responden tras startup
- **WHEN** la app arranca correctamente con pool inicializado (Redis es opcional)
- **THEN** `GET /docs` lista todos los endpoints de expenses, clients, products, branches, stock, sales, purchases y payments en la UI de Swagger

#### Scenario: No hay router de organizations registrado
- **WHEN** la app arranca y se inspecciona `GET /openapi.json`
- **THEN** no existe ninguna ruta bajo el prefijo `/organizations` ni el tag OpenAPI `organizations`

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

### Requirement: El dominio organizations no existe en el backend
El backend SHALL no contener módulos, rutas ni repositorios del dominio `organizations`, porque nunca tuvo una tabla que lo respaldara en producción y su reintroducción reintroduciría endpoints rotos.

La raíz de tenancy del sistema es `accounts` (adoptada en C-19 `v2-tenancy-cleanup`); `companies` es legacy. No existe ni existió una tabla `organizations` en el proyecto Supabase de producción. Cualquier necesidad futura de editar datos de la cuenta SHALL modelarse sobre `accounts` en un change propio, con su consumidor, su matriz de roles y su spec.

#### Scenario: No quedan módulos del dominio organizations en el árbol del backend
- **WHEN** se buscan los archivos `backend/routers/organizations.py`, `backend/services/organizations.py`, `backend/repositories/organization_repository.py`, `backend/schemas/organizations.py` y `backend/tests/test_organizations.py`
- **THEN** ninguno de los cinco existe en el repositorio

#### Scenario: main.py no importa el módulo organizations
- **WHEN** se inspecciona `backend/main.py`
- **THEN** no aparece `organizations` en el bloque de imports de routers ni ninguna llamada `app.include_router(organizations.router)`, y la app arranca sin errores de import

### Requirement: Separación explícita entre el contexto de conexión de request y el de servicio

El backend SHALL exponer dos contextos de conexión a base de datos, con contratos distintos y documentados:

- **Contexto de request**: para toda operación originada por un usuario autenticado. Inyecta los claims del usuario con alcance transaccional, opera dentro de una transacción explícita por request, y queda sujeto a la evaluación de las policies de seguridad a nivel de fila.
- **Contexto de servicio**: para operaciones de máquina sin usuario (recepción de avisos de pago, procesos programados, tareas en segundo plano). NOT SHALL inyectar claims de usuario ni quedar envuelto en la transacción de un request, porque opera de forma transversal a las cuentas por diseño.

Cada punto de entrada del backend SHALL declarar cuál de los dos contextos usa. Un endpoint que atiende a un usuario autenticado NOT SHALL usar el contexto de servicio.

#### Scenario: Un endpoint de usuario usa el contexto de request

- **WHEN** un usuario autenticado ejercita cualquier endpoint de negocio
- **THEN** la conexión proviene del contexto de request, con sus claims inyectados y dentro de su transacción

#### Scenario: El aviso de pago usa el contexto de servicio

- **WHEN** llega un aviso de pago del proveedor de cobros, sin usuario autenticado
- **THEN** la operación usa el contexto de servicio y se completa sin requerir claims de usuario

#### Scenario: Una tarea en segundo plano no reutiliza la conexión del request

- **GIVEN** un endpoint que agenda trabajo para después de responder
- **WHEN** ese trabajo se ejecuta
- **THEN** obtiene su propia conexión del contexto de servicio, sin depender de la conexión ni de la transacción del request que ya terminó

### Requirement: Las escrituras directas del backend son compatibles con las policies vigentes

Toda escritura que el backend ejecute sobre una tabla **sin** pasar por una función con privilegios de definidor SHALL contar con una policy de escritura que la habilite para el rol del camino de request. Antes de activar la evaluación de policies para el backend, el sistema SHALL disponer de un inventario verificado de las escrituras directas cruzado contra las policies existentes, y cada divergencia SHALL resolverse encaminando la escritura por una función con privilegios de definidor o incorporando la policy faltante.

Una divergencia detectada durante la activación en producción, en lugar de antes, NOT SHALL considerarse un resultado aceptable del procedimiento.

#### Scenario: El inventario precede a la activación

- **WHEN** se propone activar la evaluación de policies para el backend
- **THEN** existe un inventario verificado de escrituras directas cruzado contra las policies, sin divergencias abiertas

#### Scenario: Una escritura directa sin policy se detecta antes del corte

- **GIVEN** una tabla que el backend escribe directamente y que no tiene policy de escritura
- **WHEN** se ejecuta el inventario
- **THEN** la divergencia queda registrada y resuelta antes de la activación, en lugar de manifestarse como un error de permisos en producción

