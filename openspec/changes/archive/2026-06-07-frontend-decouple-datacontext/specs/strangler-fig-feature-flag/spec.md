## REMOVED Requirements

### Requirement: Feature flag NEXT_PUBLIC_USE_PYTHON_API controla el destino del tráfico
**Reason**: La migración Strangler Fig está completa. Todos los dominios de datos apuntan a la API Python. El DataContext (el enrutador del flag) se elimina. No hay nada que conmutar.
**Migration**: Eliminar `NEXT_PUBLIC_USE_PYTHON_API` de `.env.example`, `.env.local`, y de `lib/api/feature-flags.ts`. Los hooks de dominio llaman siempre a `python-client.ts`; no hay rama de Supabase en los hooks de datos.

### Requirement: Activación por sub-etapa sin restart completo
**Reason**: Los flags granulares por sub-etapa (`NEXT_PUBLIC_USE_PYTHON_API_ETAPA1`, etc.) pierden sentido una vez que el DataContext desaparece. No hay enrutador que los lea.
**Migration**: Eliminar las variables `NEXT_PUBLIC_USE_PYTHON_API_ETAPA*` de todos los entornos. La lógica de activación por sub-etapa en `lib/api/feature-flags.ts` se borra junto con el archivo o se reduce a solo las flags que sigan siendo necesarias.

## MODIFIED Requirements

### Requirement: Cliente HTTP del frontend para FastAPI
El sistema SHALL proveer un cliente HTTP liviano en `lib/api/python-client.ts` que:
- Lee `NEXT_PUBLIC_BACKEND_URL` como base URL
- Inyecta el Bearer token de la sesión Supabase en cada request
- Lanza un error si `NEXT_PUBLIC_BACKEND_URL` no está definida (el fallback a Supabase se elimina — ya no hay dos destinos)

#### Scenario: python-client inyecta el Bearer token automáticamente
- **WHEN** se llama `pythonClient.get("/expenses")` con una sesión Supabase activa
- **THEN** el request HTTP incluye `Authorization: Bearer <jwt>` extraído de `supabase.auth.getSession()`

#### Scenario: python-client lanza error si NEXT_PUBLIC_BACKEND_URL no está definida
- **WHEN** `NEXT_PUBLIC_BACKEND_URL` no está configurada
- **THEN** `python-client.ts` lanza `Error("NEXT_PUBLIC_BACKEND_URL es requerida")` en el momento de la llamada, sin fallback a Supabase

#### Scenario: python-client recibe 401 del backend y fuerza logout
- **WHEN** el backend FastAPI retorna HTTP 401 (token expirado o inválido)
- **THEN** `python-client` llama a `supabase.auth.signOut()` y redirige al login
