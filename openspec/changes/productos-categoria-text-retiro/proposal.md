## Why

`productos-categorias-sku` (archivada 2026-09-04) movió la imputación de categoría a `products.category_id` (FK a `product_categories`) y dejó `products.category` (TEXT) viva como **espejo mantenido por trigger**, para que ningún lector legacy tuviera que cambiar en ese change. Su OQ-3 declaró explícitamente la deuda y su forma de pago: *"su retiro es un change propio que debe migrar `v_products_with_stock` y todos sus lectores de una sola vez"*. Este es ese change.

La deuda no es cosmética. Mientras las dos columnas convivan hay **dos representaciones de la misma verdad** sostenidas por dos triggers, y el riesgo declarado en el design original —que se desincronicen— sólo está cubierto mientras el choke point siga siendo el único camino de escritura. Cada RPC nueva que inserte en `products` es una oportunidad de que alguien escriba `category` a mano y nadie lo note. Además, el renombre de una categoría hoy dispara un `UPDATE` masivo sobre `products` (peor caso medido: 2.951 filas de una cuenta) cuyo único propósito es mantener el espejo.

**Se paga ahora porque el terreno está limpio y medido**: en producción (2026-09-09) hay **5.096 productos, 0 sin `category_id`, 0 con el espejo desincronizado y 0 con `category` nula**. El invariante que hace segura la derivación se cumple hoy al 100 %; postergarlo sólo agrega lectores nuevos que habrá que migrar después.

## What Changes

- **`products.category` (TEXT) se elimina de la tabla.** La categoría del producto pasa a tener una sola representación física: `products.category_id`.
- **`v_products_with_stock` sigue exponiendo una columna `category`**, ahora **derivada** por `LEFT JOIN` contra `product_categories.name`. Todo lector de la vista —el backend entero vía `SELECT *`, y por lo tanto `ProductOut.category`, `mapProduct` y las 6 superficies de `product-catalog.tsx`— sigue leyendo exactamente el mismo nombre de columna con el mismo valor, **sin cambiar una línea**.
- **Se retiran los dos triggers de espejo** (`trg_product_category_mirror` / `fn_product_category_mirror` y `trg_product_category_propagate_name` / `fn_product_category_propagate_name`), y con ellos el `UPDATE` masivo sobre `products` al renombrar una categoría.
- **El guard de tenencia sobrevive al retiro del espejo.** El trigger que se elimina también rechaza con `P0404` la imputación de un producto a una categoría de otra cuenta — el único chequeo a nivel base de ese invariante. Se conserva en un trigger propio, reducido a esa sola responsabilidad.
- **Se reescriben los dos únicos lectores SQL de la columna física**: `rpc_product_ranking` y `rpc_product_sales_evolution` pasan a resolver el nombre por `LEFT JOIN` a `product_categories`. Sus firmas y sus `RETURNS TABLE` **no cambian**, así que ni la API de estadísticas ni `export-ranking.ts` ni `/estadisticas/productos/[id]` se enteran.
- **Se retiran los tres write paths muertos a la columna**: el `INSERT` de `rpc_bulk_upsert_products` (que escribe un `COALESCE(v_cat_name, 'Otros')` hardcodeado que el trigger pisa acto seguido), el `INSERT` de `ProductRepository.create`, y la asignación de `data["category"]` en `product_service`. Los campos `category` de `ProductCreate`/`ProductUpdate` se retiran del schema; Pydantic ignora el campo sobrante, de modo que un frontend viejo apuntando al backend nuevo **no rompe**.
- **Gate SQL nuevo** (`test_product_category_derived.sql`) que reemplaza a `test_product_category_mirror.sql`: la columna física no existe, la vista deriva el nombre vigente, el renombre se refleja sin tocar `products`, una categoría dada de baja **sigue mostrando su nombre**, el `LEFT JOIN` nunca hace desaparecer un producto, y el guard `P0404` sigue vivo.

**Sin superficie frontend nueva** (regla PO 2026-08-02, excepción declarada): este change no agrega ni mueve ninguna pantalla, ruta ni entrada de menú. Su criterio de éxito visual es **que nada cambie**, y por eso las pantallas que hoy muestran la categoría entran igual a la pasada de verificación: `/productos` (catálogo, búsqueda y exportación), `/configuracion` → Categorías, el formulario de producto (alta de padre y de variante), `/estadisticas` (ranking y "Ventas por categoría") y `/estadisticas/productos/[id]`.

**BREAKING (dominio, no API)**: cualquier consumidor externo no inventariado que consulte `public.products.category` por SQL directo deja de encontrar la columna. No hay ninguno en el repo — el inventario está en `design.md` con ruta:línea — y el camino soportado (`v_products_with_stock`) sigue intacto.

## Capabilities

### New Capabilities

Ninguna. El change retira una representación redundante dentro de una capability existente; no introduce comportamiento nuevo que merezca spec propia.

### Modified Capabilities

- `product-category`: el requirement *"Imputación del producto a una categoría del catálogo"* deja de mandar que `products.category` (TEXT) se conserve como espejo desnormalizado, y pasa a mandar que la categoría tenga **una sola representación física** (`category_id`) y que el nombre legible se **derive**. El guard de tenencia (`P0404`) se eleva a cláusula propia, independiente del mecanismo que lo hospedaba. Se agrega el escenario que hoy no está cubierto por ningún test: un producto imputado a una categoría **dada de baja** conserva su nombre legible.
- `product-ranking`: se declara normativo que el nombre de categoría que viaja en el ranking y en el detalle por producto se **deriva del catálogo** (y por lo tanto sigue el renombre), en vez de venir de una columna desnormalizada del producto.

## Impact

**Base de datos** — migración única e idempotente:
- `public.products`: `DROP COLUMN category`.
- `public.v_products_with_stock`: `CREATE OR REPLACE VIEW` con el `LEFT JOIN` (se conserva `security_invoker=true`).
- Triggers/funciones: `DROP` de `trg_product_category_mirror` + `fn_product_category_mirror` + `trg_product_category_propagate_name` + `fn_product_category_propagate_name`; `CREATE` de `fn_product_category_tenancy_guard` + su trigger.
- RPCs reescritas desde su cuerpo vivo: `rpc_product_ranking`, `rpc_product_sales_evolution`, `rpc_bulk_upsert_products` (con re-declaración de ACLs).

**Backend** (`backend/`): `schemas/products.py` (retiro de `category` de `ProductCreate`/`ProductUpdate`), `repositories/product_repository.py` (`INSERT`), `services/products.py` (resolución de nombre y herencia de variante).

**Frontend** (`frontend/`): sólo retiro de escrituras muertas — `hooks/data/use-products.ts` y `components/forms/product-form.tsx`. **Cero cambios de lectura, de tipos públicos o de UI**: `Product.category` y `ProductOut.category` sobreviven con su nombre y su significado.

**Edge Functions**: ninguna afectada — `generate-export` no selecciona `category` de la vista y `buildBusinessSnapshot` tampoco (verificado, contra lo que suponía el candidato heredado).

**CI**: `test_product_category_mirror.sql` se reemplaza por `test_product_category_derived.sql` en `KPI_Validation.yml`.

**Documentación**: `knowledge-base/04_modelo_de_datos.md:89` (la línea que aún describe `category TEXT` con la lista fija de 7 valores) y el puntero del candidato heredado en `CHANGES.md`.
