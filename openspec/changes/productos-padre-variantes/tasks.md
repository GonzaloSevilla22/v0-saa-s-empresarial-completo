> Strict TDD: en cada grupo, la tarea de test (RED) va antes que la de implementación (GREEN), y se ejecuta para verla fallar. Governance MEDIO; el grupo 4 (relabel de unidad) es tramo ALTO: checkpoint con el diff SQL antes de commitear.
> **Tanda A** = grupos 1-7 (DB + backend, sin cambio visible). **Tanda B** = grupos 8-12 (frontend), recién con la A en prod.

## 1. Checkpoints previos (Tanda A)

- [x] 1.1 Confirmar que `20261093000001` sigue libre (`ls supabase/migrations | tail`; `20261092000001` está reservado por `mp-cuota-acreditacion-resiliente` #677 — si ese change no se aplicó y este va primero, igual conservar `20261093000001` para no chocar) y re-medir en prod (sólo `SELECT`): padres `variant_only` con precio/costo (esperado 17), grupos padre + variantes por conflicto de unidad sumando `sales`, `purchases`, `sale_items`, `purchase_items`, `sales_order_items`, `quote_items`, `delivery_note_items` (propose: 344 libres / 149 una unidad / 1 mixta).
- [x] 1.2 Obtener `pg_get_functiondef` vivo de `fn_product_base_unit_guard` y comparar su md5 (por líneas, sin CR) contra `supabase/migrations/20261069000001_remitos_venta.sql` L1331; guardar el cuerpo previo para el rollback. Si difiere, partir del vivo y anotarlo en design.md.
- [x] 1.3 Revisar `rpc_bulk_upsert_products` vivo (último archivo `20261086000001`): ¿alguna rama puede dejar un `variant_only` con `price <> 0` o `cost` no nulo (fila Padre sobre un producto existente con precio, o conversión de tipo)? Si sí, re-derivarla del vivo forzando `price = 0, cost = NULL` en esa rama (`DROP FUNCTION` + `CREATE` si cambia la firma; si no, `CREATE OR REPLACE` con la misma firma); si no, registrar "sin cambio" con la evidencia.
- [x] 1.4 Grep de reutilización y de callers: `has_lines_in_other_unit`, `_account_assert_capability`, `problem_from_pg_error`, `chunkIds`, `CAN_CONFIGURE`; listar todo test/gate que introspecte o ejecute `fn_product_base_unit_guard` (al menos `test_remitos_venta.sql`, `test_ventas_unidades_conversion.sql`, `test_ventas_unidades_conversion_race.sh`) y todo caller de `POST/PUT /products` que mande precio/costo/stock/SKU/barcode a un padre.
- [x] 1.5 SAFETY NET: correr los tests existentes de `backend/tests/test_products*.py` y los gates SQL de productos/unidades listados en 1.4; registrar baseline "N passing". Fallos preexistentes se reportan, no se arreglan.

## 2. Redondeo compartido y padre sin precio/costo (DB)

- [x] 2.1 RED: crear `supabase/tests/fixtures/product_round_price_cases.json` y el gate `supabase/tests/test_productos_padre_variantes.sql` con los bloques de `product_round_price` (casos de la tabla), 0 padres `variant_only` con precio/costo, existencia y validez del CHECK `products_variant_only_no_price_cost`, rechazo de un `UPDATE` directo como `authenticated` que pone precio a un padre, y una fila `product.parent_price_cleared` por padre limpiado (fixture propia). Correrlo contra la base local sin la migración: debe fallar.
- [x] 2.2 GREEN: migración `20261093000001_productos_padre_variantes.sql` — `product_round_price(numeric)` `IMMUTABLE`, backfill auditado de padres con precio/costo (idempotente) y el CHECK, en ese orden. Gate en verde.
- [x] 2.3 TRIANGULATE: re-aplicar la migración (idempotencia del backfill sin filas nuevas de auditoría) y un caso de padre borrado (`deleted_at` no nulo) con precio para que el CHECK valide.

## 3. Contrato del padre y herencia de la variante (backend)

- [x] 3.1 RED: tests de servicio en `backend/tests/test_products_padre_variantes.py` — alta `variant_only` con `price`, `cost`, `stock`, `min_stock`, `sku`, `barcode` o `parent_id` → 422 `parent_field_not_allowed` con su `field` y sin `repo.create`; alta de variante con `base_unit_id` → se crea con `base_unit_id = None`; edición de variante con `base_unit_id` → no se escribe.
- [x] 3.2 GREEN: `_guard_parent_contract` en `backend/services/products.py` (molde de `_guard_scale_plu_not_parent`), herencia de unidad en `create_product`/`update_product` (espejo de la categoría).
- [x] 3.3 RED: edición de un `variant_only` — valor vigente o neutro aceptado (barcode legado "7790001", precio 0, mismo `stock_control_type`); valor distinto → 422; transición hacia/desde `variant_only` → 422 `stock_control_type_locked`; `23514` de `products_variant_only_no_price_cost` traducido a 422.
- [x] 3.4 GREEN: reglas de edición de D1/D2 y extensión de `_translate_check_violation`.
- [x] 3.5 REFACTOR: un solo helper de "campo prohibido en padre" para alta y edición; tests en verde tras cada paso.

## 4. Relabel de unidad (DB, tramo ALTO)

- [x] 4.1 RED: bloques del gate `test_productos_padre_variantes.sql` que EJECUTAN `rpc_relabel_product_unit`: relabel con historia (stock y movimientos intactos, cantidades sin convertir, raíz con la unidad nueva, variantes con `base_unit_id` NULL incluidas las que tenían propia), `unit_relabel_conflict` con una línea en otra unidad (y aceptado hacia esa unidad), dry-run sin escritura ni auditoría y con `conflict_unit`, idempotencia (`changed = false` sin auditar), `P0403` para rol `stock`/`cashier`, `P0404` para producto ajeno, `P0400` sin unidad, fila `product.unit_relabel` con su `metadata`, ACL sin `anon`, y el `PATCH` directo como `authenticated` sobre un producto con stock que sigue dando `P0409 base_unit_locked` (también con el GUC seteado sobre otra raíz y con re-parent).
- [x] 4.2 GREEN: en la migración, `fn_product_base_unit_guard` re-derivado del vivo (1.2) con el corte del GUC `products.unit_relabel_root` (D6), y `rpc_relabel_product_unit` (D5) con `REVOKE`/`GRANT`. Checkpoint: diff SQL del guard contra el vivo revisado antes de commitear.
- [x] 4.3 RED: `supabase/tests/test_productos_padre_variantes_race.sh` (molde de `test_ventas_unidades_conversion_race.sh`): relabel abierto + compra de la variante con otra unidad, y compra abierta + relabel; ninguno deja stock en una unidad distinta de la base efectiva.
- [x] 4.4 GREEN: ajustar el orden de locks de la RPC hasta que el test de carrera pase en ambos órdenes.
- [x] 4.5 Re-ejecutar `test_remitos_venta.sql`, `test_ventas_unidades_conversion.sql` y `test_ventas_unidades_conversion_race.sh`; actualizar la introspección del cuerpo del guard si la compara.

## 5. Precios en lote (DB)

- [x] 5.1 RED: bloques del gate que EJECUTAN `rpc_bulk_adjust_prices`: aumento por porcentaje con redondeo (1000 → 1100; 2345 → 2580), baja por importe con piso 0 y `clamped`, expansión padre → variantes con el padre excluido y contado en `skipped_parents`, variante suelta normalizada a su raíz, filas sin cambio no escritas, ids de otra cuenta sin efecto ni error, dry-run sin escritura ni auditoría, rangos (−95 %, +1.500 %, valor 0, 501 ids → `P0400`), `P0403` para vendedor, fila `product.bulk_price_adjusted`, ACL sin `anon`.
- [x] 5.2 GREEN: `rpc_bulk_adjust_prices` (D8) en la migración, usando `product_round_price`; bloque final de introspección de la migración (corte del guard, CHECK, ACLs de las tres funciones).
- [x] 5.3 Cablear `test_productos_padre_variantes.sql` (vía `python3 scripts/ci/run_gate_strict.py`) y `test_productos_padre_variantes_race.sh` en `.github/workflows/KPI_Validation.yml`, siguiendo el molde de los gates recientes.

## 6. Endpoints (backend)

- [x] 6.1 RED: tests de router/servicio — `POST /products/{id}/relabel-unit` (dry-run y aplicación, `require_account_role(CAN_CONFIGURE)` con 403 antes de llamar la RPC, mapeo `unit_relabel_conflict` → 409, `product_not_found` → 404 vía `problem_from_pg_error`); `PATCH /products/bulk-price` (validación Pydantic: 0 o 501 ids, modo/dirección inválidos, valor ≤ 0 → 422; rol; ruta declarada antes de `/{product_id}`).
- [x] 6.2 GREEN: schemas `ProductUnitRelabelIn/Out` y `ProductBulkPriceIn/Out` en `backend/schemas/products.py`; métodos de `ProductRepository` que llaman las RPCs; servicios y rutas en `backend/routers/products.py`.
- [x] 6.3 RED → GREEN: tests del tier de integración (marker `integration`, contra Postgres real) para el relabel y el lote de precios, incluido el 403 por rol y el 404 ajeno.
- [x] 6.4 Correr la suite backend completa con coverage (≥ 87 %) y comparar contra el baseline de 1.5.

## 7. Cierre de la tanda A

- [x] 7.1 `supabase db reset` local limpio + gates del grupo en el orden real del workflow.
- [x] 7.2 KB: RN-25 (padre sin precio/costo/stock/códigos; alta diferenciada) e inciso (g) de la regla de unidades (D-C firmado + excepción del relabel) en `knowledge-base/05_reglas_de_negocio.md`; `04_modelo_de_datos.md` con el CHECK y las dos RPCs.
- [x] 7.3 PR de la tanda A (#681, declara "sin cambio visible"); tras el merge, verificación en prod sólo `SELECT` (2026-11-05): `max(version) = 20261093000001` (340 migraciones), 0 padres con precio/costo, CHECK validado, 18 filas `product.parent_price_cleared`, cuerpo vivo del guard con el corte, ACLs sin `anon`, una sola firma por función.

## 8. Lógica pura del frontend (Tanda B)

- [x] 8.1 RED: `frontend/lib/__tests__/product-pricing.test.ts` — `roundToPesos` contra `product_round_price_cases.json`, `suggestPriceFromCost` (1000 → 1500, nulo/0/negativo/NaN → null) y `nextPriceOnCostChange` (precio vacío o igual a la última sugerencia → sugerencia; precio escrito → sin cambio; edición con precio → sin cambio).
- [x] 8.2 GREEN: `frontend/lib/product-pricing.ts` con `SUGGESTED_MARKUP_FACTOR`, `roundToPesos`, `suggestPriceFromCost`, `nextPriceOnCostChange`.
- [x] 8.3 RED → GREEN: generalizar `lib/product-bulk-category.ts` (`runInChunks` genérico con agregación y reporte de bloques fallidos); los tests existentes de la recategorización siguen en verde sin cambios de comportamiento.
- [x] 8.4 RED → GREEN: hooks en `hooks/data/use-products.ts` — `useRelabelProductUnit` (dry-run y aplicación) y `useBulkAdjustPrices` (troceo, suma de dry-runs, invalidación del listado de productos).

## 9. Alta y edición diferenciadas

- [x] 9.1 RED: tests de componente — `ProductKindStep` (dos opciones, teclado); `ParentProductForm` muestra sólo nombre, categoría y unidad y su payload no lleva precio/costo/stock/SKU/barcode/PLU; tras crear el padre pasa a "Agregar la primera variante" con el padre fijo; `VariantProductForm` con categoría y unidad de sólo lectura y sin selector de padre; `SimpleProductForm` sin selector de padre; elección del formulario por modo en la edición, incluido el aviso del padre `tracked` con hijos.
- [x] 9.2 GREEN: partir `components/forms/product-form.tsx` por composición (D12), extrayendo los bloques de campos compartidos; cablear el paso en `app/(dashboard)/productos/page.tsx` y "Nueva variante" desde la fila.
- [x] 9.3 RED → GREEN: sugerencia de precio conectada en `SimpleProductForm` y `VariantProductForm` (escribir costo completa precio; precio escrito no se pisa; ayuda visible).
- [x] 9.4 RED → GREEN: traducción de `parent_field_not_allowed` y `stock_control_type_locked` en `lib/operation-errors.ts` (o el traductor de errores de producto existente) con mensaje accionable.

## 10. Diálogo "Corregir unidad"

- [x] 10.1 RED: test del diálogo — vista previa con variantes, stock, movimientos y ejemplo de cantidad real; `conflict_unit` deshabilita confirmar; confirmar llama sin dry-run; oculto para roles sin `CAN_CONFIGURE`; el selector de unidad libre se reemplaza por la acción sólo cuando el grupo tiene historia.
- [x] 10.2 GREEN: componente del diálogo en `components/products/` y su conexión en el formulario de padre/simple.

## 11. Modificar precios en lote y rango del padre

- [x] 11.1 RED: test de `product-catalog.tsx` — acción "Modificar precios" junto a "Recategorizar" sólo con `CAN_CONFIGURE`; diálogo con dirección, modo y valor; confirmación habilitada sólo después de la vista previa; resultado por bloques con falla parcial informada; fila del padre `variant_only` con "desde $X".
- [x] 11.2 GREEN: diálogo y acción en `components/products/product-catalog.tsx` (prop `onBulkAdjustPrices` espejo de `onBulkRecategorize`), conexión en `productos/page.tsx`, rango "desde $X".

## 12. Verificación y cierre de la tanda B

- [x] 12.1 `pnpm vitest run` completo y `tsc --noEmit` sin errores nuevos contra el baseline.
- [ ] 12.2 Verificación visual de `/productos` (paso "¿Qué querés crear?", los tres formularios, "Corregir unidad", "Modificar precios") a 375 px y en desktop, tema claro y oscuro (4 combinaciones), con contraste por tokens semánticos.
- [ ] 12.3 PR de la tanda B; humo real del PO anotado en `docs/pendientes-manuales-po.md` (crear producto con variantes, corregir la unidad de una familia con historia, aumentar precios de una selección, sugerencia × 1,5).
- [ ] 12.4 Archive: specs sincronizadas (`product-variants` y `product-bulk-pricing` nuevas; `units-of-measure`, `product-sku`, `product-category` modificadas); candidatos `markup-por-cuenta`, `v3-uom-conversion` y conversión asistida de padres `tracked` en `CHANGES.md`.
