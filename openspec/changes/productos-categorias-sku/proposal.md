## Why

La categoría de un producto es hoy una **lista fija global de 7 valores** horneada en el frontend (`PRODUCT_CATEGORIES` en `frontend/lib/constants.ts:171`). Un ferretero, una panadería y una tienda de indumentaria comparten exactamente el mismo vocabulario, y ninguno de los tres puede nombrar lo que realmente vende. La medición en producción muestra el resultado con claridad: **2.951 de 5.084 productos (58%) están en "Otros"**, y el reparto de los otros seis valores es residual (Ropa 1.803, Alimentos 236, Accesorios 58, Salud 25, Hogar 8, Electrónica 3). "Otros" no es una categoría: es el acuse de recibo de que el sistema no dejó decir la verdadera. El importador de carga masiva refuerza el efecto — cuando el CSV trae una categoría desconocida, `validator.ts:129-131` la **descarta y asigna "Otros"** con un warning.

Pedido textual del PO (2026-09-03): *"La categoría de los productos no es libre, sino que tenés varias opciones para elegir, pero a los productos me gustaría que pudieras poner la categoría que quieras, es decir que cada uno de los usuarios tiene su propia categoría; y por último quiero que le agregue SKU opcional, y tenés que tener en cuenta el template de ejemplo para la carga masiva."*

En paralelo, `products.sku` **existe como columna desde hace meses y no está expuesta en ningún formulario** (grep de `sku` en `components/forms/` = 0 resultados): sólo **6 de 5.084 productos** tienen SKU, todos cargados por importación. El campo está cableado de punta a punta salvo el último tramo — `ProductCreate.sku` lo acepta, `ProductRepository.create` lo persiste, `mapProduct` lo devuelve, `document-snapshots` ya especifica congelar `sku_snapshot` desde `products.sku` — y ese snapshot viene siendo NULL en el 100% de las líneas por falta de dato de origen, no por falta de código.

Este change es además el **prerrequisito de `estadisticas-ventas`**, que rankea productos por categoría: agrupar un ranking por un texto libre que el 58% de las filas comparte no produce información.

## What Changes

- **Catálogo de categorías de producto por cuenta.** Tabla nueva `product_categories` (espejo estructural de `cost_centers`/`payment_methods`: `account_id`, `name`, `sort_order`, `is_active`, soft delete, unique case-insensitive por cuenta sobre filas vivas, RLS account-direct). Cada tenant define las suyas; **sigue siendo elegir de una lista**, no texto libre por producto.
- **`products.category_id`** FK nullable al catálogo, como fuente de verdad de la imputación. `products.category` (TEXT) **se conserva** y pasa a ser un espejo desnormalizado mantenido por trigger, para que ningún lector legacy (vista `v_products_with_stock`, Edge Functions de IA, exportaciones, reportes) se rompa ni pierda su dato.
- **Seed de provisioning** con las 7 categorías legacy en `handle_new_user`, en sub-bloque aislado degrade-don't-fail, más backfill idempotente para las cuentas existentes. **Backfill de los 5.084 productos** `category` (texto) → `category_id`: la medición en prod da 0 productos sin categoría y 0 fuera de la lista fija, así que la correspondencia es total y sin residuo.
- **Gestión del catálogo** (crear, renombrar, reordenar, desactivar) gateada a `owner`/`admin`, como **décima pestaña de `/configuracion`** junto a Centros de costo y Formas de pago — un solo lugar para todos los catálogos de la cuenta (sign-off del PO, OQ-2); lectura para todo miembro.
- **Alta rápida inline "Nueva categoría"** desde el selector, en el formulario de producto y en el alta inline de producto del formulario de compra — sin salir de la pantalla en la que el usuario descubre que le falta la categoría.
- **Recategorización en lote** desde el listado de `/productos`: selección múltiple de productos y asignación de una categoría a todos de una vez. Es la herramienta que hace accionable el hallazgo de los 2.951 productos varados en "Otros" — sin ella, el catálogo por cuenta le da al usuario dónde poner sus productos pero no cómo moverlos.
- **SKU opcional visible** en el alta y la edición de producto, y buscable en el listado de productos.
- **BREAKING (interno, sin daño histórico): el alcance de unicidad del SKU pasa de `user_id` a `account_id`.** El índice vivo `idx_products_sku_user` es `UNIQUE (user_id, sku)`, no por cuenta — un residuo de tenencia anterior a C-19 que hoy es inerte porque ninguna cuenta con productos tiene más de un usuario, y que deja de serlo justo cuando el SKU se vuelve un campo que la gente carga a mano. Se reemplaza por `UNIQUE (account_id, lower(sku))` sobre filas vivas, y `rpc_bulk_upsert_products` —que resuelve SKU y padre por `user_id`— se migra a `account_id` en la misma pasada, para que la clave de upsert y la clave de unicidad no discrepen. Medición en prod: **0 colisiones** con el criterio nuevo.
- **Importador y template de carga masiva.** La columna `Categoría` se valida contra el catálogo del tenant y **una categoría desconocida se crea automáticamente**, anunciada en el paso de revisión antes de confirmar y acotada por un tope por importación. El template de ejemplo descargable pasa a generarse con las categorías reales de la cuenta y documenta SKU y Categoría con su comportamiento real.
- **Las variantes siguen heredando la categoría del padre** (comportamiento vigente en `product-form.tsx:95-96`), ahora por `category_id`.

