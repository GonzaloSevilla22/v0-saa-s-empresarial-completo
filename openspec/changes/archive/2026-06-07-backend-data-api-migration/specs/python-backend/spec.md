## ADDED Requirements

### Requirement: Routers de datos registrados en main.py
El sistema SHALL registrar los 8 routers de dominio (expenses, clients, products, branches, stock, sales, purchases, organizations) en `backend/main.py` con sus prefijos correspondientes y el tag OpenAPI apropiado.

#### Scenario: Todos los routers de datos responden tras startup
- **WHEN** la app arranca correctamente con pool y Redis inicializados
- **THEN** `GET /docs` lista todos los endpoints de expenses, clients, products, branches, stock, sales, purchases y organizations en la UI de Swagger

#### Scenario: Exception handler global captura errores asyncpg
- **WHEN** cualquier endpoint lanza `asyncpg.PostgresError` no manejado explícitamente
- **THEN** el exception handler registrado en `main.py` lo convierte en respuesta HTTP con código y mensaje apropiado según `core/errors.py`

### Requirement: CORS configurado para el dominio Vercel
El sistema SHALL configurar CORS en FastAPI para aceptar requests del dominio frontend (`NEXT_PUBLIC_FRONTEND_URL` de entorno, con fallback a `*` en desarrollo). Solo métodos HTTP seguros y con credenciales para los dominios permitidos.

#### Scenario: Request desde Vercel con Origin correcto pasa CORS
- **WHEN** el frontend en `https://empresarial.vercel.app` hace un request a FastAPI con el header `Origin: https://empresarial.vercel.app`
- **THEN** FastAPI incluye `Access-Control-Allow-Origin: https://empresarial.vercel.app` en la respuesta y el browser no bloquea la llamada

#### Scenario: Request OPTIONS preflight retorna 200 con headers CORS
- **WHEN** el browser envía un preflight `OPTIONS /expenses`
- **THEN** FastAPI retorna HTTP 200 con los headers `Access-Control-Allow-Methods`, `Access-Control-Allow-Headers` correctos
