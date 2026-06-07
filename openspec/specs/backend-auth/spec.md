# Spec: backend-auth

## Overview

Middleware de autenticación para FastAPI que valida JWTs emitidos por Supabase. FastAPI no emite tokens propios — actúa como resource server que verifica la firma del token.

## Requirements

### REQ-BA-01: Validación de JWT de Supabase
El middleware debe decodificar y verificar tokens usando `SUPABASE_JWT_SECRET` y algoritmo `HS256`.

### REQ-BA-02: Claims extraídos
Tras validación exitosa, el dependency debe retornar:
```python
{"user_id": str, "role": str}
```
Donde `user_id` = claim `sub` y `role` = claim `role` (default: `"authenticated"` si ausente).

### REQ-BA-03: Token inválido → 401
Si el token tiene firma incorrecta, ha expirado, o está malformado: HTTP 401 con body `{"detail": "Invalid token"}`.

### REQ-BA-04: Sin verificación de audience
Supabase emite `aud: "authenticated"` (string no-URL). La verificación de `aud` debe estar desactivada (`verify_aud: False`) para evitar falsos 401.

### REQ-BA-05: Header Bearer en HTTP, query param en WebSocket
- Endpoints HTTP: `Authorization: Bearer <token>`
- Endpoints WebSocket: query param `?token=<token>` (los browsers no envían headers custom en WS handshake)
