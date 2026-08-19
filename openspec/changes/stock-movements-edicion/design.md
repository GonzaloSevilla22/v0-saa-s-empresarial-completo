# Design — stock-movements-edicion

## Context

### Mapa completo de emisión de `stock_movements` HOY

Verificado en prod `gxdhpxvdjjkmxhdkkwyb` (2026-08-19) con `pg_proc.prosrc` + `pg_get_functiondef`, y contra `backend/repositories/*.py`. **Solo SELECTs.**

| Ruta | Mueve `branch_stock` | Emite `stock_movements` | Cómo |
|---|---|---|---|
| `rpc_create_sale_operation` (legacy) | ✅ `c21_apply_branch_stock_delta` | ✅ | `type='sale'`, `reference_type='sale'` |
| `rpc_create_sale_operation_v2` | ✅ `c21` | ✅ | ídem |
| `rpc_create_purchase_operation` (+ `_v2`) | ✅ `c21` | ✅ | `type='purchase'`, `reference_type='purchase'` |
| `rpc_quick_sale` → `_c29_confirm_order_core` | ✅ `c21` | ✅ | POS; `reference_type='sale'` |
| `rpc_confirm_sales_order` → `_c29_confirm_order_core` | ✅ `c21` | ✅ | ídem |
| **`rpc_atomic_update_sale_operation`** | ✅ `c21` (×2: REVERSE y APPLY) | ❌ **HUECO** | — |
| **`rpc_atomic_update_purchase_operation`** | ✅ `c21` (×2) | ❌ **HUECO** | — |
| DELETE venta/compra (`SalesRepository.delete_by_id`, `delete_by_operation`, espejo en compras) | ✅ vía `rpc_apply_product_stock_delta` | ✅ | `rpc_reverse_stock_movement` → `type='sale_return'`, `reference_type='sale_reversal'` |
| `rpc_stock_adjustment` | ✅ | ✅ | ajuste manual |
| `rpc_adjust_branch_stock` | ✅ | ✅ | ajuste por sucursal |
| `rpc_apply_product_stock_delta` | ✅ | ✅ si `p_log_movement` | primitiva compartida; también loguea el *floor-a-cero* |
| `rpc_transfer_stock` | ✅ | ✅ | `transfer_in` / `transfer_out` |
| `rpc_promote_legacy_sale_to_order` | ❌ (falso positivo de grep: la única mención de `branch_stock` es el comentario "NO se toca") | ❌ | side-effect-free por diseño (D1 de su change) — **no es un hueco** |
| Importador `rpc_bulk_upsert_products` | escribe stock inicial | `type='initial'` (43 filas, 2026-05-09) | — |

**El hueco es exactamente el que declara OQ-B, y solo ese**: las dos RPCs de edición. Todo el resto del write path emite. Medido, no asumido.

### El hueco es peor que un agujero de auditoría

`SalesRepository.delete_by_id` (`backend/repositories/sales_repository.py:86-119`) y su espejo en compras derivan la reversa de stock **leyendo `stock_movements`**:

```python
await self._conn.fetch(
    "SELECT * FROM public.rpc_reverse_stock_movement($1::uuid, 'sale', $2)", sale_id, "Venta eliminada")
await self._conn.execute("DELETE FROM sales WHERE id = $1::uuid", sale_id)
```

