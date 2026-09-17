# python-backend — Spec

## Purpose

Servicio FastAPI independiente del frontend Next.js. Corre como proceso separado, expone una API **HTTP y nada más** —el canal WebSocket propio se retiró en `auth-hardening-jwt-cookies`, ver la capability `realtime-websocket`, así que el tiempo real de la aplicación es Supabase Realtime— y se integra con Supabase como fuente de verdad de la base de datos. Su arranque **no es incondicional**: desde ese mismo change, una configuración de autenticación incoherente (sin `SUPABASE_URL` sobre `https://` y sin la palanca explícita del fallback `HS256`) **aborta el proceso nombrando la variable** en vez de degradar en silencio a un secreto compartido.

## Requirements

### Requirement: Estructura de proyecto

El backend SHALL organizarse en: `backend/main.py` (punto de entrada FastAPI), `backend/routers/` (handlers HTTP), `backend/core/` (config, auth, guards, database, errors) y `backend/tests/` (suite pytest).

El backend NOT SHALL contener un módulo gestor de conexiones WebSocket ni un router de WebSocket: ese canal se retiró (ver la capability `realtime-websocket`).

#### Scenario: El árbol de directorios refleja las 3 capas más config y tests

- **WHEN** se inspecciona el repo bajo `backend/`
- **THEN** existen `backend/main.py`, `backend/routers/` (con un módulo por dominio, p. ej. `expenses.py`, `sales.py`), `backend/core/` (con `config.py`, `auth.py`, `guards.py`, `database.py`, `errors.py`) y `backend/tests/` (una suite pytest, p. ej. `test_auth.py`, `test_expenses.py`); además `backend/services/` y `backend/repositories/` completan la arquitectura de 3 capas (routers → services → repositories) que exige `data-api-endpoints`

#### Scenario: No existe módulo de gestión de conexiones WebSocket

- **WHEN** se inspecciona `backend/core/` y `backend/routers/`
- **THEN** no existe ningún módulo gestor de conexiones WebSocket ni ningún router de WebSocket

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

El servicio SHALL poder iniciarse con `uvicorn backend.main:app --reload` desde la raíz del proyecto **cuando su configuración de verificación de identidad está declarada**: la dirección del proveedor sobre `https://`, o la palanca explícita del camino de desarrollo.

Sin ninguna de las dos, el arranque SHALL abortar nombrando la variable faltante y la salida documentada. Un proceso que atiende tráfico con la verificación del token degradada es peor que un proceso que no levanta: el camino degradado acepta tokens firmados con un secreto por default que está publicado en el repositorio, y el sujeto de un token forjado se convierte en la identidad efectiva aguas abajo.

#### Scenario: `uvicorn backend.main:app --reload` levanta la app con la configuración declarada

- **WHEN** se ejecuta `uvicorn backend.main:app --reload` desde la raíz del repo, con `uvicorn[standard]` instalado (declarado en `backend/pyproject.toml`), `backend/main.py` exponiendo el objeto `app` de FastAPI y la configuración de verificación de identidad declarada (dirección del proveedor sobre `https://`, o la palanca de desarrollo encendida)
- **THEN** el proceso arranca sin errores de import, ejecuta el `lifespan` (`init_pool`, `init_service_pool`, `init_redis`) y sirve la API en el puerto por defecto

#### Scenario: Sin configuración de verificación de identidad el arranque aborta nombrando la variable

- **GIVEN** un entorno sin la dirección del proveedor de identidad (o con una dirección que no es `https://`) y con la palanca de desarrollo apagada
- **WHEN** se intenta iniciar el servicio
- **THEN** el proceso aborta durante la carga de su configuración —no en el primer request— con un mensaje que nombra la variable faltante y la palanca que habilita el camino de desarrollo

#### Scenario: Los entornos de integración continua declaran su camino de verificación

- **WHEN** un workflow de integración continua arranca el proceso o corre la suite del backend
- **THEN** ese workflow declara en su propio archivo la palanca de desarrollo encendida o una dirección de proveedor sobre `https://`, y un valor que sólo exista en tiempo de ejecución no cuenta como declaración

### Requirement: Tests cubren happy path y error path

Cada router SHALL tener al mínimo 1 test de happy path y 1 test de error (auth fallida, input inválido).

