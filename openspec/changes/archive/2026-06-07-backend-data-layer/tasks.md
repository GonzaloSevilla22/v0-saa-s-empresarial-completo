## 1. Dependencias y Configuración

- [x] 1.1 Agregar `asyncpg>=0.29`, `redis>=5.0`, `tenacity>=8.2` a `[project].dependencies` en `backend/pyproject.toml`
- [x] 1.2 Agregar `pytest-asyncio>=0.23` y `asyncpg-stubs>=0.29` a `[project.optional-dependencies].dev`
- [x] 1.3 Extender `backend/core/config.py`: agregar campos `database_url: str` y `redis_url: str` a `Settings` (sin defaults — forzar configuración explícita)
- [x] 1.4 Crear `backend/.env.example` con `DATABASE_URL=`, `REDIS_URL=`, `SUPABASE_JWT_SECRET=` documentados
- [x] 1.5 Verificar que `.gitignore` de la raíz (o `backend/.gitignore`) ignora `.env` y no `.env.example`

## 2. Pool asyncpg + JWT-passthrough

- [x] 2.1 Crear `backend/core/database.py` con variable global `pool: asyncpg.Pool | None = None`
- [x] 2.2 Implementar `async def init_pool()` que crea el pool con `asyncpg.create_pool(settings.database_url, min_size=2, max_size=10)`
- [x] 2.3 Implementar `async def close_pool()` que cierra el pool si no es `None`
- [x] 2.4 Implementar `async def get_db_conn(user: dict = Depends(get_current_user)) -> AsyncGenerator[asyncpg.Connection, None]`: adquiere conexión del pool, ejecuta `SET LOCAL app.jwt_claims = $1` con `json.dumps(user)`, yielda la conexión y la libera al finalizar
- [x] 2.5 Manejar el caso en que el pool no esté inicializado: lanzar `RuntimeError("Database pool not initialized")` en `get_db_conn`

## 3. Cliente Redis

- [x] 3.1 Crear `backend/core/redis_client.py` con variable global `redis: redis.asyncio.Redis | None = None`
- [x] 3.2 Implementar `async def init_redis()`: crea cliente con `redis.asyncio.from_url(settings.redis_url, decode_responses=True)`
- [x] 3.3 Implementar `async def close_redis()`: cierra el cliente si no es `None`

## 4. Lifespan en main.py

- [x] 4.1 Reemplazar el app `FastAPI()` sin lifespan por uno con `@asynccontextmanager async def lifespan(app)` que llama `init_pool()` + `init_redis()` en el bloque de startup y `close_pool()` + `close_redis()` en el bloque de shutdown
- [x] 4.2 Pasar `lifespan=lifespan` al constructor de `FastAPI`
- [x] 4.3 Verificar que `GET /health` sigue retornando `{"status": "ok"}` con el lifespan nuevo (el health router no depende del pool)

## 5. Repositorios Base

- [x] 5.1 Crear `backend/repositories/__init__.py` vacío
- [x] 5.2 Crear `backend/repositories/base.py` con clase `BaseRepository`:
  - constructor `__init__(self, conn: asyncpg.Connection)`
  - método `async def call_rpc(self, name: str, **params) -> asyncpg.Record`
  - método `async def fetch(self, query: str, *args) -> list[asyncpg.Record]`
  - método `async def fetchrow(self, query: str, *args) -> asyncpg.Record | None`
  - método `async def execute(self, query: str, *args) -> str`
- [x] 5.3 Documentar en docstring de `BaseRepository` el invariante: "la conexión recibida ya tiene JWT-passthrough aplicado via `get_db_conn`; no volver a inyectar claims aquí"

## 6. Tests

- [x] 6.1 Crear `backend/tests/test_database.py`: test que mockea `asyncpg.create_pool` y verifica que `get_db_conn` ejecuta `SET LOCAL app.jwt_claims` con el user_id correcto
- [x] 6.2 Crear `backend/tests/test_base_repository.py`:
  - test `call_rpc` con mock de conexión que verifica la query ejecutada
  - test `fetchrow` retorna `None` cuando la conexión mockea no encontrar filas
  - test `fetch` retorna lista vacía cuando no hay resultados
- [x] 6.3 Verificar que la suite completa pasa con `pytest` desde la raíz del monorepo

## 7. Variables de Entorno en Render

- [x] 7.1 Agregar `DATABASE_URL` (Supabase connection string — preferir el pooler `*.supabase.co:6543`) en el dashboard de Render para el servicio `emprende-smart-backend` *(manual — Render dashboard)*
- [x] 7.2 Agregar `REDIS_URL` (Upstash Redis connection string) en Render *(manual — Render dashboard)*
- [x] 7.3 Verificar que el deploy en Render levanta sin errores (revisar logs de startup en Render dashboard) *(manual — post-deploy)*
