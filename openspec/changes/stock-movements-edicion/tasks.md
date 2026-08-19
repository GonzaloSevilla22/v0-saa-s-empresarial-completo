# Tasks — `stock-movements-edicion`

> Strict TDD. El grupo 1 escribe los gates en RED contra el estado actual (el 1.6
> **debe** fallar hoy: eliminar una operación editada no repone stock); el grupo 2
> los pasa a GREEN con la migración; el 3 triangula y refactoriza.
> Governance MEDIUM: la decisión espejo-vs-neto (design §D1/§D2) se expone en el PR.
> **Los grupos 5 y 6 NO se ejecutan sin sign-off explícito del PO** — tocan datos
> históricos de producción.
>
> Base de las RPCs: `supabase/migrations/20260926000001_edicion_operaciones_lineas.sql`
> (PR #415). El acarreo de snapshots de línea NO se pisa.

## 1. RED — Gates de comportamiento primero

- [x] 1.1 Crear `supabase/tests/test_stock_movements_edicion.sql` con el patrón de `test_operation_edit_lines.sql`: anchors sintéticos vía `handle_new_user`, sesión simulada con `set_config` **LOCAL a la transacción del archivo** (NUNCA contra prod), fallos acumulados en `text[]`, un solo `RAISE EXCEPTION` final.
- [x] 1.2 Gate **creación** (control negativo del propio gate): crear una venta y una compra emite su movimiento `reference_type='sale'|'purchase'` con `quantity_delta` de signo y magnitud correctos. Debe fallar si alguien apaga la emisión de la creación.
- [x] 1.3 Gate **editar cantidad** (5→3): el ledger suma exactamente dos filas — `sale_return`/`sale_update`/`+5` sobre el id **viejo**, y `sale`/`sale`/`-3` sobre el id **nuevo** — y `branch_stock` neto varía en `+2`.
- [x] 1.4 Gate **editar producto** (A→B): A recibe `sale_return` `+qty`, B recibe `sale` `-qty`, ambos en la misma transacción; control negativo: B no hereda nada de A.
- [x] 1.5 Gate **eliminar**: emite el contramovimiento (`sale_return`/`sale_reversal`) y repone `branch_stock`.
- [x] 1.6 Gate **eliminar una operación EDITADA repone stock** — el bug de fondo. Crear → editar → eliminar → `branch_stock` vuelve al valor inicial. **Debe fallar en RED.** Confirmado RED contra `20260926000001` (branch_stock quedó en 46 en vez de reponer a 50); confirmado GREEN contra `20260927000001`.
- [x] 1.7 Gate **Σ reconstruye**: sobre la secuencia crear→editar→eliminar, Σ `quantity_delta` agrupada por `(product_id, branch_id)` == delta total aplicado a `branch_stock`, y el stock final == el inicial.
- [x] 1.8 Gate **huérfanos nuevos = 0**: dentro de los anchors, ningún movimiento `reference_type IN ('sale','purchase')` queda apuntando a una fila inexistente sin contramovimiento de cierre. Los `*_update`/`*_reversal` quedan excluidos por diseño (design §D7).
- [x] 1.9 Gate **`unit_cost_snapshot` no se re-valúa**: mover `products.cost` entre la creación y la edición → el movimiento de la pata APPLY conserva el costo viejo (control positivo).
- [x] 1.10 Gate **línea de servicio** (`product_id NULL`): cero movimientos en ambas patas, sin error.
- [x] 1.11 Gate **espejo de compras** para 1.3, 1.4, 1.6 y 1.7 (`purchase_return`/`purchase_update` y `purchase`/`purchase`, signos invertidos).
- [x] 1.12 Gate **no-regresión del PR #415**: el acarreo de `sale_items`/`purchase_items` y los guards `P0400`/`P0403`/`P0409`/`P0422` siguen pasando después de tocar las RPCs. Cubierto por el spot-check propio (1.12) + re-ejecución completa de `test_operation_edit_lines.sql` (20/20 PASS).
- [x] 1.13 Verificar que TODOS los gates nuevos fallan (o el 1.2 pasa) contra el schema actual, y dejar constancia del baseline en el PR. Baseline RED documentado en el PR (22 FAIL, 1.2/1.5/1.10/1.12 en PASS por ser no-regresión/control negativo).

## 2. GREEN — Migración `20260927000001_stock_movements_edicion.sql`

- [x] 2.1 Confirmar `MAX(version)` en prod inmediatamente antes de crear el archivo (esperado `20260926000001` → nombre `20260927000001`). Cabecera con hallazgo, decisión y rollback, al estilo de `20260926000001`.
- [x] 2.2 Crear `public.op_stock_movement(...)` (design §D3): `SECURITY DEFINER`, `SET search_path TO 'public'`, `REVOKE ALL` (solo invocable desde las RPCs dueñas — no toca la allowlist de `test_function_acl_gate.sql`). Aplica el delta vía `c21_apply_branch_stock_delta` (aritmética sin cambios, lazy-create de sucursal preservado), resuelve `after` desde `branch_stock` y deriva `before := after - delta`, e inserta el movimiento con `product_name`, `branch_id`, `operation_group_id`, `unit_cost_snapshot`, `reason`, `metadata`, `performed_by`.
- [x] 2.3 `CREATE OR REPLACE FUNCTION public.rpc_atomic_update_sale_operation(uuid[], uuid, date, text, jsonb)` — **firma idéntica**, cuerpo de `20260926000001` con el diff mínimo: agregar `id` y `operation_id` al `SELECT` de STEP 1, y reemplazar los dos `PERFORM c21_apply_branch_stock_delta(...)` por `PERFORM public.op_stock_movement(...)` según §D2 (REVERSE → `sale_return`/`sale_update`/id viejo; APPLY → `sale`/`sale`/id nuevo).
- [x] 2.4 En la pata APPLY, alimentar `unit_cost_snapshot` con `(v_line_snap->>'unit_cost_snapshot')::numeric` — el valor que `op_line_snapshot` ya resolvió (§D5), sin duplicar la lógica de acarreo. En la pata REVERSE, copiar el `unit_cost_snapshot` del movimiento original si existe, si no `NULL`.
- [x] 2.5 Respetar el orden `INSERT sales` → `INSERT sale_items` → `op_stock_movement` (lo verifica `backend/tests/migrations/test_c29_write_sale_items.py`).
- [x] 2.6 Espejo completo en `rpc_atomic_update_purchase_operation(uuid[], date, text, jsonb)`, preservando el poblado incondicional de los `*_snapshot` del header `purchases` (D5 del PR #415).
- [x] 2.7 Re-emitir `REVOKE EXECUTE ... FROM PUBLIC, anon` + `GRANT EXECUTE ... TO authenticated` y actualizar los `COMMENT ON FUNCTION` de las dos RPCs.
- [x] 2.8 Verificar que el CHECK de `reference_type` ya admite `sale_update`/`purchase_update` (confirmado en prod) — **no** se toca la constraint.
- [x] 2.9 Correr los gates del grupo 1 hasta GREEN. 19/19 PASS.

## 3. TRIANGULATE / REFACTOR

- [x] 3.1 Segundo caso por comportamiento: edición que **agrega** una línea nueva y edición que **elimina** una línea existente (no solo cambio de cantidad) — verificar el par espejo en ambos.
- [x] 3.2 Caso de colisión legacy: operación con dos filas de header del **mismo** `product_id` (forma 1-operación:N-filas) → los movimientos suman correctamente y el snapshot sigue siendo determinístico.
- [x] 3.3 Doble edición encadenada (editar dos veces seguidas) → la Σ del ledger sigue reconstruyendo `branch_stock` y no aparecen huérfanos sin cierre.
- [x] 3.4 Refactor: confirmar que no quedó ningún `PERFORM c21_apply_branch_stock_delta(...)` suelto en las dos RPCs de edición y que el helper es el único punto de escritura del ledger en la edición. Gates verdes después de cada paso. Verificado por grep: solo 2 `PERFORM public.op_stock_movement(...)` por RPC, cero `c21_apply_branch_stock_delta` directo.

## 4. CI y verificación de superficie

- [x] 4.1 Agregar el paso `Run stock movements edicion gates` a `.github/workflows/KPI_Validation.yml` (`psql -v ON_ERROR_STOP=1 ... -f supabase/tests/test_stock_movements_edicion.sql`), con el comentario explicativo que usa el resto del archivo.
- [x] 4.2 **Superficie frontend: sin pantallas nuevas.** Verificado en `frontend/components/stock/stock-movements-panel.tsx`: `MOVEMENT_META` ya tiene entradas para `sale`/`purchase`/`sale_return`/`purchase_return` con label, ícono y clasificación entrante/saliente; el panel clasifica por `type` (no por `reference_type`), así que los movimientos de edición se renderizan sin cambios. **Cero cambios en TSX** — la verificación no reveló ningún hueco.
- [x] 4.3 Desktop/mobile/claro/oscuro: sin superficie nueva que verificar (4.2) — el panel existente ya está cubierto por la regla PO 2026-08-02 desde que se construyó; esta migración no introduce ningún estado visual nuevo (mismos 4 `type` ya soportados).
- [x] 4.4 Confirmado que `backend/` no requiere cambios: `SalesRepository.delete_by_id` / `PurchaseRepository.delete_by_id` empiezan a encontrar el movimiento sin tocarse. `pytest tests/test_sales.py tests/test_purchases.py tests/test_sale_items.py` → 60/60 passed.

## 5. Backfill del ledger — **FIRMADO por el PO 2026-08-19: SÍ se ejecuta** (design §D6)

- [x] 5.1 Escribir `scripts/sql/backfill_stock_movements_operaciones.sql` — **solo INSERT, NO toca `branch_stock`** (el saldo ya es correcto; lo que falta es el asiento). Encabezado en mayúsculas advirtiéndolo.
- [x] 5.2 Alcance A: operaciones vivas con `product_id` y **cero** movimientos → un movimiento `sale`/`purchase` derivado del header, `quantity_before`/`quantity_after` NULL, `reason='backfill_edicion_sin_movimiento'`, `metadata.backfilled=true`.
- [x] 5.3 Alcance B (ventas/compras con movimiento `sale_update`/`purchase_update` de mayo 2026, bug de `20260527000002`): par sintético append-only de neto cero (cancela + re-apunta con `reference_type` correcto). Nunca `UPDATE` (RN-21). Incluido en el mismo script para venta y compra (el conteo real de compras se mide en el dry-run al ejecutar).
- [x] 5.4 Verificado localmente con datos sintéticos (4 casos: alcance A venta/compra, alcance B venta/compra) antes de tocar prod: dry-run conteos correctos (1/1/1/1), ejecución inserta exactamente lo esperado (6 filas: 2 alcance A + 4 alcance B cancel+correct), re-ejecución = 0 filas (idempotente), `branch_stock` bit-a-bit idéntico antes/después. **Ejecución real contra prod: PENDIENTE — corre post-merge de PR1 vía MCP con conteos antes/después, ver plan en el PR.**
- [ ] 5.5 Post-ejecución CONTRA PROD: verificar `ventas_delete_inseguras_total = 0` y `compras_delete_inseguras_total = 0`, y que `branch_stock` no cambió en ninguna fila. **Pendiente hasta después del merge de PR1** (instrucción explícita: ejecutar UNA vez post-merge).

## 6. Huérfanos históricos — **FIRMADO por el PO 2026-08-19: dejarlos como están** (design §D7)

- [x] 6.1 Presentado al PO las tres opciones con su fundamento (dejar / cerrar con movimiento sintético / re-apuntar) — decisión: **dejarlos** (opción (a), recomendada en design.md — el invariante de no-orfandad se acota "hacia adelante", nunca retroactivo sobre prod).
- [x] 6.2 N/A — el PO no eligió cerrar. Sin script de cierre sintético (`reason='cierre_edicion_historica'`) para esta ronda; puede proponerse como change/tarea aparte si el PO cambia de decisión más adelante.
- [x] 6.3 Corte temporal documentado: el gate 1.8/huérfanos de `test_stock_movements_edicion.sql` verifica no-orfandad solo sobre los anchors sintéticos de la transacción (nunca sobre datos históricos de prod), consistente con design §D7 ("el gate es de comportamiento sobre anchors sintéticos, no una aserción retroactiva"). Los 139 huérfanos históricos (62 venta + 77 compra) quedan documentados en `CHANGES.md` (task 7.1) como deuda conocida y acotada, sin acción.

## 7. Documentación

- [ ] 7.1 Actualizar `CHANGES.md`: ficha del change, cierre de **OQ-B** de `edicion-operaciones-lineas`, y el hallazgo nuevo (204 operaciones delete-inseguras; 77 huérfanos de compra nunca medidos).
- [ ] 7.2 Actualizar `knowledge-base/05_reglas_de_negocio.md`: RN-21 gana la precisión de que **la edición también asienta** en el ledger, y que un huérfano con contramovimiento de cierre es un estado válido.
- [ ] 7.3 Registrar en `CHANGES.md` la dimensión de **OQ-C** (6 `sales_orders` colgando): misma causa raíz que OQ-A, re-apuntar es técnicamente trivial pero el mapping no existe → revisión manual de 6 filas o esperar a OQ-A. **No es un change propio.**
- [ ] 7.4 `mem_save` con `topic_key: "opsx/stock-movements-edicion/apply"` al cerrar la implementación.
