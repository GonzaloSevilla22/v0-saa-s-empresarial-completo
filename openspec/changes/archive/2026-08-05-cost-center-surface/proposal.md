## Why

La capability `cost-center` está completa por debajo y es **inutilizable por arriba**: el catálogo, la RLS, los endpoints, la columna en `expenses`/`purchases` y la propagación al asiento contable (`journal_lines.cost_center_id`, línea 5100) están en producción desde `cost-center-dimension` (2026-06-27), pero **le faltan las dos puntas visibles**:

1. **No hay puerta de entrada.** `frontend/components/cost-centers/CostCenterManager.tsx` fue escrito y nunca montado — ninguna página lo importa (su propio comentario dice "el punto de entrada está en /configuracion o similar", y ese montaje jamás se hizo). Como nadie puede dar de alta un centro desde la UI, el selector "Centro de costo (opcional)" que sí está montado en el form de gasto y en el de compra aparece **siempre vacío** para todos los usuarios.
2. **No hay salida.** Ningún read-model agrega por centro de costo — el reporting quedó explícitamente diferido en el proposal de `cost-center-dimension` ("reporting/agregación por centro de costo llega con `journal-entry-outbox` / reporting") y nunca llegó. La dimensión acumularía datos que nadie puede leer.

Resultado neto: una migración aplicada, RLS, 3 capas de backend y tests verdes con **valor cero entregado**. Es el caso testigo que originó la regla PO del 2026-08-02 (*superficie frontend obligatoria en todo change que lo amerite*); este change la salda.

## What Changes

- **Gestión del catálogo con puerta de entrada real**: `CostCenterManager` se monta como tab **"Centros de costo"** en `/configuracion`, junto a Perfil / Cuenta / AFIP / Sistema / Equipo / Plan. Se reutiliza el componente existente tal cual (ya resuelve alta/edición/desactivación y el gate `isWriter`); no se reescribe.
- **Read-model nuevo `rpc_cost_center_report(p_account_id, p_start, p_end)`**: agrega **costos** por centro en un rango — gastos (`expenses.amount`) y compras (`COALESCE(purchases.total, purchases.amount)`) — devolviendo una fila por centro más una fila **"Sin centro de costo"** para lo no imputado (`cost_center_id IS NULL`). Espejo estructural de `rpc_branch_report`: mismo `SECURITY DEFINER` + verificación de membership sobre `p_account_id`, mismos invariantes RN-D (revenue de línea, conteo de operaciones unificado, borde superior inclusivo, dinero `NUMERIC`). Los centros desactivados siguen apareciendo en el reporte con su nombre histórico.
- **Pantalla `/reportes/centros-costo`** con gráfico de barras + tabla con totales, siguiendo el patrón ya establecido en `/reportes/sucursal` (React Query + `supabase.rpc` + Recharts). **Sin gate de plan** (decisión PO): coherente con la decisión ya tomada en `CostCenterSelect` de no gatear el catálogo — gatear el único consumidor de los datos dejaría al plan free imputando información que nunca puede leer.
- **Entrada de menú** en el sidebar, grupo "Inteligencia", con `pro: false, proOnly: false`.
- **Filtro por centro de costo en los listados de Gastos y Compras** + badge del centro en cada fila, para bajar del agregado al detalle:
  - **Gastos**: hoy `usePaginatedQuery` tiene un set de filtros **cerrado** (`search`/`dateFrom`/`dateTo`) y su efecto de fetch no depende de ningún filtro externo, así que un filtro nuevo capturado en el closure de `applyFilters` **no dispararía refetch**. Se extiende el hook compartido con un `extraFilters` opcional que viaja en `FilterParams` y en las deps del fetch — la capa canónica, no un workaround por pantalla.
  - **Compras**: el listado va por `GET /purchases` (FastAPI). Se agrega el query param opcional `cost_center_id` en las 3 capas (router → service → repository) y se expone `cost_center_id` + nombre del centro en la respuesta.
