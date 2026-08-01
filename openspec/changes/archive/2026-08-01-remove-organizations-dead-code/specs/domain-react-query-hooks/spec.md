## MODIFIED Requirements

### Requirement: Hooks React Query por dominio en hooks/data/
El sistema SHALL proveer un hook React Query por cada dominio de negocio en `frontend/hooks/data/`. Cada hook SHALL encapsular queries (GET) y mutations (CREATE/UPDATE/DELETE) que llaman a la API Python via `lib/api/python-client.ts`. Los 7 hooks requeridos son: `useExpenses`, `useClients`, `useProducts`, `useBranches`, `useStock`, `useSales`, `usePurchases`.

`useOrganizations` (`frontend/hooks/data/use-organizations.ts`, con `useOrganization` y `useUpdateOrganization`) fue eliminado en `remove-organizations-dead-code`: no lo consumía ningún componente ni página — su único importador era su propio archivo de test — y los endpoints `/organizations/*` contra los que llamaba nunca existieron en la base de datos.

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

#### Scenario: No existe hook ni query key del dominio organizations
- **WHEN** se busca `use-organizations.ts` en `frontend/hooks/data/` y la entrada `organizations` en `frontend/lib/query-keys.ts`
- **THEN** ninguno de los dos existe, y ningún archivo del frontend importa `useOrganization` ni `useUpdateOrganization`
