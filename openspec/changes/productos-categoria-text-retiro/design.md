## Context

### Estado vivo, verificado el 2026-09-09

Base local migrada (= `main`) y **producción** coinciden exactamente: `MAX(version) = 20261039000001`, 288 migraciones, y el mismo conjunto de funciones que mencionan el token `category` sin sufijo. Todo lo que sigue se verificó contra el cuerpo **vivo** (`pg_get_functiondef`), no contra archivos de migración — la regla del repo desde `metodos-pago-saga`.

**Medición en producción (2026-09-09):**

| Métrica | Valor |
|---|---:|
| Productos totales | 5.096 |
| Vivos (`deleted_at IS NULL`) | 4.953 |
| **Sin `category_id`** | **0** |
| Sin `category_id` pero con texto legacy | **0** |
| **Espejo desincronizado** (`category <> pc.name`) | **0** |
| `category` NULL | **0** |

El invariante que hace segura la derivación —*todo producto tiene `category_id`, y su TEXT ya dice exactamente el nombre de esa categoría*— se cumple hoy al **100 %**. No hay ninguna fila cuyo texto legacy se pierda al dejar de materializar la columna. Es la diferencia entre este retiro y el de las columnas legacy de RN-97, que sí tienen datos sin correspondencia.

### Estructura vigente

- `products.category` es `TEXT NULL`, **sin índice, sin constraint y sin default**. Su único mantenedor son dos triggers.
- `products.category_id` es `UUID NULL` → `product_categories(id)` `ON DELETE RESTRICT`, con `products_category_id_idx` parcial (`WHERE category_id IS NOT NULL`).
- `v_products_with_stock` es una vista de **una sola tabla** (`FROM products p`) con dos subconsultas correlacionadas sobre `branch_stock` (`stock`, `min_stock`), declarada **`security_invoker=true`**, propiedad de `postgres`, con `SELECT` para `anon`/`authenticated`/`service_role` y **sin triggers `INSTEAD OF`** (nadie escribe a través de ella).
- `product_categories` tiene **RLS activa**, con `SELECT` para `authenticated` bajo `account_id IN (current_account_ids())` — y **sin filtro por `deleted_at`**. Este detalle es load-bearing (D3).

### Inventario completo de lectores y escritores de `products.category`

Barrido por tres vías independientes: `pg_get_functiondef` de las 100+ funciones de `public` con el regex `category(?![_a-z])`; `grep` sobre `frontend/`, `backend/`, `supabase/functions/` y `supabase/tests/`; e inspección columna por columna de cada `SELECT` que toca `v_products_with_stock`.

**Lectores de la columna FÍSICA `products.category` (los que obligan a reescribir):**

| # | Sitio | Qué hace | Acción |
|---|---|---|---|
| 1 | `rpc_product_ranking(uuid,date,date,text,boolean,uuid,text,int,int)`, CTE `ranked` → `hp.category AS head_category` | `JOIN public.products hp` (la **tabla**) para el encabezado del grupo | Reescribir: `LEFT JOIN product_categories` |
| 2 | `rpc_product_sales_evolution(uuid,uuid,date,date,text,uuid,text)`, CTE de cabecera → `pr.category` | Ídem, para el detalle por producto | Reescribir: `LEFT JOIN product_categories` |
| 3 | `fn_product_category_mirror()` (`NEW.category := v_name`) | Espejo **+ guard de tenencia `P0404`** | Partir en dos (D4) |
| 4 | `fn_product_category_propagate_name()` (`UPDATE products SET category = NEW.name`) | Propaga el renombre | Eliminar |
| 5 | `v_products_with_stock` (columna `category` de la lista de selección) | Expone la columna física | Derivar (D1) |

**Escritores de la columna física (todos redundantes hoy — el trigger los pisa):**