- **Sin cambios en los write paths**: no se toca el alta de gasto ni `rpc_create_purchase_operation`; no hay migración de datos ni backfill.

## Capabilities

### New Capabilities
<!-- Ninguna: este change completa la superficie de una capability ya existente, no introduce un dominio nuevo. -->

### Modified Capabilities
- `cost-center`: se agregan requirements de **superficie** a la capability existente — la gestión del catálogo SHALL ser alcanzable desde la UI por un `owner`/`admin` (hoy la spec define el CRUD pero no exige que exista una pantalla que lo exponga); el sistema SHALL ofrecer un read-model de costos agregados por centro de costo, incluyendo lo no imputado; y los listados de gastos y compras SHALL poder filtrarse por centro de costo. El requirement de baja (desactivación) se refina: un centro desactivado SHALL seguir siendo legible en reportes y filtros con su nombre histórico, aunque no se ofrezca para altas nuevas.

<!-- `reporting-invariants` NO se modifica: sus requirements ya son universales
     ("Todo read-model financiero SHALL...") y el RPC nuevo nace cumpliéndolos.
     `api-standards` NO se modifica: agregar un query param opcional de filtro no
     cambia el contrato de paginación `{items,total,page,pages}` ya especificado. -->

## Impact

- **DB / migraciones**: una migración aditiva con `CREATE OR REPLACE FUNCTION public.rpc_cost_center_report(...)` + `REVOKE`/`GRANT` (patrón del gate de ACLs vigente: revocar `anon`, otorgar `authenticated`). Sin DDL de tablas, sin backfill. Idempotente / both-worlds-safe, porque la integración GitHub de Supabase la auto-aplica al mergear antes del `db push` de Actions.
- **Backend (Python/FastAPI)**: `backend/routers/purchases.py`, `backend/services/purchases.py`, `backend/repositories/purchase_repository.py` (filtro `cost_center_id` opcional en el listado paginado + columna expuesta) y `backend/schemas/purchases.py`. Sin endpoints nuevos: el CRUD de `/cost-centers` ya existe completo y se reutiliza sin tocarlo.
- **Frontend (Next.js)**: `app/(dashboard)/configuracion/page.tsx` (tab nuevo), `app/(dashboard)/reportes/centros-costo/page.tsx` (nueva), `components/app-sidebar.tsx` (entrada de menú), `app/(dashboard)/gastos/page.tsx` y `app/(dashboard)/compras/page.tsx` (+ su lista) para filtro y badge, `hooks/use-paginated-query.ts` y `lib/pagination-utils.ts` (`extraFilters` opcional, retrocompatible — solo 2 pantallas consumen el hook hoy: gastos y clientes), `hooks/data/use-purchases.ts`. Sin `any` nuevo. Componentes reutilizados sin reescribir: `CostCenterManager`, `CostCenterSelect`, `useCostCenters`, `PaginationBar`.
- **Estética (regla PO 2026-08-02)**: tokens semánticos del design system, verificación en **desktop y mobile** y en **tema claro y oscuro** antes del merge — incluido el comportamiento del `TabsList` de configuración al pasar de 6 a 7 tabs.
- **Tests**: gates SQL de introspección + comportamiento en la migración (espejo de `20260814000001`); pytest para el filtro nuevo en el listado de compras (router + service + repository); vitest para `extraFilters` del hook de paginación y para el mapeo del reporte.
- **Fuera de alcance**: imputación de centro de costo en ventas (la dimensión es de costos, no de ingresos — decisión vigente de `cost-center-dimension`); jerarquías y distribución porcentual; reporte contable por centro sobre `journal_lines` (el asiento ya lleva el `cost_center_id`, pero el reporte de este change lee los documentos operativos, no el libro diario); edición del centro de costo de una compra ya registrada.
- **Governance**: **BAJO** — read-model nuevo de solo lectura, filtros opcionales y montaje de UI ya escrita. No toca dinero, ni el hot path de escritura, ni fiscal, ni autorización.
