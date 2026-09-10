> **Gobernanza: MEDIA.** Cambio de modelo de datos + backfill sobre el 53 % del catálogo vivo + lectores en cuatro capas. **No escribe dinero** (declarado: ninguna RPC de caja, banco, cuenta corriente o asiento se toca). Implementar con checkpoints visibles; las decisiones no obvias se surfacean al PO. El grupo 4 no arranca hasta cerrar el grupo 1.
>
> **Strict TDD activo.** Cada grupo con lógica arranca por su test en rojo (RED → GREEN → TRIANGULATE → REFACTOR). El grupo 2 es el SAFETY NET y no es opcional: `Product.cost: number → number | null` rompe la compilación en cascada a propósito (D-riesgo 3), y sin la línea base de `tsc` no hay forma de distinguir un error nuevo de los 9 pre-existentes.
>
> **Regla del repo (integridad de función):** toda reescritura de RPC parte del `pg_get_functiondef` **vivo** de prod (el orquestador entrega los md5), nunca del último archivo de migración. Precedente: `compras-proveedor-cuenta-corriente`, donde el archivo estaba desincronizado del cuerpo vivo.
>
> **Sign-off previo requerido:** OQ-1 (backfill de los 2.617 ceros) y OQ-2 (columna de disclosure en el KPI) están **asumidas resueltas por su recomendación** en los delta specs. Si el PO decide distinto, se corrigen los specs antes de tocar código.

## 1. Checkpoint de estado vivo — antes de escribir una línea de SQL

- [ ] 1.1 Fijar el número de la migración **en el momento del apply**: `MAX(version)` de `supabase_migrations.schema_migrations` en prod y en la base local. El design reserva `20261042000001` porque `20261041000001` está tomado por otro change en vuelo; si al aplicar cambió, **renumerar** (se renumeró tres veces en changes anteriores — nunca asumir el número del design).
- [ ] 1.2 Obtener del orquestador los md5 del `pg_get_functiondef` **vivo en prod** de `reporting_sales_lines_in_window(uuid,date,date,uuid,text)`, `rpc_product_ranking`, `rpc_product_sales_evolution`, `rpc_bulk_upsert_products(jsonb,uuid)`, `rpc_dashboard_kpi_summary`, `rpc_product_profitability(integer)`, `check_low_margin()` y `op_line_snapshot(jsonb,text,text,numeric)`, y verificar que coinciden con la base local. Comparar **por líneas con `\r` stripped** (el CRLF del checkout Windows da falsos negativos de md5 — gotcha registrado). Si alguno difiere: **parar** y releer el cuerpo vivo antes de escribir SQL.
- [ ] 1.3 Re-medir en prod el baseline del change (read-only): productos vivos, con `cost = 0`, con `cost > 0`, de los ceros cuántos son `variant_only`, cuántos fueron comprados alguna vez con costo positivo, cuántos vendidos, y cuántos con stock ≠ 0. Baseline 2026-09-09: **4.953 / 2.617 / 2.336 / 626 / 0 / 10 / 601 productos (1.299 unidades)**. Si "comprados con costo positivo" ya no es **0**, reportar al orquestador: la argumentación de OQ-1 se apoya en ese número.
- [ ] 1.4 Re-medir en prod las líneas de venta: totales, con snapshot, sin snapshot, y de las sin snapshot cuántas resuelven contra un master en `0` (baseline: 811 / 667 / 144 / **1**). Y `COUNT(*)` de líneas con `unit_cost_snapshot = 0` (baseline: **9**, el residuo declarado de D9 que va escrito en la spec con su magnitud). Si el conteo cambió, actualizar la cifra en `specs/product-cost/spec.md` **antes** del apply.
- [ ] 1.5 Verificar contra `information_schema` que `unit_cost_snapshot` sigue NULLABLE en las **cinco** tablas de línea (`sale_items`, `purchase_items`, `quote_items`, `sales_order_items`, `stock_movements`). Es la premisa de D8: si alguna se endureció, la ausencia no se puede heredar y el design cambia.
- [ ] 1.6 **Barrido de INSERT sin `cost`**: buscar en `supabase/tests/*.sql`, `supabase/migrations/*.sql` y los seeds todo `INSERT INTO products` que **omita** la columna `cost` y dependa del `DEFAULT 0` (el barrido debe ser multilínea — un `INSERT` de fixture ocupa varias líneas y un grep por línea lo pierde). Lead preliminar del propose: `test_admin_kpis.sql`. Los que dependan del default se hacen **explícitos** en el mismo PR (declarar `cost` con el valor que su aserción necesita), nunca dejarlos caer a `NULL` en silencio. Es el riesgo #4 del design.
- [ ] 1.7 Re-correr el barrido de lectores del design (grep de `cost` sobre `frontend/`, `backend/`, `supabase/functions/`, `supabase/tests/` + `pg_get_functiondef ~* 'cost'` sobre `pg_proc`) y confirmar que el inventario de §"Inventario de lectores y escritores" sigue completo. Los lectores nuevos aparecidos después de la redacción del design se reportan, no se asumen inertes.
- [ ] 1.8 Confirmar que las ACLs vivas de las funciones a reescribir (`REVOKE ALL FROM PUBLIC`, sin `EXECUTE` para `anon`, `GRANT` a `authenticated`/`service_role`) quedan registradas literal — el `DROP FUNCTION` de D3/D14 **resetea las ACLs** y hay que re-emitirlas idénticas en el mismo archivo (gotcha del advisor 0028).

