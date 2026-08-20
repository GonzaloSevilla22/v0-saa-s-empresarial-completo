## 1. Red de seguridad y captura del estado vigente

- [x] 1.1 Capturar `pg_get_functiondef` VIVO de `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` desde prod (`gxdhpxvdjjkmxhdkkwyb`, solo SELECT) y guardarlo como base del cuerpo nuevo — el cuerpo se **extiende**, nunca se reescribe de memoria (regla anti-regresión de julio)
- [x] 1.2 Confirmar `MAX(version)` en `supabase_migrations.schema_migrations` (esperado `20260929000001`) y que `20260930000001` esté libre localmente
- [x] 1.3 Correr la suite existente de edición (gates de #415/#416, #417/#418, #419) y registrar el baseline verde; si algo falla ya, reportarlo como fallo preexistente y **no** arreglarlo dentro de este change — baseline verde confirmado; hallazgo adicional reportado (no arreglado como "bug preexistente" sino reparado dentro de este change por ser bloqueante de F3 — ver nota al final)
- [x] 1.4 Verificar con `pg_get_function_arguments` que hoy existe **una sola** función con cada nombre (sin overloads previos)

## 2. Gates RED — comportamiento esperado antes de escribir la implementación

- [x] 2.1 Gate SQL: editar una venta imputada a sucursal no default y con canal, sin informar ninguno, conserva `branch_id` y `canal` (RED hoy: ambos quedan `NULL`)
- [x] 2.2 Gate SQL: editar una compra con `supplier_id`, `cost_center_id` y `unit_id` conserva los tres (RED hoy: los tres quedan `NULL`)
- [x] 2.3 Gate SQL: editar una venta con `unit_id` conserva la unidad en el header **y** en `sale_items` (RED hoy: la línea nace con `unit_id = NULL` explícito)
- [x] 2.4 Gate SQL: editar una venta de sucursal no default deja **ambas** patas del ledger sobre esa sucursal y no toca el stock de la default (RED hoy: la pata APPLY cae en la default)
- [x] 2.5 Gate SQL: editar una venta creada con `quantity = 2.5` a `3.25` funciona y persiste `3.25` en header, línea y delta de stock (RED hoy: `22P02 invalid input syntax for type integer`)
- [x] 2.6 Gate SQL: editar una venta con comprobante `authorized` falla con `P0423` y deja filas, líneas y stock intactos (RED hoy: la edición procede y destruye la venta facturada)
- [x] 2.7 Gate SQL: editar una venta con comprobante `pending_cae` falla con `P0423`; con comprobante `rejected` o sin comprobante, la edición procede (control negativo — sin él el gate 2.6 no prueba nada)
- [x] 2.8 Gate SQL: editar una venta promovida a `sales_orders` sin comprobante re-apunta `sale_operation_id` al `operation_id` nuevo, y no quedan órdenes huérfanas (RED hoy: la orden queda colgada) — hallazgo en RED contra la propia migración nueva: `WHERE fiscal_document_id IS NULL` a secas dejaba huérfana una orden cuyo único comprobante quedó `rejected` (rejected no bloquea F2 pero sí deja `fiscal_document_id` poblado); corregido a `NOT EXISTS (... status IN ('pending_cae','authorized'))`, misma definición que el guard F2
- [x] 2.9 Gate SQL: reimputar sucursal a una de otra cuenta o cerrada falla con `P0422` sin haber revertido ni reaplicado stock
- [x] 2.10 Registrar los gates nuevos en `.github/workflows/KPI_Validation.yml` y confirmar que fallan en rojo antes de tocar las RPCs — RED confirmado: (a) suite completa contra baseline aborta con `42883 undefined_function` al usar los parámetros tri-estado nuevos (no existen aún), (b) probes standalone confirman F1 (branch_id/canal quedan `NULL` tras editar) y F3 (`22P02 invalid input syntax for type integer: "3.25"`) contra el schema pre-migración

## 3. Migración SQL — `20260930000001_edicion_preserva_contexto.sql`

- [x] 3.1 `DROP FUNCTION IF EXISTS` de ambas RPCs con la **firma vieja completa y explícita** (`uuid[], uuid, date, text, jsonb, uuid, boolean` y `uuid[], date, text, jsonb, uuid, boolean`)
- [x] 3.2 `rpc_atomic_update_sale_operation`: firma nueva con `p_branch_id uuid DEFAULT NULL, p_branch_provided boolean DEFAULT false, p_canal text DEFAULT NULL, p_canal_provided boolean DEFAULT false` **al final**, todos con DEFAULT (compatibilidad de la ventana de despliegue, design §D4)
- [x] 3.3 Sale: capturar `branch_id`, `canal`, `unit_id`, `operation_id` viejos antes del DELETE, junto al bloque de `v_old_snapshots` / `v_old_payment_method_id` (design §D1)
- [x] 3.4 Sale: resolver `v_final_branch_id` / `v_final_canal` con el contrato tri-estado espejo de `payment_method_id` (§D3), validando pertenencia a la cuenta y sucursal operativa antes de aplicar (`P0422` si no)
- [x] 3.5 Sale: guard fiscal `P0423` al inicio, **antes** del REVERSE, por join `sales_orders → fiscal_documents` con `status IN ('pending_cae','authorized')`, con mensaje que nombra nota de crédito + venta nueva (§D5)
- [x] 3.6 Sale: `jsonb_to_recordset` pasa a `AS x(product_id uuid, amount numeric, quantity numeric, unit_id uuid)` — igualando la forma de `rpc_create_sale_operation` (§D7)
- [x] 3.7 Sale: el `INSERT INTO sales` incluye `branch_id`, `canal`, `unit_id`; el `INSERT INTO sale_items` escribe `unit_id` real en vez de `NULL`
- [x] 3.8 Sale: la pata APPLY de `op_stock_movement` recibe `v_final_branch_id` en vez de `NULL`; la pata REVERSE sigue usando la sucursal vieja (§D8)
- [x] 3.9 Sale: `UPDATE sales_orders SET sale_operation_id = v_new_op_id WHERE sale_operation_id = <viejo> AND fiscal_document_id IS NULL` después del INSERT (§D9) — condición ajustada en RED (ver 2.8): equivalente al guard F2 (`NOT EXISTS fd.status IN (pending_cae,authorized)`), no `IS NULL` a secas
- [x] 3.10 `rpc_atomic_update_purchase_operation`: firma nueva con `p_branch_id` + `p_branch_provided` al final; preservación de `supplier_id`, `cost_center_id` y `unit_id`; recordset a `numeric` + `unit_id`; `INSERT INTO purchases` y `purchase_items` completos; pata APPLY sobre la sucursal efectiva
- [x] 3.11 `REVOKE ALL ON FUNCTION ... FROM PUBLIC` + `GRANT EXECUTE ... TO authenticated` para **ambas** funciones, en el mismo archivo, inmediatamente después del CREATE (el DROP resetea las ACLs)
- [x] 3.12 `COMMENT ON FUNCTION` de ambas apuntando a este change; verificar que el archivo completo es idempotente (re-ejecutable sin error) — verificado: segunda aplicación produce `DROP FUNCTION ... does not exist, skipping` + `CREATE FUNCTION` limpio, sin error
- [x] 3.13 (no listada originalmente, agregada en RED) §0 de la migración: `sales.quantity`/`purchases.quantity` son `integer` en el stack local/CI reconstruido desde cero (ningún archivo de migración registra el `ALTER` a `numeric(15,4)` que sí está aplicado en prod) — F3 no era verificable end-to-end en CI sin repararlo. Reparación gateada por el tipo actual de columna (no-op en prod), reconstruyendo `v_sales_flat`/`v_purchases_flat` con su definición exacta (`WITH (security_invoker = true)` preservado)

## 4. Backend Python

- [ ] 4.1 `backend/schemas/sales.py`: `SaleOperationUpdateItemIn` suma `unit_id: str | None = None`; `SaleOperationUpdateIn` suma `branch_id: uuid.UUID | None` y `canal: str | None` (documentando que el tri-estado se resuelve por `model_fields_set`, nunca por `is None`)
- [ ] 4.2 `backend/schemas/purchases.py`: equivalente para la compra (`unit_id` por ítem, `branch_id` en el header de update)
- [ ] 4.3 `backend/repositories/sales_repository.py` y `purchase_repository.py`: pasar los parámetros nuevos por nombre (`p_branch_id =>`, `p_branch_provided =>`, …), igual que el patrón ya usado para `payment_method_id`
- [ ] 4.4 `backend/services/sales.py` y `purchases.py`: derivar los flags `*_provided` desde `model_fields_set` del payload
- [ ] 4.5 Routers: mapear `P0423` a RFC 7807 (`api-standards`) con título y detalle que nombren el camino de nota de crédito; mapear `P0422` de sucursal inválida
- [ ] 4.6 Exponer en la lectura lo que el form necesita para prefillear: `branch_id`, `canal` y `unit_id` en `SaleItemOut` (y equivalente de compra) + el `SELECT` del repositorio
- [ ] 4.7 Tests pytest de los servicios/repos: tri-estado (ausente / `null` explícito / valor) para sucursal y canal, y propagación de `P0423`

## 5. Frontend

- [ ] 5.1 `frontend/lib/group-operations.ts`: `SaleOperation` y `PurchaseOperation` suman `branchId`, `canal`, `unitId`; `frontend/hooks/data/use-sales.ts` y `use-purchases.ts` mapean los campos nuevos
- [ ] 5.2 `sale-form.tsx`: `branchId` y `canal` se inicializan desde `editingOperation` (hoy arrancan en `null` ignorándolo) y se incluyen en el payload de edición
- [ ] 5.3 `purchase-form.tsx`: equivalente para sucursal; verificar que centro de costo y proveedor no se pisen al editar
- [ ] 5.4 Banner de bloqueo fiscal: form en solo lectura, explicación del motivo, camino de nota de crédito, botón de guardar deshabilitado con motivo accesible (no solo gris)
- [ ] 5.5 Verificar que el modo edición conserva `step`/`min` por unidad en el input de cantidad (decimales para productos medibles) y que la cantidad decimal pre-cargada no se degrada
- [ ] 5.6 Revisión visual con tokens semánticos del design system: **desktop y mobile**, **tema claro y oscuro**
- [ ] 5.7 Tests vitest de los forms: prefill de sucursal/canal en modo edición, payload de edición completo, render de solo lectura con operación facturada

## 6. Verificación y cierre

- [ ] 6.1 Todos los gates del grupo 2 en verde
- [ ] 6.2 Gates de regresión de #415/#417/#419/#421 en verde **sin modificar** (líneas acarreadas, par espejo del ledger, tri-estado de forma de pago, POS)
- [ ] 6.3 Post-merge: verificar en prod con `pg_get_function_arguments` que quedó **una sola** función con cada nombre (sin overload fantasma → `42725`) y que las ACLs son las esperadas
- [ ] 6.4 Post-merge: verificar que `MAX(version)` avanzó a `20260930000001`
- [ ] 6.5 Confirmar que no quedan `sales_orders` huérfanas nuevas y consultar al PO por las 3 históricas (no reconstruibles, design §D10)
- [ ] 6.6 Registrar en engram las decisiones y el resultado; llevar las OQ-1..4 del design al PO para firma
