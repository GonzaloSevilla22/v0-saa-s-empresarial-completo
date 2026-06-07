# Tasks: fastapi-backend-monorepo

## Phase 1 — Folder Reorganization (HIGH governance — revisar antes de aplicar)

- [ ] **T-01** Crear directorio `frontend/` y mover todo el código Next.js
  - Mover: `app/`, `components/`, `hooks/`, `lib/`, `contexts/`, `providers/`, `public/`, `__tests__/`, `middleware.ts`, `next.config.mjs`, `tsconfig.json`, `tailwind.config.ts`, `postcss.config.mjs`, `components.json`, `next-env.d.ts`, `package.json`
  - **No mover**: `.git/`, `openspec/`, `knowledge-base/`, `CLAUDE.md`, `AGENTS.md`, `CHANGES.md`, `.gitignore`, `pnpm-workspace.yaml`, `node_modules/`
  - Mover `.env.local` a `frontend/.env.local`

- [ ] **T-02** Actualizar `pnpm-workspace.yaml` para apuntar a `frontend/`
  ```yaml
  packages:
    - 'frontend'
  ```

- [ ] **T-03** Actualizar `tsconfig.json` en `frontend/` — verificar que `paths @/*` sean relativos a `frontend/`
  ```json
  { "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["./*"] } } }
  ```

- [ ] **T-04** Verificar que `next build` pasa desde `frontend/` (sin errores de imports)

## Phase 2 — Backend Scaffold

- [ ] **T-05** Crear `backend/pyproject.toml` con dependencias
  ```toml
  [project]
  name = "emprende-smart-backend"
  version = "0.1.0"
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

  [tool.pytest.ini_options]
  asyncio_mode = "auto"
  ```

- [ ] **T-06** Crear `backend/requirements.txt` (generado desde pyproject para compatibilidad)

- [ ] **T-07** Crear `backend/.env.example`
  ```
  SUPABASE_JWT_SECRET=your-supabase-jwt-secret-here
  APP_ENV=development
  ```

## Phase 3 — Core Auth (TDD — CRITICAL governance)

- [ ] **T-08** [RED] Escribir `backend/tests/test_auth.py` — 3 casos:
  1. Token válido → retorna `{user_id, role}`
  2. Token inválido (firma incorrecta) → levanta `HTTPException 401`
  3. Token expirado → levanta `HTTPException 401`
  El archivo de producción `backend/core/auth.py` NO existe todavía.

- [ ] **T-09** [GREEN] Crear `backend/core/config.py` con `Settings(BaseSettings)`
  - Campo: `supabase_jwt_secret: str`
  - Campo: `app_env: str = "development"`

- [ ] **T-10** [GREEN] Crear `backend/core/auth.py` con `get_current_user(token)` mínimo que pasa T-08

- [ ] **T-11** [TRIANGULATE] Agregar caso 4 en `test_auth.py`: payload con `role` vacío → default a `"authenticated"`

- [ ] **T-12** [REFACTOR] Limpiar `auth.py` — extraer constante `ALGORITHM = "HS256"`

## Phase 4 — WebSocket Manager (TDD — MEDIUM governance)

- [ ] **T-13** [RED] Escribir `backend/tests/test_ws.py` — 2 casos:
  1. `connect` + `disconnect` → la room queda vacía
  2. `broadcast` a room con 1 cliente → cliente recibe el mensaje

- [ ] **T-14** [GREEN] Crear `backend/core/ws_manager.py` con `ConnectionManager`:
  - `connect(room_id, ws)`
  - `disconnect(room_id, ws)`
  - `broadcast(room_id, message: dict)`

- [ ] **T-15** [TRIANGULATE] Agregar caso: `broadcast` a room vacía → no lanza excepción

## Phase 5 — Routers y App Principal (TDD — LOW governance)

- [ ] **T-16** Crear `backend/tests/conftest.py` con fixtures:
  - `app` — FastAPI test app
  - `async_client` — `httpx.AsyncClient`
  - `valid_token` — JWT firmado con secret de test

- [ ] **T-17** [RED+GREEN] `backend/routers/health.py` — `GET /health` → `{"status": "ok"}`
  - Test: `test_health.py` → status 200 + body correcto

- [ ] **T-18** [RED+GREEN] `backend/routers/ws.py` — `WebSocket /ws/{room_id}`
  - Valida JWT via `get_current_user` (query param `?token=`)
  - Conecta al `ConnectionManager`
  - Loop de recepción de mensajes
  - Disconnect en cierre

- [ ] **T-19** Crear `backend/main.py`:
  ```python
  from fastapi import FastAPI
  from routers import health, ws

  app = FastAPI(title="EmprendeSmart Backend")
  app.include_router(health.router)
  app.include_router(ws.router)
  ```

## Phase 6 — Verificación Final

- [ ] **T-20** Ejecutar `pytest backend/tests/ -v` — todos los tests en verde

- [ ] **T-21** Ejecutar `pnpm --filter frontend build` desde la raíz — build de Next.js sin errores

- [ ] **T-22** Iniciar `uvicorn backend.main:app --reload` — servicio levanta sin errores

- [ ] **T-23** Actualizar `.gitignore` raíz:
  - Agregar: `backend/__pycache__/`, `backend/.venv/`, `backend/.env`, `frontend/.next/`

---

## Notas de Governance

- **Phase 1 (T-01)**: HIGH — mover archivos puede romper imports. Verificar con `next build` antes de continuar.
- **T-08/T-09/T-10**: CRITICAL — dominio auth. No escribir código de producción sin tests RED primero.
- **T-13/T-14**: MEDIUM — implementar con checkpoints entre RED y GREEN.
- Resto: LOW — autonomía completa si los tests pasan.