## 2. SAFETY NET — línea base antes de tocar nada

- [ ] 2.1 `tsc --noEmit` del frontend y registrar el conteo y la lista exacta de errores pre-existentes (baseline conocido del change anterior: **9**, todos en archivos ajenos). Sin este registro, los errores que `Product.cost: number | null` va a destapar son indistinguibles de los viejos.
- [ ] 2.2 Suite backend completa (`pytest`) y registrar total + coverage. Archivos que este change toca: `test_products.py`, `test_products_category_sku.py`, `test_product_repository_c21.py`.
- [ ] 2.3 Suite frontend completa (`pnpm vitest run`) y registrar el total, más los conteos por archivo de los que se van a modificar: hooks de productos, `product-form*`, `product-catalog*`, `numeric-input*`, importador (`validator`/`importer`), `kpi-summary`, `ai-alerts`.
- [ ] 2.4 Correr los ~40 gates SQL en el orden real de `KPI_Validation.yml` contra una base limpia y registrar los fallos **pre-existentes** conocidos (`test_cuentas_billetera_tipo.sql` por artefacto de invocación local) para no confundirlos con regresiones propias.
- [ ] 2.5 Dejar por escrito, antes de tocar código, **qué aserciones de qué archivos van a cambiar y por qué**: todo test que hoy afirme "producto sin costo → margen 100 %" o "el importador usa 0" está afirmando exactamente lo que este change invierte. Sin la lista previa, romperlos se lee como regresión en vez de como la inversión deliberada que son.

## 3. Gate SQL nuevo — RED primero

> Archivo `supabase/tests/test_productos_costo_nullable.sql`, con el estilo de los 63 gates existentes: fixtures propias, `RAISE EXCEPTION` con mensaje explícito por bloque, cleanup que se assertea (lección de `test_admin_kpis.sql`: `session_replication_role = replica` **no** cascadea — el cleanup se verifica, no se supone).

