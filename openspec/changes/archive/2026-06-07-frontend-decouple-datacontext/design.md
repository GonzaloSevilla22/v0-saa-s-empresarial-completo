## Context

El `DataContext` (`frontend/contexts/data-context.tsx`, 886 líneas) es un God Object que:
- Carga todos los datos de todos los dominios en memoria al iniciar la sesión
- Expone mutaciones síncronas a toda la app vía un único contexto React
- Mezcla fetching, caching, invalidación y estado de UI en una sola capa
- Hoy despacha tráfico al backend Python o a Supabase según el flag `NEXT_PUBLIC_USE_PYTHON_API` (implementado en C-16)

Con C-16 completo y el flag validado en producción, este change elimina el DataContext y el flag: el frontend pasa a consumir la API Python directamente via React Query, igual que los hooks de dominio ya existentes (`hooks/data/use-branches.ts`, `use-expenses-query.ts`, etc.).

El frontend ya tiene `lib/api/python-client.ts` (cliente HTTP con JWT-passthrough) y `lib/api/feature-flags.ts` (lectura de flags). TanStack React Query ya está configurado en el proyecto (`@tanstack/react-query` v5).

## Goals / Non-Goals

**Goals:**
- Eliminar `data-context.tsx` y todos sus consumidores; reemplazar con 8 hooks React Query por dominio
- Apagar y eliminar la lógica del feature flag `NEXT_PUBLIC_USE_PYTHON_API`
- Borrar Edge Functions de datos migradas: `create-sale`, `create-purchase`, `delete-product`
- Dejar el frontend como UI pura: React Query para datos, Supabase solo para Realtime/Auth/Storage
- Mantener paridad funcional completa; no perder ninguna mutación ni query que hoy el DataContext expone

**Non-Goals:**
- Cambiar el esquema de la API Python (eso fue C-16)
- Migrar las Edge Functions de IA/OCR (DEC-15 — pospuesto)
- Implementar el WebSocket del backend en producción (DEC-16 — reservado para el futuro)
- Migrar las suscripciones Supabase Realtime (se mantienen igual)
- Cambiar el modelo de autenticación

## Decisions

### D-01 — Un hook por dominio en `hooks/data/`
Cada dominio de negocio (expenses, clients, products, branches, stock, sales, purchases, organizations) tendrá su propio archivo de hook en `frontend/hooks/data/`. Los hooks existentes (`use-branches.ts`, `use-branch-stock.ts`, `use-expenses-query.ts`) se extienden o reemplazan; el patrón se unifica.

**Alternativa descartada**: mantener el DataContext y hacerlo consumir React Query internamente. Esto solo mueve el problema: sigue siendo un God Object aunque sea "reactivo". La deuda crece con el tiempo.

**Por qué un hook por dominio**: alineado con el patrón ya establecido en el proyecto (hooks/data existentes), permite tree-shaking, y cada componente importa solo lo que necesita.

### D-02 — QueryKeys centralizadas en `lib/api/query-keys.ts`
Todas las query keys de React Query se definen en un único archivo `frontend/lib/api/query-keys.ts` para evitar duplicaciones y garantizar que la invalidación post-mutación funcione correctamente. Ejemplo:
```ts
export const queryKeys = {
  expenses: { all: ['expenses'] as const, list: (orgId: string) => ['expenses', orgId] as const },
  sales:    { all: ['sales'] as const, list: (orgId: string, from?: string, to?: string) => ['sales', orgId, from, to] as const },
  // ...
}
```

### D-03 — Invalidación optimista vs. refetch post-mutación
Para mutaciones simples (add/update/delete expense, client, product): `queryClient.invalidateQueries` post-mutación — suficiente dado que las operaciones son rápidas y el cold start de Render ya está mitigado con ping a `/health`.

Para `addSaleOperation` / `addPurchaseOperation`: optimistic update parcial en el cache de la lista + invalidación completa en `onSettled`, igual al patrón actual del DataContext pero sin el array mutable en memoria.

**Alternativa descartada**: optimistic updates en todos los casos. Más complejo, riesgo de state divergence en operaciones atómicas multi-tabla. No vale la complejidad para el volumen actual.

### D-04 — Eliminación del DataContext en dos pasos dentro del mismo PR
1. Crear todos los hooks de dominio con sus tests
2. Migrar todos los consumidores de `useDataContext()` a los hooks individuales
3. Eliminar `data-context.tsx` y el `DataContextProvider` del layout

