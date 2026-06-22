## Why

La spec `sale-line-items` ya exige (requirement "SalesOrder.confirm() es una ruta de escritura adicional del ledger de ventas", C-29) que `SalesOrder.confirm()`/`quickSale()` escriban la línea en `sale_items`. Pero la implementación shippeada (`_c29_confirm_order_core` en `20260702000001_c29_quote_salesorder.sql`) **no lo hace**: escribe `sales` + `stock_movements` y nunca `sale_items` (usa `sales_order_items`). Es un drift spec↔implementación con dos consecuencias reales: (1) forzó que el fix de reposición de stock al borrar leyera de `stock_movements` en vez de `sale_items`; (2) **bloquea el C-20 Grupo 10** (DROP del header plano de `sales`), porque las ventas C-29 hoy dependen del fallback al header en `v_sales_flat` — sin `sale_items` real, post-DROP quedarían sin datos de línea.

## What Changes

- `_c29_confirm_order_core`: insertar una fila en `sale_items` por cada línea con producto, en la misma transacción que el `sales` INSERT, espejando `rpc_create_sale_operation_v2` (`sale_id`, `product_id`, `account_id`, `variant_id = NULL`, `quantity`, `unit_id`, `price`, `subtotal`). Cubre `rpc_confirm_sales_order` y `rpc_quick_sale` (ambos pasan por el core). Las líneas de servicio (sin `product_id`) siguen sin ítem, igual que la ruta v2.
- Backfill idempotente: reconstruir `sale_items` para las ventas con `product_id` que hoy no tienen ítem (11: 9 legacy + 2 C-29), desde las columnas planas de `sales` (`amount`→`price`, `total`→`subtotal`), con `variant_id = NULL`. Re-ejecutable vía `NOT EXISTS`.
- Sin cambios de API, schema de tablas, ni frontend.

## Capabilities

### New Capabilities

<!-- Ninguna. -->

### Modified Capabilities

- `sale-line-items`: agregar un invariante testable — toda venta con `product_id`, **independiente de la ruta de creación** (v2, legacy o C-29/POS), tiene exactamente una fila en `sale_items`; y la ruta C-29 lo cumple en producción (hoy la implementación viola el requirement de confirm ya existente).

## Impact

- **Código**: `supabase/migrations/` — nueva migración `CREATE OR REPLACE FUNCTION public._c29_confirm_order_core(...)` con el INSERT a `sale_items`, reproduciendo el cuerpo actual sin otros cambios + el backfill de las 11 ventas.
- **Datos**: +11 filas `sale_items` (reconstruidas; ninguna pérdida ni modificación de filas existentes, incl. las 23 de variantes del importador).
- **Desbloquea**: el checkpoint C-20 Grupo 10 (DROP header plano) deja de depender del fallback para ventas C-29.
- **Riesgo / gobernanza**: RPC del hot path de ventas (MEDIO). El backfill solo inserta filas faltantes (bajo riesgo, idempotente). Tests que verifiquen el INSERT de `sale_items` en confirm/quickSale antes de mergear.