- [ ] 3.1 **T1** — `products.cost` es nullable y **sin default** en `information_schema.columns` (`is_nullable = 'YES'`, `column_default IS NULL`). Las dos mitades: con el `DEFAULT 0` vivo el defecto sobrevive en todo `INSERT` que omita la columna.
- [ ] 3.2 **T2** — un `INSERT` en `products` que omite `cost` deja `cost IS NULL`, no `0`.
- [ ] 3.3 **T3** — un producto con `cost = 0` **explícito** conserva su `0` y su margen se calcula normalmente (el cero declarado sigue siendo un dato).
- [ ] 3.4 **T4** — `reporting_sales_lines_in_window` expone `has_cost` (no `has_cost_snapshot`) y su valor es `true` para una línea **sin snapshot pero con costo de catálogo**, y `false` para una línea sin ninguno de los dos. Es el corazón de D3 y el bloque que prueba que la cobertura mide costo resoluble.
- [ ] 3.5 **T5** — `rpc_product_ranking`: producto sin ningún costo resoluble → `total_cost`, `gross_margin` y `gross_margin_pct` en `NULL` (nunca 0), y `cost_coverage_pct = 0`. Gemelo con cobertura **parcial** (2 líneas, 1 con costo) → margen sobre la línea cubierta y `cost_coverage_pct = 50`.
- [ ] 3.6 **T6** — el producto sin costo queda **al final** del orden por margen del ranking, no en la cabecera (`NULLS LAST` efectivo). Es, en una línea, el bug que el change corrige.
- [ ] 3.7 **T7** — `rpc_product_sales_evolution`: las **tres** expresiones de cobertura (total, bucket, variante) usan el predicado nuevo; un producto sin costo devuelve margen ausente en sus tres tipos de fila.
- [ ] 3.8 **T8** — `rpc_product_profitability(30)` (que **no** se reescribe, D5): producto sin costo resoluble llega con `total_cost`/`gross_margin`/`gross_margin_pct` en `NULL`. Sin este bloque, "no cambia" es una afirmación sin evidencia.
- [ ] 3.9 **T9** (D8) — venta y compra de un producto sin costo congelan `unit_cost_snapshot IS NULL` en su línea. Dos casos, no uno: `op_line_snapshot` lo propaga por diseño y hay que probar que sigue siendo cierto por los dos caminos.
- [ ] 3.10 **T10** (D6) — `check_low_margin` **no** dispara con `cost IS NULL` (no se puede afirmar que un margen es bajo sin costo) y **sí** sigue disparando con un costo real que produce margen bajo. El caso positivo es obligatorio: sin él, "no dispara" es verdadero por omisión.
- [ ] 3.11 **T11** (D10) — `rpc_bulk_upsert_products`: alta con `cost` ausente en el JSON → producto con `cost IS NULL`; alta con `"cost": 0` → producto con `cost = 0`; **edición** con `cost` ausente sobre un producto con costo → **conserva** el costo (nunca lo borra).
- [ ] 3.12 **T12** (OQ-2 = a) — `rpc_dashboard_kpi_summary` devuelve el conteo de productos sin costo dentro del stock sin rotación, y el valor total suma **sólo** los que tienen costo (aritmética idéntica a hoy, D13).
- [ ] 3.13 **T13** — ACLs de todas las funciones reescritas: sin `EXECUTE` para `anon`, `GRANT` a `authenticated`/`service_role`, y **una sola definición viva** por función (sin overload — el gotcha `42725` del `DROP`+`CREATE`).
- [ ] 3.14 **RED confirmado**: correr el gate contra la base local **sin** la migración y verificar que falla en T1 con su mensaje propio.

## 4. Migración `20261042000001` — orden de D14, idempotente

