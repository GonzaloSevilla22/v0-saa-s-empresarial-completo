> **Governance: MEDIA** (modelo de datos + lectores múltiples; sin dinero). Implementar con checkpoints; surfacear al PO las decisiones no obvias.
> **Strict TDD**: cada grupo con código sigue RED → GREEN → TRIANGULATE → REFACTOR, con SAFETY NET previo sobre los archivos que se modifican.
> **Regla del repo**: toda reescritura de RPC parte del `pg_get_functiondef` **vivo** (el orquestador entrega los md5 de prod), nunca del último archivo de migración.

## 1. Checkpoint de estado vivo (antes de escribir una línea de SQL)

- [ ] 1.1 Re-medir en prod el invariante que habilita el change: `COUNT(*)` de `products` total / sin `category_id` / con espejo desincronizado / con `category` no nula y `category_id` nula. **Si `sin category_id con texto` > 0, DETENER** y reportar al orquestador: la derivación perdería datos y el design necesita un backfill previo. (Baseline 2026-09-09: 5.096 / 0 / 0 / 0.)
- [ ] 1.2 Obtener del orquestador los md5 del `pg_get_functiondef` vivo en prod de `rpc_product_ranking`, `rpc_product_sales_evolution` y `rpc_bulk_upsert_products`, y verificar que coinciden con la base local migrada (comparar por líneas con `\r` stripped — CRLF del checkout Windows da falsos negativos).
- [ ] 1.3 Re-verificar en prod que la policy `product_categories_member_select` sigue siendo `account_id IN (current_account_ids())` **sin filtro por `deleted_at`** (D3). Si cambió, el escenario "categoría dada de baja conserva su nombre" no se cumple y hay que reabrir D3.
- [ ] 1.4 Re-verificar que `v_products_with_stock` sigue con `security_invoker=true` y sin triggers `INSTEAD OF`.
- [ ] 1.5 Re-correr el barrido de lectores (`pg_get_functiondef ~* 'category(?![_a-z])'` + grep en `frontend/`, `backend/`, `supabase/functions/`, `supabase/tests/`) y confirmar que el inventario del `design.md` sigue completo. Reportar cualquier lector nuevo antes de seguir.

## 2. Gate SQL nuevo — RED primero

- [ ] 2.1 Escribir `supabase/tests/test_product_category_derived.sql` heredando **literalmente** los bloques (7) `P0404`, (8) FK `RESTRICT` y (9) guard de soft delete de `test_product_category_mirror.sql`.
- [ ] 2.2 Agregar el bloque **T1**: `products.category` no existe en `information_schema.columns`.
- [ ] 2.3 Agregar **T2**: `v_products_with_stock` devuelve `category` = nombre vigente de la categoría referenciada.
- [ ] 2.4 Agregar **T3**: renombrar una categoría cambia lo que devuelve la vista **sin reescribir filas de `products`** (`xmin` intacto antes/después).
- [ ] 2.5 Agregar **T4** (D3): producto imputado a una categoría **soft-deleted** → la vista sigue devolviendo su nombre. Y su gemelo con categoría sólo **desactivada**.
- [ ] 2.6 Agregar **T5**: producto con `category_id IS NULL` aparece en la vista con `category` nula; y `COUNT(*)` de la vista = `COUNT(*)` de `products` (el `LEFT JOIN` no filtra a nadie).
- [ ] 2.7 Agregar **T6**: la vista conserva `security_invoker=true` y los `GRANT` de `authenticated`/`service_role`.
- [ ] 2.8 Agregar **T7**: ninguna función de `public` referencia ya la columna física (barrido `pg_get_functiondef`), con allowlist vacía.
- [ ] 2.9 **RED confirmado**: correr el gate contra la base local SIN la migración → debe fallar en T1 (la columna existe). Registrar la evidencia.

## 3. Migración (orden de D5, idempotente)

