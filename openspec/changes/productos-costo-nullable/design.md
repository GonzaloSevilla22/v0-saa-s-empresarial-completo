## Context

`products.cost` es `NUMERIC NOT NULL DEFAULT 0` desde la migración fundacional `20250101000003_create_tables.sql:7`. No hay CHECK constraints sobre la columna (verificado contra `pg_constraint` del cuerpo vivo: sólo PK y las 4 FK). El default nunca fue una decisión — es el default de una tabla escrita el primer día — pero se convirtió en semántica: **"no cargué el costo" y "el costo es cero" son la misma fila**, y el sistema entero razona sobre el segundo cuando lo que ocurrió fue el primero.

`estadisticas-ventas` (E1) lo dejó escrito en su propio design (`openspec/changes/archive/2026-09-04-estadisticas-ventas/design.md:215`):

> *"Margen `NULL` es estructuralmente inalcanzable por la cascada canónica: `products.cost` es `NOT NULL DEFAULT 0`, así que `COALESCE(unit_cost_snapshot, products.cost)` siempre resuelve. El read-model y la UI implementan igual la rama `NULL → "—"` (spec `product-ranking`) por si el catálogo cambia."*

Ese "por si el catálogo cambia" es este change. **El andamiaje ya existe**: la spec `product-ranking` ya declara "margen ausente, nunca cero"; `rpc_product_ranking` ya usa `SUM(...)` (que rinde `NULL` si todos los sumandos lo son) y `NULLS LAST`; `lib/reporting/product-ranking.ts:38` ya tipa `marginPct: number | null`; `_shared/export-ranking.ts:148` ya emite celda vacía (D11); `/estadisticas` ya renderiza "—". Ninguna fila puede llegar a ese camino porque la columna no lo permite.

### Estado medido en producción (2026-09-09, `mcp__supabase__execute_sql`, sólo lectura)

| Medición | Valor |
|---|---|
| Productos vivos (`deleted_at IS NULL`) | **4.953** en 16 cuentas |
| Con `cost = 0` | **2.617 (52,8 %)** |
| Con `cost > 0` | 2.336 · Con `cost < 0` | 0 |
| De los `cost = 0`: entradas padre `variant_only` | **626 de 644** (97 % de los padres — no pueden tener costo propio) |
| De los `cost = 0`: **comprados alguna vez con costo positivo** | **0** |
| De los `cost = 0`: vendidos alguna vez | 10 |
| De los `cost = 0`: con stock ≠ 0 | **601 productos / 1.299 unidades** |
| Líneas de venta totales | 811 → con snapshot **667 (82 %)**, sin snapshot 144 |
| De las 144 sin snapshot: master `cost = 0` | **1** · master `cost > 0` | 114 · sin producto (servicio) | 29 |
| Líneas con `unit_cost_snapshot = 0` | **9** (en 9 productos distintos) |

Dos lecturas load-bearing:

1. **Ninguno de los 2.617 ceros tiene evidencia de ser un cero real.** Cero compras con costo positivo, 10 ventas. El cero no es un dato: es el default.
2. **El impacto retroactivo sobre el reporting es de 1 línea**, no de 144. Sólo una línea de venta histórica resuelve su costo por el peldaño `products.cost` con un master en 0; las otras 114 tienen master positivo y las 29 restantes no tienen producto. El valor de este change es casi todo **hacia adelante**, y su riesgo de reescribir el pasado es casi nulo.

### Regla dura que acota el alcance

`knowledge-base/05_reglas_de_negocio.md:281`: las líneas de un documento confirmado **no se editan nunca — ni los snapshots** (`unit_cost_snapshot` incluido). Las 9 líneas con snapshot `0` quedan como están; son historia congelada, no un default que se pueda reinterpretar. Ver D9.

## Goals / Non-Goals

**Goals:**
- `products.cost` NULLABLE sin default; `NULL` = sin costo cargado, `0` = costo cero declarado.
- La cascada canónica RN-D2 puede rendir `NULL` y los consumidores lo informan como ausencia, jamás como cero.
- `cost_coverage_pct` mide costo **resoluble**, no presencia de snapshot.
- Capturar la ausencia en los tres caminos de entrada: formulario, API y importador.
- Cada superficie que hoy muestra `0`/`100 %` muestra "—" o "sin costo".

**Non-Goals:**
- `products.price` NO cambia. Tiene el mismo defecto (`NOT NULL DEFAULT 0`) pero un precio ausente no falsea ningún margen — un producto sin precio no se vende. Candidato aparte.
- **No se reescribe ningún `unit_cost_snapshot` histórico** (D9).
- No se toca el asiento contable, ni caja/banco, ni ninguna RPC que mueva dinero. Este change no escribe dinero.
- No se agrega un costo por sucursal ni costeo promedio ponderado (BOM / V3 Inteligencia).
- No se migra el importador de productos a FastAPI (sigue por `rpc_bulk_upsert_products` con supabase-js — candidato heredado de `productos-categorias-sku` D7).

