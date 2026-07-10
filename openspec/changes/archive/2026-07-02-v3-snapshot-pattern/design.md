## Context

El modelo V3 §1 (Snapshot Pattern) exige que todo documento confirmado sea una fotografía inmutable: la línea congela nombre, SKU, **costo** y alícuota de IVA del maestro al persistirse, porque con inflación semanal el maestro cambia y un reporte de margen histórico leído contra el maestro actual miente (RN-D2). Hoy las líneas guardan solo `price`/`subtotal`.

Estado real verificado en `supabase/migrations/` (la última `CREATE OR REPLACE FUNCTION` de cada RPC gana):

| RPC / tabla | Migración vigente | Escribe hoy |
|---|---|---|
| `rpc_create_sale_operation` (+ `_v2`, feature-flag `sale_items_rpc_v2`) | `20260625000001_c26_branch_as_root.sql` | `sale_items(sale_id, product_id, account_id, variant_id, quantity, unit_id, price, subtotal)` + `stock_movements(... product_name, quantity_before/after ...)` |
| `_c29_confirm_order_core` (llamado por `rpc_confirm_sales_order` / `rpc_quick_sale`) | `20260721000001_c29_write_sale_items.sql` | `sale_items` + `stock_movements` |
| `rpc_accept_quote` | `20260702000001_c29_quote_salesorder.sql` | copia `quote_items` → `sales_order_items`; Quote/`quote_items` se crean por **INSERT directo** (RLS), no por RPC |
| `rpc_create_purchase_operation` | `20260804000004_fix_purchase_rpc_onconflict_branchstock.sql` (firma con `p_branch_id, p_cost_center_id`) | **líneas en `public.purchases` (flat)** + `stock_movements` |
| `rpc_product_profitability` | `20260606110000_product_profitability.sql` | reporting: costo = `COALESCE(SUM(purchases.amount), products.cost * units_sold)` — lee del maestro/plano |

Constraints del proyecto: aditivo sin drops; RN-97 vigente (no construir sobre columnas planas en retirada; operar sobre las tablas de ítems que son la fuente de verdad V2); CI aplica migraciones a prod al mergear a main (nunca a mano); RLS org-based; governance **ALTO** (hot path de dinero/stock) → apply bloqueado hasta sign-off del PO.

## Goals / Non-Goals

**Goals:**
- Columnas snapshot aditivas y NULLABLE en las líneas (`sale_items`, `purchase_items`, `quote_items`, `sales_order_items`) + `snapshot_backfilled` flag.
- `stock_movements.unit_cost_snapshot` para valuación.
- Congelamiento en la MISMA transacción de escritura de cada RPC del hot path, sin tocar idempotencia ni comportamiento de stock/ledger.
- `fiscal_documents`: `receptor_legal_name` + `receptor_iva_condition` (FiscalIdentitySnapshot del receptor) + datos del emisor vigentes.
- Backfill best-effort idempotente marcado `snapshot_backfilled = true`.
- Reporting de margen (`rpc_product_profitability`, KPIs) migra a leer snapshots (RN-D2) con fallback.
- Nueva regla de negocio en `knowledge-base/05` (líneas inmutables tras `confirm()`).
- Desbloquear C-20 Grupo 10 (línea de servicio = `product_id NULL` + `name_snapshot`).

**Non-Goals:**
- DROP del header plano de `sales`/`purchases` (C-20 Grupo 10 — solo se desbloquea).
- Percepciones/retenciones (V2.5, dependen del snapshot fiscal pero son otro change).
- Enrutar compras a través de `purchase_items` como refactor del write path (ver Decisión 2 / Open Question).
- Introducir una columna de IVA en `products` como parte obligatoria (ver Decisión 3).
- Conversión de unidades, composición de producto, notificaciones (otros changes V3).

## Decisions

### D1 — Snapshot congelado en el mismo INSERT que crea la línea, leyendo el maestro ya cargado
Cada RPC del hot path ya hace `SELECT ... INTO v_product FROM products` para validar y para `stock_movements.product_name`. Se reusa esa lectura: el `INSERT INTO sale_items/...` agrega `name_snapshot = v_product.name`, `sku_snapshot = v_product.sku`, `unit_cost_snapshot = v_product.cost`, `iva_rate_snapshot = <fuente IVA>` en el mismo statement. No hay lectura ni UPDATE adicional → cero costo de latencia extra y atomicidad garantizada.
- *Alternativa descartada*: trigger `BEFORE INSERT` que complete los snapshots. Rechazado: oculta la lógica del hot path, complica el debugging del RPC y duplica el `SELECT` del maestro.

Partir SIEMPRE del cuerpo vigente de cada función (tabla de Context), no de un cuerpo viejo — hubo regresiones históricas (ON CONFLICT + `products.stock` en el purchase RPC) por reemplazar desde cuerpos obsoletos.

