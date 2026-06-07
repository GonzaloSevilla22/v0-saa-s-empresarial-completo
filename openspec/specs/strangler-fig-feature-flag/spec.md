# strangler-fig-feature-flag

## Purpose

Cliente HTTP `python-client.ts` para el frontend Next.js que inyecta automáticamente el JWT de la sesión Supabase en cada request al backend FastAPI. El Strangler Fig con feature flags fue completado en C-18 — los flags `NEXT_PUBLIC_USE_PYTHON_API*` han sido eliminados; el frontend siempre llama a la API Python.

## Requirements

### Requirement: Cliente HTTP del frontend para FastAPI
El sistema SHALL proveer un cliente HTTP liviano en `lib/api/python-client.ts` que:
- Lee `NEXT_PUBLIC_BACKEND_URL` como base URL
- Inyecta el Bearer token de la sesión Supabase en cada request
- Lanza un error si `NEXT_PUBLIC_BACKEND_URL` no está definida (no hay fallback a Supabase — ya no hay dos destinos)

#### Scenario: python-client inyecta el Bearer token automáticamente
- **WHEN** se llama `pythonClient.get("/expenses")` con una sesión Supabase activa
- **THEN** el request HTTP incluye `Authorization: Bearer <jwt>` extraído de `supabase.auth.getSession()`

#### Scenario: python-client lanza error si NEXT_PUBLIC_BACKEND_URL no está definida
- **WHEN** `NEXT_PUBLIC_BACKEND_URL` no está configurada
- **THEN** `python-client.ts` lanza `Error("NEXT_PUBLIC_BACKEND_URL es requerida")` en el momento de la llamada, sin fallback a Supabase

#### Scenario: python-client recibe 401 del backend y fuerza logout
- **WHEN** el backend FastAPI retorna HTTP 401 (token expirado o inválido)
- **THEN** `python-client` llama a `supabase.auth.signOut()` y redirige al login