- [ ] 3.1 Crear `supabase/migrations/<siguiente>_productos_categoria_text_retiro.sql`. Numerar **después** de `20261039000001`; si otro PR toma el número mientras tanto, renumerar (gotcha recurrente del repo).
- [ ] 3.2 Paso 1 — `CREATE OR REPLACE VIEW public.v_products_with_stock` con `LEFT JOIN public.product_categories pc ON pc.id = p.category_id` y `pc.name AS category` en la **misma posición y tipo** que la columna actual. **`LEFT`, nunca `INNER`** (D1). Si el `REPLACE` es rechazado, usar el fallback `DROP VIEW` + `CREATE VIEW` re-declarando `security_invoker=true` y los `GRANT` **en el mismo archivo**.
- [ ] 3.3 Paso 2 — `CREATE OR REPLACE FUNCTION public.fn_product_category_tenancy_guard()` conservando el chequeo de cuenta y el `RAISE ... USING ERRCODE = 'P0404'` con el **mismo texto** (los clientes traducen por token), sin la asignación del espejo; montar `trg_product_category_tenancy_guard BEFORE INSERT OR UPDATE OF category_id, account_id ON public.products`.
- [ ] 3.4 Paso 2b — `DROP TRIGGER IF EXISTS` + `DROP FUNCTION IF EXISTS` de `trg_product_category_mirror`/`fn_product_category_mirror` y `trg_product_category_propagate_name`/`fn_product_category_propagate_name`.
- [ ] 3.5 Paso 3a — `CREATE OR REPLACE` de `rpc_product_ranking` desde el cuerpo vivo: reemplazar `hp.category AS head_category` por el `LEFT JOIN public.product_categories` correspondiente. **No tocar** las CTEs `keyed`/`agg`, el `ORDER BY`, el `RETURNS TABLE` ni la firma.
- [ ] 3.6 Paso 3b — ídem `rpc_product_sales_evolution` (`pr.category` en la CTE de cabecera).
- [ ] 3.7 Paso 3c — `rpc_bulk_upsert_products`: quitar `category` de la lista de columnas del `INSERT` y su valor `COALESCE(v_cat_name, 'Otros')`. **No tocar** la resolución/creación de categorías, el tope, la resolución de padre ni el `EXCEPTION` por fila.
- [ ] 3.8 Paso 3d — re-declarar ACLs de las tres RPCs (`REVOKE ALL FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated, service_role`), aunque `CREATE OR REPLACE` las preserve — convención del repo.
- [ ] 3.9 Paso 4 — **guarda de verificación**: `RAISE EXCEPTION` si existe alguna fila con `category_id IS NULL AND category IS NOT NULL AND category <> ''`, ANTES del `DROP`.
- [ ] 3.10 Paso 5 — `ALTER TABLE public.products DROP COLUMN IF EXISTS category;` + `COMMENT ON COLUMN public.v_products_with_stock.category` explicando que es derivada (mitigación de OQ-1).
- [ ] 3.11 Verificar idempotencia: `supabase db reset` local, y luego **reaplicar el archivo dos veces** sobre la base ya migrada sin error.

## 4. Backend — retiro de las escrituras muertas

