## MODIFIED Requirements

### Requirement: Routers de datos registrados en main.py
El sistema SHALL registrar los 8 routers de dominio (expenses, clients, products, branches, stock, sales, purchases, payments) en `backend/main.py` con sus prefijos correspondientes y el tag OpenAPI apropiado.

Routers registrados:
- `health.router`
- `ws.router`
- `expenses.router` (prefix `/expenses`)
- `clients.router` (prefix `/clients`)
- `products.router` (prefix `/products`)
- `branches.router` (prefix `/branches`)
- `stock.router` (prefix `/stock`)
- `sales.router` (prefix `/sales`)
- `purchases.router` (prefix `/purchases`)
- `payments.router` (prefix `/payments`) ← C-17

> El router `organizations` fue retirado en `remove-organizations-dead-code`: apuntaba a una tabla `organizations` inexistente en producción y sus dos endpoints devolvían HTTP 500 desde C-16.

#### Scenario: Todos los routers de datos responden tras startup
- **WHEN** la app arranca correctamente con pool inicializado (Redis es opcional)
- **THEN** `GET /docs` lista todos los endpoints de expenses, clients, products, branches, stock, sales, purchases y payments en la UI de Swagger

#### Scenario: No hay router de organizations registrado
- **WHEN** la app arranca y se inspecciona `GET /openapi.json`
- **THEN** no existe ninguna ruta bajo el prefijo `/organizations` ni el tag OpenAPI `organizations`

## ADDED Requirements

### Requirement: El dominio organizations no existe en el backend
El backend SHALL no contener módulos, rutas ni repositorios del dominio `organizations`, porque nunca tuvo una tabla que lo respaldara en producción y su reintroducción reintroduciría endpoints rotos.

La raíz de tenancy del sistema es `accounts` (adoptada en C-19 `v2-tenancy-cleanup`); `companies` es legacy. No existe ni existió una tabla `organizations` en el proyecto Supabase de producción. Cualquier necesidad futura de editar datos de la cuenta SHALL modelarse sobre `accounts` en un change propio, con su consumidor, su matriz de roles y su spec.

#### Scenario: No quedan módulos del dominio organizations en el árbol del backend
- **WHEN** se buscan los archivos `backend/routers/organizations.py`, `backend/services/organizations.py`, `backend/repositories/organization_repository.py`, `backend/schemas/organizations.py` y `backend/tests/test_organizations.py`
- **THEN** ninguno de los cinco existe en el repositorio

#### Scenario: main.py no importa el módulo organizations
- **WHEN** se inspecciona `backend/main.py`
- **THEN** no aparece `organizations` en el bloque de imports de routers ni ninguna llamada `app.include_router(organizations.router)`, y la app arranca sin errores de import
