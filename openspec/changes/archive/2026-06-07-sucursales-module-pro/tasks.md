## 1. Migración de base de datos

- [x] 1.1 Crear migración SQL: tabla `branches` (`id UUID PK DEFAULT gen_random_uuid()`, `account_id UUID FK accounts(id) ON DELETE CASCADE`, `name TEXT NOT NULL`, `address TEXT`, `is_active BOOLEAN DEFAULT TRUE`, `created_at TIMESTAMPTZ DEFAULT now()`; UNIQUE constraint `(account_id, name)`)
- [x] 1.2 Crear migración SQL: `ALTER TABLE sales ADD COLUMN branch_id UUID REFERENCES branches(id) ON DELETE SET NULL`
- [x] 1.3 Crear migración SQL: `ALTER TABLE purchases ADD COLUMN branch_id UUID REFERENCES branches(id) ON DELETE SET NULL`
- [x] 1.4 Crear migración SQL: `ALTER TABLE expenses ADD COLUMN branch_id UUID REFERENCES branches(id) ON DELETE SET NULL`
- [x] 1.5 Crear migración SQL: `ALTER TABLE stock_movements ADD COLUMN branch_id UUID REFERENCES branches(id) ON DELETE SET NULL`
- [x] 1.6 Crear índices: `CREATE INDEX ON branches(account_id)` y `CREATE INDEX ON sales(account_id, branch_id)`, `purchases(account_id, branch_id)`, `expenses(account_id, branch_id)`, `stock_movements(account_id, branch_id)`
- [x] 1.7 Añadir columna `max_branches INTEGER NOT NULL DEFAULT 0` a `plan_limits` y actualizar seed: `gratis=0`, `inicial=0`, `avanzado=0`, `pro=3`
- [x] 1.8 Habilitar RLS en `branches`: policy SELECT para miembros de la cuenta, policy INSERT/UPDATE/DELETE solo para `owner` y `admin` (verificar vía `account_members`)
- [x] 1.9 Crear función `rpc_create_branch(p_account_id UUID, p_name TEXT, p_address TEXT DEFAULT NULL)` `SECURITY DEFINER`: verifica membresía del caller, cuenta sucursales activas vs `plan_limits.max_branches`, INSERT o lanza excepción con códigos `branch_limit_exceeded` / `branch_name_duplicate` / `unauthorized`
- [x] 1.10 Crear función `rpc_deactivate_branch(p_branch_id UUID)` `SECURITY DEFINER`: verifica que el caller es `owner` o `admin` de la cuenta dueña del branch, hace `UPDATE branches SET is_active = FALSE`
- [x] 1.11 Aplicar migración a producción con `npx supabase db push` — 3 migraciones aplicadas 2026-06-07

## 2. Tipos TypeScript y hooks

- [x] 2.1 Añadir tipo `Branch` en `lib/types.ts`: `{ id: string; account_id: string; name: string; address: string | null; is_active: boolean; created_at: string }`
- [x] 2.2 Extender `usePlanLimits()` en `hooks/usePlanLimits.ts` (o donde esté) para incluir `maxBranches: number` leyendo de `plan_limits.max_branches`
- [x] 2.3 Crear hook `useBranches()` en `hooks/useBranches.ts`: query a Supabase `branches` donde `is_active = TRUE` scoped al account activo, invalidación automática con React Query
- [x] 2.4 Añadir mutaciones `createBranch(name, address)` y `deactivateBranch(id)` en `useBranches()` que llaman a los RPCs y revalidan la query

## 3. Page `/sucursales` — CRUD de sucursales

- [x] 3.1 Crear page `app/(dashboard)/sucursales/page.tsx` con gating: si `maxBranches === 0`, renderizar `<PlanGate feature="sucursales" requiredPlan="pro" />` en lugar del contenido
- [x] 3.2 Crear componente `BranchList` que lista las sucursales activas con nombre, dirección e indicador de cupo (`N de 3 sucursales usadas`)
- [x] 3.3 Crear componente `BranchForm` (modal o sección inline): inputs de nombre y dirección, validación client-side con Zod, llama a `createBranch()`, muestra error si límite alcanzado
- [x] 3.4 Añadir botón "Desactivar" en cada item de `BranchList` (solo visible para `owner` y `admin`): confirmación antes de llamar a `deactivateBranch()`
- [x] 3.5 Añadir item "Sucursales" al sidebar de navegación del dashboard, con condición `maxBranches > 0` (plan PRO); el item no se renderiza para otros planes

