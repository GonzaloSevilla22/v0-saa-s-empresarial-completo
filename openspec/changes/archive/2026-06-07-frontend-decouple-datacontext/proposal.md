## Why

El `DataContext` (`contexts/data-context.tsx`) es un God Object de cliente que concentra toda la lógica de fetching, mutaciones y estado del servidor en un solo contexto React. Con la API Python (C-16) ya implementada y funcionando detrás de feature flags, el paso natural es eliminar este cuello de botella: reemplazarlo con hooks React Query por dominio, apagar los flags legacy y convertir el frontend en una UI pura que consume FastAPI para datos y Supabase solo para Realtime, Auth y Storage.

## What Changes

- **Eliminar `contexts/data-context.tsx`**: el God Object desaparece; sus consumidores migran a hooks de React Query
- **Crear hooks por dominio** (si no existen o son incompletos): `useExpenses()`, `useClients()`, `useProducts()`, `useBranches()`, `useStock()`, `useSales()`, `usePurchases()`, `useOrganizations()` — cada uno con queries + mutations que apuntan a la API Python
- **Apagar feature flags de migración** (`NEXT_PUBLIC_USE_PYTHON_API`): el DataContext ya no es el router de tráfico; el destino es siempre FastAPI
- **Borrar Edge Functions de datos migradas**: `create-sale`, `create-purchase`, `delete-product` — estas fueron migradas a Python en C-16; mantenerlas activas es dead code con riesgo de split-brain
- **Mantener intacto** todo lo que sigue en Supabase: suscripciones Realtime (`supabase.channel(...).on(...)`), `supabase.auth.*`, Storage (signed URLs), y las Edge Functions de IA/OCR (DEC-15)
- **Load testing con k6**: 50 usuarios concurrentes → p95 ≤ 500ms en `/sales`, `/products`
- **Proxy Next.js → backend docs**: `/docs` en el frontend redirecciona a `/docs` de FastAPI en dev

## Capabilities

### New Capabilities
- `domain-react-query-hooks`: Hooks React Query por dominio (8 dominios) que encapsulan queries + mutations contra la API Python, con invalidación automática post-mutación y optimistic updates donde corresponde

### Modified Capabilities
- `data-api-endpoints`: Los endpoints de la API Python que C-16 introdujo dejan de estar detrás de feature flag; ahora son el único camino de datos. El contrato de la spec no cambia, pero la condición de activación (flag) desaparece.
- `strangler-fig-feature-flag`: El flag `NEXT_PUBLIC_USE_PYTHON_API` se apaga y se elimina. La migración Strangler Fig está completa para los dominios de datos.

## Impact

- **Archivos eliminados**: `contexts/data-context.tsx`, `supabase/functions/create-sale/`, `supabase/functions/create-purchase/`, `supabase/functions/delete-product/`
- **Archivos creados/modificados**: hooks en `hooks/` (uno por dominio), `lib/api/` (cliente HTTP hacia FastAPI, ya creado en C-16 o a crear aquí), componentes que hoy consumen el DataContext
- **Variables de entorno**: `NEXT_PUBLIC_USE_PYTHON_API` se retira; `NEXT_PUBLIC_PYTHON_API_URL` sigue vigente (ya configurada en C-16)
- **Sin cambios en**: esquema Supabase, migraciones SQL, RLS, Edge Functions de IA/OCR, WebSocket del backend (reservado para el futuro, DEC-16)
- **Dependencia**: C-16 debe estar completo y en producción con paridad validada antes de ejecutar este change
