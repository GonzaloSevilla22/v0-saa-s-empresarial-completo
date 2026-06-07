## Why

Con C-15 el backend tiene pool asyncpg + JWT-passthrough + BaseRepository. Hoy toda la lógica de datos (lecturas, mutaciones, guards de plan y rol) vive en el `DataContext` del browser — un God Object no testeable que mezcla estado UI con acceso a datos. C-16 expone esa lógica como API REST en FastAPI via **Strangler Fig con feature flag**, sin corte abrupto: el frontend puede alternar entre el endpoint antiguo (Supabase directo) y el nuevo (Python) por variable de entorno mientras se valida paridad.

## What Changes

- **3 sub-etapas de migración por riesgo creciente**:
  - Sub-etapa 1 (LOW): `expenses` + `clients` — sin RPCs complejos, sin idempotencia
  - Sub-etapa 2 (MEDIUM): `products` + `branches` + `stock` — preserva idempotencia, transferencias vía `rpc_transfer_stock`
  - Sub-etapa 3 (MEDIUM-HIGH): `sales` + `purchases` + `organizations` — orquesta `rpc_create_operation_aggregate`, verifica contadores de plan pre-insert
- **Repositorios concretos por dominio** en `backend/repositories/` — extienden `BaseRepository` de C-15
- **Services con guards** (`require_role`, `require_plan`) en `backend/services/`
- **Routers FastAPI** con Pydantic v2 schemas en `backend/routers/`
- **Feature flag** `NEXT_PUBLIC_USE_PYTHON_API=true/false` — el `DataContext` dirige tráfico al endpoint correcto; nunca corte abrupto
- **Mapeo de errores PG** → respuestas HTTP con mensajes en español (FK violation → 404, unique → 409, check → 422)
- **OpenAPI docs** en `/docs` y `/redoc` (automático FastAPI)
- Los servicios de IA/OCR **NO se migran** — permanecen como Supabase Edge Functions (DEC-15)
- El Realtime **NO se toca** — sigue en Supabase Realtime (DEC-16)

## Capabilities

### New Capabilities
- `domain-repositories`: Repositorios concretos por dominio (`ExpenseRepository`, `ClientRepository`, `ProductRepository`, `BranchRepository`, `StockRepository`, `SalesRepository`, `PurchaseRepository`, `OrganizationRepository`) que extienden `BaseRepository` y llaman a los RPCs PostgreSQL existentes.
- `data-api-endpoints`: Routers FastAPI + services por dominio con Pydantic v2 schemas, guards `require_role`/`require_plan`, y mapeo de errores PG a respuestas HTTP en español.
- `strangler-fig-feature-flag`: Mecanismo de feature flag (`NEXT_PUBLIC_USE_PYTHON_API`) para alternar tráfico del `DataContext` entre Supabase directo y FastAPI sin corte abrupto.

### Modified Capabilities
- `python-backend`: Se registran los nuevos routers de datos en `backend/main.py` (expenses, clients, products, branches, stock, sales, purchases, organizations).
- `base-repositories`: El patrón de instanciación desde endpoints se vuelve canónico; se agrega documentación del ciclo de vida connection-scoped.

## Impact

- **Backend** (`backend/`): nuevos directorios `routers/`, `services/`, `repositories/` con archivos por dominio; `main.py` actualizado con los nuevos routers; `core/errors.py` con mapeo PG → HTTP.
- **Frontend** (`contexts/data-context.tsx`, hooks): lógica de feature flag agregada para alternar el target de las llamadas de datos; sin cambios en la UI.
- **Tests** (`backend/tests/`): tests por router — happy path, guard 403 para `member` en mutaciones, y verificación de paridad de latencia.
- **Env vars nuevas**: `NEXT_PUBLIC_USE_PYTHON_API` (frontend), `BACKEND_URL` (frontend → FastAPI); `DATABASE_URL` y `REDIS_URL` ya configuradas en C-15.
- **Dependencias Python nuevas**: ninguna — el stack del scaffold (`fastapi`, `asyncpg`, `pydantic`, `python-jose`) cubre todo.
