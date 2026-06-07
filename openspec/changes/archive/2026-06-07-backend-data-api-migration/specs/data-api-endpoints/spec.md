## ADDED Requirements

### Requirement: Routers FastAPI por dominio con Pydantic v2 schemas
El sistema SHALL exponer un router FastAPI por dominio en `backend/routers/<domain>.py`. Cada router SHALL validar el payload de entrada con schemas Pydantic v2 definidos en `backend/schemas/<domain>.py` antes de llamar al service correspondiente. Los endpoints SHALL usar los prefijos: `/expenses`, `/clients`, `/products`, `/branches`, `/stock`, `/sales`, `/purchases`, `/organizations`.

#### Scenario: GET /expenses retorna lista de gastos de la org del usuario
- **WHEN** un usuario autenticado hace `GET /expenses` con Bearer token válido
- **THEN** retorna HTTP 200 con `{"items": [...], "total": N}` filtrado por la org del token; los ítems siguen el schema `ExpenseOut`

#### Scenario: POST /expenses con payload inválido retorna 422
- **WHEN** se hace `POST /expenses` con body `{"amount": "no-es-numero"}`
- **THEN** FastAPI retorna HTTP 422 con detalle de validación Pydantic antes de llamar al service

#### Scenario: GET /sales retorna ventas agrupadas por operation_id
- **WHEN** un usuario autenticado hace `GET /sales?date_from=2026-01-01&date_to=2026-06-30`
- **THEN** retorna HTTP 200 con ventas de esa org en el rango de fechas; ítems agrupados por `operation_id`

#### Scenario: POST /sales con idempotency_key duplicada retorna la operación previa
- **WHEN** se hace `POST /sales` con un `idempotency_key` que ya fue procesado por esta org
- **THEN** retorna HTTP 200 con la operación previa (no duplica) — el RPC subyacente es idempotente

### Requirement: Services con guards require_role y require_plan
Cada dominio SHALL tener un service en `backend/services/<domain>.py` con funciones que reciben `auth: AuthContext` (de C-15) y el payload validado. Los guards SHALL aplicarse al inicio de cada función de mutación:
- `require_role(auth, allowed_roles)` — lanza HTTP 403 si el rol del usuario no está en `allowed_roles`
- `require_plan(auth, allowed_plans)` — lanza HTTP 403 si el plan de la org no está en `allowed_plans`
Los guards aplican a mutaciones (CREATE, UPDATE, DELETE); las lecturas no requieren guard de rol (pero sí de autenticación).

#### Scenario: member intenta crear un gasto y recibe 403
- **WHEN** un usuario con rol `member` hace `POST /expenses`
- **THEN** `require_role(auth, ["owner", "admin"])` lanza HTTP 403 con `{"detail": "Rol insuficiente: se requiere owner o admin"}`

#### Scenario: usuario en plan gratis intenta agregar más productos del límite
- **WHEN** un usuario en plan `gratis` intenta `POST /products` y ya tiene `max_products` alcanzado
- **THEN** `require_plan` o la verificación de contadores retorna HTTP 403 con `{"detail": "Límite de plan alcanzado: máximo N productos"}`

#### Scenario: owner puede crear una venta sin restricción de rol
- **WHEN** un usuario con rol `owner` hace `POST /sales` con payload válido
- **THEN** `require_role(auth, ["owner", "admin"])` pasa, el service procede y retorna HTTP 201 con el `operation_id`

#### Scenario: member puede listar ventas sin restricción de rol
- **WHEN** un usuario con rol `member` hace `GET /sales`
- **THEN** no hay guard de rol en la lectura; retorna HTTP 200 con las ventas de la org

### Requirement: Mapeo de errores PostgreSQL a respuestas HTTP con mensajes en español
El sistema SHALL convertir errores asyncpg en respuestas HTTP con mensajes en español antes de retornarlos al cliente. El mapeo SHALL cubrirse en `backend/core/errors.py` y aplicarse via exception handler global en `main.py`.

#### Scenario: FK violation en DELETE de producto con ventas asociadas
- **WHEN** `DELETE /products/{id}` y el producto tiene registros en `sales`
- **THEN** asyncpg lanza `ForeignKeyViolationError`; el handler retorna HTTP 409 con `{"detail": "No se puede eliminar: el recurso tiene registros asociados"}`

#### Scenario: Unique violation al crear cliente con email duplicado
- **WHEN** `POST /clients` y el email ya existe para esa org
- **THEN** asyncpg lanza `UniqueViolationError`; el handler retorna HTTP 409 con `{"detail": "Ya existe un cliente con ese email en esta organización"}`

#### Scenario: Check violation en transferencia de stock insuficiente
- **WHEN** `POST /stock/transfer` con quantity mayor al stock disponible en la sucursal origen
- **THEN** asyncpg lanza `CheckViolationError`; el handler retorna HTTP 422 con `{"detail": "Stock insuficiente para realizar la transferencia"}`

#### Scenario: Error de DB inesperado retorna 500 sin exponer detalles internos
- **WHEN** ocurre un error de PostgreSQL no mapeado
- **THEN** el handler retorna HTTP 500 con `{"detail": "Error interno del servidor"}` y loguea el error completo en stderr

### Requirement: OpenAPI docs disponibles sin autenticación
El sistema SHALL exponer la documentación OpenAPI generada por FastAPI en `/docs` (Swagger UI) y `/redoc` (ReDoc) sin requerir autenticación.

#### Scenario: GET /docs retorna la interfaz Swagger UI
- **WHEN** se hace `GET /docs` al backend FastAPI
- **THEN** retorna HTTP 200 con la interfaz Swagger UI que lista todos los endpoints de datos

#### Scenario: GET /openapi.json retorna el schema completo
- **WHEN** se hace `GET /openapi.json`
- **THEN** retorna HTTP 200 con el schema OpenAPI 3.x válido incluyendo todos los endpoints, schemas Pydantic, y códigos de respuesta documentados
