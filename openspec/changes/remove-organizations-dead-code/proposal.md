## Why

El dominio `organizations` del backend FastAPI **nunca funcionó**: `backend/repositories/organization_repository.py` consulta una tabla `organizations` que **no existe** en el proyecto Supabase de producción (`gxdhpxvdjjkmxhdkkwyb`). Producción tiene `companies` (legacy) y `accounts` (la raíz de tenancy real desde V2). Cualquier llamada a `GET /organizations/{org_id}` o `PUT /organizations/{org_id}/settings` falla con `asyncpg.UndefinedTableError` desde que se creó el dominio en C-16 (2026-06-07). El fallo pasó inadvertido porque `backend/tests/test_organizations.py` mockea el repositorio y por eso los tests siempre pasaron en verde.

Del lado del frontend, el hook `useOrganization` / `useUpdateOrganization` no lo consume ninguna página ni componente: su único importador es el propio archivo de test. Es decir: dos capas completas (5 archivos de backend + 1 hook de frontend + su bloque de query keys) de código muerto que además **mienten** — las specs declaran 9 routers y 8 dominios como si `organizations` fuera un dominio operativo, lo que induce a error a cualquier agente o desarrollador que lea la spec como fuente de verdad.

## What Changes

- **Eliminar** la cadena completa del dominio `organizations` en el backend FastAPI: router, service, repository, schemas y su archivo de tests, más el import y el `include_router` en `backend/main.py`.
- **Eliminar** el hook `frontend/hooks/data/use-organizations.ts` (`useOrganization` + `useUpdateOrganization`) y el bloque de keys `organizations` en `frontend/lib/query-keys.ts`.
- **Eliminar** los `describe` de `useOrganization` y `useUpdateOrganization` en `frontend/__tests__/hooks/use-clients-purchases-branches-stock-orgs.test.ts`, conservando intactos los tests de los otros cuatro hooks del archivo.
- **Actualizar las specs** para que los conteos y las listas de dominios reflejen la realidad post-eliminación (8 routers registrados, 7 dominios de endpoints, 7 repositorios concretos, 7 hooks React Query).
- **NO BREAKING**: no hay consumidores. Los endpoints `/organizations/*` respondían 500 (`UndefinedTableError`) desde su creación; ningún componente, página ni cliente externo los usa. No hay migraciones de base de datos ni cambios de contrato para clientes en producción.

## Capabilities

### New Capabilities

Ninguna. Este change solo retira código muerto y corrige specs existentes.

### Modified Capabilities

- `python-backend`: el requirement "Routers de datos registrados en main.py" pasa de 9 a 8 routers de dominio — se quita `organizations.router` de la lista y del escenario de Swagger.
- `data-api-endpoints`: el Purpose y el requirement "Routers FastAPI por dominio con Pydantic v2 schemas" pasan de 8 a 7 dominios — se quita el prefijo `/organizations`.
- `domain-repositories`: el Purpose y el requirement "Repositorios concretos por dominio extienden BaseRepository" pasan de 8 a 7 dominios — se quita `OrganizationRepository`.
- `domain-react-query-hooks`: el requirement "Hooks React Query por dominio en hooks/data/" pasa de 8 a 7 hooks — se quita `useOrganizations`.

## Impact

**Backend (eliminado):**
- `backend/routers/organizations.py`
- `backend/services/organizations.py`
- `backend/repositories/organization_repository.py`
- `backend/schemas/organizations.py`
- `backend/tests/test_organizations.py`
- `backend/main.py` — import (línea ~30) y `app.include_router(organizations.router)` (línea ~149)

**Frontend (eliminado):**
- `frontend/hooks/data/use-organizations.ts`
- `frontend/lib/query-keys.ts` — bloque `organizations` (líneas ~55-58)
- `frontend/__tests__/hooks/use-clients-purchases-branches-stock-orgs.test.ts` — import + 2 bloques `describe`

**Specs (modificadas):** `python-backend`, `data-api-endpoints`, `domain-repositories`, `domain-react-query-hooks`.

**Sin impacto:** base de datos (cero migraciones), auth, billing, RLS, Edge Functions, contratos con clientes en producción. La superficie de API pública se reduce en 2 endpoints que solo devolvían error 500.

**Riesgo:** bajo. El único riesgo real es que la suite de tests baje su conteo total (backend −N tests de `test_organizations.py`, frontend −3 tests); se documenta el delta esperado en `tasks.md` para que no se confunda con una regresión.
