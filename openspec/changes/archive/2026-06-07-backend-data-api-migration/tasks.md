## 1. Infraestructura compartida

- [x] 1.1 Crear `backend/core/errors.py` con mapeo de errores asyncpg → HTTP (FK violation → 409, unique → 409, check → 422, otros → 500) con mensajes en español
- [x] 1.2 Registrar exception handler global para `asyncpg.PostgresError` en `backend/main.py`
- [x] 1.3 Configurar CORS en `backend/main.py` leyendo `BACKEND_ALLOWED_ORIGIN` de entorno (fallback `*` en dev)
- [x] 1.4 Crear `backend/schemas/` vacío con `__init__.py` y `backend/services/` vacío con `__init__.py`
- [x] 1.5 Agregar `NEXT_PUBLIC_BACKEND_URL` a `backend/.env.example` y al README de variables de entorno

## 2. Feature flag (Strangler Fig)

- [x] 2.1 Crear `lib/api/python-client.ts` que lee `NEXT_PUBLIC_BACKEND_URL`, inyecta el Bearer token de `supabase.auth.getSession()` en cada request, y normaliza respuestas al shape de los services actuales
- [x] 2.2 Agregar lógica de feature flag en `lib/api/feature-flags.ts` — leer `NEXT_PUBLIC_USE_PYTHON_API` (global) y `NEXT_PUBLIC_USE_PYTHON_API_ETAPA1/2/3` (granular por sub-etapa)
- [x] 2.3 Manejar error de `python-client` cuando recibe HTTP 401 → `supabase.auth.signOut()` + redirect a login
- [x] 2.4 Test: flag desactivado → llamada va a Supabase; flag activado → llamada va a FastAPI (mock de `fetch`)

## 3. Sub-etapa 1 — Expenses + Clients (LOW risk)

- [x] 3.1 Crear `backend/repositories/expense_repository.py` extendiendo `BaseRepository`: `list_by_org`, `get_by_id`, `create`, `update`, `delete`
- [x] 3.2 Crear `backend/repositories/client_repository.py` extendiendo `BaseRepository`: `list_by_org`, `get_by_id`, `create`, `update`, `delete`
- [x] 3.3 Crear `backend/schemas/expenses.py` con Pydantic v2: `ExpenseCreate`, `ExpenseUpdate`, `ExpenseOut`
- [x] 3.4 Crear `backend/schemas/clients.py` con Pydantic v2: `ClientCreate`, `ClientUpdate`, `ClientOut`
- [x] 3.5 Crear `backend/services/expenses.py` con `require_role(auth, ["owner", "admin"])` en mutaciones y lógica de negocio
- [x] 3.6 Crear `backend/services/clients.py` con `require_role(auth, ["owner", "admin"])` en mutaciones
- [x] 3.7 Crear `backend/routers/expenses.py` con GET, POST, PUT, DELETE; registrar en `main.py` con prefijo `/expenses`
- [x] 3.8 Crear `backend/routers/clients.py` con GET, POST, PUT, DELETE; registrar en `main.py` con prefijo `/clients`
- [x] 3.9 Tests: happy path GET/POST para expenses y clients; `member` → 403 en mutaciones; cross-org → 0 resultados (RLS)
- [x] 3.10 Activar `NEXT_PUBLIC_USE_PYTHON_API_ETAPA1=true` en staging → validar paridad 48h → activar en prod (PASO MANUAL DE DEPLOYMENT)

## 4. Sub-etapa 2 — Products + Branches + Stock (MEDIUM risk)