## Inventario de lectores y escritores de `cost` (ruta:línea)

Levantado por grep sobre el árbol + `pg_proc.prosrc` del cuerpo vivo. Cada fila dice si **cambia** o si sólo se **verifica**.

### Base de datos (cuerpos vivos, base local migrada = `main` @ `20261040000001`)

| Objeto | Uso | Acción |
|---|---|---|
| `products.cost` | `numeric NOT NULL DEFAULT 0` | **CAMBIA** — `DROP NOT NULL` + `DROP DEFAULT` + backfill |
| `v_products_with_stock` | `p.cost` proyectado (col. 5 del viewdef) | **verificar** — ya expone `cost` nullable (`information_schema` dice `nullable=YES` para la vista); ningún cambio |
| `reporting_sales_lines_in_window(uuid,date,date,uuid,text)` | `COALESCE(si.unit_cost_snapshot, pr.cost)` → `unit_cost`; `(si.unit_cost_snapshot IS NOT NULL)` → `has_cost_snapshot` | **CAMBIA (1 columna)** — ver D3 |
| `rpc_product_ranking(...)` | `SUM(k.unit_cost * k.quantity)`; `COUNT(*) FILTER (WHERE k.has_cost_snapshot)`; `ORDER BY ... NULLS LAST` | **CAMBIA (1 predicado)** — ver D4 |
| `rpc_product_sales_evolution(...)` | 3 expresiones de cobertura (`t_coverage`, `b_coverage`, `m_coverage`) con el mismo FILTER | **CAMBIA (3 predicados)** |
| `rpc_product_profitability(integer)` | `SUM(l.unit_cost * l.quantity)`; `ORDER BY gross_margin_pct DESC NULLS LAST` | **verificar, NO cambia** — ver D5 |
| `rpc_dashboard_kpi_summary(...)` | `COALESCE(si.unit_cost_snapshot, pr.cost, 0)` (COGS, 2×); `SUM(bs.quantity * COALESCE(p.cost, 0))` (stock estancado, 2×) | **CAMBIA sólo si OQ-2 = (a)** — ya es NULL-safe |
| `rpc_dashboard_channel_margin(...)` | `COALESCE(si.unit_cost_snapshot, pr.cost, 0)` (3×) | **verificar, NO cambia** — ya NULL-safe, misma aritmética que hoy |
| `check_low_margin()` (trigger) | `SELECT cost INTO prod_cost`; `IF prod_cost IS NOT NULL THEN` | **verificar, NO cambia** — ya cortocircuita en NULL (D6) |
| `op_line_snapshot(jsonb,text,text,numeric)` | `'unit_cost_snapshot', p_cost` sin COALESCE | **verificar, NO cambia** — propaga NULL solo (D8) |
| `rpc_bulk_upsert_products(jsonb,uuid)` | INSERT `COALESCE((v_row->>'cost')::numeric, 0)`; UPDATE `COALESCE(..., cost)` | **CAMBIA (INSERT)** — ver D10 |
| `rpc_create_sale_operation_v2`, `_c29_confirm_order_core`, `rpc_create_purchase_operation`, `rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation`, `rpc_accept_quote`, `op_stock_movement` | escriben `unit_cost_snapshot` desde `pr.cost` vía `op_line_snapshot` / directo | **verificar, NO cambian** (D8) |
| `fn_guard_product_soft_delete()` | falso positivo (la palabra "costo" en un comentario) | ninguna |

Gates SQL existentes que insertan `cost` (fixtures): `test_estadisticas_ventas.sql`, `..._e2.sql`, `..._e3.sql`, `test_bulk_upsert_products_categories.sql`, `test_kpis_edge_cases.sql`, `test_dashboard_critical_stock_items.sql`, `test_confirm_core_integrity.sql`, `test_operation_edit_lines.sql`, `test_asiento_venta_formulario.sql` y ~10 más. Todos siguen válidos (un INSERT que informa `cost` explícito no depende del default); el riesgo es el **inverso** — un INSERT que **omitía** `cost` y confiaba en el default `0` pasaría a NULL. Task 1.6 barre exactamente eso.

### Backend Python

| Ruta:línea | Uso | Acción |
|---|---|---|
| `backend/schemas/products.py:23,44,65` | `cost: Decimal \| None` en `ProductCreate`/`ProductUpdate`/`ProductOut` | **ya nullable**; sólo comentario |
| `backend/repositories/product_repository.py:24` | `_NULLABLE_ON_UPDATE = frozenset({"sku","category_id"})` | **CAMBIA** — sumar `"cost"` |
| `backend/repositories/product_repository.py:87-97` | INSERT `cost` ← `data.get("cost")` | **verificar** — ya pasa `None` tal cual |
| `backend/repositories/product_repository.py:131` | `fields = {k:v for ... if v is not None or k in _NULLABLE_ON_UPDATE}` | efecto de la línea anterior |
| `backend/services/products.py:144` | `model_dump(exclude_none=True, exclude={"sku","category_id"})` | **CAMBIA** — excluir también `cost` y aplicar `cost_provided` |
| `backend/routers/products.py:104-107` | `sku_provided` / `category_provided` desde `model_fields_set` | **CAMBIA** — sumar `cost_provided` |
| `backend/repositories/quote_repository.py:76` | `SELECT p.cost` para la línea del presupuesto | **verificar** — el snapshot admite NULL |