- [ ] 4.1 Crear `supabase/migrations/<número de 1.1>_products_cost_nullable.sql` con el encabezado documentado del repo: qué hace, por qué, idempotencia y el **rollback exacto** escrito en comentario (`UPDATE products SET cost = 0 WHERE cost IS NULL` + `SET NOT NULL` + `SET DEFAULT 0` + restaurar los cuerpos previos, cuyos `pg_get_functiondef` quedan guardados en el registro del apply).
- [ ] 4.2 Paso 1 — `ALTER TABLE public.products ALTER COLUMN cost DROP NOT NULL, ALTER COLUMN cost DROP DEFAULT;` + `COMMENT ON COLUMN public.products.cost` fijando la semántica (`NULL` = sin costo cargado, `0` = costo cero declarado) **en la base**, que es donde vive la ambigüedad.
- [ ] 4.3 Paso 2 — backfill `UPDATE public.products SET cost = NULL WHERE cost = 0;` con `RAISE NOTICE` del conteo afectado. Idempotente por el `WHERE` (la segunda corrida no matchea nada). **Sólo si OQ-1 quedó firmada en (a)**.
- [ ] 4.4 Paso 3 — `DROP FUNCTION IF EXISTS public.reporting_sales_lines_in_window(uuid,date,date,uuid,text);` + `CREATE` con `has_cost` (`COALESCE(si.unit_cost_snapshot, pr.cost) IS NOT NULL`) reemplazando a `has_cost_snapshot`. **`DROP`+`CREATE`, nunca `CREATE OR REPLACE`**: cambia el `RETURNS TABLE`. La cascada de costo **no se toca** — la nulabilidad se propaga sola.
- [ ] 4.5 Paso 3b — re-emitir las ACLs de `reporting_sales_lines_in_window` en el **mismo archivo**, idénticas a las registradas en 1.8 (el `DROP` las reseteó).
- [ ] 4.6 Paso 4 — `CREATE OR REPLACE rpc_product_ranking` partiendo del cuerpo vivo (md5 de 1.2): único cambio real, `FILTER (WHERE k.has_cost_snapshot)` → `FILTER (WHERE k.has_cost)`. Firma, `RETURNS TABLE`, CTEs y `ORDER BY ... NULLS LAST` intactos.
- [ ] 4.7 Paso 4b — ídem `rpc_product_sales_evolution`, en sus **tres** expresiones de cobertura (`t_coverage`, `b_coverage`, `m_coverage`). Tres, no una: es el error de omisión más barato de cometer acá.
- [ ] 4.8 Paso 5 — `CREATE OR REPLACE rpc_bulk_upsert_products` (D10): en la rama **INSERT**, `COALESCE((v_row->>'cost')::numeric, 0)` → `(v_row->>'cost')::numeric`. La rama **UPDATE** (`COALESCE(..., cost)`) se conserva **byte a byte**: la celda vacía sobre un producto existente conserva, no borra. Resolución de categorías, tope de 50, resolución de padre y `EXCEPTION` por fila intactos.
- [ ] 4.9 Paso 6 (OQ-2 = a) — `DROP FUNCTION` + `CREATE` de `rpc_dashboard_kpi_summary` sumando `stagnant_stock_without_cost_count` al `RETURNS TABLE` (cambia el tipo de retorno → `DROP`, no `REPLACE`), con la aritmética del total **sin cambios** (`SUM(bs.quantity * COALESCE(p.cost, 0))`, D13) + re-`GRANT`/`REVOKE` en el mismo archivo.
- [ ] 4.10 Verificar que `rpc_product_profitability`, `rpc_dashboard_channel_margin`, `check_low_margin` y `op_line_snapshot` **no** aparecen en la migración (D5, D6, D8): son "verificar, no cambiar", y reescribirlas sin necesidad las expone a la regla de integridad de función a cambio de nada.
- [ ] 4.11 GREEN: aplicar la migración contra la base local y correr el gate del grupo 3 completo → todos los bloques verdes.
- [ ] 4.12 Idempotencia: reaplicar el archivo completo **dos veces** sobre la base ya migrada y confirmar `EXIT=0` sin errores (sólo `NOTICE ... skipping`). El `ALTER` de 4.2 y el `WHERE` de 4.3 lo hacen idempotente por naturaleza; hay que **probarlo**, no deducirlo (la reaplicación rompió en el change anterior por una guarda que leía una columna ya dropeada).

## 5. Backend — el costo es tri-estado en la API