### D2 — El snapshot de compra aterriza donde el write path escribe HOY: `purchases` (flat), no `purchase_items`
Hallazgo verificado: aunque `purchase_items` tiene schema real (`product_id, account_id, unit_id, quantity, subtotal`; `variant_id` nullable — `20260616000001`), **ningún RPC vigente lo escribe**. El `rpc_create_purchase_operation_v2` que sí lo hacía (última vez `20260623000001`) quedó fuera del camino cuando las reescrituras de cost-center (`20260802000001`) y branch-routing (`20260804000004`) redefinieron el wrapper desde un cuerpo que escribe `public.purchases` directamente.

Decisión pragmática para este change (aditivo, sin refactor del write path): agregar las columnas snapshot **tanto a `purchase_items` (para paridad de schema y futuro) como a `purchases`**, y congelar en `purchases` desde `rpc_create_purchase_operation` (`20260804000004`), que es donde la compra realmente se escribe. Así el snapshot de compra existe en producción sin reactivar el v2. La reactivación de `purchase_items` como fuente de verdad de compra es trabajo de C-20/otro change.
- *Alternativa descartada*: reactivar `rpc_create_purchase_operation_v2` + feature flag en este change. Rechazado: es un refactor del hot path de compra (governance ALTO por sí solo) que infla el scope; el objetivo del snapshot se cumple congelando en `purchases`. Se registra como Open Question para el PO.

### D3 — `iva_rate_snapshot`: `products` no tiene columna de IVA; congelar desde la mejor fuente disponible, NULL si no hay
Hallazgo verificado: `products` **no** tiene `iva_rate`/`tax_rate`. El IVA solo vive a nivel `fiscal_documents` (`iva_alicuota_id smallint`, `20260800000006`). Para no expandir el scope a un rediseño del maestro, `iva_rate_snapshot` se congela desde la fuente que exista en el momento del INSERT (p. ej. la alícuota default de la cuenta/organización si está disponible, o el desglose que ya calcula la ruta de facturación); si no hay fuente, queda **NULL** (aceptable: la columna es NULLABLE y el margen bruto no depende del IVA). Agregar `iva_alicuota_id`/`iva_rate` a `products` como default por producto se propone como Open Question (habilitaría congelar siempre), pero NO es requisito de este change.
- *Alternativa descartada*: bloquear el change hasta que `products` tenga IVA. Rechazado: el valor central (costo histórico) no depende del IVA; NULL es un estado válido y honesto.

### D4 — `fiscal_documents`: agregar solo lo que falta del FiscalIdentitySnapshot
`fiscal_documents` ya congela `punto_de_venta` (snapshot del PV) y `receptor_doc_tipo`/`receptor_doc_nro` + `neto`/`iva_amount`/`iva_alicuota_id` (`20260800000006`). Faltan `receptor_legal_name TEXT` y `receptor_iva_condition TEXT` (NULLABLE) para completar el FiscalIdentitySnapshot, más los datos del emisor vigentes al emitir (la condición IVA propia y el PV ya están; se documenta qué datos del emisor se congelan). Las RPC de emisión (`rpc_emit_pending_cae`, `rpc_emit_subscription_payment_cae`) capturan estos campos al insertar el `pending_cae`, derivándolos de la identidad fiscal del cliente (`client-fiscal-identity`) cuando existe. NULL histórico = comportamiento actual (consumidor final sin identificar).

### D5 — Backfill best-effort idempotente con `snapshot_backfilled`
`ALTER TABLE ... ADD COLUMN snapshot_backfilled BOOLEAN NOT NULL DEFAULT false`. Un `UPDATE ... SET name_snapshot = p.name, ..., snapshot_backfilled = true FROM products p WHERE line.product_id = p.id AND line.snapshot_backfilled = false AND line.name_snapshot IS NULL` completa las líneas históricas desde el maestro **actual** (aproximado — el costo de hoy ≠ el de la venta original, por eso se marca). Idempotente por la condición `snapshot_backfilled = false AND name_snapshot IS NULL`: no toca líneas ya congeladas en vivo (`snapshot_backfilled = false` pero con snapshot no nulo) ni re-corre sobre las ya backfilleadas. El reporting distingue `snapshot_backfilled = true` (aproximado) de `false` con snapshot (exacto).

### D6 — Reporting: leer snapshot con fallback en cascada
`rpc_product_profitability` migra el costo de `COALESCE(SUM(purchases.amount), products.cost*units)` a un costo por línea con fallback:
`COALESCE(sale_items.unit_cost_snapshot, products.cost)` ponderado por cantidad. La cascada: (1) `unit_cost_snapshot` congelado exacto; (2) si NULL (línea muy vieja no backfilleada), `products.cost` actual como último recurso. Las filas `snapshot_backfilled = true` usan su snapshot aunque sea aproximado (mejor que el maestro de hoy). Se mantiene la firma `rpc_product_profitability(p_period_days INT DEFAULT 30)` y el resto del contrato (columnas de salida, `P403` sin cuenta) sin cambios.

