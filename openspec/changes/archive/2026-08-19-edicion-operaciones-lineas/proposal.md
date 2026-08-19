# Edición de operaciones que mantiene las líneas (`sale_items` / `purchase_items`)

## Why

La **creación** de operaciones ya escribe línea para el 100% de las cuentas (PR #413, flag `sale_items_rpc_v2` opt-out). La **edición** no: `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` — verificadas en prod con `pg_get_functiondef` el 2026-08-18 — no mencionan `sale_items` ni `purchase_items` en ninguna línea de su cuerpo.

Y el daño es peor que "líneas desactualizadas". Ambas RPCs implementan la edición como **REVERSE → `DELETE FROM sales/purchases` → INSERT de filas nuevas**. Como `sale_items.sale_id` y `purchase_items.purchase_id` tienen FK `ON DELETE CASCADE`, **cada edición borra las líneas existentes** y las filas nuevas nacen sin ninguna. Es decir: la edición no desincroniza la línea, la **destruye**, y devuelve la operación al estado "sin línea" que el change anterior acaba de cerrar en la creación.

Evidencia en prod (2026-08-18): 119 de 663 ventas y 190 de 427 compras no tienen línea; 62 filas de `stock_movements` con `reference_type='sale'` apuntan a ventas que ya no existen (residuo del DELETE); 6 de 120 `sales_orders` tienen `sale_operation_id` colgando de un `operation_id` que ya no existe (la edición **regenera** el `operation_id`).

Consecuencia de negocio: rentabilidad histórica y márgenes falsos (sin `unit_cost_snapshot` congelado se cae al `products.cost` de hoy), historial del cliente (`clientes-frecuentes-historial`) con montos por línea que no cierran contra el header, y KPIs de producto ciegos para toda operación editada. Es la deuda OQ-1 del change `deudas-menores-agosto`, priorizada por el PO.

## What Changes

- **`rpc_atomic_update_sale_operation` escribe `sale_items`** para cada fila nueva de `sales` con `product_id NOT NULL`, en la misma transacción, con `price`/`subtotal` recalculados desde el payload editado.
- **`rpc_atomic_update_purchase_operation` escribe `purchase_items`** con la misma semántica, y además completa las columnas snapshot del header `purchases` (`name_snapshot`/`sku_snapshot`/`unit_cost_snapshot`) que la ruta de edición tampoco escribía.
- **Política de snapshot en edición (nueva regla de dominio)**: si el producto de la línea **no cambia**, la edición **preserva** el `unit_cost_snapshot` (y `name`/`sku`/`iva`) original de la línea previa y solo recalcula `quantity`/`price`/`subtotal`; si el producto **cambia** (o la línea es nueva), se congela un snapshot **fresco** de `products` al momento de la edición. Corregir un typo de cantidad no debe re-precificar la historia con el costo de hoy; cambiar de producto sí exige el snapshot del producto nuevo.
- **Mismo interruptor que la creación**: la escritura de línea en edición queda gobernada por el flag existente `sale_items_rpc_v2` (opt-out: ausencia de fila = encendido), para que un solo kill-switch apague la línea en creación y edición.
- **Gates SQL de comportamiento** nuevos en CI (`KPI_Validation.yml`): editar cantidad preserva el snapshot, editar producto re-snapshotea, editar una operación que nació sin línea la hace nacer, la compra se comporta igual, y el kill-switch sigue devolviendo el camino legacy.
- **Backfill de las operaciones históricas sin línea — GATEADO a sign-off del PO**: script idempotente (no migración: el merge aplica migraciones solo) que reconstruye la línea faltante desde el header. Ver `design.md` §D6 para la recomendación fundada sobre el costo histórico.
- **Sin superficie frontend nueva.** Los formularios de edición existentes (`frontend/components/forms/sale-form.tsx`, `purchase-form.tsx` → `PUT /sales|purchases/operation`) no cambian: empiezan a producir líneas correctas sin tocar una sola línea de TSX. El contrato del endpoint y el payload quedan idénticos.

## Capabilities

### New Capabilities

Ninguna. El hueco vive dentro de dos capacidades ya especificadas.

### Modified Capabilities

- `sale-line-items`: hoy el requirement "RPC versionado que escribe el ítem" cubre solo las rutas de **creación**. Se extiende para que **toda ruta que muta una operación** (creación y edición) deje la línea en sincronía con el header, y para que la edición no pueda dejar una operación sin línea.
- `document-snapshots`: se agrega la política de snapshot **en edición** (preservar si el producto no cambia, re-congelar si cambia) — hoy el requirement "Congelamiento de snapshots en la transacción de escritura" solo habla de la creación. Se precisa además el backfill de líneas **inexistentes** (distinto del backfill de líneas existentes con snapshot NULL que ya está especificado).

## Impact

- **Migración**: `supabase/migrations/20260926000001_*.sql` — `CREATE OR REPLACE` de ambas RPCs **sin cambio de firma** (ACLs y GRANTs vigentes preservados; sin `DROP`, sin riesgo 42725). Último `version` en prod: `20260925000001`.
- **Backend Python**: sin cambios de contrato. `backend/repositories/sales_repository.py:150-173` y `purchase_repository.py:176-190` siguen llamando las mismas firmas; `backend/schemas/sales.py` / `purchases.py` sin tocar.
- **Frontend**: sin cambios.
- **Datos**: script de backfill gateado (`scripts/sql/`), no aplicado por el merge.
- **CI**: nuevo gate SQL registrado en `.github/workflows/KPI_Validation.yml`.
- **Governance**: MEDIUM (RPCs core de operaciones). El enfoque de snapshot y de reconciliación se documenta en `design.md` para revisión del PO en el PR.