- [ ] 5.1 **SAFETY NET** del grupo: correr los archivos de tests de productos y registrar el conteo (subconjunto de 2.2).
- [ ] 5.2 RED: test que assertea que un `PATCH /products/{id}` con `{"cost": null}` **desasigna** el costo, y que un `PATCH` que **no menciona** `cost` lo **conserva**. Debe fallar hoy: `exclude_none` descarta el nulo y borrar un costo por la API es imposible.
- [ ] 5.3 GREEN: sumar `"cost"` a `_NULLABLE_ON_UPDATE` en `backend/repositories/product_repository.py` (hoy `{"sku", "category_id"}`).
- [ ] 5.4 GREEN: en `backend/services/products.py::update_product`, excluir `cost` del `model_dump(exclude_none=True, exclude={...})` y aplicarlo bajo `cost_provided`, con el molde exacto de `sku_provided`/`category_provided` (D12 de `productos-categorias-sku` — precedente, no invención).
- [ ] 5.5 GREEN: en `backend/routers/products.py`, derivar `cost_provided="cost" in payload.model_fields_set` y pasarlo al service. **`model_fields_set`, nunca `is None`** — es la distinción entre "no informé" e "informé nulo".
- [ ] 5.6 TRIANGULAR: alta con `cost` ausente → producto sin costo; alta con `cost = 0` → producto con `0`; edición que informa `cost = 0` sobre un producto sin costo → queda en `0`. Tres casos, porque el tri-estado tiene tres ramas.
- [ ] 5.7 Verificar (sin cambiar) que `ProductRepository.create` ya pasa `data.get("cost")` tal cual y que `quote_repository.py` acepta el `SELECT p.cost` nulo en el snapshot de la línea del presupuesto. Comentario en ambos puntos explicando por qué no cambian.
- [ ] 5.8 Comentario en `backend/schemas/products.py` fijando la semántica de `cost: Decimal | None` (ya era nullable en el schema; lo que faltaba era el camino de escritura).
- [ ] 5.9 Suite backend completa: 0 regresiones contra 2.2, coverage ≥87 %.

## 6. Frontend — tipos, control numérico y formulario

- [ ] 6.1 `frontend/lib/types.ts`: `Product.cost` y `Product.margin` → `number | null`. Correr `tsc` inmediatamente y **usar la lista de errores como inventario ejecutable** de lo que falta migrar; compararla contra el inventario del design (§Frontend) y reportar los que el design no anticipó.
- [ ] 6.2 Regenerar `frontend/lib/database.types.ts` desde el schema migrado (`cost` pasa a `number | null` en Row/Insert/Update).
- [ ] 6.3 RED + GREEN: `frontend/components/ui/numeric-input.tsx` gana la prop opt-in `nullable` (default `false`). Con `nullable`: cadena vacía → `onValueChange(null)`; `value == null` → input vacío; **`value === 0` se renderiza `"0"`** (un cero declarado tiene que verse). Widening del tipo de `onValueChange` a `number | null` sólo en la variante nullable.
- [ ] 6.4 **Control negativo obligatorio** de 6.3: test que fija que con `nullable` en `false` el comportamiento es **idéntico al de hoy** (cadena vacía → `0`, `0` → input vacío). `ui/*` es superficie compartida por 22 instancias en 7 archivos: governance MEDIA y la prop es opt-in justamente para que ninguna de las otras 21 cambie.
- [ ] 6.5 RED + GREEN: `frontend/hooks/data/use-products.ts` — `Number(p.cost ?? 0)` deja de imputar; el `null` se preserva y el margen derivado es `null` cuando no hay costo (nunca `0`, nunca `100`).
- [ ] 6.6 RED + GREEN: `frontend/components/forms/product-form.tsx` — estado y payload admiten `null`, el input usa `nullable`, el margen derivado se muestra "—" sin costo, y aparece el texto de ayuda *"Dejalo vacío si todavía no sabés el costo"*. El payload **omite la clave** cuando el usuario no tocó el campo y la envía en `null` cuando la vació: es el otro extremo del tri-estado de 5.5.
- [ ] 6.7 RED + GREEN: `frontend/components/products/product-catalog.tsx` — los 4 render de `margin`/`cost` muestran "—" sin costo y **no** aplican los umbrales de color; los 2 export CSV emiten **celda vacía** (mismo criterio que `_shared/export-ranking.ts`), no `0` ni `100`.
- [ ] 6.8 GREEN: `frontend/components/invoice/InvoiceAIButton.tsx` y `frontend/app/dev-harness/popover/PopoverHarness.tsx` — ajuste de tipos del `Product` sintético/fixture, sin cambio de conducta.

