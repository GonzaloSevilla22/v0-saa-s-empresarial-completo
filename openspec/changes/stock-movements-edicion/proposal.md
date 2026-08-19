## Why

La **edición** de una operación (`rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`) mueve `branch_stock` pero **no escribe una sola fila en `stock_movements`** (OQ-B de `edicion-operaciones-lineas`, 2026-08-19). El cableado existió — `20260527000002_wire_movements_to_rpcs.sql` — y se perdió en una redefinición posterior de las RPCs; prod todavía conserva la huella del período en que funcionó: **117 movimientos con `reference_type` `sale_update`/`purchase_update`, todos entre 2026-05-27 y 2026-06-05**, y ninguno después.

Investigando el hueco aparece una consecuencia que **no es solo de auditoría**: `SalesRepository.delete_by_id` / `PurchaseRepository.delete_by_id` derivan la reversa de stock **leyendo `stock_movements`** (`reference_id = <sale|purchase>.id`, `reference_type = 'sale'|'purchase'`) — es el contrato que el spec `inventory-single-ledger` fijó justamente para que la reposición fuera independiente de la ruta de creación. Como la edición hace `DELETE` + `INSERT` con **id nuevo** y no emite movimiento, la operación editada queda **sin movimiento de referencia**: al eliminarla, `rpc_reverse_stock_movement` recorre cero filas, `DELETE FROM sales` se ejecuta igual y **el stock nunca vuelve**, en silencio y sin error.

Medición en prod (`gxdhpxvdjjkmxhdkkwyb`, 2026-08-19):

| Medición | Valor |
|---|---|
| Filas `sales` vivas con `product_id` **sin** movimiento `reference_type='sale'` | **112 / 652** (17%) |
| Filas `purchases` vivas con `product_id` **sin** movimiento `reference_type='purchase'` | **92 / 412** (22%) |
| → operaciones vivas cuya eliminación **no repondría stock** | **204** |
| `stock_movements` `reference_type='sale'` huérfanos (apuntan a una venta inexistente) | 62 (57 sin contramovimiento) |
| `stock_movements` `reference_type='purchase'` huérfanos | **77** (36 sin contramovimiento) — nunca medidos antes |
| Pares `(product_id, branch_id)` donde Σ `quantity_delta` ≠ `branch_stock.quantity` | 1376 / 3522 |
| `sales_orders` colgando de un `operation_id` inexistente (OQ-C) | 6 / 120 |

El panel **"Movimientos de stock"** de `/stock` lee esta tabla directamente: el hueco **ya es visible para el usuario** — edita una venta y el historial no registra nada, aunque el stock cambió.

## What Changes

- **Emisión de `stock_movements` en la edición**, con semántica **espejo** de las dos patas que la RPC ya ejecuta (REVERSE y APPLY), no un neto: es la semántica que usó el cableado original (prod conserva pares `sale_return` + `sale` bajo `sale_update`), la que el panel de `/stock` ya sabe renderizar, y la única que deja el kardex legible.
  - Pata REVERSE → `type='sale_return'`/`'purchase_return'`, `reference_id` = id viejo, `reference_type='sale_update'`/`'purchase_update'`.
  - Pata APPLY → `type='sale'`/`'purchase'`, `reference_id` = **id nuevo**, `reference_type='sale'`/`'purchase'` — **idéntico a la creación**, que es lo que devuelve la eliminación a un estado correcto.