## 4. Selector de sucursal en formularios de operaciones

- [x] 4.1 Crear componente `BranchSelect` (shadcn/ui `<Select>`): lista sucursales activas de `useBranches()`, opción vacía "Sin sucursal (general)"; solo se renderiza si `maxBranches > 0`
- [x] 4.2 Integrar `BranchSelect` en el formulario de nueva venta (`app/(dashboard)/ventas/`): campo opcional `branch_id`, pasa el valor al handler de guardado
- [x] 4.3 Integrar `BranchSelect` en el formulario de nueva compra (`app/(dashboard)/compras/`)
- [x] 4.4 Integrar `BranchSelect` en el formulario de nuevo gasto (`app/(dashboard)/gastos/`)
- [x] 4.5 Actualizar los handlers/server actions de creación de venta, compra y gasto para incluir `branch_id` en el INSERT (si el valor es vacío/undefined, enviar `null`)

## 5. Filtro de sucursal en el dashboard

- [x] 5.1 Crear componente `BranchFilter` para el header del dashboard: `<Select>` con opciones "Todas las sucursales" + lista de sucursales activas; solo visible si `maxBranches > 0`
- [x] 5.2 Implementar la propagación del filtro vía URL: al cambiar la selección en `BranchFilter`, usar `router.push` con `?branch=<uuid>` (o limpiar el param si "Todas")
- [x] 5.3 Leer el query param `branch` en los Server Components del dashboard (`searchParams.branch`) y pasarlo como filtro a las queries de Supabase
- [x] 5.4 Actualizar las queries de KPIs del dashboard (ventas totales, gastos, operaciones del mes) para añadir `.eq('branch_id', branchId)` cuando `branchId` es definido y pertenece a la cuenta activa
- [x] 5.5 Persistir la última selección en `sessionStorage` con la key `eie_branch_filter` y restaurarla al montar `BranchFilter`

## 6. Reporte por sucursal

- [x] 6.1 Crear RPC o query SQL `rpc_branch_report(p_account_id UUID, p_start DATE, p_end DATE)`: devuelve por branch (`branch_id`, `branch_name | 'Sin sucursal'`) — `total_sales NUMERIC`, `total_expenses NUMERIC`, `operation_count INTEGER`; incluye fila con `branch_id = NULL` como "Sin sucursal"
- [x] 6.2 Crear page `app/(dashboard)/reportes/sucursal/page.tsx` con gating de plan PRO
- [x] 6.3 Crear componente `BranchReport`: selectores de fecha (inicio y fin), tabla con columnas Sucursal / Ventas / Gastos / Operaciones, total general al pie
- [x] 6.4 Añadir gráfico de barras horizontal (Recharts) comparando ventas por sucursal en el período seleccionado
- [x] 6.5 Añadir item "Reporte por sucursal" en el menú de navegación de Reportes (solo si `maxBranches > 0`)

## 7. Tests

- [x] 7.1 Test unitario: `canCreateBranch` con PRO sin sucursales → permitido (`__tests__/branches.test.ts`)
- [x] 7.2 Test unitario: `canCreateBranch` con PRO en el límite de 3 → bloqueado
- [x] 7.3 Test unitario: `canCreateBranch` con plan no-PRO → bloqueado (hasBranchesModule=false)
- [x] 7.4 Test unitario: `translateRpcError` con código `branch_name_duplicate` → mensaje correcto
- [ ] 7.5 Test RLS SQL: miembro de cuenta B no puede SELECT branches de cuenta A — requiere `npx supabase test db`
- [ ] 7.6 Test RLS SQL: `member` no puede UPDATE `branches` — requiere `npx supabase test db`
- [ ] 7.7 Test integración E2E: venta con branch_id → `sales.branch_id` correcto — requiere Supabase real
- [ ] 7.8 Test integración E2E: `rpc_branch_report` con datos conocidos → totales correctos — requiere Supabase real