## 7. Frontend — importador y pantallas de reporting

- [ ] 7.1 RED + GREEN: `frontend/lib/import/types.ts` — `cost: number | null` en `ValidatedRow` y `ProductUpsertPayload`.
- [ ] 7.2 RED + GREEN: `frontend/lib/import/validator.ts` — `let cost = 0` → `let cost: number | null = null`; el warning de costo ilegible pasa de *"se usará 0"* a *"se dejará sin costo"*. Decirle al usuario que se usó `0` cuando el `0` significa algo sería una mentira nueva.
- [ ] 7.3 RED + GREEN: `frontend/lib/import/importer.ts` — la fila `"Padre"` manda `cost: null`, no `0` (es el caso de los 626 padres `variant_only` del baseline).
- [ ] 7.4 Plantilla y ayuda del importador: la columna Costo deja de ser obligatoria de facto y el texto declara las tres entradas — vacía en un alta = sin costo, `0` = costo cero, vacía en una **edición** = conserva el costo actual.
- [ ] 7.5 RED + GREEN: `frontend/app/(dashboard)/rentabilidad/page.tsx` (**D7 — riesgo de pantalla en blanco**): `fmtPct`/`fmtARS` con guarda de nulo → "—"; los umbrales de color (`>= 30`, etc.) sólo se evalúan cuando hay número; los productos con margen ausente no cuentan como mejor ni peor margen ni ocupan posiciones del top 10. El test RED debe reproducir el `TypeError` de `null.toFixed` **antes** del fix.
- [ ] 7.6 RED + GREEN: `frontend/lib/reporting/kpi-summary.ts` + `frontend/components/dashboard/KpiSummaryBlock.tsx` (OQ-2 = a) — el mapper transporta el conteo nuevo y el badge dice *"N productos · M sin costo"*.
- [ ] 7.7 RED + GREEN: `frontend/components/dashboard/ai-alerts.tsx` — un producto sin costo **no** genera alerta de margen (no hay margen que evaluar), en vez de generar una con `(price - 0) / price = 100 %`.
- [ ] 7.8 RED + GREEN: `frontend/app/(dashboard)/simulador/page.tsx` — sin costo, aviso *"este producto no tiene costo cargado"* y simulación de margen deshabilitada; el `min={Math.max(1, cost)}` del slider deja de apoyarse en un cero imputado.
- [ ] 7.9 `frontend/components/forms/purchase-form.tsx` (D12): el `?? 0` del prefill del costo unitario **se conserva** —ahí el campo *captura* el costo que se está pagando, no *informa* uno publicado— con un comentario que explique por qué, para que la próxima revisión no lo "arregle".
- [ ] 7.10 `/estadisticas` y `/estadisticas/productos/[id]`: verificar que la rama "—" **ya implementada** se recorre de verdad (hasta hoy era inalcanzable) y actualizar el texto de la nota al pie — la cobertura pasa a ser "% de líneas **con costo**", no "% con snapshot".
- [ ] 7.11 `tsc --noEmit`: **cero errores nuevos** contra la línea base de 2.1. Los errores que queden deben ser exactamente los 9 pre-existentes registrados.
- [ ] 7.12 Suite frontend completa: 0 regresiones contra 2.3, más los tests nuevos. Las aserciones invertidas son las declaradas en 2.5 y ninguna otra.

## 8. Edge Functions — el contexto de IA omite, nunca sustituye

