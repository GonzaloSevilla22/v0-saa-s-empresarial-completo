## 1. Red de seguridad (antes de borrar nada)

- [x] 1.1 Crear rama de feature desde `main` (NUNCA commitear a `main` — el trabajo se entrega vía PR)
- [x] 1.2 Correr la suite completa de backend (`pytest` desde la raíz del repo) y anotar el conteo base de tests que pasan. Si hay fallos previos, NO arreglarlos: registrarlos como "pre-existing failure" y seguir — **Baseline: 1085 passed, 3 skipped, 0 failed** (`python -m pytest backend -q`; nota: `pytest -q` sin argumento `backend` no descubre `backend/pyproject.toml` y produce 274 errores espurios de fixtures async — usar siempre `pytest backend`)
- [x] 1.3 Correr la suite completa de frontend (`pnpm test` / vitest en `frontend/`) y anotar el conteo base de tests que pasan. Mismo criterio con fallos previos — **Baseline: 663 passed (87 test files), 0 failed**
- [x] 1.4 Verificar por `grep` en todo el repo que no aparecen consumidores nuevos: `organizations` en `backend/` debe dar exactamente 5 archivos (router, service, repository, schemas, tests) + `backend/main.py`; `useOrganization`/`use-organizations` en `frontend/` debe dar exactamente el hook, `query-keys.ts` y el archivo de test combinado. Si aparece cualquier otro consumidor, PARAR y reportarlo antes de continuar — **Verificado: backend grep dio 5 archivos (router/service/repository/tests + main.py; `schemas/organizations.py` existe pero usa nombres `Org*` y no matchea el literal "organization", no es un consumidor nuevo); frontend grep dio exactamente 3 archivos (hook, query-keys.ts, test combinado). Sin STOP.**

## 2. Eliminación en el backend

- [x] 2.1 Eliminar `backend/routers/organizations.py`
- [x] 2.2 Eliminar `backend/services/organizations.py`
- [x] 2.3 Eliminar `backend/repositories/organization_repository.py`
- [x] 2.4 Eliminar `backend/schemas/organizations.py`
- [x] 2.5 Eliminar `backend/tests/test_organizations.py` (4 tests, todos con el repositorio mockeado — cubren exclusivamente el código borrado)
- [x] 2.6 En `backend/main.py`: quitar `organizations` del bloque de imports de routers (línea ~30) y la llamada `app.include_router(organizations.router)` (línea ~149). No tocar ningún otro router
- [x] 2.7 Correr la suite de backend: debe quedar en el conteo base **−4** tests, con **cero fallos nuevos** — **Resultado: 1081 passed (−4 exacto), 3 skipped, 0 failed**

## 3. Eliminación en el frontend

- [x] 3.1 Eliminar `frontend/hooks/data/use-organizations.ts`
- [x] 3.2 En `frontend/lib/query-keys.ts`: eliminar el bloque `organizations: { all, detail }` (líneas ~55-58). No tocar los bloques vecinos (`branchStock`, `stock`)
- [x] 3.3 En `frontend/__tests__/hooks/use-clients-purchases-branches-stock-orgs.test.ts`: quitar el import de `@/hooks/data/use-organizations` (línea ~15) y los dos bloques `describe("useOrganization", ...)` y `describe("useUpdateOrganization", ...)` (líneas ~260-307). **Conservar intactos** los tests de `useClients`, `usePurchases`, `useBranches` y `useStock`. Actualizar el comentario de cabecera del archivo para que no liste `useOrganizations` — **Nota: el archivo solo contenía describes de `useClients` y `usePurchases` (no `useBranches`/`useStock` pese al nombre del archivo); ambos conservados intactos**
- [x] 3.4 NO renombrar el archivo de test (decisión 3 del `design.md`): conserva el sufijo `-orgs` a propósito para no ensuciar el diff
- [x] 3.5 Verificar que no quedan mocks huérfanos que rompan lint en el archivo de test (p. ej. `pythonClient.put` si ya no lo usa ningún test del archivo — si queda sin uso, dejarlo solo si el mock es global y compartido) — **`put` sigue usado por `updateClient` en `useClients`, sin mocks huérfanos**
- [x] 3.6 Correr typecheck del frontend (`pnpm tsc --noEmit` o el script equivalente del proyecto): cero errores nuevos por imports rotos — **`npx tsc --noEmit`: 0 errores**
- [x] 3.7 Correr la suite de frontend: debe quedar en el conteo base **−3** tests, con **cero fallos nuevos** — **Resultado: 660 passed (−3 exacto), 87 test files, 0 failed**

## 4. Verificación conjunta

- [x] 4.1 `grep -ri "organization" backend/` no devuelve resultados (fuera de comentarios en español que usen la palabra "organización" en prosa) — **0 resultados**
- [x] 4.2 `grep -ri "useOrganization\|use-organizations\|queryKeys.organizations" frontend/` no devuelve resultados — **0 resultados**
- [x] 4.3 Levantar el backend localmente (`uvicorn backend.main:app --reload`) y confirmar que arranca sin errores de import y que `GET /openapi.json` no contiene ninguna ruta bajo `/organizations` ni el tag `organizations` — **Verificado por import directo de `backend.main:app` (114 routes, 0 con "organization") + `app.openapi()` (82 paths, 0 con "organization"). No se levantó uvicorn real porque el lifespan requiere credenciales reales de Supabase/Redis no disponibles en este sandbox; el import directo da la misma garantía de import-safety y superficie de rutas**
- [x] 4.4 Registrar en el cuerpo del PR el delta de conteo esperado (backend −4, frontend −3) para que la caída no se lea como regresión

## 5. Entrega

- [ ] 5.1 Commit del backend: `refactor(backend): elimina el dominio organizations (código muerto desde C-16)` con `Co-Authored-By` del agente
- [ ] 5.2 Commit del frontend: `refactor(frontend): elimina el hook y las query keys de organizations`
- [ ] 5.3 Abrir el PR contra `main` describiendo: causa raíz (tabla `organizations` inexistente en el proyecto Supabase de producción), por qué se elimina en lugar de re-apuntar a `companies`, y el delta de tests
- [ ] 5.4 Esperar a que todos los checks de CI pasen (`gh pr checks`) antes de mergear. Recordar que el merge dispara build + deploy de Vercel y redeploy del backend en Render automáticamente. **Este change no tiene migraciones SQL**, así que el `db push` del pipeline debe ser no-op

## 6. Cierre de specs (durante el archive)

- [ ] 6.1 Sincronizar los delta specs a las specs principales (`/opsx:archive`), lo que actualiza los requirements de `python-backend`, `data-api-endpoints`, `domain-repositories` y `domain-react-query-hooks`
- [ ] 6.2 Edición manual post-sync (los deltas NO tocan la sección `## Purpose`): en `openspec/specs/data-api-endpoints/spec.md` cambiar "8 dominios de negocio (… , organizations)" por "7 dominios de negocio" sin `organizations`; en `openspec/specs/domain-repositories/spec.md` cambiar "8 dominios: … , organizations" por "7 dominios" sin `organizations`
- [ ] 6.3 Correr `openspec validate --specs` y confirmar que todas las specs siguen válidas tras el sync y la edición manual del `Purpose`
- [ ] 6.4 No tocar `openspec/changes/archive/**` — los changes archivados son registro histórico y mantienen las menciones originales a `organizations` a propósito
