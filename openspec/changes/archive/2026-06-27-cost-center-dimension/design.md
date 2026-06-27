## Context

Estado actual (verificado contra migraciones):
- No existe ninguna columna `cost_center` ni tabla `cost_centers` (greenfield total).
- `public.expenses` y `public.purchases` son las tablas canónicas de costo. Ambas evolucionaron desde el v1 (`user_id`) y hoy tienen `account_id` (multi-tenant, RLS) y `branch_id`. `expenses` tiene además `category` (TEXT libre) y `description`; `purchases` tiene `total`, `description`, `supplier_id`.
- El modelo V2 de compra no usa una tabla `purchase_items` separada: `rpc_create_purchase_operation` inserta **N filas en `public.purchases`** que comparten un `operation_id` (cada fila = una línea de la compra). La idempotencia usa `operation_idempotency` con `operation_kind='purchase'`.
- El alta de gasto es un INSERT simple en `public.expenses`.

Patrones a reusar: RLS por `account_id` (todo el sistema), escritura de catálogos gateada por rol (espejo de los guards `is_account_writer`/`require_role` de C-28/C-30), validación de pertenencia a la cuenta de los FK opcionales en los RPCs (igual que `rpc_create_purchase_operation` ya valida que `branch_id` pertenezca a la cuenta).

## Goals / Non-Goals

**Goals:**
- Catálogo plano `cost_centers` por cuenta, con CRUD y RLS (lectura = miembros; escritura = owner/admin).
- Dimensión analítica opcional `cost_center_id` (nullable) en `expenses` y `purchases`, imputable en el alta.
- Aditivo y backward-compatible: callers que no pasan `cost_center_id` siguen funcionando; filas existentes quedan `NULL`.
- Meter la columna **ahora** (volumen bajo) para evitar la migración dolorosa futura que el modelo §3.5 advierte, y dejar lista la dimensión que `journal-entry-outbox` (JournalLine.cost_center) va a necesitar.

**Non-Goals:**
- Jerarquías de centros de costo (catálogo plano, sin `parent_id`).
- Distribución porcentual de un gasto/compra entre varios centros (uno por operación).
- Reporting / agregación por centro de costo (llega con `journal-entry-outbox` / reporting).
- Imputación en **ventas** (el centro de costo es para costos, no ingresos).
- Hacer el centro de costo obligatorio (siempre opcional en V1).
- Imputación por línea en una compra multi-línea (es por operación: todas las líneas comparten el centro de costo).

## Decisions

1. **`cost_center_id` cuelga directo de `public.expenses` y `public.purchases`.** Son las tablas canónicas; no hay `purchase_items` separada. FK `uuid NULL REFERENCES cost_centers(id) ON DELETE SET NULL`. Sin default, sin backfill.

2. **Forma del catálogo `cost_centers`:** `id uuid PK`, `account_id uuid NOT NULL` (FK accounts), `name text NOT NULL`, `code text NULL` (código corto opcional p/contador), `is_active boolean NOT NULL DEFAULT true`, `created_at timestamptz`. `UNIQUE(account_id, lower(name))` para evitar duplicados por cuenta. Índice por `account_id`.

3. **RLS / autorización (lección C-28 bug #3: tabla con RLS + escritura directa del repo NECESITA policy de escritura).** El catálogo se escribe **directo desde el repo** (no vía SECURITY DEFINER RPC — no maneja dinero). Policies: `SELECT` para miembros de la cuenta (`account_id IN (SELECT current_account_ids())`); `INSERT`/`UPDATE` sólo owner/admin (reusar el helper de rol del proyecto — confirmar el nombre exacto en apply: `is_account_writer` o equivalente). Defensa en profundidad: el service también aplica `require_role(owner/admin)`.

4. **Baja = soft-delete (`is_active = false`), no DELETE físico.** Un centro de costo referenciado por gastos/compras históricos no debe perder su nombre. Desactivar lo saca del selector de altas nuevas pero conserva la imputación histórica. (El `ON DELETE SET NULL` queda sólo como red de seguridad.)

5. **Imputación por operación en compras.** `rpc_create_purchase_operation` gana un parámetro opcional `p_cost_center_id`; valida que pertenezca a la cuenta (igual que ya valida `branch_id`) y lo escribe en **todas** las filas `purchases` de esa operación. El alta de gasto persiste el `cost_center_id` opcional en su INSERT.

6. **NO se agrega un `operation_kind` nuevo a `operation_idempotency`** → no hace falta tocar su CHECK (la regla que rompió C-30 en prod no aplica acá). La firma de idempotencia de la compra no cambia.

7. **Ortogonalidad explícita.** `cost_center_id` es independiente de `branch_id` (sucursal física) y de `expenses.category` (naturaleza del gasto, texto libre). Los tres conviven; ninguno reemplaza a otro.

## Risks / Trade-offs

- **Tocar `rpc_create_purchase_operation` (path de alta de compra).** Mitigación: el parámetro es opcional con default `NULL`; se mantiene la firma anterior como wrapper o con default para no romper callers. Cubrir con tests RED→GREEN que el alta sin `cost_center_id` sigue igual (regresión) y con `cost_center_id` lo persiste en todas las líneas.
- **Validación de pertenencia del FK.** Si no se valida, un usuario podría imputar a un `cost_center_id` de otra cuenta. Mitigación: RLS sobre `cost_centers` + chequeo explícito en el RPC (espejo del de `branch_id`); test del caso cross-account rechazado.
- **`UNIQUE(account_id, lower(name))`** puede chocar si dos centros difieren sólo en mayúsculas/espacios. Mitigación: normalizar (trim) en el service; el índice funcional cubre el case-insensitive.
- **Riesgo general BAJO**: columna nullable aditiva + catálogo; no toca dinero, hot path de venta, ni fiscal. La regresión más sensible es el RPC de compra, cubierta por TDD.
- **Dating de la migración**: debe ser > la última (`20260801000003`). Usar `20260802000001` (o `ls supabase/migrations | sort | tail -1` al implementar).