- **Helper canónico único `op_stock_movement`** (familia de `op_line_snapshot`, PR #415): resuelve sucursal, aplica el delta vía `c21_apply_branch_stock_delta`, calcula `quantity_before`/`quantity_after` y escribe el movimiento. Reemplaza los cuatro `PERFORM c21_apply_branch_stock_delta(...)` sueltos de las dos RPCs de edición, sin cambiar la aritmética ni los guards.
- **`unit_cost_snapshot` del movimiento reusa el snapshot ya resuelto por `op_line_snapshot`** — la corrección de una cantidad no re-valúa el movimiento al costo de hoy, misma regla que la línea (D2 de `edicion-operaciones-lineas`).
- **Gate de comportamiento en CI** (`supabase/tests/test_stock_movements_edicion.sql`, patrón de `test_operation_edit_lines.sql`): crear→editar→eliminar sobre anchors sintéticos, verificando que Σ `quantity_delta` reconstruye el delta de `branch_stock`, que la eliminación de una operación **editada** repone stock, y que no nacen huérfanos nuevos.
- **Corrección de deriva del spec**: `inventory-single-ledger` todavía dice que la fila reversada "SHALL eliminarse en la misma transacción"; el ledger es append-only desde `v31-tenancy-pool-rls` (policies `UPDATE`/`DELETE` con `qual=false`) y la reversa se expresa como contramovimiento. El requirement se alinea con la implementación real.
- **GATEADO a sign-off del PO, grupo aparte**: backfill de ledger para las 204 operaciones vivas sin movimiento (INSERT puro, **sin tocar `branch_stock`**) y tratamiento de los 139 huérfanos históricos. Recomendación fundada abajo y en `design.md` §D6/§D7.
- **NO entra**: preservar la identidad de la operación en la edición (OQ-A, `UPDATE` in-place), bloquear la edición de operaciones facturadas (OQ-C), `branch_id`/`canal` perdidos (OQ-D), `quantity integer` (OQ-G). Este change hace que el ledger cuente la verdad de lo que la edición ya hace; no cambia lo que la edición hace.

## Capabilities

### New Capabilities

_(ninguna — la conducta pertenece a un spec existente; canon de reutilización)_

### Modified Capabilities

- `inventory-single-ledger`: ADDED — toda mutación de `branch_stock` por edición de operación SHALL dejar su rastro espejo en `stock_movements`; ADDED — invariante de reconstrucción (Σ `quantity_delta` por `(product_id, branch_id)` reproduce el delta aplicado) y de no-orfandad hacia adelante; MODIFIED — el requirement de reversa al eliminar deja de prometer el `DELETE` de la fila (ledger append-only) y explicita que la edición es una ruta más que debe dejar movimiento de referencia.

## Impact

- **DB / migración**: `20260927000001_stock_movements_edicion.sql` (MAX(version) en prod verificado = `20260926000001`). `CREATE OR REPLACE` de `rpc_atomic_update_sale_operation(uuid[],uuid,date,text,jsonb)` y `rpc_atomic_update_purchase_operation(uuid[],date,text,jsonb)` **sin cambio de firma** (sin `DROP`, sin gotcha 42725, ACLs intactas) sobre la base vigente de `20260926000001` — el acarreo de snapshots del PR #415 se preserva íntegro. Helper nuevo `public.op_stock_movement(...)`.
- **Datos**: sin migración de datos en el grupo autónomo. El backfill y los huérfanos van en scripts aparte (`scripts/sql/`), gateados.
- **Backend Python**: sin cambios de código. `SalesRepository.delete_by_id` / `PurchaseRepository.delete_by_id` **se benefician** sin tocarse (empiezan a encontrar el movimiento que hoy falta).
- **Frontend**: **sin pantallas nuevas**. Superficie afectada existente: `frontend/app/(dashboard)/stock/page.tsx` → `frontend/components/stock/stock-movements-panel.tsx`. Los `type` emitidos (`sale`, `purchase`, `sale_return`, `purchase_return`) ya están en `MOVEMENT_META` con label, ícono, color y clasificación entrante/saliente — el panel muestra las ediciones sin una línea de TSX nueva. Se verifica desktop + mobile y tema claro + oscuro.
- **CI**: paso nuevo en `.github/workflows/KPI_Validation.yml`.
- **Governance**: MEDIUM (lógica de negocio / ledger de stock). El grupo de backfill/huérfanos toca datos históricos de prod → sign-off explícito del PO antes de ejecutarse.
