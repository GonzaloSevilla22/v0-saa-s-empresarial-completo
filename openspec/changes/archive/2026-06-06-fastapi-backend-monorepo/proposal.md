## Why

El proyecto EmprendeSmart necesita capacidades de tiempo real (notificaciones push, actualizaciones de dashboard en vivo) y lógica de dominio pesada (procesamiento IA, pipelines de datos) que Next.js + Supabase Edge Functions no cubren bien: las Edge Functions tienen límites de tiempo de ejecución, no soportan WebSockets persistentes, y mezclar lógica de servidor con el frontend en el mismo proceso dificulta testear y escalar. Un backend Python/FastAPI desacoplado resuelve estos tres problemas a la vez.

## What Changes

- **BREAKING** — Reorganización de carpetas: todo el código Next.js actual se mueve a `frontend/`, el nuevo backend Python va en `backend/`.
- Nuevo servicio FastAPI en `backend/` con estructura de routers, modelos y tests.
- Validación de JWTs emitidos por Supabase (usando `SUPABASE_JWT_SECRET`) — FastAPI no emite tokens propios.
- Endpoint WebSocket (`/ws/{room_id}`) para notificaciones en tiempo real al frontend.
- Suite de tests con `pytest` + `httpx` (AsyncClient) cubriendo auth, routers y WebSocket.
- Configuración de monorepo: `pnpm-workspace.yaml` para frontend, `pyproject.toml` para backend.
- Variables de entorno separadas: `.env` raíz compartida + `.env.local` para frontend, `backend/.env` para el servicio Python.

## Capabilities

### New Capabilities

- `python-backend`: Servicio FastAPI con estructura de routers, JWT validation middleware, WebSocket manager y configuración del proyecto Python.
- `realtime-websocket`: Canal WebSocket para broadcast de eventos en tiempo real a clientes suscritos (por room/tenant).
- `backend-auth`: Middleware FastAPI que valida JWTs de Supabase y extrae el `user_id` y `role` para autorización.

### Modified Capabilities

<!-- No hay specs existentes que modifiquen requisitos — esto es adición pura -->

## Impact

- **Código**: Todos los paths de import del frontend cambian de `@/` (relativo a raíz) a `@/` (relativo a `frontend/`) — requiere actualizar `tsconfig.json`, `next.config.mjs`, `tailwind.config.ts`.
- **CI/CD**: Vercel necesita `rootDirectory: frontend` en su configuración. El backend requiere un proceso separado (Docker / Railway / Cloud Run).
- **Dependencias nuevas**: `fastapi`, `uvicorn`, `python-jose[cryptography]`, `httpx`, `pytest`, `pytest-asyncio`, `websockets`.
- **Env vars**: `SUPABASE_JWT_SECRET` debe estar disponible en el backend.
- **pnpm-workspace**: Actualizar para que apunte solo a `frontend/`.
