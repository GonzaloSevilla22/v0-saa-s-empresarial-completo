## Context

El stock se reversa al eliminar una venta/compra **solo dentro del backend Python** (asyncpg); no hay trigger `ON DELETE` en `sales` ni `purchases` (verificado: el único trigger de `sales` es `on_sale_insert_margin_check`, AFTER INSERT). La reversa vive en `SalesRepository.delete_by_id` / `delete_by_operation` y sus espejos en `PurchaseRepository`.

Estado actual del código (post C-20 / C-21):

```python
item_row = fetchrow("SELECT product_id FROM sale_items WHERE sale_id=$1 AND product_id IS NOT NULL LIMIT 1", sale_id)
product_id = item_row["product_id"] if item_row else None
if product_id is not None:                       # ← gate
    movement = fetchrow("SELECT quantity_delta, branch_id FROM stock_movements WHERE reference_id=$1 AND reference_type='sale' LIMIT 1", sale_id)
    if movement: rpc_apply_product_stock_delta(product_id, -movement.quantity_delta, movement.branch_id)
    execute("DELETE FROM stock_movements ...")   # ← también dentro del gate
```

El gate asume que `sale_items` es la fuente de verdad (C-20). Pero hay tres rutas de creación y solo una escribe `sale_items`:

| Ruta | `sale_items` | `stock_movements` | `branch_id` en `sales` |
|---|---|---|---|
| `rpc_create_sale_operation_v2` (flag ON) | ✅ | ✅ | normalmente NULL |
| `rpc_create_sale_operation` legacy (flag OFF) | ❌ | ✅ | — |
| C-29 `rpc_quick_sale` / `rpc_confirm_sales_order` (POS) | ❌ | ✅ | seteado |

La ruta C-29 escribe en `sales` + `stock_movements` (`reference_type='sale'`) + decrementa `branch_stock`, pero usa `sales_order_items` y **nunca** inserta en `sale_items`. Para esas ventas `product_id=None` → el bloque entero se saltea → no se reversa el stock y la fila de `stock_movements` queda huérfana. Confirmado en producción: ventas con `branch_id` seteado tienen `n_sale_items=0`, `n_stock_mov=1`. `PurchaseRepository` tiene el mismo patrón gateando por `purchase_items`.

## Goals / Non-Goals

**Goals:**
- Que eliminar una venta o compra reponga el stock para **toda** ruta de creación.
- Eliminar la fila de `stock_movements` siempre que exista (no dejar huérfanos).
- Corregir el bug espejo en compras en el mismo change (paridad).
- Reponer el stock de las operaciones ya eliminadas sin reversa (backfill puntual e idempotente).

**Non-Goals:**
- Unificar las rutas de creación de ventas (que C-29 escriba `sale_items`) — fuera de alcance; el fix no depende de eso.
- Cambiar contratos HTTP, schemas Pydantic o el frontend.
- Tocar la lógica de creación / descuento de stock (solo la de borrado).
- Mover la reversa a un trigger de DB (se mantiene en el repositorio, consistente con la arquitectura actual).

## Decisions

**D1 — Leer los datos de reversa desde `stock_movements`, no desde `sale_items`/`purchase_items`.**
`stock_movements` ya contiene las tres columnas necesarias (`product_id`, `quantity_delta`, `branch_id`) y la escribe toda ruta de creación. La query pasa a:

```python
movement = fetchrow(
  "SELECT product_id, quantity_delta, branch_id FROM stock_movements "
  "WHERE reference_id=$1::uuid AND reference_type='sale' LIMIT 1", sale_id)
if movement and movement["product_id"] is not None and movement["quantity_delta"] is not None:
    rpc_apply_product_stock_delta(movement["product_id"], -movement["quantity_delta"], movement["branch_id"])
    execute("DELETE FROM stock_movements WHERE reference_id=$1::uuid AND reference_type='sale'", sale_id)
```

