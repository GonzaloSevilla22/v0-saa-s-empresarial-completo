## ADDED Requirements

### Requirement: Feature flag NEXT_PUBLIC_USE_PYTHON_API controla el destino del tráfico
El sistema SHALL leer la variable de entorno `NEXT_PUBLIC_USE_PYTHON_API` (booleano como string: `"true"` o `"false"`) en el frontend Next.js para determinar si las llamadas de datos se dirigen al backend FastAPI o al cliente Supabase original. El default SHALL ser `"false"` (tráfico a Supabase) para garantizar que cualquier deploy sin la variable configurada no rompe el comportamiento actual.

#### Scenario: Flag desactivado — tráfico va a Supabase como antes
- **WHEN** `NEXT_PUBLIC_USE_PYTHON_API` es `"false"` o no está definida
- **THEN** el `DataContext` y los hooks hacen las llamadas al cliente Supabase (`lib/supabase/client.ts`) igual que antes de C-16

#### Scenario: Flag activado — tráfico va a FastAPI
- **WHEN** `NEXT_PUBLIC_USE_PYTHON_API` es `"true"` y `NEXT_PUBLIC_BACKEND_URL` está configurada
- **THEN** el `DataContext` y los hooks hacen las llamadas HTTP al endpoint FastAPI en `NEXT_PUBLIC_BACKEND_URL`; el token Bearer se inyecta en el header `Authorization`

#### Scenario: Flag activado sin BACKEND_URL definida lanza error visible en dev
- **WHEN** `NEXT_PUBLIC_USE_PYTHON_API=true` pero `NEXT_PUBLIC_BACKEND_URL` no está definida
- **THEN** en runtime el cliente Python lanza un error con mensaje `"NEXT_PUBLIC_BACKEND_URL requerida cuando NEXT_PUBLIC_USE_PYTHON_API=true"`; en producción retorna los datos de Supabase como fallback y loguea el error

### Requirement: Cliente HTTP del frontend para FastAPI
El sistema SHALL proveer un cliente HTTP liviano en `lib/api/python-client.ts` que:
- Lee `NEXT_PUBLIC_BACKEND_URL` como base URL
- Inyecta el Bearer token de la sesión Supabase en cada request
- Sigue el mismo shape de respuesta que las funciones de `lib/services/` actuales (para que los hooks no necesiten cambios en C-16)

#### Scenario: python-client inyecta el Bearer token automáticamente
- **WHEN** se llama `pythonClient.get("/expenses")` con una sesión Supabase activa
- **THEN** el request HTTP incluye `Authorization: Bearer <jwt>` extraído de `supabase.auth.getSession()`

#### Scenario: python-client retorna los datos en el mismo shape que el servicio Supabase
- **WHEN** se llama `pythonClient.get("/expenses")` y el servidor retorna `{"items": [...], "total": N}`
- **THEN** el caller recibe el mismo objeto que recibiría de `lib/services/expenseService.ts`, sin transformación adicional en el hook

#### Scenario: python-client recibe 401 del backend y fuerza logout
- **WHEN** el backend FastAPI retorna HTTP 401 (token expirado o inválido)
- **THEN** `python-client` llama a `supabase.auth.signOut()` y redirige al login, igual que el flujo de auth error actual

### Requirement: Activación por sub-etapa sin restart completo
El sistema SHALL permitir que el feature flag se active de forma independiente por sub-etapa via variables de entorno granulares opcionales. Si no están definidas, heredan el valor de `NEXT_PUBLIC_USE_PYTHON_API`.

#### Scenario: Sub-etapa 1 activa, sub-etapas 2 y 3 desactivadas
- **WHEN** `NEXT_PUBLIC_USE_PYTHON_API=false`, `NEXT_PUBLIC_USE_PYTHON_API_ETAPA1=true`
- **THEN** expenses y clients llaman a FastAPI; products, branches, stock, sales, purchases siguen en Supabase

#### Scenario: Flag global activa todas las sub-etapas sin variables granulares
- **WHEN** `NEXT_PUBLIC_USE_PYTHON_API=true` y no hay variables `_ETAPA*` definidas
- **THEN** los 8 dominios llaman a FastAPI
