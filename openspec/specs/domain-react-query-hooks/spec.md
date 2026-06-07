# domain-react-query-hooks

## Purpose

Hooks React Query por dominio de negocio que reemplazan el God Object `DataContext`. Cada hook encapsula queries (GET) y mutations (CREATE/UPDATE/DELETE) contra la API Python via `lib/api/python-client.ts`, con invalidación de cache post-mutación. Los dominios `posts` e `insights` mantienen conexión directa a Supabase.

## Requirements

### Requirement: Hooks React Query por dominio en hooks/data/
El sistema SHALL proveer un hook React Query por cada dominio de negocio en `frontend/hooks/data/`. Cada hook SHALL encapsular queries (GET) y mutations (CREATE/UPDATE/DELETE) que llaman a la API Python via `lib/api/python-client.ts`. Los 8 hooks requeridos son: `useExpenses`, `useClients`, `useProducts`, `useBranches`, `useStock`, `useSales`, `usePurchases`, `useOrganizations`.

#### Scenario: useExpenses retorna la lista de gastos de la org activa
- **WHEN** un componente llama a `useExpenses()` con una sesión activa
- **THEN** retorna `{ expenses, isLoading, error }` con los datos filtrados por la org del usuario, obtenidos via `GET /expenses` de la API Python

#### Scenario: useSales.addSaleOperation crea una venta y invalida el cache
- **WHEN** se llama a `mutation.mutateAsync(payload)` desde `useSales`
- **THEN** el sistema ejecuta `POST /sales` con el payload y el Bearer token; en `onSuccess` invalida la query key `['sales', orgId]` forzando un refetch de la lista

#### Scenario: useProducts.deleteProduct invalida el cache post-delete
- **WHEN** se llama a `useProducts().deleteProduct(id)` y el servidor retorna 204
- **THEN** el cache de `['products', orgId]` se invalida y el componente refleja la lista actualizada sin el ítem borrado

#### Scenario: hook retorna isLoading=true durante el primer fetch
- **WHEN** un componente monta y llama a `useClients()` por primera vez
- **THEN** `isLoading` es `true` y `clients` es `[]` hasta que la API Python responde

#### Scenario: hook retorna error cuando la API responde 4xx/5xx
- **WHEN** la API Python retorna HTTP 503
- **THEN** el hook retorna `{ error: Error("..."), isLoading: false }` y el componente puede mostrar un mensaje de error

### Requirement: Query keys centralizadas en lib/query-keys.ts
El sistema SHALL centralizar todas las query keys de React Query en `frontend/lib/query-keys.ts`. Los hooks SHALL importar sus keys desde este archivo; no se permiten query keys inline en los hooks.

#### Scenario: Invalidación de ventas post-mutación usa la key centralizada
- **WHEN** `useSales().addSaleOperation` tiene éxito
- **THEN** `queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })` se ejecuta usando la key importada de `query-keys.ts`, no una string hardcodeada

#### Scenario: Dos hooks distintos que leen el mismo dominio comparten cache
- **WHEN** tanto `useProducts()` en el sidebar como `useProducts()` en la página de stock están montados
- **THEN** React Query usa la misma entrada de cache y solo realiza un fetch, no dos

### Requirement: Eliminación del DataContext (data-context.tsx)
El sistema SHALL eliminar `frontend/contexts/data-context.tsx` y `DataProvider`. Todos los consumidores de `useData()` SHALL migrar a los hooks individuales por dominio. El hook `useData` SHALL dejar de existir.

#### Scenario: No existe ningún import de data-context en el codebase post-migración
- **WHEN** se ejecuta `grep -r "data-context\|useData" frontend/` tras completar el change
- **THEN** no retorna ningún resultado — el archivo fue eliminado y todos sus consumidores migrados

#### Scenario: El layout de dashboard no incluye DataProvider
- **WHEN** se abre `frontend/app/(dashboard)/layout.tsx`
- **THEN** no hay referencia a `DataProvider`; los hooks de dominio se invocan directamente en los componentes que los necesitan

### Requirement: Posts e insights migran a hooks propios que siguen usando Supabase
El sistema SHALL extraer los datos de `posts` e `insights` del DataContext a sus propios hooks React Query que llaman directamente al cliente Supabase (no a la API Python). Estos dominios NO se migran a FastAPI.

#### Scenario: usePosts retorna posts de comunidad desde Supabase
- **WHEN** un componente llama a `usePosts()`
- **THEN** el hook consulta `supabase.from('posts').select(...)` y retorna `{ posts, isLoading, error }` via React Query

#### Scenario: useInsights retorna insights generados por IA desde Supabase
- **WHEN** un componente llama a `useInsights()`
- **THEN** el hook consulta `supabase.from('ai_insights').select(...)` y retorna los insights de la org activa

### Requirement: Load testing k6 — p95 ≤ 500ms en endpoints críticos con 50 usuarios concurrentes
El sistema SHALL incluir un script k6 (`frontend/tests/load/k6-baseline.js`) que pruebe `/sales` y `/products` con 50 usuarios virtuales concurrentes. El criterio de éxito SHALL ser p95 ≤ 500ms.

#### Scenario: k6 test pasa con p95 dentro del umbral
- **WHEN** se ejecuta `k6 run frontend/tests/load/k6-baseline.js` con el backend en Render (warm)
- **THEN** la salida de k6 reporta `http_req_duration{p(95)} ≤ 500ms` para `/sales` y `/products`

#### Scenario: k6 test falla si el backend está cold
- **WHEN** se ejecuta el test inmediatamente tras un período de inactividad (Render cold start)
- **THEN** el test puede fallar; la documentación del script SHALL indicar ejecutarlo tras un ping previo a `/health`
