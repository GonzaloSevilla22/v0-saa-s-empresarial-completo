## Why

Abre la **Fase V2.5 (Finanzas)** del roadmap, ya desbloqueada porque V2.0/V2.1 están completas. El modelo de dominio V2 (`modelo-dominio-aliadata-v2.md` §3.5) pide un **centro de costo como dimensión analítica opcional**: "una dimensión analítica opcional (`cost_center_id`) en gastos y compras + catálogo plano. No jerarquías ni distribuciones porcentuales en V1. Costo casi nulo, lo piden contadores, y **agregar la columna después es migración dolorosa** sobre millones de filas."

Verificación contra el código real: la columna `cost_center` **no existe hoy** en ninguna tabla (greenfield). Este change es deliberadamente el **abre-fase**: es barato, aditivo y de-riskea el próximo change pesado (`journal-entry-outbox`), cuyo `JournalLine` referencia `cost_center` (modelo §5.6). Meter la columna ahora —mientras el volumen de filas es chico— evita exactamente la migración dolorosa que el modelo advierte.

## What Changes

- **Catálogo plano nuevo `cost_centers`** (account-scoped): centros de costo definidos por la organización, con nombre, código opcional y estado activo. RLS por `account_id`; escritura sólo `owner`/`admin` (vía `is_account_writer`, espejo de C-28/C-30); `SELECT` para todos los miembros de la cuenta.
- **Columna nullable `cost_center_id`** (FK a `cost_centers`, `ON DELETE SET NULL`) en las tablas portadoras de costo: `public.expenses` y `public.purchases`. Aditiva, sin default, sin backfill: las filas existentes quedan `NULL` (sin imputar).
- **Propagación opcional en el alta**: los RPCs/paths de creación de gasto y compra (`rpc_create_purchase_operation` y el alta de gasto) aceptan un `cost_center_id` opcional y lo persisten. En una compra multi-línea (varias filas `purchases` con el mismo `operation_id`) todas las líneas comparten el mismo centro de costo de la operación.
- **CRUD del catálogo + selector opcional** en los formularios de gasto/compra (frontend Next.js, sin `any`): listar/crear/editar/desactivar centros de costo, y un selector "Centro de costo (opcional)" en el alta.

## Capabilities

### New Capabilities
- `cost-center`: Catálogo plano de centros de costo por cuenta (CRUD con RLS owner/admin) y la imputación opcional de gastos y compras a un centro de costo vía una columna `cost_center_id` nullable. Dimensión analítica ortogonal a `branch_id` y a `expenses.category`.

### Modified Capabilities
<!-- Ninguna: no existe spec previa de expenses/purchases. La columna es impacto aditivo de código/DB, no un cambio de requirement de una capability existente. -->

## Impact

- **DB / migraciones**: tabla nueva `cost_centers` (+ RLS + policies + índice por `account_id`); `ALTER TABLE` aditivo en `expenses` y `purchases` (`cost_center_id uuid NULL REFERENCES cost_centers(id) ON DELETE SET NULL`); actualización de `rpc_create_purchase_operation` (y el path de alta de gasto) para aceptar/propagar el `cost_center_id` opcional. Migración aplicada por CI (`supabase db push` al mergear; datear > última migración).
- **Backend (Python/FastAPI)**: nuevos endpoints CRUD de `cost_centers` en 3 capas (router → service con guard `require_role` owner/admin para escritura → repository) + schemas Pydantic v2; extensión opcional de los schemas/paths de gasto y compra para aceptar `cost_center_id`. JWT-passthrough (RLS activa).
- **Frontend (Next.js)**: pantalla/sección de gestión del catálogo de centros de costo + selector opcional en los formularios de gasto y compra; hooks React Query asociados. Sin `any`.
- **Fuera de scope (diferido)**: jerarquías de centros de costo, distribución porcentual, reporting/agregación por centro de costo (llega con `journal-entry-outbox` / reporting), e imputación en ventas (el centro de costo es para costos, no ingresos). `expenses.category` (texto libre) se conserva sin cambios: es ortogonal al centro de costo, no lo reemplaza.
- **Governance**: BAJO (catálogo CRUD + columna nullable aditiva; no toca dinero, hot path ni fiscal).