### Frontend

| Ruta:línea | Uso | Acción |
|---|---|---|
| `frontend/lib/types.ts:366,368` | `Product.cost: number`, `Product.margin: number` | **CAMBIA → `number \| null`** (el compilador es el inventario) |
| `frontend/hooks/data/use-products.ts:34,42` | `Number(p.cost ?? 0)`; `margin: price > 0 ? ... : 0` | **CAMBIA** — `null` se preserva, margen `null` sin costo |
| `frontend/components/ui/numeric-input.tsx:26,39` | `raw === "" ? 0`; `value === 0 ? "" : value` | **CAMBIA** — opt-in `nullable` (D11) |
| `frontend/components/forms/product-form.tsx:35,54,111,234` | estado `cost`, margen derivado, payload, input | **CAMBIA** |
| `frontend/components/products/product-catalog.tsx:398-399,414-415,430-431,653-655,726-728,1009-1016,1131-1138` | export CSV (2×) + 4 render de `margin` con umbrales de color | **CAMBIA** |
| `frontend/components/dashboard/ai-alerts.tsx:14` | `(p.price - p.cost) / p.price` | **CAMBIA** — sin costo no hay alerta de margen |
| `frontend/components/dashboard/KpiSummaryBlock.tsx:98-99` | valor + badge del stock estancado | **CAMBIA si OQ-2 = (a)** |
| `frontend/lib/reporting/kpi-summary.ts:25-26,46-49,82-84` | mapper de `stagnant_stock_*` | **CAMBIA si OQ-2 = (a)** |
| `frontend/app/(dashboard)/rentabilidad/page.tsx:52,236,243,298,302-309` | `fmtPct = (n:number) => n.toFixed(1)`, `fmtARS(p.total_cost)`, umbrales de color | **CAMBIA — riesgo de crash, ver D7** |
| `frontend/app/(dashboard)/simulador/page.tsx:58,61-62,97,221,227,338` | `selectedProduct?.cost \|\| 0`, márgenes, `min={Math.max(1,cost)}` | **CAMBIA** |
| `frontend/components/forms/purchase-form.tsx:374,376,392,506` | prefill de `unitCost` desde `product.cost` | **CAMBIA (mínimo)** — `?? 0` como valor inicial de un input de captura (D12) |
| `frontend/components/invoice/InvoiceAIButton.tsx:108-110` | construye un `Product` sintético con `cost`/`margin` | **CAMBIA** — tipos |
| `frontend/app/dev-harness/popover/PopoverHarness.tsx:48,50` | fixture | **CAMBIA** — tipos |
| `frontend/lib/import/types.ts:86,118` | `cost: number` en `ValidatedRow` / `ProductUpsertPayload` | **CAMBIA → `number \| null`** |
| `frontend/lib/import/validator.ts:29,151-160` | `let cost = 0`; warning *"se usará 0"* | **CAMBIA** |
| `frontend/lib/import/importer.ts:157` | `row.rowType === "Padre" ? 0 : row.cost` | **CAMBIA** — un padre va `null` |
| `frontend/lib/ai/buildBusinessSnapshot.ts:125,272,279-286` | `Number(p.cost)` en valor inmovilizado, bajo margen y detalle | **CAMBIA** |
| `frontend/lib/database.types.ts:3041,3060,3079` | tipos generados de Supabase | **CAMBIA** — regenerar |
| `frontend/lib/reporting/product-ranking.ts:38-40,124` | `marginPct: number \| null` | **ya listo** |
| `frontend/app/(dashboard)/estadisticas/**` | margen "—" + marca de cobertura | **ya listo** (D11 de `estadisticas-ventas`); cambia sólo el texto de la nota al pie |

### Edge Functions (Deno)

| Ruta:línea | Uso | Acción |
|---|---|---|
| `supabase/functions/ai-precio/index.ts:32,212,294,302` | `cost: number`; `COSTO CATÁLOGO: ${fmt(prod.cost)}` en el prompt | **CAMBIA** — ver OQ-3 |
| `supabase/functions/ai-insights/index.ts:139,238,243-245` | inmovilizado + lista de bajo margen | **CAMBIA** — excluir sin costo |
| `supabase/functions/fair-advisor/index.ts:111,123-129` | margen por producto | **CAMBIA** — excluir sin costo |
| `supabase/functions/_shared/ai-rentabilidad-core.ts:51` | `costo ${fmt(p.total_cost)}, margen ${pctFmt(...)}` | **CAMBIA** — NULL-safe |
| `supabase/functions/_shared/export-ranking.ts:148,176-179,245-248` | celda vacía para costo/margen ausente (D11) | **verificar, NO cambia** |
| `supabase/functions/_shared/ai-estadisticas-core.ts:123` | ya imprime la cobertura cuando < 100 % | **verificar, NO cambia** |
| `supabase/functions/generate-export/index.ts:129` | inventario exporta `name, sku, stock, min_stock, price` — **sin costo** | ninguna |

