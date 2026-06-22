## 1. Reproducción y safety net (TDD — RED)

- [x] 1.1 Correr la suite existente de `backend/tests/test_sales.py` y compras; capturar baseline ("N passing"). Si algo falla, reportar como pre-existing y no arreglarlo acá. → baseline 15/15 passing.
- [x] 1.2 Escribir test RED en `test_sales.py`: venta con `stock_movements` (`reference_type='sale'`, `quantity_delta=-2`) y **sin** `sale_items` (simula ruta C-29) → `delete_by_id` debe reponer +2 en `branch_stock` y borrar el `stock_movements`. Debe fallar con el código actual.
- [x] 1.3 Escribir test de paridad: venta **con** `sale_items` + `stock_movements` → `delete_by_id` sigue reponiendo stock y borrando el movimiento (no romper la ruta v2).
- [x] 1.4 Escribir test de operación completa (`delete_by_operation`): varias líneas con producto creadas sin `sale_items` → repone cada línea en su `branch_id` y borra todos los movimientos.
- [x] 1.5 Escribir test de línea de servicio (sin `product_id`, sin movimiento) → la eliminación procede sin reversa y sin error.

## 2. Fix SalesRepository (GREEN)

- [x] 2.1 En `backend/repositories/sales_repository.py::delete_by_id`: reemplazar el `SELECT product_id FROM sale_items ...` por `SELECT product_id, quantity_delta, branch_id FROM stock_movements WHERE reference_id=$1::uuid AND reference_type='sale' LIMIT 1`; reversar con `movement["product_id"]` y mover el `DELETE FROM stock_movements` dentro del bloque "hay movimiento".
- [x] 2.2 Aplicar el mismo cambio en `delete_by_operation` (loop por `sale_id`).
- [x] 2.3 Correr tests de §1 → todos GREEN. Refactor si hace falta (extraer la query de reversa si se repite), tests siguen verdes. → 17/17 test_sales.

## 3. Fix espejo PurchaseRepository

- [x] 3.1 Tests RED en compras: compra con `stock_movements` (`reference_type='purchase'`, `quantity_delta>0`) sin `purchase_items` → `delete_by_id` decrementa `branch_stock` en `quantity_delta` y borra el movimiento.
- [x] 3.2 Aplicar el fix de D1 en `backend/repositories/purchase_repository.py::delete_by_id` y `delete_by_operation` con `reference_type='purchase'`.
- [x] 3.3 Correr tests de compras → GREEN, sin regresión en la ruta con `purchase_items`. (También actualizados los tests de contrato viejo en `test_sale_items.py` y `test_c21_checkpoint2_single_write.py` que asertaban el gate por items.)

## 4. Backfill de operaciones ya afectadas (dato sensible — revisión humana)

- [x] 4.1 Escribir el `SELECT` de movimientos huérfanos: `stock_movements` con `reference_type IN ('sale','purchase')` cuyo `reference_id` no existe en `sales`/`purchases`. → afectados: sale=38 mov / 31 prod / +37.01 u; purchase=73 mov / 64 prod / −81 u.
- [x] 4.2 Presentar el conjunto afectado al PO y obtener aprobación explícita antes de aplicar (modifica stock real). → PO eligió "solo ventas".
- [x] 4.3 Script idempotente y atómico (DO block): por cada huérfano de venta aplicar `c21_apply_branch_stock_delta(account_id, product_id, branch_id, -quantity_delta)` (NO `rpc_apply_product_stock_delta`, que exige `auth.uid()` ausente en el MCP admin) y `DELETE` la fila. 38 movimientos eliminados, 32 con producto → +32 u repuestas a la branch default por cuenta. Compras NO tocadas.
- [x] 4.4 Re-correr el `SELECT` de §4.1 → `sale_orphans_restantes = 0`. branch_stock verificado en 3 productos afectados.

## 5. Verificación y cierre

- [x] 5.1 Suite completa de backend en verde (ventas + compras + coverage mínimo CI). → 454 passed; 7 pre-existing fails en `test_receipts`/`test_payments` (PDF, ajenas al cambio, fallan también con el código original por orden de tests).
- [ ] 5.2 Smoke manual / E2E: crear venta POS (C-29) → eliminarla → confirmar stock repuesto. ⏸️ POST-DEPLOY (el backend en Render aún no tiene el fix; cubierto a nivel test por `test_delete_sale_c29_path_restores_stock`).
- [x] 5.3 Tabla de evidencia TDD (Safety Net / RED / GREEN / TRIANGULATE / REFACTOR) en el resumen de apply.
- [x] 5.4 Recomendación de unificar la fuente de verdad de C-29 (escribir `sale_items`) registrada como deuda separada en memoria + Open Question del design.