### D7 — Governance ALTO: checkpoints de sign-off en tasks
El apply toca RPCs del hot path de dinero/stock. `tasks.md` marca explícitamente: (a) checkpoint de **sign-off del PO ANTES de escribir cualquier SQL**; (b) al recrear el CHECK de `operation_idempotency.operation_kind`, enumerar la unión vigente en prod (`ARRAY['sale','purchase','payment_received','payment_made','supplier_charge']` — `20260720000002`) tras `pg_get_constraintdef`, porque CI nace con DB vacía y no atrapa kinds faltantes; (c) smoke test con rollback plan antes del merge.

## Risks / Trade-offs

- **[Regresión al reemplazar RPCs del hot path desde un cuerpo viejo]** → Partir siempre del cuerpo de la migración vigente listada en Context; diff explícito contra ella; el único delta permitido es agregar las columnas snapshot al INSERT existente. Smoke test de venta/compra/quickSale post-migración.
- **[Discrepancia roadmap vs. realidad: compras escriben `purchases`, no `purchase_items`]** → Documentado en D2; el snapshot se congela en `purchases`. Se agrega la columna a `purchase_items` para paridad futura, pero no se afirma que se llene hasta reactivar ese path.
- **[`iva_rate_snapshot` frecuentemente NULL por falta de IVA en `products`]** → Aceptado (D3); margen bruto no lo requiere; Open Question para agregar IVA al maestro.
- **[Backfill aproximado presenta costos "de hoy" como históricos]** → El flag `snapshot_backfilled = true` marca la aproximación; el reporting puede filtrarla o etiquetarla; no se sobrescribe ningún snapshot congelado en vivo.
- **[Recrear el CHECK de `operation_idempotency` omitiendo un kind]** → Gotcha conocido (falló el deploy de C3 por omitir `event_consumer`): enumerar la unión con `pg_get_constraintdef` antes de recrear. Idealmente NO recrear el CHECK en este change (los RPCs ya usan los kinds vigentes).
- **[Gate de CI `validate-kpis` corre contra DB vacía]** → Los DO-blocks de verificación no deben insertar en `auth.users` sin considerar el trigger `handle_new_user`.
- **[Índices]** → Agregar índice en `sale_items(product_id)` si el reporting nuevo lo requiere; verificar plan de `rpc_product_profitability` tras el cambio.

## Migration Plan

1. **[Gate PO]** Sign-off explícito del PO antes de escribir SQL (governance ALTO).
2. Nueva migración `supabase/migrations/2026NNNN000001_v3_snapshot_pattern.sql` (timestamp posterior a `20260805000001`):
   - `ALTER TABLE` aditivo: `name_snapshot`, `sku_snapshot`, `unit_cost_snapshot NUMERIC(15,2)`, `iva_rate_snapshot NUMERIC(5,2)`, `snapshot_backfilled BOOLEAN NOT NULL DEFAULT false` en `sale_items`, `purchase_items`, `quote_items`, `sales_order_items` (+ en `purchases` para el snapshot de compra real — D2).
   - `ALTER TABLE stock_movements ADD COLUMN unit_cost_snapshot NUMERIC(15,2)`.
   - `ALTER TABLE fiscal_documents ADD COLUMN receptor_legal_name TEXT, receptor_iva_condition TEXT`.
   - `CREATE OR REPLACE FUNCTION` de `rpc_create_sale_operation`(+`_v2`), `rpc_create_purchase_operation`, `_c29_confirm_order_core`, `rpc_accept_quote` (y el INSERT directo de quotes vía su ruta) — partiendo del cuerpo vigente, agregando el congelamiento.
   - Backfill idempotente (D5).
   - `CREATE OR REPLACE FUNCTION rpc_product_profitability` con la cascada de fallback (D6).
3. Actualizar `knowledge-base/05_reglas_de_negocio.md` con la regla de líneas inmutables.
4. Actualizar `CHANGES.md` (estado del change) tras el archive.
5. **Rollback**: las columnas son aditivas → rollback = restaurar los cuerpos de RPC previos (guardar el diff) y, si hiciera falta, `DROP COLUMN` de las nuevas columnas (ninguna es referenciada por otras estructuras). Smoke test de venta/compra/quickSale/quote antes y después.

## Open Questions

- **¿Reactivar `purchase_items` como fuente de verdad de compra en este change o dejarlo para C-20?** Recomendación: dejarlo fuera (D2) — este change congela el snapshot en `purchases`.
- **¿Agregar `iva_alicuota_id`/`iva_rate` a `products` para poder congelar siempre `iva_rate_snapshot`?** Requiere decisión del PO sobre el modelo de IVA por producto; fuera de scope por ahora (D3).
- **¿Qué datos exactos del emisor se congelan en `fiscal_documents` más allá de `punto_de_venta` y la condición IVA propia (ya presentes)?** Confirmar con el flujo de facturación vigente durante el apply.
- **¿El reporting debe excluir, etiquetar o incluir sin distinción las filas `snapshot_backfilled = true`?** Decisión de producto para el dashboard; el dato queda disponible para cualquiera de las tres opciones.