- [ ] 4.1 **SAFETY NET**: correr `pytest backend/tests/test_products*.py backend/tests/test_product_categories*.py` y registrar el baseline ("N passed").
- [ ] 4.2 Retirar `category` del `INSERT` de `ProductRepository.create` (`backend/repositories/product_repository.py:87-96`), incluido su parámetro posicional. Verificar que la renumeración de `$N` quedó consistente.
- [ ] 4.3 Retirar `data["category"] = parent["category"]` (`backend/services/products.py:108`) y `data["category"] = category["name"]` (`:114`). La herencia de variante queda sólo por `category_id`.
- [ ] 4.4 Retirar `category` de `ProductCreate` y `ProductUpdate` (`backend/schemas/products.py:16`, `:41`). **Conservar `ProductOut.category`** — es la salida y sigue siendo verdad.
- [ ] 4.5 Test: un payload de alta que incluya `category` (cliente viejo) **no falla** y el producto queda con la categoría del `category_id` (D6).
- [ ] 4.6 Test: alta de variante hereda `category_id` del padre y su `ProductOut.category` trae el nombre del padre, sin que el servicio escriba nombre alguno.
- [ ] 4.7 Test: `ProductOut.category` sigue llegando poblado desde `list_by_org`, `get_by_id`, `search_by_sku` y `search_by_barcode` (los cuatro `SELECT *`).
- [ ] 4.8 Correr la suite backend completa y comparar con el baseline de 4.1. Coverage ≥87%.

## 5. Frontend — retiro de las escrituras muertas

- [ ] 5.1 **SAFETY NET**: `pnpm vitest run` sobre los tests de productos y registrar el baseline.
- [ ] 5.2 Retirar `category: product.category || null` del payload de alta y de edición (`frontend/hooks/data/use-products.ts:74`, `:98`).
- [ ] 5.3 Retirar `category: parent?.category ?? ""` de `frontend/components/forms/product-form.tsx:105`.
- [ ] 5.4 Verificar que **NO** cambian: `Product.category` (`lib/types.ts:355`), `mapProduct` (`use-products.ts:38`, incluido el fallback `|| "Otros"`), ni ninguna de las 10 lecturas de `product-catalog.tsx`. Si alguna necesitó cambiar, es señal de que D1 no se cumplió — reportar.
- [ ] 5.5 Test de regresión: el payload que sale del hook de alta **no** contiene la clave `category`, y sí contiene `category_id` cuando corresponde.
- [ ] 5.6 `pnpm tsc --noEmit` sin errores nuevos (verificar que `next-env.d.ts` no quedó sucio de un `next dev` previo).
- [ ] 5.7 Suite frontend completa contra el baseline de 5.1.

## 6. CI y documentación

- [ ] 6.1 En `.github/workflows/KPI_Validation.yml`: reemplazar el paso "Run productos-categorias-sku category mirror gate" por el gate nuevo, con `ON_ERROR_STOP=1`, conservando el comentario explicativo actualizado.
- [ ] 6.2 Borrar `supabase/tests/test_product_category_mirror.sql` (sus bloques vivos ya migraron al gate nuevo en 2.1).
- [ ] 6.3 Revisar si la migración nueva debe sumarse a la cadena de reaplicación de idempotencia de `KPI_Validation.yml` (líneas ~653-673). **Nota**: ese paso está roto en `main` desde antes (candidato conocido) — seguir el precedente de los últimos PRs y no bloquear el change por él; dejar constancia de la decisión.
- [ ] 6.4 Actualizar `knowledge-base/04_modelo_de_datos.md:89`: la línea `category TEXT -- Electrónica|Ropa|...` ya no describe la realidad. Reemplazar por `category_id UUID` → `product_categories`, señalando que el nombre se lee derivado de `v_products_with_stock`.
- [ ] 6.5 Actualizar en `CHANGES.md` el candidato heredado de `productos-categorias-sku` ("Retiro de `products.category` TEXT"): marcarlo resuelto por este change y anotar la corrección del inventario (`rpc_product_profitability` **no** era lectora).
- [ ] 6.6 Verificar que `CLAUDE.md` y `AGENTS.md` siguen sincronizados (`python scripts/ci/check_docs_sync.py --fix` si se tocó alguno).

## 7. Verificación (superficie declarada "sin cambios")

> Este change **no agrega superficie frontend** (excepción declarada en el proposal). Su criterio de éxito visual es **que nada cambie**, así que las pantallas se recorren igual.

