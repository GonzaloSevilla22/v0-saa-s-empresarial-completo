## 1. Infraestructura de hooks

- [x] 1.1 Crear `frontend/lib/api/query-keys.ts` con todas las query keys centralizadas para los 8 dominios (expenses, clients, products, branches, stock, sales, purchases, organizations) + posts + insights
- [x] 1.2 Verificar que `frontend/lib/api/python-client.ts` no tiene fallback a Supabase; actualizar para lanzar error si `NEXT_PUBLIC_BACKEND_URL` no está definida (eliminar rama de fallback del Strangler Fig)
- [x] 1.3 Crear `frontend/hooks/data/use-organizations.ts` — query + mutations (updateOrganization, inviteMember) via API Python

## 2. Hooks por dominio — datos principales

- [x] 2.1 Completar/crear `frontend/hooks/data/use-expenses-query.ts` → renombrar a `useExpenses` si es necesario; añadir mutations (addExpense, updateExpense, deleteExpense) con invalidación via query-keys.ts
- [x] 2.2 Crear `frontend/hooks/data/use-clients.ts` — queries + mutations (addClient, updateClient, deleteClient) via API Python
- [x] 2.3 Crear `frontend/hooks/data/use-products.ts` — queries + mutations (addProduct, updateProduct, deleteProduct) via API Python
- [x] 2.4 Completar `frontend/hooks/data/use-branches.ts` — añadir mutations si faltan; asegurarse que usa query-keys centralizadas
- [x] 2.5 Completar `frontend/hooks/data/use-branch-stock.ts` → renombrar export a `useStock` si corresponde; queries + mutations (transferStock) via API Python

## 3. Hooks por dominio — operaciones transaccionales

- [x] 3.1 Crear `frontend/hooks/data/use-sales.ts` — query de lista + mutations: `addSaleOperation` (idempotente, multi-ítem), `updateSale`, `deleteSale`, `deleteSalesByOperation`, `updateSaleOperation`; optimistic update en addSaleOperation
- [x] 3.2 Crear `frontend/hooks/data/use-purchases.ts` — query de lista + mutations: `addPurchaseOperation`, `updatePurchase`, `deletePurchase`, `deletePurchasesByOperation`, `updatePurchaseOperation`; mismo patrón que ventas

## 4. Hooks para dominios que siguen en Supabase

- [x] 4.1 Crear `frontend/hooks/data/use-posts.ts` — extrae lógica de posts del DataContext; usa `supabase.from('posts')` via React Query (no API Python)
- [x] 4.2 Crear `frontend/hooks/data/use-insights.ts` — extrae lógica de insights del DataContext; usa `supabase.from('ai_insights')` via React Query

## 5. Tests de los hooks

- [x] 5.1 Tests para `useExpenses`: hook retorna datos correctos mockeando `python-client`; addExpense invalida cache; error 503 retorna `{ error }` (TDD: RED → GREEN → TRIANGULATE)
- [x] 5.2 Tests para `useSales`: addSaleOperation llama a POST /sales con payload correcto; optimistic update aparece antes del settle; operación duplicada (idempotency_key) retorna operación previa
- [x] 5.3 Tests para `useProducts`: deleteProduct invalida cache post-204; useProducts en dos componentes comparte una sola entrada de cache (query-keys test)
- [x] 5.4 Tests para `useClients`, `usePurchases`, `useBranches`, `useStock`, `useOrganizations` — happy path + invalidación de cache (al menos 2 casos por hook)

## 6. Migración de consumidores del DataContext

- [x] 6.1 Buscar todos los usos de `useDataContext()` en `frontend/`: `grep -r "useDataContext\|DataContextProvider" frontend/` — documentar la lista completa
- [x] 6.2 Migrar consumidores de **expenses**: reemplazar `useDataContext()` con `useExpenses()` en cada componente; ejecutar `tsc --noEmit`
- [x] 6.3 Migrar consumidores de **clients**: reemplazar con `useClients()`; ejecutar `tsc --noEmit`
- [x] 6.4 Migrar consumidores de **products**: reemplazar con `useProducts()`; ejecutar `tsc --noEmit`
- [x] 6.5 Migrar consumidores de **branches + stock**: reemplazar con `useBranches()` / `useStock()`; ejecutar `tsc --noEmit`
- [x] 6.6 Migrar consumidores de **sales**: reemplazar con `useSales()`; ejecutar `tsc --noEmit`
- [x] 6.7 Migrar consumidores de **purchases**: reemplazar con `usePurchases()`; ejecutar `tsc --noEmit`
- [x] 6.8 Migrar consumidores de **organizations**: reemplazar con `useOrganizations()`; ejecutar `tsc --noEmit`
- [x] 6.9 Migrar consumidores de **posts + insights**: reemplazar con `usePosts()` / `useInsights()`; ejecutar `tsc --noEmit`

## 7. Eliminación del DataContext y feature flags

- [x] 7.1 Eliminar `DataContextProvider` del layout de dashboard (`frontend/app/(dashboard)/layout.tsx`)
- [x] 7.2 Eliminar `frontend/contexts/data-context.tsx`
- [x] 7.3 Confirmar con `grep -r "data-context\|useDataContext" frontend/` que no quedan referencias
- [x] 7.4 Eliminar lógica de `NEXT_PUBLIC_USE_PYTHON_API` y `NEXT_PUBLIC_USE_PYTHON_API_ETAPA*` de `frontend/lib/api/feature-flags.ts`
- [x] 7.5 Actualizar `frontend/.env.example`: eliminar `NEXT_PUBLIC_USE_PYTHON_API*`; confirmar que `NEXT_PUBLIC_BACKEND_URL` está documentada

## 8. Acceso a docs del backend desde dev

- [x] 8.1 Agregar rewrite en `frontend/next.config.mjs` para dev: `{ source: '/api/backend-docs', destination: process.env.NEXT_PUBLIC_BACKEND_URL + '/docs' }`
- [ ] 8.2 Verificar que `GET /api/backend-docs` en dev redirige a la UI de Swagger del backend

## 9. Load testing con k6

- [x] 9.1 Crear `frontend/tests/load/k6-baseline.js` — 50 VUs, 1 minuto, endpoints `/sales` y `/products`; umbral `http_req_duration{p(95)} < 500`
- [ ] 9.2 Ejecutar k6 con el backend en Render (warm tras ping a `/health`) y confirmar que el umbral se cumple
- [ ] 9.3 Documentar el resultado en `frontend/tests/load/README.md` (fecha, ambiente, resultado p95)

## 10. Verificación final y limpieza de Edge Functions

- [x] 10.1 Ejecutar `pnpm build` en `frontend/` — 0 errores TypeScript, 0 warnings críticos
- [x] 10.2 Ejecutar `pnpm lint` en `frontend/` — 0 errores
- [ ] 10.3 Deploy a Vercel y verificar en producción: navegar por ventas, compras, gastos, productos, clientes, stock
- [ ] 10.4 Confirmar que no hay errores en Sentry/logs de Vercel en las primeras 15 minutos post-deploy
- [ ] 10.5 Borrar Edge Function `create-sale` desde el Supabase Dashboard (proyecto `gxdhpxvdjjkmxhdkkwyb`)
- [ ] 10.6 Borrar Edge Function `create-purchase` desde el Supabase Dashboard
- [ ] 10.7 Borrar Edge Function `delete-product` desde el Supabase Dashboard
- [x] 10.8 Marcar `[x]` en `CHANGES.md` para C-18
