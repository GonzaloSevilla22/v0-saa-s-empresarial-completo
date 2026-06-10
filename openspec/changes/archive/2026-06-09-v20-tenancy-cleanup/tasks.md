## 1. Safety Net — Baseline de tests

- [x] 1.1 Correr `pytest backend/tests/ -v` y documentar el resultado baseline (N tests passing); no continuar si hay fallos pre-existentes — reportar al PO
- [x] 1.2 Auditar columnas `user_id` en tablas ERP: listar cuáles son FK a `auth.users` vs. cuáles son solo filtro de tenancy (resultado define qué se dropea en paso 7)

## 2. DB — Backfill account_id y migración de companies (Paso 1 del plan)

- [x] 2.1 Crear migration SQL: completar NULLs de `account_id` en `sales`, `purchases`, `products`, `expenses`, `clients` via join con `account_members` por `user_id`
- [x] 2.2 Crear migration SQL: completar NULLs de `account_id` en `stock_movements` (tiene `user_id` y `account_id`)
- [x] 2.3 Crear migration SQL: agregar columna `account_id UUID REFERENCES accounts(id)` a `suppliers` (nullable inicialmente)
- [x] 2.4 Crear migration SQL: backfill `suppliers.account_id` via join `company_id → companies → company_users → account_members`
- [x] 2.5 Crear migration SQL: para cada fila en `companies`, verificar si sus usuarios ya tienen `account_id` en `account_members`; si no, crear `accounts` + `account_members` con role=owner; nunca duplicar cuentas existentes
- [x] 2.6 Verificar que la migration no genera NULLs residuales: queries `SELECT COUNT(*) FROM <tabla> WHERE account_id IS NULL` deben retornar 0 para todas las tablas listadas
- [x] 2.7 Aplicar migrations al proyecto `gxdhpxvdjjkmxhdkkwyb` via `npx supabase db push`; verificar en producción

## 3. DB — RLS de suppliers (Paso 2 del plan)

- [x] 3.1 Crear migration SQL: agregar políticas RLS a `suppliers` para SELECT, INSERT, UPDATE, DELETE usando `account_id = ANY(current_account_ids())` — alineadas con el patrón del resto de tablas ERP
- [x] 3.2 Aplicar migration al proyecto `gxdhpxvdjjkmxhdkkwyb` via `npx supabase db push`
- [ ] 3.3 Verificar: desde la UI, un usuario no puede ver suppliers de otro tenant

## 4. Backend Python — core/deps.py y core/auth.py (Paso 3 del plan)

- [x] 4.1 Correr baseline de tests antes de tocar cualquier archivo: `pytest backend/tests/ -v` — debe quedar igual al baseline del paso 1.1
- [x] 4.2 Actualizar `core/auth.py`: verificar si extrae `user_id` de JWT claims; documentar cómo se pasará `account_id` a la capa de repositorios
- [x] 4.3 Agregar dependency `get_account_id` en `core/deps.py`: ejecuta `SELECT account_id FROM account_members WHERE user_id = auth.uid() LIMIT 1` via la conexión JWT-passthrough; si no hay fila retorna `HTTPException(403)`
- [x] 4.4 Actualizar `backend/repositories/expense_repository.py`: reemplazar `WHERE user_id = $1` por `WHERE account_id = $1` en todas las queries (verificar con grep)
- [x] 4.5 Actualizar `backend/repositories/client_repository.py`: reemplazar filtro de tenancy `user_id` → `account_id`
- [x] 4.6 Actualizar `backend/repositories/product_repository.py`: reemplazar filtro de tenancy `user_id` → `account_id`
- [x] 4.7 Actualizar `backend/repositories/sales_repository.py`: reemplazar filtro de tenancy `user_id` → `account_id`
- [x] 4.8 Actualizar `backend/repositories/purchase_repository.py`: reemplazar filtro de tenancy `user_id` → `account_id`
- [x] 4.9 Actualizar `backend/repositories/branch_repository.py`: reemplazar filtro de tenancy `user_id` → `account_id`
- [x] 4.10 Actualizar `backend/repositories/stock_repository.py`: reemplazar `SELECT stock FROM products WHERE id = $1 AND user_id = $2` y similares para usar `account_id`
- [x] 4.11 Actualizar fixtures y mocks en `backend/tests/` para inyectar `account_id` en lugar de `user_id` como parámetro de tenancy
- [x] 4.12 Correr `pytest backend/tests/ -v` — debe pasar al 100%; si hay fallos, corregir antes de continuar
- [x] 4.13 Actualizar endpoints que exponen `user_id` como filtro explícito (si existen): usar `Depends(get_account_id)` en lugar de `Depends(get_current_user).id`
- [x] 4.14 Deploy backend en Render; verificar `/health` y smoke test de los endpoints principales

## 5. Edge Functions — actualizar filtro de tenancy (Paso 4 del plan)