- [ ] 7.1 Levantar el stack local con la migración aplicada.
- [ ] 7.2 `/productos`: la categoría se ve en las tarjetas y en la tabla, la búsqueda por nombre de categoría sigue encontrando, y la exportación del catálogo trae la columna `categoria` poblada.
- [ ] 7.3 `/configuracion` → Categorías: renombrar una categoría y confirmar que `/productos` muestra el nombre nuevo **sin recargar datos a mano**; desactivar una categoría con productos y confirmar que esos productos **siguen mostrando su nombre** (D3, el escenario que más importa).
- [ ] 7.4 Formulario de producto: alta de un padre con categoría, y alta de una variante (que no pide categoría y hereda la del padre).
- [ ] 7.5 `/estadisticas`: el ranking trae la columna de categoría poblada; "Ventas por categoría" sigue igual (no se tocó `rpc_sales_breakdown`); exportar el ranking a CSV y verificar la columna `categoria`.
- [ ] 7.6 `/estadisticas/productos/[id]`: el badge de categoría del detalle sigue apareciendo.
- [ ] 7.7 Importador CSV: importar un archivo con una categoría existente y otra nueva; verificar que ambas se resuelven/crean y que los productos quedan con su categoría legible.
- [ ] 7.8 Pasada visual en las 4 combinaciones (claro/oscuro × desktop/móvil) de `/productos` y `/configuracion` → Categorías, sólo para confirmar que no hubo regresión colateral.
- [ ] 7.9 `EXPLAIN (ANALYZE, BUFFERS)` de `SELECT * FROM v_products_with_stock WHERE account_id = $1` sobre el tenant más grande, comparado contra el plan previo al change. Reportar si el plan degeneró.

## 8. Gates y merge

- [ ] 8.1 Correr los gates SQL de `KPI_Validation.yml` en el **orden real del workflow** contra la base local, con foco en: el gate nuevo, `test_product_categories_catalog.sql`, `test_product_categories_seed.sql`, `test_product_sku_uniqueness_scope.sql`, `test_bulk_upsert_products_categories.sql`, `test_products_barcode_account_scope.sql`, `test_estadisticas_ventas_e1/e2/e3.sql` y `test_function_acl_gate.sql`.
- [ ] 8.2 Correr `test_qa_integral_fixes.sql` y `test_kpis_edge_cases.sql` (ambos mencionan `category`) y confirmar que no dependían de la columna física.
- [ ] 8.3 `npx openspec validate --specs --strict` — esperado 98/98 (no nace capability nueva).
- [ ] 8.4 Abrir PR desde la rama de apply. **Nunca commitear a `main`.** Esperar los checks (`Backend_Tests`, `Frontend_Tests`, `E2E_Tests`, `KPI_Validation`, `Docs Sync`, Vercel) y mergear con todos en verde.

## 9. Verificación post-merge en producción

- [ ] 9.1 `MAX(version)` = la migración de este change; conteo de migraciones = 289.
- [ ] 9.2 `products.category` **ausente** de `information_schema.columns`.
- [ ] 9.3 `trg_product_category_mirror` y `trg_product_category_propagate_name` ausentes de `pg_trigger`; `trg_product_category_tenancy_guard` presente y su función con el `P0404` en el cuerpo vivo.
- [ ] 9.4 `v_products_with_stock` con `security_invoker=true`; `COUNT(*)` de la vista **igual** a `COUNT(*)` de `products` (5.096); `category` no nula para los 4.953 vivos.
- [ ] 9.5 ACLs de `rpc_product_ranking`, `rpc_product_sales_evolution` y `rpc_bulk_upsert_products` sin `EXECUTE` para `anon`; una sola definición viva de cada una (sin overload).
- [ ] 9.6 Humo real con el PO: abrir `/productos` y `/estadisticas` en prod, renombrar una categoría y ver el cambio reflejado en ambas.
- [ ] 9.7 Guardar en engram el resultado del apply con `topic_key: "opsx/productos-categoria-text-retiro/apply"`.
