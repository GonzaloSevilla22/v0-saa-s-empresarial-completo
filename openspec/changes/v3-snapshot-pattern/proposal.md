## Why

En una economía con inflación semanal (el comando `applyMassIncrease` remarca precios y costos con frecuencia), una línea de venta/compra que solo referencia `product_id` deja de ser un dato histórico confiable: un reporte de margen de marzo calculado en julio lee el costo *actual* del maestro y **miente**. Hoy `sale_items`/`purchase_items`/`quote_items`/`sales_order_items` guardan solo `price`/`subtotal` — sin nombre, SKU, **costo** ni alícuota de IVA congelados; `stock_movements` no registra el costo unitario para valuación; y `fiscal_documents` solo persiste `receptor_doc_tipo`/`receptor_doc_nro`, sin la razón social ni la condición de IVA del receptor vigentes al emitir (dato que justifica el tipo de comprobante A/B ante una inspección). El modelo V3 §1 eleva la inmutabilidad histórica del documento a regla de negocio; este change la implementa.

Además, congelar `name_snapshot` en la línea es el bloqueo registrado de **C-20 Grupo 10**: sin snapshot de nombre, una línea de servicio (`product_id NULL`) no tiene cómo representarse. Este change lo desbloquea.

## What Changes

- **Columnas snapshot aditivas** en `sale_items`, `purchase_items`, `quote_items`, `sales_order_items`: `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)`, `iva_rate_snapshot NUMERIC(5,2)` — todas NULLABLE (retrocompat con filas históricas).
- **`stock_movements.unit_cost_snapshot NUMERIC(15,2)`** para valuación de inventario (el ledger ya congela `quantity_after`; se agrega el costo).
- **`fiscal_documents`**: completar el `FiscalIdentitySnapshot` del receptor — `receptor_legal_name TEXT`, `receptor_iva_condition TEXT` (hoy solo doc tipo/nro), más los datos del emisor vigentes al emitir. Todas NULLABLE; NULL histórico = comportamiento actual.
- **RPCs de escritura del hot path congelan snapshots desde el maestro en la MISMA transacción**: `rpc_create_sale_operation` (v2), `rpc_create_purchase_operation`, `_c29_confirm_order_core` (y las rutas de quotes / sales orders). Cada uno copia `products.name`, `products.sku`, `products.cost`, y la alícuota de IVA vigente a las columnas snapshot al insertar la línea y el movimiento de stock. **Sin drops, aditivo, idempotencia y comportamiento de stock/ledger preservados.**
- **`flag snapshot_backfilled BOOLEAN` + backfill best-effort** de líneas históricas desde el maestro actual, marcadas `snapshot_backfilled = true` para que el reporting distinga dato congelado exacto vs. aproximado.
- **Reporting de margen migra a snapshots (RN-D2)**: `rpc_product_profitability` (y los KPIs del dashboard afectados) leen `unit_cost_snapshot`/`price` de la línea, con fallback documentado para filas backfilled-aproximadas y para el caso sin snapshot.
- **Nueva regla de negocio en `knowledge-base/05`** (equivalente a RN-04 de Food Store): tras `confirm()` las líneas de un documento no se editan — la corrección es un documento nuevo (nota de crédito, ajuste), nunca un `UPDATE`.
- **Governance ALTO**: toca los RPCs del hot path de venta/compra. El apply queda **bloqueado hasta sign-off explícito del PO**. Los cambios son aditivos y sin drops, pero el hot path de dinero/stock exige checkpoint humano antes de escribir código.

**Fuera de alcance (explícito):** el DROP del header plano de `sales`/`purchases` (C-20 Grupo 10 — este change solo lo *desbloquea*); percepciones/retenciones (V2.5, dependen del snapshot fiscal pero son otro change); el snapshot del emisor más allá de lo mínimo para el comprobante (punto de venta / condición IVA propia).

## Capabilities

### New Capabilities
- `document-snapshots`: patrón de inmutabilidad histórica — las columnas snapshot en las líneas de documentos y en `stock_movements`, la regla de congelamiento en la misma transacción del RPC, la invariante "líneas inmutables tras confirm()", y la estrategia de backfill con el flag `snapshot_backfilled`.

### Modified Capabilities
- `sale-line-items`: las líneas `sale_items`/`purchase_items` incorporan las columnas snapshot y su RPC congela los valores desde el maestro en la transacción de escritura.
- `quote`: las líneas `quote_items` incorporan las columnas snapshot congeladas al crear/aceptar el presupuesto (un presupuesto honra el precio cotizado, no el remarcado).
- `sales-order`: `sales_order_items` incorpora las columnas snapshot; `_c29_confirm_order_core` las congela en la confirmación transaccional.
- `inventory-single-ledger`: `stock_movements` incorpora `unit_cost_snapshot` para valuación de inventario, congelado por el mismo RPC que registra el movimiento.
- `afip-fiscal-document`: `fiscal_documents` persiste el `FiscalIdentitySnapshot` del receptor (`receptor_legal_name`, `receptor_iva_condition`) y datos del emisor vigentes al emitir.
- `product-profitability`: `rpc_product_profitability` migra el cálculo de costo/margen a leer `unit_cost_snapshot` de la línea (RN-D2), con fallback para filas backfilled-aproximadas.

## Impact

- **DB / migraciones**: una nueva migración SQL aditiva (`supabase/migrations/`) con `ALTER TABLE ADD COLUMN` en 5 tablas + backfill; `CREATE OR REPLACE FUNCTION` de los RPCs del hot path (partiendo del cuerpo más reciente de cada uno). CI aplica a prod al mergear a main.
- **RPCs del hot path (governance ALTO)**: `rpc_create_sale_operation` v2, `rpc_create_purchase_operation`, `_c29_confirm_order_core`, rutas de quotes/sales-orders, más `rpc_product_profitability`. Si algún RPC recrea el CHECK de `operation_idempotency.operation_kind`, debe enumerar la unión vigente en prod (`pg_get_constraintdef`) — CI no atrapa kinds faltantes.
- **Reporting**: `rpc_product_profitability`, KPIs de dashboard que leen costo/margen. Cambio de fuente de dato (maestro → snapshot) con fallback.
- **Knowledge base**: `knowledge-base/05_reglas_de_negocio.md` (nueva regla de líneas inmutables); `CHANGES.md` (marcar `v3-snapshot-pattern` en progreso/hecho).
- **Desbloquea**: C-20 Grupo 10 (línea de servicio = `product_id NULL` + `name_snapshot`).
- **Respeta RN-97**: no construye features sobre las columnas planas en retirada de `sales`/`purchases`; opera sobre las tablas de ítems que son la fuente de verdad V2.