#### Scenario: Un router de dominio cubre happy path y error path

- **WHEN** se revisa `backend/tests/test_expenses.py` (router `expenses`)
- **THEN** existen tests de happy path (`test_get_expenses_ok`, `test_create_expense_ok`) y tests de error (`test_create_expense_member_forbidden`, `test_delete_expense_member_forbidden`, que ejercitan el guard `require_role` con un rol insuficiente), el mismo patrón que siguen `test_clients.py`, `test_products.py`, `test_sales.py` y `test_purchases.py` para sus respectivos routers

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

### Requirement: Service-role pool initialization (C-17)

El módulo `backend/core/database.py` SHALL exponer `get_service_conn()` como dependencia FastAPI que provee una conexión asyncpg usando el pool regular (usuario `postgres` con BYPASSRLS), separado del pool con JWT-passthrough para usuarios autenticados.

#### Scenario: Service pool es inicializado al startup

- **WHEN** la aplicación FastAPI arranca
- **THEN** `init_pool()` inicializa el pool compartido y `get_service_conn()` retorna una conexión válida sin JWT-passthrough

#### Scenario: get_service_conn está confinado a los routers exentos (webhooks/relays y disparadores de plataforma)

- **WHEN** cualquier router distinto de `payments`, `fiscal` y `outbox` es llamado
- **THEN** usa `get_db_conn` (JWT-passthrough pool), no `get_service_conn`
- **AND** dentro de `payments`, `fiscal` y `outbox` cada dependencia de `get_service_conn` corresponde a una de las tres categorías exentas del requirement "Separación explícita entre el contexto de conexión de request y el de servicio": (a) un camino de máquina sin usuario final (`payments.mercadopago_webhook`, `fiscal.process_pending_cae_cron`); (b) un endpoint gateado por `require_platform_admin`/`require_admin` que opera a través de todas las cuentas por diseño (`outbox.process_pending_outbox`, y los endpoints de administración de `payments`: `list_ambiguous_subscriptions`, `resolve_ambiguous_subscription_endpoint`, `replay_subscription_charges_endpoint`, `discard_ambiguous_subscription_endpoint`, `list_recent_subscriptions_endpoint`, `search_accounts`, `list_payment_receipts`, `download_payment_receipt`, `resend_payment_receipt`); o (c) un endpoint de autoservicio de suscripción que atiende a un usuario autenticado pero resuelve la cuenta explícitamente por `Depends(get_account_id)` y filtra por ella en cada consulta, sin apoyarse en RLS (`payments.create_subscription`, `payments.get_subscription_status`, `payments.delete_subscription`)

#### Scenario: Exception handler global captura errores asyncpg
- **WHEN** cualquier endpoint lanza `asyncpg.PostgresError` no manejado explícitamente
- **THEN** el exception handler registrado en `main.py` lo convierte en respuesta HTTP con código y mensaje apropiado según `core/errors.py`

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

Cada punto de entrada del backend SHALL declarar cuál de los dos contextos usa. Un endpoint que atiende a un usuario autenticado NOT SHALL usar el contexto de servicio, salvo que caiga en una de tres categorías verificadas: (a) un camino de máquina sin usuario final (`payments.mercadopago_webhook`, `fiscal.process_pending_cae_cron`); (b) un endpoint gateado por un guard de administrador de plataforma (`require_platform_admin`/`require_admin`) que lo habilita a operar a través de todas las cuentas por diseño (`outbox.process_pending_outbox`, `payments.list_ambiguous_subscriptions`, `payments.resolve_ambiguous_subscription_endpoint`, `payments.replay_subscription_charges_endpoint`, `payments.discard_ambiguous_subscription_endpoint`, `payments.list_recent_subscriptions_endpoint`, `payments.search_accounts`, `payments.list_payment_receipts`, `payments.download_payment_receipt`, `payments.resend_payment_receipt`); o (c) un endpoint de autoservicio de suscripción que resuelve la cuenta explícitamente por `Depends(get_account_id)` y filtra por ella en cada consulta, sin apoyarse en RLS (`payments.create_subscription`, `payments.get_subscription_status`, `payments.delete_subscription`). Cualquier endpoint nuevo que no encaje en ninguna de estas tres categorías NOT SHALL usar el contexto de servicio.

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