| # | Sitio | Qué escribe | Acción |
|---|---|---|---|
| 6 | `rpc_bulk_upsert_products(jsonb,uuid)`, rama `INSERT` | `COALESCE(v_cat_name, 'Otros')` — un `'Otros'` **hardcodeado** que el trigger sobrescribe acto seguido | Quitar la columna del `INSERT` |
| 7 | `backend/repositories/product_repository.py:87-96` | `category` en la lista del `INSERT`, valor `data.get("category")` | Quitar |
| 8 | `backend/services/products.py:108` | `data["category"] = parent["category"]` (variante) | Quitar (`category_id` ya se hereda en la línea anterior) |
| 9 | `backend/services/products.py:114` | `data["category"] = category["name"]` | Quitar |
| 10 | `backend/schemas/products.py:16` y `:41` | `ProductCreate.category` / `ProductUpdate.category` | Retirar del schema (D6) |
| 11 | `frontend/hooks/data/use-products.ts:74` y `:98` | `category: product.category \|\| null` en el payload de alta/edición | Quitar |
| 12 | `frontend/components/forms/product-form.tsx:105` | `category: parent?.category ?? ""` | Quitar |

**Lectores de `v_products_with_stock` que NO leen `category` — verificado columna por columna, no por presunción:**

| Sitio | Columnas que selecciona |
|---|---|
| `supabase/functions/generate-export/index.ts:128` (hoja de stock) | `name, sku, stock, min_stock, price` |
| `frontend/lib/ai/buildBusinessSnapshot.ts:124` | `id, name, price, cost, stock` |
| `backend/repositories/product_repository.py:152` | `stock` |

**Lectores que leen `category` a través de la vista (siguen intactos bajo D1):**

- `backend/repositories/product_repository.py:66, 75, 170, 178` — cuatro `SELECT *` (`list_by_org`, `get_by_id`, `search_by_sku`, `search_by_barcode`). De acá sale `ProductOut.category`.
- `frontend/hooks/data/use-products.ts:38` → `mapProduct` → `Product.category` (`frontend/lib/types.ts:355`).
- `frontend/components/products/product-catalog.tsx` — búsqueda (`:251`, `:271`), exportación (`:383`, `:396`, `:412`) y presentación (`:592`, `:720`, `:891`, `:993`, `:1115`).

**Lectores que leen `category` a través de las dos RPCs reescritas (intactos: las firmas no cambian):**

- `supabase/functions/_shared/export-ranking.ts:113, 170, 235` (`ProductRankingRpcRow.category` → columna `categoria` del CSV).
- `frontend/app/(dashboard)/estadisticas/productos/[id]/page.tsx:111` (`detail.product.category`).

**Falsos positivos del candidato heredado, corregidos por medición:**

- **`rpc_product_profitability`** — el candidato en `CHANGES.md` la nombra como lectora. **No lo es**: su cuerpo vivo no contiene la subcadena `categ` en ninguna forma. `estadisticas-ventas` E1 la reescribió sobre `reporting_sales_lines_in_window` y en esa pasada dejó de leer categoría. **No se toca en este change.**
- **Las Edge Functions de IA** — `ai-insights/index.ts:140,250` y `buildBusinessSnapshot.ts:132,206` leen `category`, pero de **`expenses`**, una columna TEXT distinta y ajena a este change. `generate-export/index.ts:105,111` idem.
- **`rpc_sales_breakdown`** — ya agrupa por `pr.category_id → product_categories.name` desde `estadisticas-ventas` E2. Ya está del lado correcto; no se toca.
- **El importador** (`frontend/lib/import/validator.ts`, `lib/import/types.ts`) — su `category` es el **nombre de la columna del CSV** y la clave del payload JSONB (`v_row->>'category'`), no la columna de la tabla. Sigue igual: el usuario carga un nombre de categoría y la RPC lo resuelve contra el catálogo.

### Restricciones

- Reutilización antes que repetición (regla PO 2026-08-02): si el nombre `category` ya significa "nombre de la categoría del producto", no se inventa uno nuevo.
- Toda reescritura de RPC parte del `pg_get_functiondef` **vivo**; el orquestador entrega los md5 de prod en el apply.
- Migración idempotente (Supabase auto-aplica y puede reaplicar).
- `DROP COLUMN` sólo después de verificar 0 lectores físicos.
- Gate SQL nuevo cableado en `KPI_Validation.yml`.

## Goals / Non-Goals

**Goals:**

- Dejar **una sola representación física** de la categoría de un producto: `products.category_id`.
- Que **ningún lector de aplicación cambie**: `ProductOut.category`, `Product.category` y la columna `category` de las dos RPCs de estadísticas conservan nombre, tipo y valor.
- Preservar intacto el guard de tenencia `P0404`, que hoy viaja de polizón en el trigger de espejo.
- Eliminar el `UPDATE` masivo sobre `products` que dispara hoy cada renombre de categoría.
- Convertir en garantía estructural lo que hoy es sólo una promesa del choke point: con una sola columna, la desincronización **no puede existir**.