- [ ] 8.1 RED + GREEN: `supabase/functions/ai-precio/index.ts` (OQ-3 = b) — sin costo de catálogo, se **omite del prompt** la línea `COSTO CATÁLOGO` y la instrucción de margen no negativo; la respuesta trae el margen ausente y una advertencia de que la sugerencia no lo considera. La cuota se verifica **antes** de leer nada.
- [ ] 8.2 GREEN: `PriceSuggestionModal` renderiza el margen ausente como "—" con su explicación, sin romper el formateo.
- [ ] 8.3 RED + GREEN: `supabase/functions/ai-insights/index.ts` — el valor inmovilizado y la lista de bajo margen **excluyen** los productos sin costo en vez de contarlos con costo cero.
- [ ] 8.4 RED + GREEN: `supabase/functions/fair-advisor/index.ts` — ídem para el margen por producto.
- [ ] 8.5 RED + GREEN: `supabase/functions/_shared/ai-rentabilidad-core.ts` — el texto `costo ${fmt(...)}, margen ${pctFmt(...)}` se vuelve NULL-safe (omite el par, no imprime `$0` / `100 %`).
- [ ] 8.6 RED + GREEN: `frontend/lib/ai/buildBusinessSnapshot.ts` — el valor inmovilizado, el bajo margen y el detalle omiten el producto sin costo en vez de imputarle `Number(p.cost) → 0`.
- [ ] 8.7 **Verificar sin tocar**: `_shared/export-ranking.ts` (ya emite celda vacía) y `_shared/ai-estadisticas-core.ts` (ya imprime la cobertura cuando < 100 %). Un test por cada uno que lo fije — "ya es NULL-safe" sin prueba es una suposición sobre el archivo que más va a recorrer ese camino a partir de ahora.
- [ ] 8.8 `deno check` de las funciones tocadas, corrido desde una copia **fuera del monorepo** con `DENO_NO_PACKAGE_JSON=1` (dentro, Deno escribe `workspaces` en `package.json`). Registrar si aparece algún error nuevo respecto del estado de `main`.

## 9. Verificación por capa y pasada visual

- [ ] 9.1 Gate nuevo + la tanda completa de gates SQL en el orden real del workflow contra una base recién migrada; comparar contra los fallos pre-existentes de 2.4. Prestar atención a los gates que 1.6 hizo explícitos.
- [ ] 9.2 Levantar el stack local y recorrer la superficie declarada (D15): `/productos` formulario y catálogo, export CSV, importador, `/estadisticas` + `/estadisticas/productos/[id]`, `/rentabilidad`, Tablero, `/simulador`.
- [ ] 9.3 Caso extremo obligatorio en el recorrido: producto con **costo `0` declarado** al lado de uno **sin costo**. Los dos tienen que verse distintos en las siete pantallas — es la prueba de que el change hizo lo que dice y no sólo cambió un `0` por un guion en todos lados.
- [ ] 9.4 Pasada visual en las **4 combinaciones** (claro/oscuro × desktop/móvil) sobre las pantallas que cambian de estado visual, con capturas. El sistema de tokens ya garantiza AA (gate `token-contrast-aa`): no hace falta medir contraste a mano.
- [ ] 9.5 `EXPLAIN (ANALYZE, BUFFERS)` de `rpc_product_ranking` y `rpc_product_sales_evolution` post-migración: confirmar que el cambio de predicado del `FILTER` no degradó el plan. Declarar honestamente la limitación de escala de la base local frente a prod.

## 10. CI y documentación