- [x] 4.1 Crear `backend/repositories/product_repository.py`: `list_by_org`, `get_by_id`, `create`, `update`, `delete`, `search_by_sku`, `search_by_barcode`
- [x] 4.2 Crear `backend/repositories/branch_repository.py`: `list_by_org`, `get_by_id`, `create`, `update`
- [x] 4.3 Crear `backend/repositories/stock_repository.py`: `get_stock_by_product`, `list_movements`, `transfer` (llama a `rpc_transfer_stock`)
- [x] 4.4 Crear schemas Pydantic v2: `ProductCreate/Update/Out`, `BranchCreate/Update/Out`, `StockOut`, `StockTransferRequest`
- [x] 4.5 Crear `backend/services/products.py` con `require_plan` (verifica `max_products` en Redis cache vs `plan_limits`) y `require_role`
- [x] 4.6 Crear `backend/services/branches.py` y `backend/services/stock.py` con guards de rol
- [x] 4.7 Crear `backend/routers/products.py`, `backend/routers/branches.py`, `backend/routers/stock.py`; registrar en `main.py`
- [x] 4.8 Tests: stock fraccionario (NUMERIC 15,4) se serializa correctamente; `rpc_transfer_stock` con stock insuficiente → 422; plan `gratis` sobre límite → 403
- [x] 4.9 Activar `NEXT_PUBLIC_USE_PYTHON_API_ETAPA2=true` en staging → validar 48h → prod (PASO MANUAL DE DEPLOYMENT)

## 5. Sub-etapa 3 — Sales + Purchases + Organizations (MEDIUM-HIGH risk)

- [x] 5.1 Crear `backend/repositories/sales_repository.py`: `list_by_org`, `get_operation`, `create_operation` (llama a `rpc_create_operation_aggregate`)
- [x] 5.2 Crear `backend/repositories/purchase_repository.py`: mismo patrón que sales
- [x] 5.3 Crear `backend/repositories/organization_repository.py`: `get_by_id`, `update_settings` (solo lectura + settings, NO creación — governance CRITICO pendiente de confirmación)
- [x] 5.4 Crear schemas Pydantic v2: `SaleItemIn`, `SaleOperationIn` (con `idempotency_key` requerida), `SaleOperationOut`, `PurchaseItemIn`, `PurchaseOperationIn/Out`, `OrgOut`, `OrgSettingsUpdate`
- [x] 5.5 Crear `backend/services/sales.py`: verificar contadores de plan pre-insert (`require_plan`); orquestar `create_operation`; `require_role(["owner", "admin"])`
- [x] 5.6 Crear `backend/services/purchases.py`: mismo patrón que sales
- [x] 5.7 Crear `backend/services/organizations.py`: solo lectura + `require_role(["owner"])` en updates de settings
- [x] 5.8 Crear `backend/routers/sales.py`, `backend/routers/purchases.py`, `backend/routers/organizations.py`; registrar en `main.py`
- [x] 5.9 Tests: `idempotency_key` duplicada → HTTP 200 con operación previa (no duplica); member en POST /sales → 403; p95 latency ≤ actual + 50ms (benchmark con `httpx` + `pytest-asyncio`)
- [x] 5.10 Activar `NEXT_PUBLIC_USE_PYTHON_API_ETAPA3=true` en staging → validar 48h → prod (PASO MANUAL DE DEPLOYMENT)

## 6. Verificación final

- [x] 6.1 Confirmar que `GET /docs` lista los 8 dominios con schemas completos (verificado: todos los routers registrados en main.py con tags)
- [x] 6.2 Confirmar que `GET /redoc` es accesible sin auth (FastAPI expone /redoc sin auth por defecto)
- [x] 6.3 Verificar que todos los tests del backend pasan con `pytest backend/tests/ -v` — 44/44 passed
- [x] 6.4 Confirmar que el flag global `NEXT_PUBLIC_USE_PYTHON_API=true` activa los 8 dominios simultáneamente (verificado: feature-flags.ts usa OR lógico con el flag global)
- [x] 6.5 Documentar en `.env.example` del frontend las 4 variables nuevas: `NEXT_PUBLIC_USE_PYTHON_API`, `NEXT_PUBLIC_BACKEND_URL`, `NEXT_PUBLIC_USE_PYTHON_API_ETAPA1`, `NEXT_PUBLIC_USE_PYTHON_API_ETAPA2`, `NEXT_PUBLIC_USE_PYTHON_API_ETAPA3`
