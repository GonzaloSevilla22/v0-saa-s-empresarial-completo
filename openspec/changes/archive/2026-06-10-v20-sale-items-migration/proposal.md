# v20-sale-items-migration (C-20)

> **Governance: ALTO (HIGH).** Este documento y sus artefactos (design, specs, tasks) son **solo propuesta**. La implementación requiere **aprobación explícita del PO** antes de escribir código (espejo de cómo C-19 trató los DROP de columnas). El DROP de columnas del header es su propio checkpoint con aprobación aparte.

## Why

Hoy `sales` y `purchases` guardan la línea de venta/compra **en el propio header** (`product_id`, `amount`, `quantity`, `total` planos): cada fila de `sales` ES un ítem, y `operation_id` agrupa el carrito. Esto es deuda del modelo V1 que `modelo-dominio-aliadata-v2.md` §5.3 retira: una `Sale` debe ser un header con sus `SaleItem` como hijos. Las tablas `sale_items`/`purchase_items` ya existen (23/18 filas del importador de variantes) pero con un esquema de "variantes" que **no es la fuente de verdad** y choca con el modelo flat. Mientras los campos planos sigan vivos, RN-97 bloquea features sobre ventas/compras (C-29 quote/salesorder, C-30 cuentas corrientes dependen de esto). C-20 es el primer eslabón del camino crítico de la rama ventas (C-20 → C-29 → C-30).

## What Changes

Patrón **Strangler Fig** (casa de V2): nueva estructura → backfill → migrar lecturas → drop viejo. El header conserva `operation_id`/`client_id`/`date`/`currency`/`canal`/`branch_id`/tenancy; el ítem se mueve a `sale_items`/`purchase_items`.

- **Reparar el esquema de `sale_items`/`purchase_items`** para que puedan ser la fuente de verdad del modelo flat:
  - `variant_id` pasa a **nullable** (hoy es `NOT NULL` con FK a `product_variants`) — PA-20: backfill con `variant_id = NULL`, sin variantes default.
  - Agregar `product_id uuid` FK→`products(id)` (el modelo flat referencia producto, no variante).
  - Ampliar `quantity` de `integer` a `numeric(15,4)` (hay 2 ventas con cantidad fraccional; `sales.quantity` es `numeric(15,4)`).
  - Agregar `account_id uuid` (tenancy V2, RLS) y `unit_id uuid` FK→`units_of_measure(id)` (preservar unidad de medida).
  - Alinear precios: mapear `amount`(precio unitario)→`price`, `total`→`subtotal`.
- **Backfill idempotente**: por cada fila de `sales`/`purchases` con `product_id NOT NULL` (133 ventas / 181 compras), crear **1** fila en `sale_items`/`purchase_items` con `sale_id = sales.id` (relación 1:1, preserva `operation_id` en el header), `variant_id = NULL`, `product_id` del header. Re-ejecutable sin duplicar (DEC-06).
- **Versionar el RPC** `rpc_create_sale_operation` / `rpc_create_purchase_operation`: la nueva versión inserta el header **y** la fila `sale_items`/`purchase_items` en la misma transacción; la versión legacy queda como fallback detrás de un feature flag (setting de DB, sin redeploy). Cutover y rollback documentados.
- **Vista de compatibilidad** `v_sales_flat` / `v_purchases_flat` (`security_invoker = true`) que expone `product_id`/`amount`/`quantity`/`total` calculados desde el ítem, para que las queries y Edge Functions que aún leen campos planos no rompan durante la transición.
- **Migrar lecturas**:
  - `backend/repositories/sales_repository.py` y `purchase_repository.py`: query paginada pasa de leer `s.product_id/quantity/amount` del header a `JOIN sale_items si ON si.sale_id = s.id`.
  - `frontend/hooks/data/use-sales.ts` y `use-purchases.ts`: el mapper lee del ítem (vía el shape del repo) en vez de campos planos del header.
  - Edge Functions `ai-insights/index.ts` y `ai-precio/index.ts`: leen de `v_sales_flat` en vez de `sales` directo.
- **BREAKING (checkpoint con aprobación PO aparte)**: DROP de `product_id`, `amount`, `quantity`, `total`, `unit_id` del header `sales`; equivalentes en `purchases`. Último paso, tras validar que nada lee columnas del header y que la vista de compat está en uso.

## Capabilities

### New Capabilities
- **sale-line-items**: el modelo de línea de venta/compra vive en `sale_items`/`purchase_items` como hijos de un header; reglas de backfill, esquema canónico del ítem, RPC versionado, vista de compatibilidad y orden de retirada del header flat.

### Modified Capabilities
- **sales-channel**: el cálculo de "Margen neto por canal" (RPC `rpc_dashboard_channel_margin`) hoy lee `venta.quantity` y `s.product_id` planos del header para el COGS; tras el DROP de C-20 debe resolver producto y cantidad desde la línea (`sale_items`/`v_sales_flat`). El delta MODIFICA esa requirement para desacoplarla de las columnas planas. El `canal` sigue en el header.

## Impact

- **Datos**: 135 `sales` (133 con producto) + 184 `purchases` (181 con producto) en prod (`gxdhpxvdjjkmxhdkkwyb`). Backfill ~314 filas de ítems. 23+18 filas de ítems del importador preexistentes (de variantes) conviven — no se tocan; el backfill solo cubre filas flat sin ítem.
- **Código**: 2 RPCs, 2 repositories, 2 hooks, 2 Edge Functions, 1–2 migraciones SQL, 2 vistas de compat.
- **Dependencias**: C-19 (`v20-tenancy-cleanup`) ✅ completado — tenancy es `account_id` en todas las capas. Desbloquea C-29, C-30.
- **Riesgo**: ALTO. Toca el hot path de ventas (dinero/stock). El RPC versionado + feature flag + vista de compat permiten cutover y rollback graduales sin downtime. Los DROP destructivos son un checkpoint separado.
- **Regla dura RN-97**: ninguna feature nueva sobre las columnas flat durante la transición.
- **Migraciones**: aplicar SIEMPRE vía `npx supabase db push` (CLI), NUNCA el MCP `apply_migration` (desincroniza timestamps).