## Decisions

### D1 — `products.cost` NULLABLE sin default; `NULL` ≠ `0`

`ALTER TABLE public.products ALTER COLUMN cost DROP NOT NULL, ALTER COLUMN cost DROP DEFAULT;` + `COMMENT ON COLUMN` que fija la semántica en la base, donde vive la ambigüedad.

Quitar el `DEFAULT 0` es tan importante como quitar el `NOT NULL`: con el default vivo, todo `INSERT` que omita la columna seguiría escribiendo un cero indistinguible, y el defecto sobreviviría en el único camino que nadie mira (los INSERT directos: gates SQL, seeds, fixtures).

**Alternativas descartadas:**
- *Columna hermana `cost_is_set boolean`*: dos fuentes de verdad para un hecho; toda query tendría que acordarse de consultarla. Es exactamente el patrón que `products.category` TEXT (espejo por trigger) acaba de pagar con un change entero para retirarse (`productos-categoria-text-retiro`, `20261040000001`).
- *Centinela `-1`*: reintroduce el problema con otro número y rompe todos los `SUM`.

### D2 — Backfill: los 2.617 `cost = 0` pasan a `NULL` (recomendación de OQ-1)

Con **0 de 2.617** comprados alguna vez con costo positivo y **626 de ellos entradas padre `variant_only`** (que estructuralmente no tienen costo propio: el importador les escribe `0` en `lib/import/importer.ts:157`), no existe un solo caso con evidencia de cero real. Dejarlos en `0` conservaría el defecto **para el 53 % del catálogo** — el change no cumpliría su propósito para la mayoría de los productos vivos.

El costo del error es asimétrico y barato en una dirección: quien tenga un producto realmente gratuito lo vuelve a declarar con **una edición**, y desde este change ese `0` significa algo. Al revés no hay salida: un `0` heredado es indistinguible para siempre.

**Rollback exacto**: `UPDATE public.products SET cost = 0 WHERE cost IS NULL;` restaura el estado previo (post-change, `NULL` es el conjunto de "sin costo", que es superconjunto de los 2.617 + los nuevos). Se documenta en la migración.

**Alternativa descartada** — *migrar sólo los que nunca tuvieron una línea de venta con snapshot > 0*: el predicado suena prudente pero, medido, **discrimina 10 filas de 2.617** (sólo 10 de los `cost = 0` fueron vendidos alguna vez). Añade una CTE, un criterio que nadie podrá reconstruir en seis meses, y deja 53 % del catálogo a medio migrar para proteger un caso que los datos dicen que no existe.

### D3 — El helper canónico no inventa un costo: `has_cost_snapshot` → `has_cost`

`reporting_sales_lines_in_window` **no cambia su cascada**: `COALESCE(si.unit_cost_snapshot, pr.cost)` ya rinde `NULL` cuando ninguno de los dos peldaños resuelve. La nulabilidad se propaga sola — ése es el diseño correcto y es la razón por la que el change es chico en SQL.

Lo que sí cambia es la **columna de cobertura**. Hoy vale `(si.unit_cost_snapshot IS NOT NULL)`, que responde *"¿la línea tiene snapshot?"*. La pregunta que la spec `product-ranking` hace es *"¿la línea tiene costo?"*. Hoy las dos difieren en dos direcciones opuestas:

- una línea **sin snapshot pero con costo de catálogo real** (114 líneas en prod) cuenta como *sin cobertura* aunque su margen está perfectamente medido;
- una línea **con snapshot `0`** (9 líneas) cuenta como *cubierta* aunque su margen es el 100 % artificial que este change existe para desterrar.

Se renombra la columna a `has_cost` con el predicado `COALESCE(si.unit_cost_snapshot, pr.cost) IS NOT NULL`. Es un `RETURNS TABLE` distinto → **`DROP FUNCTION` + `CREATE`**, nunca `CREATE OR REPLACE` (gotcha `42725` ya registrado en el repo: un `CREATE OR REPLACE` que cambia el tipo de retorno falla, y con firma distinta deja un overload vivo). Sus tres consumidores se reescriben en la misma migración.

**Alternativa descartada** — *conservar `has_cost_snapshot` y agregar `has_cost`*: dos booleanos casi iguales en el helper canónico del que cuelga todo el módulo de estadísticas; el primer consumidor que elija el equivocado no falla, publica un número.

### D4 — Margen ausente vs. cobertura parcial: la spec ya decidió, la implementación la hereda

