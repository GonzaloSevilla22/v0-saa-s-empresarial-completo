## Context

El backend FastAPI scaffoldeado (C-00 `fastapi-backend-monorepo`) tiene autenticación JWT funcional, WebSocket manager y un health check. Lo que no tiene es acceso a la base de datos: `pyproject.toml` no incluye `asyncpg` ni `redis`, no existe pool, no hay repositorios y no hay dependency (`get_db_conn`) que los endpoints puedan usar.

Supabase PostgreSQL expone la misma base de datos que usa el frontend. La RLS org-based (`organization_members.role`) es la última línea de defensa de seguridad (DEC-13). El backend debe mantenerla activa en cada query — no hay `service_role`.

Estado actual:
- `backend/core/auth.py` — `get_current_user()` retorna `{user_id, role}` desde el JWT (HS256, `SUPABASE_JWT_SECRET`)
- `backend/core/config.py` — `Settings` con `pydantic-settings`, solo tiene `supabase_jwt_secret` y `app_env`
- Sin `DATABASE_URL`, sin `REDIS_URL`, sin pool, sin repositorios

## Goals / Non-Goals

**Goals:**
- Pool `asyncpg` inicializado en startup de la app, cerrado en shutdown
- JWT-passthrough: cada conexión del pool inyecta los claims del usuario (`user_id`, `org_id`) para que la RLS aplique automáticamente en cada query
- `BaseRepository`: clase base con helpers tipados (`call_rpc`, `fetch`, `fetchrow`, `execute`) que garantiza que se use la conexión con JWT inyectado
- Cliente Redis (Upstash): para futuros lookups de org/rol (TTL 5 min) — inicializado en startup pero sin lógica de cache en este change
- Tests con pytest-asyncio para el pool y `BaseRepository`
- `config.py` extendido con `database_url` y `redis_url`

**Non-Goals:**
- Implementar endpoints de datos (eso es C-16)
- Cache de lookups org/rol (la infraestructura Redis se inicializa, la lógica de cache va en C-16)
- Migrar llamadas del frontend (eso es C-16 y C-18)
- Mover IA/OCR a Python (DEC-15: permanecen en Edge Functions)

## Decisions

### D-1 — JWT-passthrough vía `SET LOCAL` en asyncpg

**Decisión**: Inyectar los claims del JWT como parámetros de sesión de PostgreSQL usando `SET LOCAL` al inicio de cada transacción:

```python
await conn.execute("SET LOCAL app.jwt_claims = $1", json.dumps(claims))
```

Las RPCs de Supabase usan `auth.uid()` que internamente lee `request.jwt.claims`. Con asyncpg el camino es `SET LOCAL app.jwt_claims` + `set_local` y los RPCs SECURITY DEFINER existentes no necesitan cambios — siguen leyendo `auth.uid()`.

**Alternativa descartada**: Usar `service_role` y reimplementar la autorización en Python. Viola DEC-13 y tira el hardening de seguridad existente (RLS, triggers anti-escalación, `WITH CHECK`).

**Alternativa descartada**: Pool separado por usuario. No escala — Render free tiene límite de conexiones.

### D-2 — Pool asyncpg con `min_size=2, max_size=10`

**Decisión**: Pool compartido en el lifespan de la app (FastAPI `lifespan`), con `min_size=2` (siempre 2 conexiones calientes, reduce cold-start latency) y `max_size=10` (compatible con Supabase free tier: límite ~100 conexiones directas, el frontend ya usa algunas).

**Alternativa descartada**: `asyncpg.connect()` por request (sin pool). Cada request paga el costo de TCP handshake + auth.

### D-3 — Dependency `get_db_conn` como async context manager

**Decisión**: Exponer un FastAPI `Depends` que adquiere una conexión del pool, inyecta los claims y la libera al finalizar el request:

```python
async def get_db_conn(user: dict = Depends(get_current_user)) -> AsyncGenerator[asyncpg.Connection, None]:
    async with pool.acquire() as conn:
        await conn.execute("SET LOCAL app.jwt_claims = $1", json.dumps(user))
        yield conn
```