- [ ] 10.1 Cablear `supabase/tests/test_productos_costo_nullable.sql` en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1`, junto a los demás (paso "Run productos-costo-nullable gate"), con el comentario resumiendo T1-T13.
- [ ] 10.2 Sumar la migración nueva a la cadena de reaplicación de idempotencia del workflow, en su posición cronológica, siguiendo el precedente del change anterior. Verificar que **ninguna migración vieja de la cadena** rompe con la columna ya nullable (p. ej. alguna que asuma el `DEFAULT 0`); si alguna rompe, envolverla en el mismo patrón de tolerancia **estrecha** que el archivo ya usa (acepta un único mensaje literal, falla con cualquier otro), nunca en un `|| true`.
- [ ] 10.3 `knowledge-base/04_modelo_de_datos.md:91`: la línea `cost NUMERIC(15,2)` pasa a declarar la nulabilidad y la semántica (`NULL` = sin costo cargado, `0` = costo cero declarado; los padres `variant_only` no tienen costo propio).
- [ ] 10.4 `knowledge-base/05_reglas_de_negocio.md` (RN-D2 / inmutabilidad de líneas): nota de que la cascada de costo admite no resolver y que las 9 líneas históricas con snapshot `0` **no** se reescriben, con el porqué.
- [ ] 10.5 `CHANGES.md`: entrada propia del change + marcar **resuelto** el candidato heredado de `estadisticas-ventas` (*"`products.cost NOT NULL DEFAULT 0` hace que 'sin costo' y 'costo cero' sean indistinguibles…"*). Anotar como candidatos nuevos los que este change deja abiertos: `products.price` con el mismo defecto (OQ-6) y las 9 líneas históricas (OQ-5, residuo declarado).
- [ ] 10.6 `CLAUDE.md`: tachar el candidato heredado ya resuelto (no agregar bloques nuevos — los candidatos nuevos van a `CHANGES.md`, regla del PO 2026-09-07) y correr `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** para resincronizar `AGENTS.md` (el gate `Docs Sync` lo verifica).
- [ ] 10.7 `npx openspec validate --changes --strict` → verde. `npx openspec validate --specs --strict` → **98/98** (los deltas no tocan los specs principales; pasan a **99** al archivar, con `product-cost` como capability nueva).

## 11. PR y merge

- [ ] 11.1 Abrir el PR desde la rama de apply (el orquestador: nunca commitear a `main`, todo por PR) y esperar los checks: `Backend_Tests`, `Frontend_Tests`, `E2E_Tests`, `KPI_Validation`, `Docs Sync`, Vercel.
- [ ] 11.2 Revisión adversarial antes del merge, con foco en los tres puntos donde este change puede mentir sin fallar: un `COALESCE(..., 0)` sobreviviente en algún read-model, una de las tres expresiones de cobertura de `rpc_product_sales_evolution` sin migrar, y un test que pase porque el caso "sin costo" nunca se construye.

## 12. Verificación post-merge en producción

- [ ] 12.1 `MAX(version)` = la migración de este change; conteo total de migraciones.
- [ ] 12.2 `information_schema.columns`: `products.cost` con `is_nullable = 'YES'` y `column_default IS NULL`.
- [ ] 12.3 Conteos: `cost IS NULL` ≈ 2.617 + altas del período; `cost = 0` = **sólo** los declarados explícitamente desde el deploy (idealmente 0 el primer día); `cost > 0` sin cambios respecto de 1.3.
- [ ] 12.4 Cuerpos vivos: `reporting_sales_lines_in_window` con `has_cost`, las tres coberturas de `rpc_product_sales_evolution` migradas, `rpc_bulk_upsert_products` sin el `COALESCE(..., 0)` del INSERT y **con** el de la rama UPDATE.
- [ ] 12.5 ACLs de las funciones reescritas sin `EXECUTE` para `anon`, y **una sola definición viva** de cada una (sin overload).
- [ ] 12.6 Re-medir el ranking por margen en una cuenta real: los productos sin costo aparecen **al final**, no en la cabecera. Es la verificación de que el bug se fue, no de que el SQL corrió.
- [ ] 12.7 **Humo real del PO**: crear un producto sin costo y verlo con "—" en catálogo, ranking y `/rentabilidad`; cargarle `0` explícito y verlo como `0` con su margen calculado; importar una planilla con la celda de costo vacía sobre un producto existente y confirmar que **conserva** su costo.
- [ ] 12.8 Guardar en engram el resultado del apply con `topic_key: "opsx/productos-costo-nullable/apply"`.