Se elimina por completo el `SELECT ... FROM sale_items`. El `DELETE FROM stock_movements` queda dentro del bloque "hay movimiento" (si no hay movimiento, no hay nada que borrar). Las líneas de servicio (sin `product_id`, sin movimiento) caen naturalmente al camino sin reversa.

- *Alternativa A (descartada):* leer `product_id` desde la columna `sales.product_id` y mantener la query a `stock_movements` para delta/branch. Funciona pero usa dos fuentes; `stock_movements` ya tiene todo en una fila → menos consultas, una sola fuente.
- *Alternativa B (descartada):* fallback `sale_items` → si NULL, `sales.product_id`. Mantiene el gate frágil; innecesario.
- *Alternativa C (descartada):* mover la reversa a un trigger `ON DELETE`. Cambio mayor de arquitectura y de gobernanza; no es el problema a resolver.

**D2 — Aplicar el mismo cambio al espejo de compras.** `PurchaseRepository.delete_by_id` / `delete_by_operation` con `reference_type='purchase'`. La compra es una **entrada** de stock (`quantity_delta > 0`); la reversa `-quantity_delta` la decrementa, lo cual es correcto.

**D3 — Backfill por movimientos huérfanos.** Una fila de `stock_movements` con `reference_type IN ('sale','purchase')` cuyo `reference_id` **ya no existe** en `sales`/`purchases` corresponde a una operación eliminada por la ruta buggeada (el código viejo borraba el movimiento solo cuando reversaba). El backfill, idempotente: por cada huérfano, aplicar `-quantity_delta` a `branch_stock` y luego borrar la fila. Como se borra tras reversar, re-correrlo no doble-aplica. Se ejecuta como script SQL revisado, no como migración de schema.

**D4 — TDD.** Tests de regresión que cubran las tres rutas de creación para ventas (la C-29 es la que hoy falla) y el espejo de compras, antes de tocar el backfill de datos.

## Risks / Trade-offs

- **El backfill toca cantidades de stock reales en producción** → ejecutarlo en una transacción, con un `SELECT` previo del conjunto afectado para revisión humana explícita (gobernanza: dato sensible), y guardar el detalle (product_id, branch_id, delta) antes de aplicar. Idempotente por diseño (D3).
- **Doble reversa si el script no es idempotente** → mitigado: el backfill borra el huérfano tras reversar; un segundo run no encuentra el huérfano. Los tests verifican idempotencia.
- **`branch_id` NULL en movimientos antiguos** → `rpc_apply_product_stock_delta` con branch NULL aplica a la branch por defecto (helper C-21); es el mismo comportamiento que ya tenía el path de borrado, sin regresión.
- **Falsos positivos en el conjunto de huérfanos** → bajo: el código viejo solo borraba el movimiento cuando reversaba, así que un huérfano implica una eliminación sin reversa. Igual se revisa el `SELECT` previo antes de aplicar.

## Migration Plan

1. Corregir `SalesRepository` (D1) + tests de las tres rutas (D4) en RED→GREEN.
2. Corregir `PurchaseRepository` (D2) + tests espejo.
3. Generar el `SELECT` del conjunto de huérfanos (ventas y compras) y revisarlo.
4. Ejecutar el backfill (D3) en transacción contra `gxdhpxvdjjkmxhdkkwyb`.
5. Re-correr el `SELECT` de huérfanos → debe dar 0.
- **Rollback código:** revertir el commit (vuelve al gate por `sale_items`; el comportamiento previo se preserva para la ruta v2).
- **Rollback datos:** el backfill se documenta con el detalle por fila; si hiciera falta revertir, re-aplicar el delta opuesto sobre las filas registradas.

## Open Questions

- ¿Conviene que C-29 escriba también `sale_items` para unificar la fuente de verdad? Es deuda separada (Non-Goal aquí); este fix la vuelve innecesaria para el borrado, pero seguiría siendo deseable para listados/reporting que asuman `sale_items`.