**Non-Goals:**

- **Renombrar la columna a `category_name`** en la vista, la API o el frontend (D2, descartado explícitamente).
- **Hacer `category_id` `NOT NULL`.** Sigue nullable por el mismo argumento de D2 del change original: un `NOT NULL` convierte "no supe resolver la categoría" en "el producto no se importa" dentro del `EXCEPTION` por fila de `rpc_bulk_upsert_products`. Es un endurecimiento independiente y merece su propia decisión.
- **Tocar `rpc_product_profitability`, `rpc_sales_breakdown` ni el importador.** Ya están del lado correcto (medido).
- **`expenses.category`** (TEXT libre, sin catálogo). Es otra columna, otra deuda y otro change.
- **Superficie frontend nueva.** Declarado en el proposal.
- **Materializar la categoría en las líneas de venta.** El snapshot de línea (`v3-snapshot-pattern`) congela nombre/SKU/costo, no categoría; que el ranking siga el renombre es deliberado y ya es el comportamiento de `rpc_sales_breakdown`.

## Decisions

### D1 — La vista deriva `category` por `LEFT JOIN`, y conserva el nombre de la columna

`v_products_with_stock` deja de exponer la columna física y pasa a exponer:

```sql
LEFT JOIN public.product_categories pc ON pc.id = p.category_id
...
pc.name AS category
```

*Por qué la vista y no cada lector:* la vista es el **único punto de paso** de todo el backend a los productos (`SELECT *` en cuatro repositorios). Derivar ahí hace que `ProductOut.category` → `mapProduct` → `Product.category` → las 10 superficies de `product-catalog.tsx` sigan funcionando **sin editar un archivo**. Migrar lector por lector (opción B) tocaría ~20 sitios sin ganar nada, y cada uno sería una oportunidad de dejar un `NULL` resolviéndose en silencio — exactamente el riesgo que el design de `productos-categorias-sku` invocó para no hacer esto en su momento. Ese riesgo era real cuando la alternativa era *dropear sin derivar*; con la derivación en la vista, desaparece.

*Por qué `LEFT JOIN` y no una subconsulta correlacionada:* la vista ya tiene dos correlacionadas sobre `branch_stock`; una tercera sobre una tabla diminuta sería equivalente en costo. Se elige el `JOIN` porque es la forma que el planner puede reordenar y porque es el precedente del repo para un 1:0..1 sobre el hot path (`cobranzas-panel` D9, `_classified_activity_cte`). La multiplicidad está garantizada por la FK contra la PK.

*Por qué `LEFT` y nunca `INNER` — esto no es estilo, es correctitud:* la vista es `security_invoker=true` y `product_categories` **tiene RLS**. Con un `INNER JOIN`, cualquier fila de categoría que la RLS del invocador no vea haría **desaparecer el producto entero** del catálogo, del stock y de las búsquedas por SKU y por código de barras — una pérdida de datos silenciosa en el hot path. Con `LEFT JOIN`, el peor caso es `category = NULL`, que el frontend ya degrada a `"Otros"` (`use-products.ts:38`). El gate lo fija con un caso explícito (T5).

*Por qué se conserva el nombre `category`:* la columna siempre significó "el nombre de la categoría de este producto" y ese significado no cambia. Renombrarla sería repetir trabajo sin comprar nada (D2). Ver **OQ-1**.

*Alternativa descartada — columna generada (`GENERATED ALWAYS AS`):* Postgres no admite subconsultas a otras tablas en una columna generada. Es el mismo callejón que el design original documentó.

### D2 — No se renombra a `category_name` en ninguna capa

Alternativa considerada seriamente: renombrar la columna derivada de la vista a `category_name`, y con ella `ProductOut.category_name`, `Product.categoryName`, `ProductRankingRpcRow.category_name`, la columna del CSV del ranking y las ~13 lecturas de `product-catalog.tsx`.