`rpc_product_ranking` agrega con `SUM(k.unit_cost * k.quantity)`:

- **ningún costo resoluble en el grupo** → todos los sumandos `NULL` → `SUM` = `NULL` → `gross_margin` `NULL` → `gross_margin_pct` `NULL`. Es exactamente el *"margen ausente, nunca cero"* del requirement, **sin escribir una línea**.
- **cobertura parcial** → `SUM` ignora los `NULL` y suma lo conocido; `cost_coverage_pct` declara la proporción. Es exactamente el *"cobertura parcial declarada"* del requirement.

El único cambio real en el ranking es el predicado del FILTER: `FILTER (WHERE k.has_cost_snapshot)` → `FILTER (WHERE k.has_cost)`. Idéntico en las **tres** expresiones de cobertura de `rpc_product_sales_evolution` (total, bucket y variante).

El `ORDER BY` por margen ya lleva `NULLS LAST`: los productos sin costo caen al fondo del ranking por margen en vez de encabezarlo con un 100 % falso. **Ése es, en una línea, el bug que este change corrige.**

### D5 — `rpc_product_profitability` no se toca

Su cuerpo vivo ya rinde `NULL` por la misma mecánica de D4 (`SUM` sobre `NULL`), su `ORDER BY gross_margin_pct DESC NULLS LAST` ya está puesto y su spec fija que *"las columnas de salida NO cambian"*. Reescribirla sin necesidad la expondría al riesgo de la regla de integridad de función a cambio de nada.

Se cubre con un test del gate que prueba que un producto sin costo llega con `total_cost`/`gross_margin`/`gross_margin_pct` en `NULL`. Lo que sí cambia es **su pantalla** (D7).

### D6 — `check_low_margin` no cambia (y por qué hay que probarlo igual)

El trigger ya hace `IF prod_cost IS NOT NULL THEN` antes de dividir. Con `cost = NULL` no dispara — que es la conducta correcta: no se puede afirmar que un margen es bajo sin conocer el costo. Con `cost = 0` tampoco disparaba (margen 100 % > 15 %), así que **no hay cambio de conducta observable**; hay cambio de *motivo*, y un motivo correcto por accidente se rompe en la próxima edición. Un test del gate lo fija.

### D7 — `/rentabilidad` crashea hoy con un margen nulo: hay que endurecerla antes de que sea alcanzable

`frontend/app/(dashboard)/rentabilidad/page.tsx:52` define `const fmtPct = (n: number) => \`${n.toFixed(1)}%\`` y lo aplica a `p.gross_margin_pct` (L236, L243, L309), además de `fmtARS(p.total_cost)` (L298) y de comparaciones de umbral (`p.gross_margin_pct >= 30`) que con `null` caen a la rama equivocada en silencio. `null.toFixed` es un `TypeError` en runtime: **la pantalla queda en blanco**.

No es un bug que este change introduzca de la nada — `gross_margin_pct` ya puede ser `NULL` hoy por `NULLIF(revenue, 0)` — pero es un camino que hoy no se recorre y que este change vuelve común. La pantalla se endurece en el mismo PR: "—" para el valor ausente, y el umbral de color sólo se evalúa cuando hay número.

### D8 — El snapshot de línea hereda la ausencia sin tocar código

`op_line_snapshot` escribe `'unit_cost_snapshot', p_cost` **sin `COALESCE`**, y los callers le pasan `pr.cost` directo. Con el master en `NULL`, la línea nueva congela `NULL` — que es la respuesta a la pregunta (4) del brief: el snapshot dice "no había costo", no "el costo era cero". `unit_cost_snapshot` ya es `NULLABLE` en las cinco tablas de línea (`sale_items`, `purchase_items`, `quote_items`, `sales_order_items`, `stock_movements`), verificado contra `information_schema`. **Cero cambios**; dos tests que lo fijan (venta y compra).

### D9 — Los 9 `unit_cost_snapshot = 0` históricos NO se reescriben

`knowledge-base/05_reglas_de_negocio.md:281` (RN de inmutabilidad de líneas) prohíbe editar los snapshots de un documento confirmado — es la regla que hace que remarcar un producto no reescriba el margen histórico, y es más valiosa que estas 9 filas.

**Residuo declarado y medido**: 9 líneas en 9 productos seguirán informando margen 100 % con cobertura 100 %. No hay forma honesta de distinguir, hoy, entre "se vendió con costo cero declarado" y "se vendió cuando el master valía el default". Se documenta en la spec de `product-cost` como excepción con su cuenta exacta, para que nadie lo redescubra como un bug del reporting.

### D10 — El importador: celda vacía ≠ `"0"`, y la omisión conserva