Los routers reciben la conexión ya configurada — no necesitan saber de JWT-passthrough.

### D-4 — BaseRepository sin ORM (SQL puro + RPCs)

**Decisión**: `BaseRepository` recibe una conexión asyncpg y expone métodos tipados. Sin SQLAlchemy, sin ORM. El proyecto ya tiene RPCs SQL robustas (atómicas, con idempotencia) — el backend las llama directamente.

```python
class BaseRepository:
    def __init__(self, conn: asyncpg.Connection): ...
    async def call_rpc(self, name: str, **params) -> Record: ...
    async def fetch(self, query: str, *args) -> list[Record]: ...
    async def fetchrow(self, query: str, *args) -> Record | None: ...
    async def execute(self, query: str, *args) -> str: ...
```

**Alternativa descartada**: SQLAlchemy async. Overhead de ORM sobre un esquema ya probado con SQL puro. Aumenta complejidad y deuda de dependencias sin beneficio real en MVP.

### D-5 — Redis solo inicializado, sin lógica de cache en este change

**Decisión**: `redis_client.py` inicializa el cliente Upstash en startup y lo cierra en shutdown. La lógica de cache (lookups org/rol, rate-limit) se implementa en C-16 cuando los repositorios concretos lo necesiten.

**Razón**: No agregar funcionalidad no usada. El cliente inicializado ya permite que C-16 lo consuma sin cambios de infraestructura.

## Risks / Trade-offs

- **Cold start Render** → La primera request después de spindown paga el costo de inicializar el pool asyncpg (~200ms extra). Mitigación: cron ping a `/health` (configurado en Render gratis). El pool `min_size=2` reduce el costo de conexiones subsiguientes.
- **Límite de conexiones Supabase free** → `max_size=10` es conservador. Si el frontend ya tiene sesiones abiertas, el total puede superar el límite de Supabase free (~100). Monitorear con `pg_stat_activity` al crecer. Mitigación: Supabase tiene PgBouncer incorporado.
- **`SET LOCAL app.jwt_claims`** → Esta es la técnica usada por Supabase internamente. Si una RPC no usa `auth.uid()` sino acceso directo a tablas sin RLS (SECURITY DEFINER), el passthrough no aplica. Todos los RPCs existentes son SECURITY DEFINER — la RLS aplica dentro de la función según su propio `search_path`. El passthrough protege queries directas a tablas con RLS, que no hay por ahora en el backend (todos los accesos son via RPC). Documentar que queries directas deben ser conscientes de esto.
- **Tests en CI** → Los tests de integración de repositorios necesitan una DB real o un mock de asyncpg. Por ahora se mockea el pool en tests unitarios. Tests de integración full contra Supabase: no en este change (se agregan en C-16 cuando haya queries reales que probar).

## Migration Plan

1. Agregar deps en `pyproject.toml` (`asyncpg`, `redis`, `tenacity`)
2. Extender `config.py` con `database_url` y `redis_url`
3. Crear `core/database.py` (pool + `get_db_conn`)
4. Crear `core/redis_client.py`
5. Crear `repositories/__init__.py` + `repositories/base.py`
6. Actualizar `main.py` con lifespan
7. Agregar tests
8. Agregar variables de entorno en Render (`DATABASE_URL`, `REDIS_URL`)

Rollback: las variables de entorno son aditivas; si no se configuran, la app sigue corriendo (con el pool fallando en startup — se puede hacer lazy init con `Optional[Pool]` si se necesita un deploy gradual).

## Open Questions

- ¿`DATABASE_URL` apunta a la misma DB de Supabase (postgres directo) o a un pooler (PgBouncer)? Preferible el pooler de Supabase (`*.supabase.co:6543`) para evitar agotar conexiones. Confirmar con el equipo antes de deploy.
- ¿Upstash Redis o un Redis en Render? Upstash free (10k cmds/día) es suficiente para MVP; upgrade si se supera.
