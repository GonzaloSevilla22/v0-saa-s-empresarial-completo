# data-api-endpoints

## Purpose

Routers FastAPI tipados por dominio que validan payloads con Pydantic v2, aplican guards de rol y plan, y exponen endpoints CRUD para 8 dominios de negocio (expenses, clients, products, branches, stock, sales, purchases, organizations). Cada router retorna respuestas en schema consistente (`{items: [...], total: N}` para listas; recursos individuales para detail/create). Los errores PostgreSQL se convierten a respuestas HTTP con mensajes en español.

## Requirements

### Requirement: Routers FastAPI por dominio con Pydantic v2 schemas
El sistema SHALL exponer un router FastAPI por dominio en `backend/routers/<domain>.py`. Cada router SHALL validar el payload de entrada con schemas Pydantic v2 definidos en `backend/schemas/<domain>.py` antes de llamar al service correspondiente. Los endpoints SHALL usar los prefijos: `/expenses`, `/clients`, `/products`, `/branches`, `/stock`, `/sales`, `/purchases`, `/organizations`. Los endpoints están **activos sin condición de flag** — el feature flag `NEXT_PUBLIC_USE_PYTHON_API` fue eliminado en C-18; el frontend siempre llama a estos endpoints.

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

### Requirement: Endpoints REST de Quote
> Agregado en C-29 `v21-quote-salesorder` (2026-06-17)

El backend FastAPI SHALL exponer endpoints para gestionar presupuestos siguiendo la arquitectura de 3 capas (routers→services→repositories), con guards de rol en el service (`require_role`), validación Pydantic v2 en el endpoint y acceso a datos vía JWT-passthrough (nunca `service_role`). Los endpoints SHALL cubrir: crear presupuesto, listar presupuestos de la cuenta, obtener un presupuesto con sus ítems, transicionar estado (`send`/`reject`/`expire`) y `accept` (que crea el `SalesOrder`).

#### Scenario: crear presupuesto devuelve 201
- **WHEN** un usuario writer hace `POST` al endpoint de presupuestos con ítems válidos
- **THEN** responde 201 con el presupuesto creado en estado `draft`

#### Scenario: accept devuelve la orden creada
- **WHEN** se hace `POST` al endpoint de `accept` de un presupuesto en `sent`
- **THEN** responde con el `sales_order_id` de la orden generada y el presupuesto queda en `accepted`

#### Scenario: rol insuficiente es rechazado
- **WHEN** un usuario sin rol writer intenta crear o aceptar un presupuesto
- **THEN** el service responde 403 (guard `require_role`)

### Requirement: Endpoints REST de SalesOrder y quickSale
> Agregado en C-29 `v21-quote-salesorder` (2026-06-17)

El backend FastAPI SHALL exponer endpoints para órdenes de venta: crear orden (`draft`), confirmar orden (`confirm`), `quickSale` (crear+confirmar POS en un paso) y listar/obtener órdenes. La validación del payload (incluyendo `payment_method`, `cash_session_id` cuando es efectivo, y tipo de comprobante opcional) SHALL ocurrir con schemas Pydantic v2 antes de invocar el RPC. El service SHALL aplicar `require_role` y delegar la transacción al RPC `SECURITY DEFINER` vía el repository.

#### Scenario: quickSale devuelve la orden confirmada
- **WHEN** se hace `POST` al endpoint de `quickSale` con `idempotency_key`, ítems y `payment_method`
- **THEN** responde con el `sales_order_id` y el `operation_id`, y la orden queda `confirmed`

#### Scenario: confirm con stock insuficiente propaga el error de negocio
- **WHEN** el RPC lanza P0409 por stock insuficiente
- **THEN** el endpoint responde con un código de error de negocio (409) y un mensaje claro, sin efectos parciales

#### Scenario: payload inválido es rechazado por el schema
- **WHEN** se envía `payment_method = 'cash'` sin `cash_session_id`
- **THEN** la validación falla (422/400) antes de tocar la base de datos