- **Alta** (`rpc_bulk_upsert_products`, rama INSERT): `COALESCE((v_row->>'cost')::numeric, 0)` → `(v_row->>'cost')::numeric`. Celda vacía → `NULL`.
- **Edición** (rama UPDATE): `cost = COALESCE((v_row->>'cost')::numeric, cost)` **se conserva tal cual**. Celda vacía sobre un producto existente = *"no informo el costo"* → conserva el que tenía. Es la misma convención de tri-estado-por-ausencia que rige `sku` y `category_id` en el resto del sistema.
  **Consecuencia declarada**: no se puede *borrar* un costo desde el importador; para eso está el formulario. Un importador que borra datos por una celda vacía es cómo se pierde un catálogo entero en una pegada de Excel.
- `lib/import/validator.ts:151`: `let cost = 0` → `let cost: number | null = null`; el warning de costo ilegible pasa de *"se usará 0"* a *"se dejará sin costo"* (decirle al usuario que se usó 0 cuando 0 significa algo sería una mentira nueva).
- `lib/import/importer.ts:157`: la fila `"Padre"` manda `cost: null`, no `0` — es el caso de los 626 padres.
- La firma de `rpc_bulk_upsert_products` no cambia → `CREATE OR REPLACE` desde el cuerpo vivo (hash tomado en el apply).

### D11 — `NumericInput` gana un opt-in `nullable`; no nace un componente nuevo

`frontend/components/ui/numeric-input.tsx` **no puede representar "vacío"**: `raw === "" ? 0` colapsa la cadena vacía a cero (L26) y `value === 0 ? "" : value` renderiza el cero como vacío (L39). Los dos sentidos están soldados. Sin tocarlo, *"el formulario permite dejar el costo vacío"* es inimplementable y `0` ni siquiera se ve escrito.

Se agrega una prop `nullable` (default `false`). Con `nullable`:
- cadena vacía → `onValueChange(null)`;
- `value == null` → input vacío; `value === 0` → se renderiza **`"0"`** (un costo cero declarado tiene que verse).

Con `nullable` en `false` el comportamiento es **byte por byte el de hoy** — las 22 instancias en 7 archivos (`ventas/pos`, `expense-form-v2`, `product-form`, `purchase-form`, `sale-form`, `InvoiceProductRow`, `cart-item-list`) no se tocan y no cambian. Governance: `ui/*` compartido = **MEDIA** (precedente `qa-integral-modulos`), por eso la prop es opt-in y no un cambio de default.

**Alternativa descartada** — *`CostInput` nuevo*: duplicaría el manejo de foco/selección/NaN de un input numérico para un solo caller, contra la regla dura de reutilización antes que repetición.

### D12 — El prefill del formulario de compra usa `?? 0` y eso está bien

`purchase-form.tsx:374,376,392` prellena el costo unitario de la línea desde `product.cost`. Ese campo **no informa** un costo: **captura** el que se está pagando ahora. Un `?? 0` ahí es el valor inicial de un input editable, no un dato publicado, y es la distinción que separa este caso de todos los demás `?? 0` que el change elimina. Se deja anotado en el código para que la próxima revisión no lo "arregle".

### D13 — Valorización del stock: la aritmética no cambia; lo que cambia es lo que se declara

Un producto sin costo aporta `0` a `SUM(bs.quantity * COALESCE(p.cost, 0))` — **exactamente lo mismo que hoy aporta un producto con `cost = 0`**. La opción "excluir del total" y la opción "tratar como 0" son numéricamente idénticas: no hay decisión aritmética que tomar. La única opción con contenido sería propagar `NULL` al total, que con **601 productos sin costo en stock** dejaría el KPI en blanco para todos los tenants: se descarta.

Lo que falta no es un número distinto, es **la declaración**: hoy el Tablero dice *"$X · N productos"* sin decir que M de esos N valen $0 porque nadie cargó su costo. Ver OQ-2.

### D14 — Migración idempotente y orden de aplicación

Archivo único `supabase/migrations/20261042000001_products_cost_nullable.sql` (el `20261041` está tomado por otro change en vuelo — si al aplicar hubiera cambiado, **renumerar**, gotcha ya conocido en el repo). Orden dentro del archivo:

1. `ALTER COLUMN cost DROP NOT NULL` + `DROP DEFAULT` (idempotente por naturaleza en Postgres) + `COMMENT ON COLUMN`.
2. Backfill `UPDATE public.products SET cost = NULL WHERE cost = 0;` — idempotente por el `WHERE` (en la segunda corrida no matchea nada). Se registra el conteo con `RAISE NOTICE`.
3. `DROP FUNCTION IF EXISTS public.reporting_sales_lines_in_window(uuid,date,date,uuid,text);` + `CREATE` (D3), con sus `GRANT`/`REVOKE` re-emitidos en el **mismo archivo** — un `DROP` resetea las ACLs (gotcha registrado del advisor 0028).
4. `CREATE OR REPLACE` de `rpc_product_ranking` y `rpc_product_sales_evolution` partiendo del **cuerpo vivo** (regla de integridad de función: `pg_get_functiondef` primero, hash comparado, recién después se escribe SQL).
5. `CREATE OR REPLACE rpc_bulk_upsert_products` (D10).
6. Sólo si OQ-2 = (a): `DROP FUNCTION` + `CREATE` de `rpc_dashboard_kpi_summary` (cambia el `RETURNS TABLE`) + re-`GRANT`.
7. Gate `supabase/tests/test_productos_costo_nullable.sql` cableado en `.github/workflows/KPI_Validation.yml`.