## Capabilities

### New Capabilities
- `product-category`: catálogo de categorías de producto por cuenta — tabla, seed de provisioning y backfill, gestión gateada por rol, baja como desactivación que preserva la imputación histórica, imputación en `products` con espejo desnormalizado, herencia padre→variante, **recategorización en lote**, superficies (gestor en `/configuracion`, selector, alta rápida inline, selección múltiple en `/productos`) y resolución/creación de categorías desde la carga masiva.
- `product-sku`: SKU opcional del producto — alcance de unicidad por cuenta (case-insensitive, sobre filas vivas), exposición en alta/edición y búsqueda del listado, y su rol como clave de upsert de la carga masiva.

### Modified Capabilities
- `soft-delete-policy`: la enumeración normativa de maestros alcanzados por el soft delete (`clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`) incorpora `product_categories`.

## Impact

**Base de datos** — una migración: tabla `product_categories` + índices + RLS; `products.category_id` + FK + índice; trigger de espejo `category_id → products.category` (alta/edición de producto y renombre de categoría); swap del índice único de SKU (`user_id` → `account_id`, case-insensitive); reescritura de `rpc_bulk_upsert_products` (resolución por cuenta + resolución/creación de categoría) desde su `pg_get_functiondef` **vivo**, con re-`REVOKE`/`GRANT` de ACLs en el mismo archivo; sub-bloque de seed en `handle_new_user`; backfill idempotente de categorías por cuenta y de `products.category_id`.

**Backend FastAPI (3 capas)** — router/service/repository nuevos para el catálogo (`/product-categories`, espejo de `payment_methods`); `schemas/products.py` y `ProductRepository` incorporan `category_id`; endpoint nuevo de **recategorización en lote**; el conflicto de SKU duplicado se traduce a error legible.

**Frontend** — `PRODUCT_CATEGORIES` deja de ser la fuente (sus 2 consumidores, `product-form.tsx` y `purchase-form.tsx`, pasan al catálogo); componentes nuevos `ProductCategoryManager` y `ProductCategorySelect` (con alta rápida inline); hook `use-product-categories`; campo SKU en `product-form.tsx` y en la búsqueda de `product-catalog.tsx`; selección múltiple + barra de acción en lote en `product-catalog.tsx`; `/configuracion` pasa de 9 a 10 pestañas (`lg:grid-cols-10`); `lib/import/{types,validator,importer}.ts` y `product-import-dialog.tsx` (template + panel de columnas + aviso de categorías nuevas en el paso 2).

**Superficie frontend** (regla PO 2026-08-02): gestor de categorías como décima pestaña de `/configuracion` (ruta y entrada de menú ya existentes) junto a Centros de costo y Formas de pago; selector con alta rápida inline en el formulario de producto y en el alta inline de producto del formulario de compra; selección múltiple con barra de acción "Cambiar categoría" en el listado de `/productos`; campo SKU en el formulario de producto y en la búsqueda del listado; aviso de categorías a crear en el paso de revisión del importador. Verificación en escritorio y móvil, tema claro y oscuro, con tokens semánticos del design system.

**No se toca**: ninguna función que escriba dinero (caja, banco, cuentas corrientes, asientos), el outbox, ni la jerarquía Padre/Variante del importador.

**Governance**: **MEDIA**. No hay dinero en juego, pero el change reescribe una RPC `SECURITY DEFINER` que escribe `products`/`branch_stock`, cambia un índice único sobre una tabla caliente y toca el trigger de provisioning de cuentas.