- [x] 5.1 Actualizar `supabase/functions/ai-insights/index.ts`: solo INSERT audit trail en `ai_insights` — sin SELECT filter de tenancy, sin cambio necesario
- [x] 5.2 Actualizar `supabase/functions/ai-resumen/index.ts`: ya usa `auth.uid()` interno en RPCs (p_user_id removido en hardening previo)
- [x] 5.3 Actualizar `supabase/functions/ai-comparativo/index.ts`: solo INSERT audit trail — sin SELECT filter de tenancy
- [x] 5.4 Actualizar `supabase/functions/ai-simulador/index.ts`: ya usa `auth.uid()` interno en RPCs
- [x] 5.5 Actualizar `supabase/functions/ai-prediccion/index.ts`: ya usa `auth.uid()` interno en RPCs
- [x] 5.6 Actualizar `supabase/functions/ai-precio/index.ts`: reemplazado `.eq('user_id', user.id)` por `.eq('account_id', accountId)` en SELECT de `products` y `sales`; se obtiene `accountId` via `account_members`
- [x] 5.7 Actualizar `supabase/functions/ai-rentabilidad/index.ts`: solo INSERT audit trail — sin SELECT filter de tenancy
- [x] 5.8 Actualizar `supabase/functions/fair-advisor/index.ts`: solo INSERT — sin SELECT filter de tenancy
- [x] 5.9 Actualizar `supabase/functions/invoice-ocr/index.ts`: `invoice_documents` no está en scope de C-19 (tabla no migrada a account_id aún); filter `.eq('user_id', user.id)` correcto por ahora
- [x] 5.10 Actualizar `supabase/functions/generate-export/index.ts`: INSERT audit trail + RPC billing con p_user_id — sin SELECT filter de tenancy ERP
- [x] 5.11 Actualizar `supabase/functions/_shared/ai-quota.ts`: RPC de quota/billing con p_user_id — no es filtro de tenancy ERP
- [x] 5.12 Deploy de las 11 Edge Functions: `npx supabase functions deploy <nombre>` para cada una
- [x] 5.13 Smoke test de insights desde la UI: verificar que los insights se generan correctamente tras el cambio de filtro

## 6. Frontend hooks — actualizar query keys (Paso 5 del plan)

- [x] 6.1 Actualizar `frontend/hooks/data/use-products.ts`: query keys usan `queryKeys.products.lists()` (sin user_id); añadido `account_id: string` e `user_id?: string` en `ProductApiRow`
- [x] 6.2 Actualizar `frontend/hooks/data/use-posts.ts`: `user_id` en posts/likes es tenancy de community (no ERP); sin cambio de query key necesario para C-19
- [x] 6.3 Actualizar `frontend/hooks/data/use-clients.ts`: query keys sin user_id; añadido `account_id: string` e `user_id?: string` en `ClientApiRow`
- [x] 6.4 Actualizar `frontend/hooks/data/use-expenses-query.ts`: query keys sin user_id; añadido `account_id: string` e `user_id?: string` en `ExpenseApiRow`
- [ ] 6.5 Verificar que los hooks aun devuelven datos correctos en dev local; revisar React Query DevTools para confirmar que las query keys son correctas

## 7. Validación en producción (Paso 6 del plan)

- [x] 7.1 Ejecutar verificación de NULLs en producción: `SELECT COUNT(*) FROM <tabla> WHERE account_id IS NULL` para `sales`, `purchases`, `products`, `expenses`, `clients`, `stock_movements`, `suppliers` — todas deben retornar 0
- [ ] 7.2 Smoke test manual: login como usuario real, verificar que ventas, compras, productos, gastos, clientes y proveedores cargan correctamente
- [ ] 7.3 Verificar logs de Render (backend Python): sin errores `column "user_id" does not exist` ni `null value in column "account_id"`
- [x] 7.4 Verificar logs de Edge Functions en Supabase Dashboard: sin errores de filtro `user_id`
- [x] 7.5 Grep de seguridad: `grep -r "WHERE user_id" backend/repositories/` debe retornar 0 resultados

## 8. DB — Drop de columnas legacy [CRÍTICO — requiere aprobación PO] (Paso 7 del plan)

> **GATE:** No ejecutar este paso hasta tener ✅ explícito del PO. Los pasos 1-7 son reversibles; este paso no.

- [ ] 8.1 [REQUIERE APROBACIÓN PO] Crear migration SQL: drop `company_id` de `sales`, `purchases`, `products`, `expenses`, `clients`
- [ ] 8.2 [REQUIERE APROBACIÓN PO] Crear migration SQL: drop `user_id` de `sales`, `purchases`, `products`, `expenses`, `clients` (solo los que no tienen rol de FK a `auth.users` según inventario del paso 1.2)
- [ ] 8.3 [REQUIERE APROBACIÓN PO] Crear migration SQL: drop `company_id` de `suppliers` (ahora usa `account_id`); agregar constraint NOT NULL a `suppliers.account_id`
- [ ] 8.4 [REQUIERE APROBACIÓN PO] Crear migration SQL: drop `company_id` de `stock_movements` e `inventory_movements`
- [ ] 8.5 Aplicar todas las migrations de drop al proyecto `gxdhpxvdjjkmxhdkkwyb` via `npx supabase db push`
- [ ] 8.6 Verificar: `SELECT column_name FROM information_schema.columns WHERE table_name = 'sales' AND column_name IN ('company_id', 'user_id')` debe retornar 0 filas
- [ ] 8.7 Smoke test post-drop: verificar que la app funciona igual que antes del drop (ventas, compras, stock, IA)
- [ ] 8.8 Regenerar tipos TypeScript: `npx supabase gen types typescript --project-id gxdhpxvdjjkmxhdkkwyb > frontend/lib/database.types.ts`