**Rollback**: la migración inversa está escrita en un comentario de cabecera (`UPDATE ... SET cost = 0 WHERE cost IS NULL` + `SET NOT NULL` + `SET DEFAULT 0` + restaurar los cuerpos previos, cuyo `pg_get_functiondef` queda guardado en el design del apply).

### D15 — Superficie frontend (regla PO 2026-08-02)

| Pantalla | Qué muestra hoy | Qué muestra después |
|---|---|---|
| `/productos` — formulario | campo Costo con `0` y "Margen 100 %" | campo vacío admitido, texto de ayuda *"Dejalo vacío si todavía no sabés el costo"*, margen "—" sin costo |
| `/productos` — catálogo | `Costo $0` y badge verde `100 %` | `Costo —` y badge neutro `—` (los umbrales de color no se evalúan sin margen) |
| `/productos` — export CSV | `costo 0`, `margen 100` | celdas vacías (mismo criterio D11 de `export-ranking`) |
| `/estadisticas` + `/estadisticas/productos/[id]` | ya renderiza "—" | igual, **ahora alcanzable**; cambia el texto de la nota al pie (la cobertura pasa a ser "% de líneas con costo") |
| `/rentabilidad` | crashea con margen nulo (D7) | "—" y sin color de umbral |
| Tablero — Stock sin rotación | `$X · N productos` | `$X · N productos · M sin costo` (OQ-2) |
| `/simulador` | costo `0`, margen 100 %, slider desde `$1` | aviso *"este producto no tiene costo cargado"* y simulación de margen deshabilitada |
| Importador de productos | plantilla con `Costo` obligatorio de facto | plantilla + aviso: celda vacía = sin costo, `0` = costo cero |

Verificación en desktop + mobile y en tema claro + oscuro; el sistema de tokens ya garantiza AA (gate `token-contrast-aa`), así que no hace falta medir contraste a mano — sí capturas de las 4 combinaciones en las pantallas que cambian de estado visual.

## Risks / Trade-offs

- **[El backfill es irreversible en su intención: un `0` deliberado se pierde]** → Medido: **0 de 2.617** tienen evidencia de cero real (ninguno comprado con costo positivo). El rollback exacto está escrito (D2) y re-declarar un cero cuesta una edición. Se comunica al PO en el sign-off de OQ-1 con los números, no con adjetivos.
- **[`SUM` ignora los `NULL` y una cobertura parcial publica un margen optimista]** → Es la conducta que la spec `product-ranking` **decide** (cobertura parcial declarada, no margen suprimido), y `cost_coverage_pct` —ahora medido sobre costo resoluble y no sobre snapshot (D3)— es la marca que la UI ya muestra. El riesgo no se elimina: se declara en la superficie.
- **[`Product.cost: number → number | null` rompe la compilación en cascada]** → Es la mitigación, no el riesgo: `tsc` en strict es el inventario ejecutable. La tarea 1.5 corre `tsc` **antes** de tocar nada para tener la línea base, y compara.
- **[Un gate SQL que omitía `cost` confiando en el `DEFAULT 0` pasa a NULL y su aserción de margen cambia sin aviso]** → Task 1.6 barre los ~20 gates que insertan en `products` buscando INSERT **sin** columna `cost`; los que dependan del default se hacen explícitos en el mismo PR.
- **[`rpc_dashboard_kpi_summary` con `DROP FUNCTION` deja un overload vivo o pierde ACLs]** → Gotcha ya registrado (`42725` + reset de ACLs por DROP). `DROP` explícito con la firma completa, `GRANT`/`REVOKE` re-emitidos en el mismo archivo, y el gate de ACLs (`test_function_acl_gate.sql`) lo verifica en CI.
- **[Los caminos de IA envían "costo: null" al modelo y el modelo lo interpreta como cero]** → Ningún consumidor de IA manda el campo cuando falta: se **omite** la línea del prompt (patrón ya establecido en `ai-canonical-metrics`: *"omitir del contexto […] y NUNCA sustituirlos por una estimación"*).
- **[9 líneas históricas siguen mintiendo (snapshot `0`)]** → Aceptado y contado (D9); es el precio de la regla de inmutabilidad, que vale más.

## Migration Plan

