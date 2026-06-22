## Context

`_c29_confirm_order_core` (SECURITY DEFINER, `20260702000001_c29_quote_salesorder.sql`) es el helper compartido por `rpc_confirm_sales_order` y `rpc_quick_sale`. Dentro de su loop sobre `sales_order_items`, para cada línea con `product_id` hace: gate de stock per-branch → `c21_apply_branch_stock_delta` → `INSERT INTO sales` → `INSERT INTO stock_movements`. **Falta** el `INSERT INTO sale_items` que sí hace `rpc_create_sale_operation_v2`. La spec `sale-line-items` ya exige esa escritura (requirement de confirm, C-29) — la implementación quedó corta.

`v_sales_flat` hace `COALESCE(si.col, s.col)` al header, así que las ventas C-29 hoy se ven correctas en listados/reporting **vía el fallback**, no porque tengan `sale_items`. Eso enmascaró el drift y bloquea el DROP del header plano (C-20 Grupo 10).

## Goals / Non-Goals

**Goals:**
- Que `rpc_quick_sale` y `rpc_confirm_sales_order` escriban `sale_items` para líneas con producto, en la transacción del header.
- Backfill idempotente de las ventas con producto que hoy no tienen ítem.
- Tests que prueben el INSERT por ambas rutas C-29.

**Non-Goals:**
- DROP del header plano (C-20 Grupo 10) — este change lo desbloquea, no lo ejecuta.
- Tocar la lógica de stock/caja/fiscal/outbox del confirm (solo se agrega el INSERT de ítem).
- Representar líneas de servicio en `sale_items` (sigue reservado `product_id IS NULL` para variantes del importador).
- Backfill de compras (otro dominio).

## Decisions

**D1 — Agregar el INSERT a `sale_items` dentro del bloque de producto del core.** Justo después del `INSERT INTO sales ... RETURNING id INTO v_new_sale_id`, espejando v2:

```sql
INSERT INTO public.sale_items (
  sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal
) VALUES (
  v_new_sale_id, v_item.product_id, v_account_id, NULL,
  v_item.quantity, v_item.unit_id, v_item.price, v_item.subtotal
);
```

`sales_order_items` aporta `product_id, account_id (=v_account_id), unit_id, quantity, price, subtotal`; no tiene `variant_id` → NULL (consistente con v2). La migración es un `CREATE OR REPLACE FUNCTION` que **reproduce el cuerpo actual completo** con esta única adición (no se puede editar in-place una función plpgsql).

- *Alternativa (descartada):* un trigger `AFTER INSERT ON sales` que derive `sale_items`. Acoplaría todas las rutas a un trigger global y rompería la semántica de v2 (que ya inserta su propio ítem) → doble fila. Descartado.

**D2 — Backfill desde las columnas planas de `sales`.** Reusa la lógica del backfill C-20 (`20260616000002`): por cada `sales` con `product_id NOT NULL` sin fila en `sale_items`, insertar `(sale_id=s.id, product_id=s.product_id, account_id=s.account_id, variant_id=NULL, quantity=s.quantity, unit_id=s.unit_id, price=s.amount, subtotal=COALESCE(s.total, s.amount*s.quantity))`. Guard `NOT EXISTS` → idempotente. No toca filas de variantes (`product_id IS NULL`).

**D3 — Migración de prod vía CLI (`npx supabase db push`), nunca el MCP `apply_migration`** (regla dura del proyecto: el MCP desincroniza el historial). El backfill puede ir en la misma migración (DML tras el DDL) o como script; se incluye en la migración para que viaje con el deploy.

## Risks / Trade-offs

- **Reproducir mal el cuerpo del `_c29_confirm_order_core`** → mitigar: copiar textual el cuerpo vigente y diffear; tests de confirm/quickSale (stock + caja + idempotencia + sale_items) deben seguir verdes.
- **Doble fila de ítem si alguna ruta ya inserta** → no aplica: C-29 hoy no inserta `sale_items`; v2 es un RPC distinto. El backfill usa `NOT EXISTS`.
- **Idempotencia del confirm** → intacta: el INSERT de ítem va dentro del mismo camino que ya es idempotente por `operation_idempotency`; en replay el core retorna antes del loop.
- **Backfill sobre `subtotal` NULL** → `COALESCE(s.total, s.amount*s.quantity)` cubre filas planas sin `total`.

## Migration Plan

1. Nueva migración: `CREATE OR REPLACE _c29_confirm_order_core` (cuerpo actual + INSERT sale_items) + backfill DML idempotente + re-aplicar REVOKE/COMMENT.
2. Tests (apply): confirm escribe `sale_items`; quickSale escribe `sale_items`; idempotencia; línea de servicio no genera ítem.
3. Aplicar a `gxdhpxvdjjkmxhdkkwyb` con `npx supabase db push`.
4. Gate de validación: `SELECT count(*) FROM sales WHERE product_id IS NOT NULL AND NOT EXISTS (sale_items)` → 0.
- **Rollback**: `CREATE OR REPLACE` con el cuerpo previo (sin el INSERT). El backfill no se revierte (filas `sale_items` correctas; si hiciera falta, borrar las creadas por el script identificándolas por `variant_id IS NULL` + `sale_id` del conjunto).

## Open Questions

- Tras este change, ¿se habilita el C-20 Grupo 10 (DROP header plano)? Queda como decisión separada del PO (depende de que ningún otro consumidor lea las columnas planas).