`rpc_reverse_stock_movement` itera `WHERE reference_id = p_reference_id AND reference_type = p_reference_type AND account_id = ...`. Fue una decisión deliberada (`v31-tenancy-pool-rls` colisión #3 + el requirement "independiente de la ruta de creación" del spec): el ledger es la fuente de la reversa porque `sale_items` no existe en la ruta POS.

Como la edición hace `DELETE` del header e `INSERT` con **id nuevo** sin emitir movimiento, la operación editada queda **sin movimiento de referencia**. Al eliminarla: el `FOR` recorre **cero** filas, no hay excepción, `DELETE FROM sales` corre igual → **el stock no vuelve y nadie se entera**. No es teórico: **204 operaciones vivas están hoy en ese estado**.

### Estado de los datos en prod (2026-08-19)

| Medición | Ventas | Compras |
|---|---|---|
| Filas vivas con `product_id` | 652 | 412 |
| …**sin** movimiento `reference_type='sale'\|'purchase'` (delete-inseguras) | **112** (17%) | **92** (22%) |
| …de esas, con **algún** movimiento (los `*_update` de mayo) | 13 | a medir en apply |
| Movimientos huérfanos (`reference_id` inexistente) | 62 | **77** |
| …sin contramovimiento de cierre | 57 | 36 |
| Pares `(product_id, branch_id)` con Σ `quantity_delta` ≠ `branch_stock.quantity` | 1376 / 3522 | — |
| `sales_orders` colgando (OQ-C) | 6 / 120 | — |

Las 112 ventas sin movimiento son consistentes con las 119 ventas sin línea que midió `edicion-operaciones-lineas`: **es la misma población** — las editadas.

### La huella del cableado perdido (prueba, no conjetura)

`stock_movements` por `(reference_type, type)`:

| `reference_type` | `type` | n | primera | última |
|---|---|---|---|---|
| `sale_update` | `sale_return` | 20 | 2026-05-27 | 2026-06-05 |
| `sale_update` | `sale` | 19 | 2026-05-27 | 2026-06-05 |
| `purchase_update` | `purchase_return` | 38 | 2026-05-27 | 2026-06-01 |
| `purchase_update` | `purchase` | 40 | 2026-05-27 | 2026-06-01 |

117 filas, **todas** dentro de la ventana en que vivió `20260527000002_wire_movements_to_rpcs.sql`, ninguna después. Dos conclusiones duras:

1. El cableado existió y murió — confirmado con datos, no solo con `git log`.
2. **La semántica original era ESPEJO**, no neto: cada edición dejaba un `*_return` (pata REVERSE) **y** un `sale`/`purchase` (pata APPLY). El CHECK de `reference_type` todavía admite `sale_update`/`purchase_update` (nunca se removió), así que el vocabulario está disponible sin tocar la constraint.

### Quién consume `stock_movements`

- **UI, visible al usuario**: `frontend/app/(dashboard)/stock/page.tsx:203` monta `<StockMovementsPanel />` (`frontend/components/stock/stock-movements-panel.tsx`), que hace `.from("stock_movements")` directo, agrupa por tabs entrante/saliente/ajustes y exporta CSV. Su `MOVEMENT_META` **ya** tiene entradas para `sale`, `purchase`, `sale_return` ("Dev. venta", entrante) y `purchase_return` ("Dev. compra", saliente). El panel clasifica por `type`, **no** por `reference_type` → los movimientos de edición se renderizan correctamente sin una línea de TSX nueva.
- **Backend**: `StockRepository.list_movements` (`backend/repositories/stock_repository.py:38`) y, críticamente, el **delete path** descrito arriba.
- **Ledger append-only**: policies `stock_movements_no_update` y `stock_movements_no_delete` con `qual=false`; **sin triggers** de inmutabilidad (`pg_trigger` vacío). RN-21: correcciones solo por movimientos nuevos.

Conclusión: **el hueco es visible al usuario final**, no interno. El panel de `/stock` miente por omisión desde junio.

## Goals / Non-Goals

**Goals**

1. La edición emite el par espejo de movimientos por cada línea con producto, en la misma transacción que mueve `branch_stock`.
2. La pata APPLY es indistinguible de la creación (`reference_type='sale'|'purchase'`) → **la eliminación de una operación editada vuelve a reponer stock**.
3. Reutilizar el snapshot que la RPC ya resuelve (`op_line_snapshot`, PR #415) para `unit_cost_snapshot`, sin re-valuar.
4. Gate de comportamiento en CI que detecte la regresión si el cableado se vuelve a perder.
5. Dimensionar (no ejecutar) la reparación del historial.

**Non-Goals**

- **OQ-A** (identidad regenerada, `UPDATE` in-place): no se toca. Este change hace que el ledger cuente la verdad de lo que la edición hace, no cambia lo que hace.
- **OQ-C** (editar operación facturada), **OQ-D** (`branch_id`/`canal`/`cost_center_id` perdidos, gate global vs per-branch), **OQ-G** (`quantity integer`): fuera.
- Backfill y huérfanos: **diseñados acá, ejecución gateada** (D6/D7).
- Sin pantallas nuevas.

## Decisions

### D1 — Espejo (REVERSE + APPLY), no neto

Tres razones convergentes, en orden de peso:

1. **Correctitud, no estética**: el neto sería un único movimiento de diferencia, que solo puede ser `type='adjustment'` o un `sale` de delta parcial. Ninguno de los dos deja una fila `reference_type='sale'` con el `quantity_delta` **total** de la operación viva — y el delete path aplica `-quantity_delta` de lo que encuentra. Con un neto de `-2` sobre una venta que hoy vale 3 unidades, eliminarla repondría 2 y perdería 1. **El neto rompe la eliminación.** El espejo no.
2. **Precedente del propio sistema**: es lo que hacía `20260527000002` (117 filas en prod lo demuestran) y es exactamente el patrón que ya usa el delete path (contramovimiento + movimiento, nunca mutación).
3. **Consumidor**: el panel de `/stock` renderiza `sale_return`/`purchase_return` con label e ícono propios. El neto aparecería como "Ajuste" amarillo, sin vínculo con la operación.

Costo aceptado: dos filas por línea editada en vez de una. Con 112 ediciones acumuladas en 5 meses, el volumen es irrelevante.

### D2 — `reference_type` asimétrico: `*_update` en la reversa, `sale`/`purchase` en la aplicación

La única desviación deliberada respecto de `20260527000002`, que usaba `*_update` en **ambas** patas.

| Pata | `type` | `reference_id` | `reference_type` |
|---|---|---|---|
| REVERSE | `sale_return` / `purchase_return` | id **viejo** (a punto de morir) | `sale_update` / `purchase_update` |
| APPLY | `sale` / `purchase` | id **nuevo** | `sale` / `purchase` |

- La pata APPLY **debe** llevar `reference_type='sale'`: es la condición literal que `rpc_reverse_stock_movement` filtra. Con `sale_update` (como en 2026-05) la operación editada seguiría siendo delete-insegura — de hecho **13 de las 112** ventas sin movimiento de referencia sí tienen un movimiento `sale_update`: son las editadas en la ventana de mayo, y arrastran el mismo bug. La asimetría no es un capricho: es la corrección del diseño de 2026-05.
- La pata REVERSE conserva `*_update` porque distingue en columna (no en texto libre) "revertido por edición" de "revertido por eliminación" (`*_reversal`). Ambos quedan igualmente excluidos del filtro del delete path, que es lo que importa.
- Semánticamente es coherente: **después de la edición, la fila nueva ES la operación viva**, y su movimiento debe verse igual que si se hubiera creado así. Ese es justamente el invariante que se quiere.

### D3 — Helper canónico `op_stock_movement`, no cuatro INSERT copiados

Hoy las dos RPCs tienen cuatro `PERFORM public.c21_apply_branch_stock_delta(...)` sueltos (REVERSE y APPLY × venta y compra). `c21_apply_branch_stock_delta` devuelve `void`: no da `quantity_before`/`quantity_after`, que el panel muestra y el invariante necesita.

Helper nuevo, misma familia de nombres que `op_line_snapshot` (PR #415):

```
public.op_stock_movement(
  p_account_id uuid, p_uid uuid, p_product_id uuid, p_product_name text,
  p_branch_id uuid, p_delta numeric, p_type text, p_reference_id uuid,
  p_reference_type text, p_operation_group_id uuid, p_unit_cost numeric,
  p_reason text, p_metadata jsonb
) RETURNS uuid   -- id del movimiento
```

Cuerpo: `PERFORM c21_apply_branch_stock_delta(...)` (la aritmética **no cambia**, incluido el lazy-create de sucursal) → resolver `v_branch := COALESCE(p_branch_id, c26_default_branch(p_account_id))` → leer `quantity` de `branch_stock` como `after` → `before := after - p_delta` (exacto, una sola lectura, inmune al lazy-create) → `INSERT INTO stock_movements`.

**Por qué NO reusar `rpc_apply_product_stock_delta`** (que sí devuelve before/after y es lo que usa `rpc_reverse_stock_movement`): valida stock **por sucursal** y lanza `P0409` si no alcanza. Las RPCs de edición gatean con `Σ branch_stock` **global** (OQ-D, deliberadamente fuera de alcance). Sustituirlas haría fallar ediciones que hoy pasan — un cambio de comportamiento encubierto. `SECURITY DEFINER` + `SET search_path` + `REVOKE ALL` como `op_line_snapshot` (solo invocable desde dentro de las RPCs dueñas; no despierta `test_function_acl_gate.sql`).

### D4 — La reversa se deriva del header, no del ledger

Tentación descartada: llamar `rpc_reverse_stock_movement(old_id, 'sale', ...)` en STEP 1 y quedarse con una sola línea de código. **No.** Esa función deriva la reversa **de los movimientos existentes**; para las 112 operaciones que hoy no tienen ninguno devolvería cero filas y **dejaría de reponer stock en la edición** — una regresión inmediata sobre datos reales. STEP 1 conserva `c21_apply_branch_stock_delta` alimentado por `sales.quantity` (el header es la verdad del delta) y **suma** la emisión del movimiento. La RPC de edición es la autoridad sobre cuánto se movió; el ledger la registra, no la define.

### D5 — `unit_cost_snapshot` reusa `op_line_snapshot`

`stock_movements.unit_cost_snapshot` existe (requirement "Costo unitario congelado…" de `inventory-single-ledger`). El bloque APPLY ya calcula `v_line_snap := op_line_snapshot(v_prev_snap, v_product.name, v_product.sku, v_product.cost)`. Se pasa `(v_line_snap->>'unit_cost_snapshot')::numeric` al helper. Cero lógica de acarreo duplicada — la decisión "acarrea vs re-congela" vive en **un** lugar, como fijó D4 del PR #415. La pata REVERSE copia el `unit_cost_snapshot` del movimiento original si existe, si no `NULL` (no se inventa costo histórico).

**Orden dentro del bloque APPLY**: `INSERT sales` → `INSERT sale_items` → `op_stock_movement`. Preserva el orden que verifica `backend/tests/migrations/test_c29_write_sale_items.py` (`sales` → `sale_items` → `stock_movements`) y absorbe el `PERFORM c21_...` que hoy está al final.

### D6 — Backfill de las 204 operaciones delete-inseguras — **GATEADO a sign-off del PO**

Sin backfill, este change arregla el futuro y deja 204 operaciones vivas cuya eliminación sigue sin reponer stock.

Propuesta: `scripts/sql/backfill_stock_movements_operaciones.sql`, mismo patrón que `backfill_operation_lines.sql` de `edicion-operaciones-lineas`.

- **Solo INSERT. NO toca `branch_stock`.** `branch_stock` ya es correcto (la edición sí movió stock); lo que falta es el asiento. Un backfill que "reponga" stock corrompería el saldo de toda cuenta editada. Esto es lo primero que debe entender quien lo ejecute.
- Alcance A (99 filas de ventas + las compras equivalentes): operaciones vivas con `product_id` y **cero** movimientos. INSERT de un movimiento `type='sale'|'purchase'`, `reference_type='sale'|'purchase'`, `quantity_delta = ∓quantity` derivado del header, `branch_id` del header (o `c26_default_branch`), `quantity_before`/`quantity_after` **NULL** (no se puede reconstruir el instante histórico y no se va a inventar), `reason='backfill_edicion_sin_movimiento'`, `metadata={"backfilled":true,"change":"stock-movements-edicion"}`. Compatible con RN-21 (append-only admite INSERT).
- Alcance B (13 ventas con movimiento `sale_update` de mayo): re-apuntar el `reference_type` sería un `UPDATE` → **prohibido por RN-21**. Alternativa append-only: par sintético (`sale_return`/`sale_update` que cancela el viejo + `sale`/`sale` correcto), **neto cero sobre el ledger**, que restaura el delete path sin mutar nada. Más honesto que un UPDATE, más ruidoso que dejarlo. **Decisión del PO.**
- Verificación post-backfill: `live_*_sin_movement = 0` y Σ del ledger por `(product, branch)` sin cambio respecto de la medición previa (el backfill NO debe mover el saldo… salvo por el asiento faltante, cuyo efecto se cuantifica y se reporta antes de ejecutar).

### D7 — Los 139 huérfanos históricos — **recomendación: dejarlos, GATEADO**

62 de venta (57 sin cierre) + 77 de compra (36 sin cierre).

Primero, una precisión que la formulación original de OQ-B no tenía: **un huérfano no es por sí mismo un defecto**. El delete path emite el contramovimiento y **después** hace `DELETE FROM sales` — o sea que **toda** eliminación normal deja el movimiento original apuntando a una fila inexistente. Eso es correcto y esperado. El defecto es el huérfano **sin contramovimiento de cierre**: ahí el ledger dice "salió stock" y no hay ningún asiento que lo devuelva, aunque `branch_stock` sí volvió (lo hizo la edición, mudamente).

Opciones evaluadas:

| Opción | Veredicto |
|---|---|
| (a) Dejarlos, documentados, y acotar el invariante a "hacia adelante" | ✅ **Recomendada** |
| (b) Borrarlos | ❌ Viola RN-21 (ledger append-only, ni UPDATE ni DELETE) y destruye evidencia de que la venta existió. La política de `stock_movements` los protege por diseño |
| (c) Re-apuntar `reference_id` al id nuevo | ❌ Requiere `UPDATE` (RN-21) **y** el mapping viejo→nuevo **no existe**: la edición no lo persiste en ningún lado. Cualquier heurística (mismo producto + cantidad + fecha) es adivinanza sobre datos contables. Además duplicaría con el movimiento nuevo |

**Recomendación (a)**, con dos entregables baratos: (1) un movimiento de cierre sintético por cada huérfano sin cierre — append-only, `type='sale_return'`/`reference_type='sale_update'`, `quantity_delta` opuesto, `quantity_before/after` NULL, `reason='cierre_edicion_historica'` — que restablece la **paridad** del ledger sin tocar `branch_stock`, o (2) simplemente un corte temporal en el gate. La opción (1) hace que el invariante de no-orfandad pase también sobre el historial y evita un umbral mágico que se pudra; la (2) es cero riesgo. **Ambas GATEADAS: elige el PO.** Nada de esto se ejecuta en el grupo autónomo.

El desvío global Σledger vs `branch_stock` (**1376 / 3522 pares**) confirma que el invariante **no** puede afirmarse retroactivamente sobre prod: arrastra ajustes manuales, la era `products.stock` pre-C-21 y estos huecos. Por eso el gate es de comportamiento sobre anchors sintéticos (D8), no una aserción sobre datos de producción.

### D8 — Gates de comportamiento (Strict TDD)

Archivo nuevo `supabase/tests/test_stock_movements_edicion.sql` + paso en `.github/workflows/KPI_Validation.yml`. Patrón de `test_operation_edit_lines.sql`: anchors sintéticos vía `handle_new_user`, sesión simulada con `set_config` **LOCAL a la transacción del archivo** (nunca contra prod), fallos acumulados en `text[]`, un `RAISE EXCEPTION` final.

Casos (cada uno RED antes que GREEN):

1. **Crear** emite movimiento `reference_type='sale'` con `quantity_delta` correcto (control negativo del gate: debe fallar si alguien apaga la emisión de la creación).
2. **Editar cantidad** (5→3) emite el **par espejo**: `+5`/`sale_return`/`sale_update` sobre el id viejo y `-3`/`sale`/`sale` sobre el id nuevo.
3. **Editar producto** (A→B) emite movimientos de **ambos** productos con los signos correctos.
4. **Eliminar** emite contramovimiento y repone `branch_stock`.
5. **Eliminar una operación EDITADA repone stock** — el gate que prueba que el bug de fondo murió (falla hoy).
6. **Σ reconstruye**: sobre la secuencia crear→editar→eliminar, Σ `quantity_delta` por `(product_id, branch_id)` == delta total de `branch_stock`, y el stock final == inicial.
7. **Huérfanos nuevos = 0**: dentro de los anchors, ningún movimiento `reference_type IN ('sale','purchase')` queda sin fila viva **ni** sin contramovimiento de cierre.
8. **`unit_cost_snapshot` no se re-valúa**: `products.cost` movido entre creación y edición → el movimiento de la pata APPLY conserva el costo viejo (control positivo, calcado de D2 del PR #415).
9. **Línea de servicio** (`product_id NULL`): cero movimientos, sin error.
10. **Guards intactos**: `P0400`/`P0403`/`P0409`/`P0422` y el acarreo de snapshot de línea siguen pasando (no-regresión sobre el PR #415).

## Risks / Trade-offs

- **Reescribir dos RPCs de 8k caracteres** → riesgo de perder algo del PR #415. Mitigación: `CREATE OR REPLACE` **sin cambio de firma**, partiendo del cuerpo vigente en `20260926000001` (base verificada en prod), con el diff acotado a: reemplazar los 4 `PERFORM c21_...` por `PERFORM op_stock_movement(...)` y agregar `operation_id` al `SELECT` de STEP 1. El gate 10 cubre la no-regresión.
- **Volumen del ledger**: ×2 filas por línea editada. Despreciable (117 movimientos de edición en 5 meses de operación real).
- **La pata REVERSE nace huérfana por diseño** (apunta a un id que la misma transacción borra). Riesgo de que un gate ingenuo la marque como defecto. Mitigado explícitamente en el spec: los `*_update` / `*_reversal` quedan fuera del chequeo de no-orfandad.
- **Sin `p_branch_id` en la firma**, la pata APPLY sigue cayendo a la sucursal default mientras la REVERSE devuelve a la sucursal original (asimetría preexistente, OQ-D). Los movimientos **registrarán fielmente** esa asimetría — el ledger la vuelve visible por primera vez. No se corrige acá; queda evidenciada para OQ-D.
- **Backfill no ejecutado** = 204 operaciones siguen delete-inseguras después de mergear el grupo autónomo. Es una elección consciente de gobernanza (datos de prod), no un olvido.

## Migration Plan

1. `supabase/migrations/20260927000001_stock_movements_edicion.sql` — `MAX(version)` en prod verificado = `20260926000001`, sin colisión. Idempotente (`CREATE OR REPLACE` en las tres funciones; `REVOKE`/`GRANT` re-emitidos en el mismo archivo por si un `DROP` futuro resetea ACLs).
2. Sin cambio de firma → **sin `DROP`**, sin gotcha 42725, sin ventana de 403.
3. **Sin cambio en el CHECK de `reference_type`**: `sale_update` / `purchase_update` ya están admitidos desde `20260527000001`. Verificado en prod.
4. Frontend sin cambios; verificación visual del panel de `/stock` (desktop + mobile, claro + oscuro) como tarea de QA.
5. **Rollback**: re-aplicar la definición de `20260926000001` para las dos RPCs (el helper `op_stock_movement` queda huérfano e inocuo). No hay estado nuevo que revertir — el ledger es append-only y los movimientos emitidos son correctos aunque se revierta el código.

## Open Questions

- **OQ-1 — Backfill de las 204 operaciones delete-inseguras (D6)**: ¿se ejecuta? ¿Alcance A solo, o también el par sintético del alcance B (13 ventas de mayo)? **Requiere sign-off del PO.**
- **OQ-2 — Huérfanos históricos (D7)**: ¿cierre sintético append-only, o corte temporal en el gate? Recomendación: cierre sintético (deja el invariante limpio hacia atrás y hacia adelante). **Requiere sign-off del PO.**
- **OQ-3 — OQ-C (6 `sales_orders` colgando), dimensionada acá**: la causa **es** la misma regeneración de ids de OQ-A — `sales_orders.sale_operation_id` es una referencia **blanda** (sin FK) al `operation_id`, y la edición lo regenera. Re-apuntarlas **sí es técnicamente trivial** (`UPDATE sales_orders`, tabla mutable, sin RN que lo impida) **pero el mapping viejo→nuevo no existe**: habría que adivinar por `(account_id, total, fecha, cliente)` sobre 6 filas, y un match errado ata una orden confirmada a la venta equivocada. **Recomendación: no re-apuntar a ciegas; revisión manual de 6 casos por el PO, o esperar a OQ-A** (con `UPDATE` in-place el problema desaparece de raíz y estas 6 quedan como residuo histórico). No es un change propio; es un ítem del change de OQ-A o una tarea manual de 6 filas.
- **OQ-4 — ¿El gate debería extenderse a la ruta POS/C-29?** El caso 1 cubre la creación v2/legacy. `rpc_quick_sale` emite correctamente hoy, pero no tiene gate anti-regresión propio. Barato de agregar si el PO lo quiere; no está en el alcance de este change.