1. **Checkpoint de cuerpos vivos** (antes de escribir SQL): `pg_get_functiondef` + md5 de `reporting_sales_lines_in_window`, `rpc_product_ranking`, `rpc_product_sales_evolution`, `rpc_bulk_upsert_products`, `rpc_dashboard_kpi_summary`, `rpc_product_profitability`, `check_low_margin`, `op_line_snapshot`. Comparar contra el último archivo de migración de cada una — si divergen, **el cuerpo vivo gana** (precedente: `compras-proveedor-cuenta-corriente`, donde una reescritura in-place había desincronizado el archivo).
2. Migración `20261042000001` (D14), aplicada local con `supabase db reset` limpio.
3. Backend + frontend + Edge Functions con TDD por capa.
4. Gate nuevo + cableado en `KPI_Validation.yml`; los 40+ gates existentes corriendo en el orden real del workflow.
5. `openspec validate --specs --strict` → **99/99** (98 + `product-cost`).
6. PR → merge → el pipeline aplica la migración y despliega.
7. **Verificación post-merge en prod** (`mcp__supabase__execute_sql`, lectura): `MAX(version) = 20261042000001`; `information_schema` dice `cost nullable=YES default=<none>`; conteo `cost IS NULL` ≈ 2.617 + altas del período; `cost = 0` = los declarados explícitamente desde el deploy; ACLs de las funciones reescritas sin `EXECUTE` para `anon`; una sola definición viva por función (sin overload).
8. **Humo real del PO**: crear un producto sin costo, verlo con "—" en catálogo/ranking/rentabilidad, cargarle `0` explícito y verlo como `0`.

## Open Questions

**OQ-1 — ¿Los 2.617 productos con `cost = 0` pasan a `NULL`?**
*Recomendación: **sí, todos** (D2).* Datos: 0 de 2.617 fueron comprados alguna vez con costo positivo; 626 son padres `variant_only` que no pueden tener costo propio; sólo 10 fueron vendidos alguna vez. Alternativas: (a) todos → `NULL` *(recomendada)*; (b) sólo los que nunca tuvieron una línea de venta con snapshot > 0 — discrimina 10 filas de 2.617 y deja el 53 % del catálogo a medio migrar; (c) ninguno — el change no cumple su propósito para la mayoría del catálogo vivo.

**OQ-2 — Valorización del stock con costo ausente: ¿se declara cuántos productos no tienen costo?**
*Recomendación: **sí (a)**.* La aritmética no cambia en ninguna opción (D13); la decisión es sobre la **disclosure**. (a) `rpc_dashboard_kpi_summary` suma una columna `stagnant_stock_without_cost_count` y el badge del Tablero dice *"N productos · M sin costo"* — cuesta un `DROP FUNCTION`+`CREATE` (cambia el `RETURNS TABLE`), el mapper y el badge; hoy serían **601 productos / 1.299 unidades** valorizados en $0 sin decirlo. (b) nota estática al pie del KPI sin conteo — cero SQL, pero no dice cuántos y por lo tanto no es accionable. (c) no declarar nada — deja el KPI diciendo un número que el usuario no puede auditar.

**OQ-3 — `ai-precio` con un producto sin costo de catálogo: ¿rechaza o sugiere sin margen?**
*Recomendación: **sugerir sin margen (b)**.* (a) rechazar con *"cargá el costo para sugerir un precio"* — honesto pero deja sin servicio a un producto por el que el usuario ya gastó una consulta de su cuota; (b) sugerir **omitiendo del prompt la línea `COSTO CATÁLOGO`** y la instrucción *"que el margen no sea negativo"*, y avisando en la respuesta que la sugerencia se apoya sólo en elasticidad e historial de ventas — es el patrón ya establecido en `ai-canonical-metrics` (omitir, nunca sustituir) y sigue siendo útil; (c) mandar `0` — es la mentira que este change existe para eliminar, **descartada**. Nota de implementación en cualquier caso: la cuota se verifica antes de leer nada, y si se rechaza (opción a) **no** se incrementa el contador.

**OQ-4 — Snapshot de línea con producto sin costo: ¿`NULL` o `0`?**
*Recomendación: **`NULL`**, y no cuesta nada (D8).* `op_line_snapshot` ya propaga el valor sin `COALESCE` y las cinco tablas de línea ya admiten `NULL`. La pregunta queda registrada porque **la respuesta contraria exigiría escribir código** (meter un `COALESCE(..., 0)`), y conviene que quede claro que la ausencia se hereda por diseño y no por olvido.

**OQ-5 — ¿Se reescriben las 9 líneas históricas con `unit_cost_snapshot = 0`?**
*Recomendación: **no** (D9).* Contradiría la regla de inmutabilidad de líneas de documento confirmado (`knowledge-base/05_reglas_de_negocio.md:281`), que es la que garantiza que remarcar un producto no reescriba el margen del pasado. Residuo declarado: 9 líneas en 9 productos seguirán informando 100 % de margen con 100 % de cobertura.

**OQ-6 — ¿`products.price` recibe el mismo tratamiento?**
*Recomendación: **no en este change** (Non-Goal declarado).* Tiene el mismo `NOT NULL DEFAULT 0`, pero un precio ausente no falsea ningún margen ni ninguna valorización: un producto sin precio no se vende. Si el PO lo quiere, es un change gemelo y más chico, apoyado en el precedente que éste deja.
