# Spec: python-backend

## Overview

Servicio FastAPI independiente del frontend Next.js. Corre como proceso separado, expone una API HTTP + WebSocket, y se integra con Supabase como fuente de verdad de la base de datos.

## Requirements

### REQ-PB-01: Estructura de proyecto
El backend debe organizarse en:
- `backend/main.py` — punto de entrada FastAPI
- `backend/routers/` — handlers HTTP y WebSocket
- `backend/core/` — config, auth, ws_manager
- `backend/tests/` — suite pytest

### REQ-PB-02: Configuración via entorno
Toda configuración sensible (secrets, URLs) debe cargarse desde variables de entorno usando `pydantic-settings`. Sin valores hard-codeados en código fuente.

### REQ-PB-03: Health check
`GET /health` debe retornar `{"status": "ok"}` con HTTP 200. Sin autenticación requerida.

### REQ-PB-04: Ejecutable con uvicorn
El servicio debe poder iniciarse con:
```bash
uvicorn backend.main:app --reload
```
desde la raíz del proyecto.

### REQ-PB-05: Tests cubren happy path y error path
Cada router debe tener al mínimo: 1 test de happy path + 1 test de error (auth fallida, input inválido).
