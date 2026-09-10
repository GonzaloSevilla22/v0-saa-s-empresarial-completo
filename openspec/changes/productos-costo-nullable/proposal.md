## Why

`products.cost` es `NUMERIC NOT NULL DEFAULT 0`: "no cargué el costo" y "el costo es cero" son **la misma fila**. La consecuencia no es cosmética — un producto cargado sin costo aparenta **margen del 100 %** en el ranking, en `/rentabilidad`, en el catálogo y en los contextos de IA, y no hay forma de distinguirlo de un producto realmente medido. En prod hoy son **2.617 de 4.953 productos vivos (52,8 %)**, de los cuales **626 son entradas padre `variant_only`** que jamás pueden tener costo propio y **ninguno (0)** fue comprado alguna vez con un costo positivo: no hay un solo caso con evidencia de que su cero sea un cero real.

El cierre del change `estadisticas-ventas` lo dejó anotado con nombre y apellido: *"el margen `NULL` que la spec `product-ranking` prevé es hoy inalcanzable […]; distinguir el 0 del NULL en el catálogo es un change de modelo, no de reporting"*. La spec ya declara la conducta correcta (margen ausente, nunca cero), el read-model ya implementa la rama `NULL → "—"` y la UI ya la renderiza — **todo el andamiaje existe y ninguna fila puede llegar a él**. Este change hace alcanzable lo que ya está especificado.

## What Changes

- **BREAKING (de dominio)**: `products.cost` pasa a **NULLABLE sin default**. `NULL` = *sin costo cargado*; `0` = *costo cero real, declarado*. La ausencia deja de ser un número.
- **Backfill de los 2.617 productos con `cost = 0` → `NULL`** (decisión OQ-1, con recomendación argumentada sobre datos de prod): hoy el `0` es indistinguible de la ausencia, y toda la evidencia disponible dice que es la ausencia. Quien tenga un costo cero real lo vuelve a declarar con una edición.
- **La cascada canónica RN-D2 puede rendir `NULL`**: `COALESCE(unit_cost_snapshot, products.cost)` deja de resolver siempre. El helper `reporting_sales_lines_in_window` no cambia una línea — la nulabilidad se propaga sola; lo que cambia son los **consumidores**, que hoy sumarían en silencio sólo las líneas con costo y publicarían un margen inflado.
- **Un grupo sin ningún costo resoluble informa margen ausente** (`total_cost`/`gross_margin`/`gross_margin_pct` en `NULL`) en `rpc_product_ranking`, `rpc_product_sales_evolution` y `rpc_product_profitability` — nunca cero, nunca un margen derivado de un costo inventado.
- **`cost_coverage_pct` pasa a medir *costo resoluble*, no *snapshot presente*.** Hoy una línea sin snapshot pero con costo de catálogo real cuenta como "sin cobertura" y una línea con snapshot `0` cuenta como "cubierta": las dos son mentiras en direcciones opuestas.
- **El formulario de producto admite costo vacío** (tri-estado por `model_fields_set`, precedente exacto de `sku`/`category_id`): hoy `ProductUpdate` filtra por `exclude_none` y **es imposible borrar un costo por la API**.
- **El importador distingue celda vacía de `"0"`**: `rpc_bulk_upsert_products` deja de imputar `0` en el alta y el validador deja de defaultear a `0`.
- **Las superficies muestran la ausencia como tal**: catálogo (`Costo`/`Margen %` → "—"), ranking y detalle de producto (ya listos), `/rentabilidad` (hoy **crashea** con un `gross_margin_pct` nulo: `fmtPct` llama `toFixed` sin guarda), Tablero (el stock estancado declara cuántos productos no tienen costo), simulador y alertas de margen (no inventan un margen).
- **`ai-precio` con costo ausente** deja de mandar un costo falso al modelo (OQ-3).
- **Non-Goals declarados**: `products.price` NO cambia (sigue `NOT NULL DEFAULT 0`); los `unit_cost_snapshot = 0` **históricos NO se reescriben** (RN de inmutabilidad de líneas — son 9 líneas en 9 productos, residuo declarado y medido); no se toca el asiento contable ni ninguna RPC que mueva dinero.

## Capabilities

### New Capabilities
- `product-cost`: el costo del producto como dato **opcional** — semántica de `NULL` vs `0`, su captura (formulario, API, importador), su propagación al snapshot de línea y la regla transversal de que ningún consumidor puede sustituir un costo ausente por cero al informar margen.

### Modified Capabilities
- `product-ranking`: el margen ausente pasa de teórico a alcanzable; `cost_coverage_pct` se redefine sobre costo resoluble y no sobre presencia de snapshot; un grupo con cobertura 0 % informa margen `NULL`.
- `product-profitability`: la cascada de costo declara su tercer estado (ninguno de los dos peldaños resuelve → costo y margen ausentes) y `/rentabilidad` debe renderizar la ausencia sin romperse.
- `reporting-invariants`: RN-D2 gana la cláusula que hoy le falta — un read-model NOT SHALL sustituir por cero un costo que el catálogo no tiene, y la cobertura declarada es la marca obligatoria del margen parcial.
- `dashboard-kpi-summary`: la valorización del stock sin rotación declara cuántos de sus productos no tienen costo, en vez de sumarlos como $0 en silencio.
- `ai-price-suggestion`: conducta definida cuando el producto no tiene costo de catálogo.

## Impact

**DB (migración `20261042000001`, idempotente)**: `products.cost` `DROP NOT NULL` + `DROP DEFAULT` + backfill `0 → NULL`; reescritura desde el cuerpo vivo de `rpc_product_ranking`, `rpc_product_sales_evolution`, `rpc_product_profitability`, `rpc_bulk_upsert_products` y `rpc_dashboard_kpi_summary` (regla de integridad de función). `check_low_margin` y `op_line_snapshot` se verifican y no cambian (ya son NULL-safe por construcción). Gate SQL nuevo cableado en `KPI_Validation.yml`.

**Backend**: `ProductUpdate.cost` tri-estado (`_NULLABLE_ON_UPDATE` + `cost_provided`), `product_repository.update`, `services/products.update_product`, `routers/products.py`.

**Frontend**: `lib/types.ts` (`Product.cost`/`margin` → `number | null`, el compilador es el inventario), `hooks/data/use-products.ts`, `components/forms/product-form.tsx`, `components/products/product-catalog.tsx` (4 render + 2 export), `components/dashboard/ai-alerts.tsx`, `components/dashboard/KpiSummaryBlock.tsx`, `app/(dashboard)/rentabilidad/page.tsx`, `app/(dashboard)/simulador/page.tsx`, `components/forms/purchase-form.tsx`, `lib/import/validator.ts` + `importer.ts` + `types.ts`, `lib/reporting/kpi-summary.ts`, `lib/ai/buildBusinessSnapshot.ts`.

**Edge Functions**: `ai-precio`, `ai-insights`, `fair-advisor`, `_shared/ai-rentabilidad-core.ts` (`_shared/export-ranking.ts` y `_shared/ai-estadisticas-core.ts` ya son NULL-safe — se verifican con test, no se tocan).

**Superficie frontend** (regla PO 2026-08-02): `/productos` (formulario y catálogo), `/estadisticas` + `/estadisticas/productos/[id]`, `/rentabilidad`, Tablero, `/simulador`, importador de productos. Desktop + mobile, claro + oscuro.
