## Why

El hallazgo H-15 del Roadmap v3.1 dice que `sale_items` no es universal (flag `sale_items_rpc_v2` apagado en 3 de 29 cuentas, `name_snapshot`/`iva_rate_snapshot` en NULL) y que `purchase_items` quedó congelada a mitad de la historia. Medido en producción el 2026-11-05, buena parte ya está cerrada de hecho. Lo que queda abierto es estructural: el camino doble (flag + rama legacy) sigue vivo en 4 funciones del hot path de venta y compra, las líneas de servicio (`product_id IS NULL`) no escriben línea por diseño, y hay 6 documentos sin línea y 79 líneas sin nombre. Mientras eso siga así, la línea no es la fuente de verdad del documento. Eso bloquea el DROP del header plano (C-20 Grupo 10) y a `v3-product-composition`, que la declara dependencia dura.

## Qué ya está cerrado de hecho

Medido en producción el 2026-11-05, sólo lectura:

- **El flag ya no está apagado en ninguna cuenta.** De las 42 cuentas, 35 lo tienen encendido, 0 apagado y 7 no tienen fila. Desde `deudas-menores-agosto` (G1), la ausencia de fila resuelve a v2 (`COALESCE(v_flag_on, true)`), así que «flag off 3/29» ya no describe prod.
- **Toda venta y compra reciente tiene línea.** Las 122 ventas y las 115 compras de los últimos 30 días tienen su línea (`c29-write-sale-items` cubrió POS y confirmación de orden; `deudas-menores-agosto` G1 cubrió `purchase_items`). `account_id` NULL en líneas: 0 (K3 cerrado).
- **Toda línea de producto tiene `name_snapshot`** (`v3-snapshot-pattern`). Las 50 + 29 líneas sin nombre **no tienen producto**: 23 + 18 son filas legacy de variante (`variant_id NOT NULL`), que la spec preserva a propósito, y 27 + 11 son líneas cuyo producto se borró (`ON DELETE SET NULL`) antes del patrón snapshot. **El backfill desde `products` no aplica**: el nombre se recupera de `stock_movements.product_name`, que está 1:1 por documento.
- **`iva_rate_snapshot` NULL en el 100% de las líneas es por diseño**: `products` no tiene tasa de IVA (D3 de `v3-snapshot-pattern`). Esa parte de H-15 se reclasifica: no es un hueco de consistencia de líneas, depende de un cambio futuro de IVA/percepciones (V2.5).

## What Changes

- **Se retira el camino doble**: desaparecen la lectura del flag `sale_items_rpc_v2` y la rama legacy header-only de `rpc_create_sale_operation` (que pasa a ser un despachador incondicional a `rpc_create_sale_operation_v2`, con la firma intacta), y el `IF v_flag_on` de `_purchase_operation_core`, `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation`. Se borran las 35 filas del flag en `account_feature_flags`. **BREAKING (operativo)**: deja de existir el interruptor de apagado por cuenta.
- **Las líneas de servicio escriben su línea** (`product_id NULL`, `name_snapshot` desde la orden, el payload o la descripción de la compra, y si no hay nada, la etiqueta `Ítem sin producto`) en los 6 escritores vivos. Es la reversión de la regla «la línea de servicio NO genera fila»: sin ella la línea nunca podría ser la fuente de verdad del documento. En prod hay 0 líneas de servicio en órdenes de venta y 0 ventas o compras de servicio desde junio, así que el impacto inmediato es nulo.
- **Backfill de datos históricos**: se crea la línea de los 6 documentos sin línea (2 ventas y 4 compras, todos con `product_id` NULL) y se pone `name_snapshot` a las 79 líneas sin nombre. Se marca `snapshot_backfilled = true` en ambos casos y la fuente sigue esta cascada: `stock_movements.product_name`, después `purchases.description`, después la etiqueta.
- **Invariante permanente**: `name_snapshot NOT NULL` en `sale_items`/`purchase_items`, más un gate SQL de dinero (corre con `run_gate_strict.py`). El gate verifica que toda fila de `sales`/`purchases` tenga exactamente una línea canónica (`variant_id IS NULL`), con el subtotal igual al total del header, y que cada escritor vivo produzca su línea.
- **Lector corregido**: `client_repository.py` (actividad de clientes) une `sale_items` sin filtrar la fila de variante y cuenta dos veces 21 ventas de 14 clientes (unos $1,27 M). Pasa a unir sólo la línea canónica.
- `rpc_create_purchase_operation_v2` (4 args, sólo `service_role`, sin llamadores) gana `name_snapshot` en su INSERT para cumplir el `NOT NULL`.
- **Veredicto escrito** en `CHANGES.md` sobre qué sigue bloqueando C-20 Grupo 10. Este change **no** dropea el header plano (RN-97).

## Capabilities

### New Capabilities

(ninguna)

### Modified Capabilities

- `sale-line-items`: se retira el interruptor de apagado; las líneas de servicio pasan a tener fila; el invariante pasa a «toda fila de header tiene exactamente una línea canónica con nombre»; se suman el `NOT NULL` de `name_snapshot` y los lectores sobre la línea canónica.

## Impact

- **DB**: migración `20261091000001_v31_document_lines_consistency.sql`. Reescribe, desde el `pg_get_functiondef` vivo, `rpc_create_sale_operation`, `rpc_create_sale_operation_v2`, `_purchase_operation_core`, `_c29_confirm_order_core`, `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation` y `rpc_create_purchase_operation_v2`. También hace el backfill, borra las filas del flag y agrega el `NOT NULL`. El rollback va en `supabase/migrations_bak/`.
- **Gates**: hay 7 archivos de `supabase/tests/` que ejercitan el kill-switch o la regla «servicio sin fila» y se migran: `test_sale_items_rpc_v2_activation`, `test_operation_edit_lines`, `test_multiusuario_operaciones`, `test_pagos_cableados_restantes`, `test_ventas_sucursal_por_defecto`, `test_ventas_unidades_conversion` y `test_operacion_party_guard` (10). Hay un gate nuevo, `test_document_lines_consistency.sql`, y el paso de reapply de `KPI_Validation.yml` necesita reconvergencia.
- **Backend**: `backend/repositories/client_repository.py` (2 joins) y `backend/tests/test_sale_items.py` (tests del flag).
- **Reportes**: `reporting_sales_lines_in_window`, `rpc_dashboard_kpi_summary`, `rpc_dashboard_channel_margin`, `v_sales_flat` y los repositorios de ventas y compras ya filtran por producto, así que la línea de servicio nueva y el backfill de líneas sin producto **no cambian ningún total** (el gate lo asserta). La única cifra que cambia es la actividad de clientes, que se corrige.
- **Sin superficie frontend**: el frontend no lee el flag ni la rama legacy (verificado por grep: sólo `frontend/lib/database.types.ts` tipa las RPCs, y sus firmas no cambian). No hay pantalla nueva ni modificada. La cifra corregida de actividad de clientes se ve en las pantallas que ya existen.
