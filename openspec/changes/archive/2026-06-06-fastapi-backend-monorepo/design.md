# Design: FastAPI Backend + Monorepo Reorganization

## Architecture Overview

```
/ (monorepo root)
├── frontend/                    ← Next.js app (movido desde raíz)
│   ├── app/
│   ├── components/
│   ├── hooks/
│   ├── lib/
│   ├── contexts/
│   ├── providers/
│   ├── public/
│   ├── __tests__/
│   ├── package.json
│   ├── tsconfig.json
│   ├── tailwind.config.ts
│   ├── next.config.mjs
│   └── .env.local
│
└── backend/                     ← nuevo FastAPI
    ├── main.py                  ← FastAPI app + lifespan
    ├── routers/
    │   ├── __init__.py
    │   ├── health.py            ← GET /health
    │   └── ws.py                ← WebSocket /ws/{room_id}
    ├── core/
    │   ├── __init__.py
    │   ├── config.py            ← Settings (pydantic-settings)
    │   ├── auth.py              ← JWT validation middleware
    │   └── ws_manager.py        ← ConnectionManager para broadcast
    ├── tests/
    │   ├── __init__.py
    │   ├── conftest.py          ← fixtures: app, async_client, valid_token
    │   ├── test_health.py
    │   ├── test_auth.py
    │   └── test_ws.py
    ├── pyproject.toml
    ├── requirements.txt
    └── .env.example
```

## JWT Validation Flow

```
Frontend                Supabase              FastAPI
   │                      │                     │
   │──── login ──────────►│                     │
   │◄─── JWT token ───────│                     │
   │                      │                     │
   │──── request + Bearer JWT ─────────────────►│
   │                      │        decode JWT   │
   │                      │        (SUPABASE_JWT_SECRET)
   │                      │        extract sub, role
   │◄───────────────────────────── 200 / 401 ───│
```

FastAPI **no emite tokens** — solo los verifica. La firma usa `HS256` con el `SUPABASE_JWT_SECRET` del proyecto.

## WebSocket Flow

```
Frontend                         FastAPI
   │                               │
   │── WS connect /ws/{room_id} ──►│
   │   (query param: ?token=JWT)   │
   │                               │── validate JWT
   │                               │── ConnectionManager.connect(room_id, ws)
   │◄── WS accepted ───────────────│
   │                               │
   │   [evento en otro servicio]   │
   │                               │── broadcast(room_id, message)
   │◄── message ───────────────────│
   │                               │
   │── WS close ───────────────────►│
   │                               │── ConnectionManager.disconnect(room_id, ws)
```

## Key Components

### `core/auth.py` — JWT Dependency

```python
# Extrae y valida el JWT de Supabase
async def get_current_user(token: str = Depends(oauth2_scheme)) -> dict:
    try:
        payload = jwt.decode(token, settings.supabase_jwt_secret, algorithms=["HS256"],
                             options={"verify_aud": False})
        return {"user_id": payload["sub"], "role": payload.get("role", "authenticated")}
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")
```

### `core/ws_manager.py` — ConnectionManager

```python
class ConnectionManager:
    def __init__(self):
        self.active: dict[str, list[WebSocket]] = {}

    async def connect(self, room_id: str, ws: WebSocket): ...
    def disconnect(self, room_id: str, ws: WebSocket): ...
    async def broadcast(self, room_id: str, message: dict): ...
```

### `core/config.py` — Settings

```python
class Settings(BaseSettings):
    supabase_jwt_secret: str
    app_env: str = "development"
    model_config = SettingsConfigDict(env_file=".env")
```

## Monorepo — Cambios de Configuración

### `tsconfig.json` (en `frontend/`)
```json
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": { "@/*": ["./*"] }
  }
}
```
Los paths `@/` siguen funcionando porque ahora son relativos a `frontend/`.

### `frontend/next.config.mjs`
Sin cambios en la lógica — solo la ubicación del archivo cambia.

### `pnpm-workspace.yaml` (raíz)
```yaml
packages:
  - 'frontend'
```

### Vercel
Configurar `rootDirectory: frontend` en el dashboard de Vercel (o `vercel.json` en raíz).

## Testing Strategy

| Layer | Tool | Coverage |
|-------|------|----------|
| Unit (auth) | `pytest` + `python-jose` mock | decode válido, inválido, expirado |
| Integration (routers) | `pytest` + `httpx.AsyncClient` | GET /health, WS connect/disconnect |
| WebSocket | `pytest-asyncio` + `websockets` | connect, broadcast, disconnect |

### TDD Cycle (por task)
1. RED: test describe el behavior esperado → importa código que no existe
2. GREEN: implementación mínima que pasa
3. TRIANGULATE: segundo caso (edge case)
4. REFACTOR: limpieza sin romper tests

## Dependencies

```toml
# pyproject.toml
[project]
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.111",
    "uvicorn[standard]>=0.29",
    "python-jose[cryptography]>=3.3",
    "pydantic-settings>=2.2",
]

[project.optional-dependencies]
dev = [
    "pytest>=8",
    "pytest-asyncio>=0.23",
    "httpx>=0.27",
]
```

## Decisions

1. **`python-jose` en lugar de `PyJWT`** — mejor soporte para el formato de JWT de Supabase (claims extra como `aud`).
2. **`pydantic-settings` para config** — pattern estándar de FastAPI, carga `.env` automáticamente, type-safe.
3. **WebSocket auth por query param** — los browsers no envían `Authorization` header en WS handshake; query param `?token=` es el patrón aceptado.
4. **`verify_aud: False`** — Supabase emite JWTs con `aud: "authenticated"` que no es una URL estándar; desactivar verificación de audience evita falsos 401.
5. **Sin Docker en este change** — el backend corre con `uvicorn` local. Dockerización es un change separado.