Se descarta. El argumento a favor —"`category` suena a que es la categoría, no su nombre"— es real pero débil: el campo siempre entregó un `string`, y ningún consumidor lo confundió nunca con la entidad (la entidad es `categoryId`, que ya existe y ya se llama así desde `productos-categorias-sku`). El argumento en contra es fuerte y triple: multiplicaría el diff por veinte, rompería el CSV del ranking que el PO validó a mano hace cinco días (`estadisticas-ventas` E3, fix #508), y convertiría un change de "nada cambia para nadie" en uno con superficie de usuario. La regla de reutilización antes que repetición apunta en la misma dirección.

### D3 — Una categoría dada de baja sigue mostrando su nombre, y eso hay que probarlo

Es el riesgo funcional real de D1, y por eso se verificó antes de decidir en vez de después.

Hoy, con el espejo, un producto imputado a una categoría desactivada o soft-deleted conserva su nombre legible porque el TEXT quedó materializado. La spec `product-category` lo manda: *"La baja de una categoría es desactivación y preserva la imputación histórica"*. Si la derivación no resolviera el nombre de una categoría dada de baja, este change **rompería un requirement vigente** — silenciosamente y sólo para los tenants que hubieran dado de baja alguna categoría.

Verificado que no ocurre, por dos hechos concurrentes:

1. `product_categories` usa **soft delete** (`deleted_at`), nunca `DELETE` físico, y la FK es `ON DELETE RESTRICT` — o sea, la fila **siempre existe** mientras haya un producto que la referencie.
2. La policy `product_categories_member_select` es `account_id IN (current_account_ids())` — **no filtra por `deleted_at` ni por `is_active`**. La fila sigue siendo visible para cualquier miembro de la cuenta.

El `LEFT JOIN` la resuelve, entonces, exactamente igual que hoy. Como este comportamiento pasa a depender de una policy que vive en otro archivo y que nadie asocia con el catálogo de productos, **se fija con un escenario en la spec y un bloque de gate propio** (T4): una policy futura que agregue `AND deleted_at IS NULL` a ese `SELECT` sería una regresión invisible sin esa red.

### D4 — El guard de tenencia se conserva en un trigger propio, reducido a esa sola responsabilidad

`fn_product_category_mirror()` hace **dos** cosas: mantiene el espejo y rechaza con `P0404` la imputación a una categoría de otra cuenta. Lo segundo no es accesorio: es el **único chequeo a nivel de base** de ese invariante (la FK a `product_categories` no está alcanzada por `account_id`, exactamente el mismo hueco que `cuenta-corriente-party-guard` cerró para `clients`/`suppliers`), y la spec `product-category` lo manda como cláusula normativa: *"esa validación NO SHALL depender de lo que envíe el cliente"*.

Borrar el trigger sin más lo perdería. El backend valida por su lado (`_resolve_category_for_account`), pero `rpc_bulk_upsert_products` no pasa por el backend, y la defensa en profundidad a nivel base es justamente lo que hace que un camino de escritura futuro nazca cubierto.

Por eso el retiro del espejo **no es un `DROP TRIGGER`**, sino una partición: `fn_product_category_tenancy_guard()` conserva la comprobación y el `P0404` textualmente (mismo mensaje, mismo ERRCODE — los clientes traducen por token), pierde el `NEW.category := v_name`, y su trigger se estrecha a `BEFORE INSERT OR UPDATE OF category_id, account_id` (sin `category`, que ya no existe).

Se declara como riesgo aceptado que esto **agranda** el trabajo respecto de un `DROP` a secas. Es el precio de no perder un guard de tenencia por descuido, y el repo ya tiene el precedente de la lección opuesta (`pos-catalogo-pagos` encontró el bloque `credit` de C-30 borrado en silencio por una regresión de julio).

### D5 — Orden de la migración: la vista primero, el `DROP COLUMN` último

Dentro de una única migración idempotente:

1. `CREATE OR REPLACE VIEW v_products_with_stock` con el `LEFT JOIN` — mientras la columna física todavía existe. **Nota de implementación**: `CREATE OR REPLACE VIEW` no admite cambiar el tipo ni el **orden** de las columnas existentes; `category` sigue siendo `text` y sigue en su posición, así que el `REPLACE` es legal. Si el planner rechazara el reemplazo, el fallback es `DROP VIEW` + `CREATE VIEW` **re-declarando `security_invoker=true` y los `GRANT`** — que es exactamente el modo de romper la RLS del backend por descuido, así que se prefiere el `REPLACE` y se verifica en el gate que la opción sobrevive (T6).
2. `CREATE OR REPLACE` de `fn_product_category_tenancy_guard()` + su trigger; `DROP TRIGGER`/`DROP FUNCTION IF EXISTS` de los dos del espejo.
3. `CREATE OR REPLACE` de `rpc_product_ranking` y `rpc_product_sales_evolution` (firmas idénticas → `REPLACE`, que **preserva ACLs**; se re-declaran igual por convención del repo) y de `rpc_bulk_upsert_products`.
4. **Guarda de verificación antes del `DROP`**: si `EXISTS (SELECT 1 FROM products WHERE category_id IS NULL AND category IS NOT NULL AND category <> '')`, la migración **falla ruidosamente** en vez de dropear. Es el mismo patrón con que `productos-categorias-sku` protegió el swap del índice de SKU: hoy son 0 filas, pero el `DROP` se ejecuta cuando el PR merguee, no ahora.
5. `ALTER TABLE public.products DROP COLUMN IF EXISTS category;`

El paso 4 es el que convierte "medimos 0 en prod el 2026-09-09" en una garantía que no vence.

### D6 — `ProductCreate.category` / `ProductUpdate.category` se retiran del schema, no se dejan ignorados

Pydantic no declara `extra='forbid'` en estos modelos, así que un campo sobrante en el body se **ignora** en silencio. Eso hace el retiro seguro en la dirección que importa: **frontend viejo → backend nuevo no rompe** (Vercel y Render despliegan por separado, y este repo ya se quemó con un contrato endurecido sin migrar los callers — `Idempotency-Key`, PR #451).

*Por qué retirarlos y no dejarlos como campos muertos:* un campo que la API acepta y descarta es una mentira documentada en el schema. `ProductOut.category` se queda (es la **salida**, y sigue siendo verdad); lo que se va es la **entrada**, que ya hoy no tiene efecto observable —el trigger pisa lo que llegue— y sólo servía para que un cliente creyera que puede fijar el nombre a mano.

La herencia de variante (`services/products.py:106-108`) pierde su segunda línea: el `category_id` del padre ya se hereda, y el nombre lo deriva la vista. Deja de haber dos hechos que mantener alineados.

### D7 — El gate se reemplaza, no se agrega, y hereda los bloques que siguen siendo verdad

`test_product_category_mirror.sql` asserta un mecanismo que este change elimina: sus bloques (1)-(6) hablan del espejo. Dejarlo puesto lo volvería rojo; borrarlo perdería los bloques (7) `P0404`, (8) FK `RESTRICT` y (9) convivencia con el guard de soft delete, que **siguen siendo normativos**.

Se reemplaza por `test_product_category_derived.sql`, que hereda esos tres bloques literalmente y agrega:

- **T1** — `products.category` **no existe** en `information_schema.columns` (el detector de la deuda saldada).
- **T2** — `v_products_with_stock` expone `category` con el nombre vigente de la categoría referenciada.
- **T3** — renombrar una categoría cambia lo que la vista devuelve **sin escribir una sola fila de `products`** (`xmin` intacto — el reverso exacto del bloque (4) del gate viejo, que probaba lo contrario).
- **T4** — un producto imputado a una categoría **soft-deleted** sigue viendo su nombre por la vista (D3).
- **T5** — un producto con `category_id IS NULL` **aparece igual** en la vista, con `category` nula (el `LEFT JOIN` no filtra).
- **T6** — la vista conserva `security_invoker=true` y sus `GRANT` (D5, paso 1).
- **T7** — ninguna función de `public` referencia ya la columna física (mismo barrido `pg_get_functiondef` con el que se armó el inventario, para que un lector nuevo no nazca a escondidas).

Se cablea en `KPI_Validation.yml` en el lugar del paso viejo, con `ON_ERROR_STOP=1`.

## Risks / Trade-offs

- **[Un `INNER JOIN` en la vista haría desaparecer productos]** → Es el modo de falla catastrófico de D1, y no es hipotético: la vista es `security_invoker` y `product_categories` tiene RLS. Mitigación: `LEFT JOIN` obligatorio, declarado en la spec como cláusula normativa (no como comentario) y cubierto por el bloque T5 del gate con un producto sin `category_id`.

- **[Una policy futura sobre `product_categories` que filtre `deleted_at` rompería el nombre legible de los productos históricos]** → Hoy la policy no filtra (verificado, D3), pero ese hecho vive en otro archivo y nadie lo asocia con el catálogo de productos. Mitigación: escenario propio en la spec `product-category` + bloque T4 del gate. Es exactamente el patrón de "invariante que se sostenía sólo por comentario" que `cobranzas-reverso` convirtió en gate real para el outbox.

- **[Perder el guard `P0404` al borrar el trigger de espejo]** → Mitigación: D4 lo conserva en un trigger propio antes de borrar el viejo, con el mismo ERRCODE y el mismo texto; el bloque heredado (7) del gate lo sigue asertando y fallaría si desapareciera.

- **[Reescribir `rpc_product_ranking` rompe el ranking o el CSV que el PO acaba de validar]** → Es el tramo más delicado. Mitigación: se parte del cuerpo vivo (md5 del orquestador); el cambio se limita a **una** cláusula `JOIN` y **una** expresión de la lista de selección, sin tocar el `keyed`/`agg`/`ranked` ni el `ORDER BY`; la firma y el `RETURNS TABLE` no cambian, así que `export-ranking.ts` y `/estadisticas` no se enteran; y el gate de `estadisticas-ventas` E1/E3 ya existente corre igual y detectaría un corrimiento.

- **[El `LEFT JOIN` degrada el hot path del catálogo]** → `list_by_org` hace `SELECT * FROM v_products_with_stock WHERE account_id = $1` sobre hasta ~3.000 filas de un tenant. Se suma un join contra una tabla de decenas de filas por la PK. Es despreciable frente a las dos subconsultas correlacionadas sobre `branch_stock` que la vista ya paga por fila. Se declara igual porque es el hot path del catálogo y porque el riesgo real no es la latencia sino un plan degenerado; se verifica con un `EXPLAIN` sobre el tenant más grande antes del merge.

- **[`CREATE OR REPLACE VIEW` no acepta el reemplazo y hay que hacer `DROP` + `CREATE`]** → El `DROP`+`CREATE` es el camino por el que se pierden `security_invoker=true` y los `GRANT`, y esa pérdida **no da error**: deja la vista funcionando con los permisos del owner, es decir, con la RLS del backend anulada. Mitigación: se prefiere el `REPLACE` (legal acá porque no cambia tipos ni orden de columnas), el fallback re-declara ambas cosas en el mismo archivo, y el bloque T6 del gate las verifica.

- **[Un consumidor externo no inventariado consulta `products.category` por SQL directo]** → No existe ninguno en el repo (barrido triple, arriba). El riesgo residual es una query manual del PO o un dashboard externo. Mitigación: la columna `category` sigue disponible en `v_products_with_stock`, que es el camino soportado y documentado; se anota en la KB.

- **[Se agranda el trabajo respecto de un `DROP TRIGGER` a secas]** → Aceptado (D4). Es la diferencia entre retirar una deuda y perder un guard de tenencia.

## Migration Plan

**Migración única e idempotente**, siguiendo el orden de D5: vista derivada → guard de tenencia particionado → tres RPCs reescritas desde el cuerpo vivo con re-declaración de ACLs → guarda de verificación → `DROP COLUMN`. Todo `IF EXISTS` / `CREATE OR REPLACE`, porque Supabase auto-aplica y puede reaplicar.

**Orden de despliegue.** Backend y frontend van **detrás** de la migración, pero la secuencia es segura en cualquier orden gracias a la forma del cambio:

- Backend viejo + migración aplicada → el `INSERT` de `ProductRepository.create` referenciaría una columna que ya no existe. **Este es el único punto de rotura real**, y por eso el retiro de las escrituras del backend (ítems 7-10 del inventario) va en el **mismo PR** que la migración. Es el mismo acoplamiento que Supabase resuelve hoy en `deploy.yml` (migración y build en el mismo pipeline).
- Frontend viejo + backend nuevo → el `category` sobrante del body se ignora (D6). Sin rotura.
- Frontend nuevo + backend viejo → no manda `category`, que ya era opcional. Sin rotura.

**Rollback.** El paso no trivialmente reversible es el `DROP COLUMN`: recrear la columna la deja **vacía**. La reversión honesta no es un `ALTER TABLE ... ADD COLUMN`, sino re-materializarla desde el catálogo — que es exactamente lo que el backfill de `productos-categorias-sku` hizo al revés y que es reproducible en un `UPDATE` de una línea (`SET category = pc.name FROM product_categories pc WHERE pc.id = products.category_id`), porque **toda la información sigue viva en `category_id`**. Ésa es la propiedad que hace este retiro reversible y el de una columna con datos propios no: no se destruye ningún hecho, sólo una copia.

**Verificación post-merge en prod** (rutina del repo):
- `MAX(version)` = la migración nueva; 289 migraciones.
- `products.category` ausente de `information_schema.columns`.
- Los dos triggers del espejo ausentes de `pg_trigger`; `fn_product_category_tenancy_guard` presente y su trigger montado.
- `v_products_with_stock` con `security_invoker=true`, `category` no nula para los 4.953 productos vivos, y el conteo total de filas de la vista **idéntico al de `products`** (la prueba de que el `LEFT JOIN` no filtró a nadie).
- ACLs de las tres RPCs sin `EXECUTE` para `anon`.
- Humo real: abrir `/productos` y confirmar que la categoría se ve; renombrar una categoría en `/configuracion` y ver el cambio reflejado en el catálogo y en el ranking.

## Open Questions

Las cuatro OQs quedaron **resueltas por el orquestador** (sign-off general del PO, "si a todo") por la recomendación de cada una, sin excepción. Estado final:

- **OQ-1 — ¿La columna derivada de la vista se sigue llamando `category`, o pasa a `category_name`?**
  → ✅ **RESUELTA: `category`** (D1/D2). El significado no cambia, la entidad ya tiene su nombre propio (`category_id`), y renombrar multiplicaría el diff por veinte y tocaría el CSV del ranking que el PO validó hace cinco días. El costo de la recomendación es que un lector nuevo del schema podría no notar de inmediato que la columna ya no es física — mitigado con un comentario `COMMENT ON COLUMN` y con la spec. **Implementado**: `v_products_with_stock.category` lleva `COMMENT ON COLUMN` explicando la derivación (migración `20261040000001`, paso 1).

- **OQ-2 — ¿El change incluye hacer `products.category_id` `NOT NULL`?**
  → ✅ **RESUELTA: NO** (Non-Goal, sin cambios). Prod tiene 0 filas nulas hoy, así que la restricción "entraría gratis", pero rompería el degradado por fila de `rpc_bulk_upsert_products` que `productos-categorias-sku` D2 eligió deliberadamente: convertiría "no supe resolver la categoría de esta fila del CSV" en "esta fila no se importa". Si el PO lo quiere, es una decisión de producto sobre el importador, no un accesorio de este retiro. `category_id` sigue `uuid NULL` en la migración.

- **OQ-3 — Con la columna física fuera, ¿el ranking histórico debería congelar la categoría al momento de la venta?**
  → ✅ **RESUELTA: NO, Non-Goal** (sin cambios). Hoy el nombre sigue el renombre (es lo que ya hace `rpc_sales_breakdown` desde `estadisticas-ventas` E2) y ése es el comportamiento correcto para un **rótulo de maestro**: renombrar "Ropa" a "Indumentaria" no debe partir el histórico en dos. Congelar la categoría en la línea de venta sería sumarla a `v3-snapshot-pattern`, que hoy congela nombre/SKU/costo/IVA y deliberadamente no la incluye. Verificado con el gate T3 (`test_product_category_derived.sql`): renombrar se refleja de inmediato en el ranking/detalle, sin reescribir `products` ni ninguna línea histórica.

- **OQ-4 — ¿Se retira también el campo `category` del payload del importador?**
  → ✅ **RESUELTA: NO** (sin cambios). Es el nombre de la columna del CSV que el usuario carga y que la RPC resuelve contra el catálogo; no tiene relación con la columna de la tabla más allá del nombre. Retirarlo rompería todas las plantillas que los tenants ya tienen bajadas. `rpc_bulk_upsert_products` sigue leyendo `r->>'category'`/`v_row->>'category'` del JSONB de entrada sin cambios (sólo se retiró su escritura a la columna física, ya inexistente).
