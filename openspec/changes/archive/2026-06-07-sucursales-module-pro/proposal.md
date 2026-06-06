## Why

El plan PRO promete gestión multi-punto de venta (sucursales) como diferenciador clave frente a los planes inferiores, pero el módulo no existe en la app. Sin él, el precio de $69.900/mes del plan PRO no está justificado ante emprendedores con más de un local. Este change implementa el módulo completo como feature-flag exclusiva de PRO.

## What Changes

- **Nueva tabla `branches`**: CRUD de sucursales (`name`, `address`, `is_active`) scoped por `account_id`, hasta 3 por cuenta PRO (límite en `plan_limits`).
- **Campo `branch_id NULLABLE`** añadido a `sales`, `purchases`, `expenses` y `stock_movements`; `NULL` significa "sucursal principal" (retrocompatible).
- **RLS en `branches`**: visible solo para miembros de la misma cuenta; escritura solo para `owner` y `admin`.
- **Page `/sucursales`**: listado, creación, edición y soft-delete de sucursales con gating de cupo.
- **Selector de sucursal** en los formularios de venta, compra y gasto (dropdown opcional).
- **Filtro por sucursal** en el dashboard/header: todos los KPIs y charts se filtran por `branch_id` seleccionado.
- **Reporte por sucursal** en `/reportes/sucursal`: ventas, gastos y operaciones desglosadas por branch con comparativa.
- **Gating UI**: menú "Sucursales" y selector de branch ocultos para planes `gratis`, `inicial` y `avanzado`; accesibles solo en `pro`.

## Capabilities

### New Capabilities

- `branches`: Gestión de sucursales — tabla DB, RLS, RPCs de CRUD, límite por plan, UI `/sucursales`, selector en formularios, filtro de dashboard y reporte comparativo por branch.

### Modified Capabilities

- `plan-gating`: Añade enforcement del límite `max_branches` (plan PRO = 3, resto = 0) en la creación de sucursales vía RPC y UI.

## Impact

- **DB**: nueva tabla `branches`; ALTER TABLE en `sales`, `purchases`, `expenses`, `stock_movements` (+ `branch_id` NULLABLE).
- **RLS**: nueva policy para `branches`; las políticas existentes de las tablas de operaciones no cambian (filtrado por `account_id` se mantiene).
- **Edge Functions**: ninguna nueva; las de IA reciben un parámetro opcional `branch_id` para filtrar sus consultas.
- **Next.js**: nueva page `/sucursales`, nuevo componente `BranchSelector` (global header), nuevo componente `BranchReport` en `/reportes/sucursal`.
- **Hooks**: `useBranches()` (CRUD + estado activo), extensión de `usePlanLimits()` para `max_branches`.
- **Dependencias externas**: ninguna nueva.