No se usa un feature flag para esta transición — la migración es dentro del mismo change y es atómica (un PR, un deploy). El feature flag de C-16 ya validó la paridad de la API Python; este change no añade riesgo de regresión en datos.

### D-05 — Borrar Edge Functions solo tras deploy exitoso
El orden de operaciones es:
1. Deploy del frontend sin DataContext (Vercel)
2. Verificar en producción que todo funciona
3. Borrar Edge Functions `create-sale`, `create-purchase`, `delete-product` (Supabase Dashboard)

Las Edge Functions no se borran antes del deploy por seguridad. Si hay un rollback del frontend, las funciones siguen disponibles como fallback.

### D-06 — Proxy a /docs del backend desde Next.js en dev
Agregar una rewrite en `next.config.mjs` para dev:
```js
{ source: '/api/backend-docs', destination: `${process.env.NEXT_PUBLIC_BACKEND_URL}/docs` }
```
En producción no es necesario — los devs pueden abrir `NEXT_PUBLIC_BACKEND_URL/docs` directamente.

## Risks / Trade-offs

**[Re-renderizado masivo durante la transición]** → Los componentes que hoy consumen el DataContext se re-renderizan por cualquier cambio en cualquier dominio. Al migrar a hooks individuales se reduce el re-renderizado innecesario, pero el cambio de dependencias puede descubrir componentes que dependían implícitamente del estado global. Mitigación: migrar dominio por dominio dentro del mismo PR, corriendo el linter y type-checker después de cada dominio.

**[Prop drilling en componentes de carrito]** → Los formularios de nueva venta y nueva compra hoy acceden a `products`, `clients`, `branches` via DataContext simultáneamente. Con hooks individuales el componente debe llamar a 3 hooks. Mitigación: esto es explicitamente más claro; no es un problema real, pero el reviewer debe saberlo.

**[Cold start de Render]** → En producción, el primer request al backend tras 15 min de inactividad tiene ~50s de latency. React Query mostrará loading state durante ese tiempo. Mitigación: el cron ping a `/health` (ya recomendado en C-15/C-16) debe estar activo. Si no está, configurarlo como parte de este change.

**[Estado de `posts` e `insights` en el DataContext]** → El DataContext también maneja `posts` (comunidad) e `insights` (IA). Los posts NO migran a la API Python (no son parte de C-16). Mitigación: los hooks de `posts` e `insights` siguen consumiendo Supabase directamente — esto es correcto y no contradice la arquitectura. El DataContext se reemplaza por hooks, no necesariamente todos apuntando a FastAPI.

## Migration Plan

1. **Crear `lib/api/query-keys.ts`** con todas las query keys centralizadas
2. **Crear/completar hooks por dominio** en `hooks/data/` — orden recomendado por riesgo ascendente: expenses → clients → products → branches → stock → sales → purchases → organizations
3. **Migrar consumidores** dominio por dominio: buscar `useDataContext()` en cada página/componente y reemplazar con los hooks individuales. `tsc --noEmit` y `next lint` tras cada dominio.
4. **Eliminar** `DataContextProvider` del layout y `data-context.tsx`
5. **Eliminar lógica de feature flags de migración**: remover `NEXT_PUBLIC_USE_PYTHON_API` de `feature-flags.ts` y de `python-client.ts`; actualizar `.env.example`
6. **Deploy a Vercel** — verificar en producción
7. **Borrar Edge Functions** `create-sale`, `create-purchase`, `delete-product` desde el Supabase Dashboard

**Rollback**: si hay regresión tras el deploy, el rollback en Vercel restaura el build anterior con el DataContext intacto. Las Edge Functions no se borran hasta confirmar estabilidad.

## Open Questions

- **¿El ping a `/health` de Render ya está configurado?** Si no, debe incluirse en este change (puede ser un cron de Vercel o un servicio externo como UptimeRobot).
- **¿`posts` e `insights` del DataContext también salen del God Object?** La propuesta los migra a hooks propios que siguen consumiendo Supabase — hay que confirmar con el equipo que no se espera migrarlos a Python en este change.
- **¿Tests E2E con Playwright para el camino feliz de venta/compra?** El change incluye load testing con k6 pero no especifica tests E2E de UI. Recomendado agregar al menos un test Playwright para el flujo de nueva venta post-migración.
