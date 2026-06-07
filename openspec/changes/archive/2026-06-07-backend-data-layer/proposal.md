## Why

El scaffolding FastAPI (`fastapi-backend-monorepo`, 2026-06-06) dejó el backend listo para recibir tráfico pero sin acceso real a la base de datos: no hay pool `asyncpg`, no hay JWT-passthrough a RLS y no hay repositorios. Sin esta capa, ninguna migración de endpoint (C-16) es posible — es el prerequesite bloqueante de toda la Fase 5.

## What Changes

- Agregar `asyncpg`, `redis` y `tenacity` como dependencias en `pyproject.toml`
- Crear `backend/core/database.py`: pool asyncpg con JWT-passthrough — inyecta el JWT del usuario como `app.jwt_claims` en cada conexión para que la RLS org-based siga activa
- Crear `backend/core/redis_client.py`: cliente Redis (Upstash) para cache de lookups org/rol (TTL 5 min)
- Crear `backend/repositories/__init__.py` + `backend/repositories/base.py`: clase `BaseRepository` que recibe una conexión asyncpg y expone helpers para ejecutar RPCs y queries con RLS activo
- Exponer un dependency FastAPI (`get_db_conn`) que adquiere una conexión del pool con el JWT del request inyectado
- Tests: cobertura unitaria de `BaseRepository` y del helper JWT-passthrough (pytest + pytest-asyncio)
- `backend/main.py`: registrar `startup`/`shutdown` lifespan para el pool asyncpg y el cliente Redis

## Capabilities

### New Capabilities
- `asyncpg-pool`: Pool de conexiones asyncpg con JWT-passthrough a RLS (1 conexión por request, JWT del usuario inyectado como `app.jwt_claims`)
- `base-repositories`: Capa base de repositorios — `BaseRepository` con helpers para RPCs (`call_rpc`), queries (`fetch`, `fetchrow`, `execute`) y manejo de errores DB

### Modified Capabilities
- (ninguna — el comportamiento externo de los endpoints existentes no cambia)

## Impact

- **`backend/pyproject.toml`**: nuevas deps (`asyncpg`, `redis`, `tenacity`)
- **`backend/core/`**: 2 archivos nuevos (`database.py`, `redis_client.py`)
- **`backend/repositories/`**: directorio nuevo con `__init__.py` y `base.py`
- **`backend/main.py`**: lifespan para inicializar/cerrar pool y Redis
- **`backend/tests/`**: tests nuevos para la capa de datos
- **Variables de entorno nuevas**: `DATABASE_URL` (postgres asyncpg), `REDIS_URL` (Upstash)
- **Sin impacto en el frontend**: esta capa es interna del backend; no hay cambios en API contracts ni en llamadas desde Next.js
