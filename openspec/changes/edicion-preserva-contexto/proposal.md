# La edición de una operación preserva su contexto (sucursal, canal, unidad, proveedor) y admite cantidades decimales

## Why

Las RPCs de edición (`rpc_atomic_update_sale_operation` / `rpc_atomic_update_purchase_operation`) implementan la edición como **REVERSE → DELETE → INSERT**. Los dos changes previos de la saga curaron lo que el DELETE se llevaba puesto *hacia abajo* — las líneas (`sale_items`/`purchase_items`, #415) y el ledger de stock (#417) — pero nadie miró lo que el **INSERT nuevo no vuelve a escribir**: el contexto del header.

Verificado con `pg_get_functiondef` VIVO en prod (`gxdhpxvdjjkmxhdkkwyb`, 2026-08-20, base #415+#417+#419 vigente). El INSERT de venta escribe once columnas de diecisiete; el de compra, catorce de veinte. Lo que no escribe queda en `NULL` para siempre, en silencio, sin error ni aviso:

| Se pierde al editar | Venta | Compra | Filas en prod hoy | Qué rompe |
|---|---|---|---|---|
| `branch_id` | ✗ | ✗ | 208/682 ventas · 0/427 compras | Reportes por sucursal (recién canonizados), stock por sucursal |
| `canal` | ✗ | — | 237/682 ventas | "Margen por Canal" (`sales-channel`) |
| `unit_id` | ✗ | ✗ | 310/682 ventas · 218/427 compras | Unidad de medida de la operación **y** de la línea (ambas RPCs insertan `unit_id => NULL` explícito en la línea) |
| `supplier_id` | — | ✗ | 0/427 compras | Cuenta corriente de proveedor (C-30) — la compra queda huérfana de proveedor |
| `cost_center_id` | — | ✗ | 0/427 compras | Centro de costo (V2.5) |
| `company_id` | ✗ | ✗ | 5/682 ventas | Columna legacy pre-`account_id` — **se declara muerta, no se restaura** |

Dos daños colaterales del mismo INSERT, del mismo tamaño:

- **El stock se muda de sucursal solo.** La pata REVERSE devuelve a `v_old_sale.branch_id` (la sucursal original), pero la pata APPLY llama a `op_stock_movement(..., p_branch_id => NULL, ...)` → **sucursal default**. Editar una venta de una sucursal que no es la default mueve stock entre sucursales sin que nadie lo pida. Hay 15 sucursales con stock en prod.
- **La orden promovida queda colgando.** La edición regenera `operation_id` (`gen_random_uuid()`), y `sales_orders.sale_operation_id` apunta al viejo. Quedan 3 órdenes colgadas en prod — es la OQ-C que el change anterior dejó abierta ("revisión manual, no amerita change"): tiene causa raíz, y es esta.

Y hay un tercer agujero, éste **ruidoso**: el `jsonb_to_recordset` de ambas RPCs de edición castea `quantity integer`, mientras la creación (`rpc_create_sale_operation`, `rpc_create_purchase_operation`, `rpc_quick_sale`) ya la acepta `numeric` y toda la cadena de stock es decimal (`sales.quantity numeric(15,4)`, `branch_stock.quantity numeric(15,4)`, `stock_movements.quantity_delta numeric(15,4)`, `op_stock_movement(p_delta numeric)`). El frontend ya ofrece `step=0.001` para productos medibles (`unitInputStep`) y Pydantic ya usa `Decimal`. Resultado: **se pueden crear ventas de 2,5 kg pero no editarlas** — el `jsonb_to_recordset` levanta `22P02 invalid input syntax for type integer: "2.5"` (verificado por `SELECT` en prod). Hoy hay **57 ventas con cantidad decimal en prod que ningún usuario puede editar**.

Cierra las tres OQ que el PO firmó el 2026-08-19 sobre `edicion-operaciones-lineas`: OQ-D (F1), OQ-C (F2, "bloquear"), OQ-G (F3, "decimal").

## What Changes

**F1 — El contexto del header sobrevive a la edición.**
- Ambas RPCs capturan el contexto vigente de la operación **antes del DELETE** (mismo momento y mismo patrón que `v_old_snapshots` de #415 y `v_old_payment_method_id` de #419) y lo reescriben en el INSERT nuevo.
- `branch_id` y `canal` (venta) se vuelven además **editables**: entran a la firma como parámetros tri-estado `p_*_provided` — el mismo contrato `COALESCE(param → viejo)` que #419 le dio a `payment_method_id`. Ausente = preservar; presente = reimputar. Son atributos que el usuario ya elige al crear; no poder corregirlos era la otra mitad del bug.
- `unit_id`, `supplier_id` y `cost_center_id` se **preservan sin exponerse** en esta iteración (`unit_id` viaja por ítem, junto al producto; `supplier_id`/`cost_center_id` no tienen selector en el form de edición hoy). **BREAKING** de firma: ambas RPCs cambian de signatura → `DROP FUNCTION` + `CREATE` + re-`GRANT` en la misma migración (42725).
- La pata APPLY de `op_stock_movement` pasa la **sucursal preservada** en vez de `NULL`: editar deja de mudar stock.
- Si la operación tiene una `sales_orders` promovida **sin comprobante**, su `sale_operation_id` se re-apunta al `operation_id` nuevo en la misma transacción (cierra la OQ-C del change anterior en su causa raíz, no a mano).

**F2 — Una operación facturada es inmutable.**
- Guard nuevo al inicio de `rpc_atomic_update_sale_operation`: si la operación tiene una `sales_orders` con `fiscal_document_id` cuyo comprobante está en `pending_cae` o `authorized`, la edición **falla** con `ERRCODE = 'P0423'` y un mensaje que nombra el camino correcto: *nota de crédito + venta nueva*. Un comprobante `rejected` no bloquea (nunca llegó a existir ante ARCA).
- El bloque fiscal existente **no se toca**: esto es un guard que impide entrar, no lógica fiscal nueva.
- Fuera de alcance: la compra no lleva CAE propio (el comprobante lo emite el proveedor) — se declara explícitamente, no se implementa.

**F3 — Cantidad decimal de punta a punta.**
- `jsonb_to_recordset(... quantity numeric)` en ambas RPCs de edición: única línea que faltaba. **Sin `ALTER` de columnas, sin `DROP VIEW`**: las cuatro columnas ya son `numeric(15,4)` en prod y las tres vistas dependientes (`v_sales_flat`, `v_purchases_flat`, `v_products_with_stock`) no se tocan.
- Backend: `SaleOperationUpdateItemIn` / el equivalente de compra suman `unit_id` (hoy solo lo tiene el schema de creación).
- Frontend: el form ya emite decimales; se verifica que el modo edición no los degrade.

**Superficie frontend** (`sale-form.tsx`, `purchase-form.tsx`, ambos en modo edición):
- Prefill y envío de sucursal y canal al editar — hoy `useState(null)` ignora `editingOperation` y el payload ni los manda.
- Banner de bloqueo fiscal: al abrir una operación facturada, el form se muestra en solo-lectura con la explicación y el atajo a nota de crédito.
- Requiere exponer `branch_id`/`canal`/`unit_id` en la lectura (`SaleItemOut`, `SaleOperation` de `group-operations.ts`) — sin eso no hay con qué prefillear.
- Desktop + mobile, tema claro + oscuro, tokens semánticos del design system.

## Capabilities

### New Capabilities
- `operation-edit-context`: contrato de preservación del contexto de una operación a través de su edición — qué atributos sobreviven al ciclo REVERSE→DELETE→INSERT, cuáles son reimputables por parámetro tri-estado, y que la cantidad decimal atraviesa la ruta de edición igual que la de creación.

### Modified Capabilities
- `afip-fiscal-document`: se agrega el requirement de **inmutabilidad de la operación con comprobante emitido** — la idempotencia fiscal ya especificada impide emitir dos veces; falta impedir que la venta *debajo* del comprobante cambie después de emitido.
- `inventory-single-ledger`: el requirement "Toda mutación de stock por edición de operación deja rastro espejo en el ledger" hoy solo ata la pata REVERSE a la sucursal original; se extiende para que la pata APPLY aterrice en la **misma** sucursal preservada.

## Impact

- **Migración**: `supabase/migrations/20260930000001_edicion_preserva_contexto.sql`. `MAX(version)` en prod verificado = `20260929000001` (idéntico al último archivo local). `DROP FUNCTION` + `CREATE` + re-`GRANT` de ambas RPCs (cambio de firma), idempotente.
- **Backend Python**: `backend/schemas/sales.py`, `purchases.py` (`unit_id`, `branch_id`, `canal` en los schemas de update), `backend/repositories/sales_repository.py:172+`, `purchase_repository.py` (nuevos parámetros nombrados), `backend/services/sales.py`, `purchases.py` (tri-estado por `model_fields_set`), routers para mapear `P0423` a RFC 7807.
- **Frontend**: `frontend/components/forms/sale-form.tsx`, `purchase-form.tsx`, `frontend/lib/group-operations.ts`, `frontend/hooks/data/use-sales.ts`, `use-purchases.ts`.
- **Datos**: **ningún backfill**. Lo perdido en ediciones pasadas no es reconstruible (el registro viejo se borró y el `stock_movements` espejo solo existe desde #417). Se declara pérdida histórica asumida.
- **CI**: gates SQL nuevos en `.github/workflows/KPI_Validation.yml` + tests pytest.
- **Governance**: **MEDIUM**. F2 roza el dominio fiscal pero es un guard de entrada; el bloque de emisión no se modifica.
