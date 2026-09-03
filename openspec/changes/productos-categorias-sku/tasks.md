# Tasks — productos-categorias-sku

> **Governance: MEDIA.** No se escribe dinero, pero se reescribe una RPC `SECURITY DEFINER` que escribe `products`/`branch_stock`, se cambia un índice único sobre una tabla caliente y se toca el trigger de provisioning de cuentas. Implementar en pasos, exponiendo las decisiones no obvias.
>
> **Strict TDD obligatorio.** Cada grupo que toque código sigue el ciclo SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR. Antes de modificar un archivo existente, correr sus tests y anotar el baseline (`N/N passing`); un fallo previo se reporta como *pre-existente* y NO se arregla en este change.
>
> **Reutilización antes que repetición.** El molde a copiar es `payment_methods` (tabla, seed, RLS, backend 3 capas, `PaymentMethodManager`, `PaymentMethodSelect`). No inventar patrones nuevos donde ya hay precedente.

## 1. Checkpoints previos — medir lo vivo antes de escribir SQL

- [ ] 1.1 Volcar `pg_get_functiondef` **vivo en prod** de `rpc_bulk_upsert_products` y de `handle_new_user` a un archivo de trabajo; hashearlos. Toda reescritura parte de ese cuerpo, NUNCA del último archivo de migración (precedente: la divergencia del G3 de `rpc_create_purchase_operation` por una reescritura in-place).
- [ ] 1.2 Confirmar contra prod las mediciones del design: 5.084 productos / 0 sin categoría / 0 fuera de la lista fija / 6 con SKU / 0 cuentas multiusuario con productos / 0 colisiones de `lower(trim(sku))` por cuenta. Si alguna cambió, revisar la decisión que se apoya en ella antes de seguir.
- [ ] 1.3 Listar los índices únicos vivos de `products` sobre `sku` y sobre `barcode`, y las ACLs vivas de `rpc_bulk_upsert_products`, para reproducirlas exactas tras el `CREATE OR REPLACE`.
- [ ] 1.4 Enumerar por búsqueda (no de memoria) TODOS los callers de `rpc_bulk_upsert_products` y todos los lectores de `products.category` (código, vistas, gates SQL, tests). El design nombra `v_products_with_stock`, `rpc_product_profitability`, `ProductOut`/`mapProduct` y `product-catalog.tsx`; confirmar que no hay más.
- [ ] 1.5 Reservar el número de migración mirando `MAX(version)` vivo en prod **y** el último archivo del repo (precedente: `cuenta-corriente-party-guard` tuvo que renumerar tres veces por PRs en vuelo).

## 2. Migración — tabla `product_categories`

- [ ] 2.1 RED: escribir el gate SQL `test_product_categories_catalog.sql` que exija tabla, columnas, unique case-insensitive parcial, índice por `account_id`, RLS habilitada y las tres policies (`member_select`, `writer_insert`, `writer_update`). Debe fallar antes de existir la tabla.
- [ ] 2.2 GREEN: crear `product_categories` copiando la forma de `payment_methods` **sin** la columna `kind`: `id`, `account_id` NOT NULL FK `accounts`, `name` NOT NULL, `is_active` DEFAULT TRUE, `sort_order` DEFAULT 0, `created_at`, `deleted_at`, `deleted_by`. Índices: `(account_id)` y `UNIQUE (account_id, lower(name)) WHERE deleted_at IS NULL`.
- [ ] 2.3 GREEN: RLS con las mismas tres policies que `cost_centers`/`payment_methods` — `SELECT` por `account_id IN (SELECT current_account_ids())`, `INSERT`/`UPDATE` por `is_account_writer(account_id)`.
- [ ] 2.4 TRIANGULATE: casos de aislamiento por cuenta, duplicado case-insensitive rechazado, mismo nombre en dos cuentas permitido, y nombre reutilizable tras soft delete.
- [ ] 2.5 Verificar que la migración es **idempotente** (`IF NOT EXISTS` / `DROP POLICY IF EXISTS` + `CREATE`): Supabase auto-aplica y puede reaplicar.

## 3. Migración — `products.category_id` y los triggers de espejo

- [ ] 3.1 RED: gate `test_product_category_mirror.sql` — el espejo `products.category` debe coincidir siempre con el `name` de la categoría referenciada, por los tres caminos (INSERT de producto, UPDATE de `category_id`, UPDATE de `name` de la categoría).
- [ ] 3.2 GREEN: agregar `products.category_id UUID NULL REFERENCES product_categories(id) ON DELETE RESTRICT` + índice `(category_id) WHERE category_id IS NOT NULL`.
- [ ] 3.3 GREEN: trigger `BEFORE INSERT OR UPDATE ON products` que setea `NEW.category` desde `category_id` cuando está informado. Es el **choke point** que hace imposible desincronizar el espejo desde cualquier camino de escritura (D1).
- [ ] 3.4 GREEN: trigger `AFTER UPDATE OF name ON product_categories` que propaga el nombre a `products.category` de las filas que la referencian. Guardar con `IS DISTINCT FROM` para no disparar cuando el nombre no cambió, y filtrar por `category_id` para no barrer la tabla (mitigación del riesgo de `UPDATE` masivo).
- [ ] 3.5 TRIANGULATE: renombrar una categoría con productos → todos actualizados; renombrar sin cambio efectivo → cero filas tocadas; producto sin `category_id` → `category` intacta; categoría de otra cuenta → rechazada.
- [ ] 3.6 Verificar que el trigger de espejo **no** rompe el guard de soft delete `fn_guard_product_soft_delete` ya vivo sobre `products`.

## 4. Migración — alcance de unicidad del SKU (`user_id` → `account_id`)

- [ ] 4.1 RED: gate `test_product_sku_uniqueness_scope.sql` — debe existir el índice único por `(account_id, lower(sku))` parcial sobre filas vivas y **no** debe sobrevivir ningún índice único de `sku` alcanzado por `user_id`.
- [ ] 4.2 GREEN: verificación defensiva en la migración — si existe alguna colisión con el criterio nuevo, abortar ruidosamente con mensaje explicativo en vez de crear el índice a medias.
- [ ] 4.3 GREEN: crear `UNIQUE (account_id, lower(sku)) WHERE sku IS NOT NULL AND sku <> '' AND deleted_at IS NULL` y dropear `idx_products_sku_user`.
- [ ] 4.4 TRIANGULATE: mismo SKU en dos cuentas → permitido; mismo SKU distinta caja en la misma cuenta → rechazado; SKU de un producto soft-deleteado → recreable (invariante RN-B3 de `soft-delete-policy`); dos miembros de la misma cuenta → rechazado.
- [ ] 4.5 Decidir y documentar en el archivo si `idx_products_barcode_unique` (mismo residuo `user_id`) se toca o no. **Recomendación: NO** — el código de barras no es superficie de este change y ampliar el alcance ahí es gratis de postergar. Anotarlo como candidato.

## 5. Migración — `rpc_bulk_upsert_products`

- [ ] 5.1 SAFETY NET: correr los tests/gates existentes que ejercitan la importación y anotar el baseline. Si alguno ya falla, reportarlo como pre-existente.
- [ ] 5.2 RED: tests que cubran las **tres** estrategias de vinculación de padre (`parent_id` explícito, `sku_parent`, `parent_name`) más el acarreo a `branch_stock` y `product_attributes`, ANTES de tocar el cuerpo. Son el contrato que no debe moverse.
- [ ] 5.3 RED: tests de lo nuevo — categoría desconocida se crea e imputa; categoría existente se reutiliza case-insensitive sin duplicar; fila sin categoría va a la default; fila con error fatal no crea su categoría; superar el tope rechaza la importación sin crear nada.
- [ ] 5.4 GREEN: reescribir la RPC partiendo del cuerpo vivo de 1.1. Dos ejes y sólo dos: (a) `user_id` → `account_id` en las tres resoluciones (SKU existente, `sku_parent`, `parent_name`); (b) resolución/creación de categoría + seteo de `category_id`. Ni una línea del resto.
- [ ] 5.5 GREEN: la firma `(p_rows jsonb, p_user_id uuid)` **no cambia** → `CREATE OR REPLACE` alcanza y no hay riesgo de overload `42725`. Re-declarar las ACLs exactas de 1.3 en el mismo archivo (el gate de ACLs del proyecto las verifica).
- [ ] 5.6 GREEN: implementar el tope de categorías nuevas por importación (OQ-1, propuesta 50) como constante única, con error explicativo que sugiera revisar el mapeo de la columna.
- [ ] 5.7 TRIANGULATE: re-correr la matriz de 5.2 completa — la jerarquía y el stock deben quedar idénticos al baseline.
- [ ] 5.8 REFACTOR: normalización del nombre de categoría (`trim` + colapso de espacios internos) en **un** helper, usado por el mismo camino que usa el resto del sistema.

## 6. Migración — seed de provisioning y backfill

- [ ] 6.1 RED: gate `test_product_categories_seed.sql` — toda cuenta tiene las 7 categorías; el sub-bloque de seed no aborta el signup ante fallo; re-ejecución no duplica.
- [ ] 6.2 GREEN: sub-bloque nuevo en `handle_new_user` con el molde **exacto** del bloque §6 de `payment_methods`: `INSERT … SELECT FROM (VALUES …) WHERE NOT EXISTS (…)`, envuelto en `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING`. Semilla: las 7 legacy con `sort_order` 1..7, "Otros" al final.
- [ ] 6.3 GREEN: backfill idempotente paso 1 — sembrar las 7 categorías en cada cuenta existente que no las tenga.
- [ ] 6.4 GREEN: backfill idempotente paso 2 — `UPDATE products SET category_id = …` resolviendo por `lower(trim(category))` contra el catálogo de **su propia** cuenta. Escribirlo tolerante: un producto que no resolviera queda con `category_id NULL` y su `category` intacta, **nunca** con la categoría de otra cuenta.
- [ ] 6.5 TRIANGULATE: reaplicar el backfill completo → cero categorías duplicadas y cero productos re-escritos.
- [ ] 6.6 Verificar el criterio de aceptación duro: tras el backfill, `COUNT(*) FROM products WHERE category_id IS NULL` = **0**.

## 7. Gates SQL en CI

- [ ] 7.1 Cablear los gates nuevos (2.1, 3.1, 4.1, 6.1) a `KPI_Validation.yml`. **Verificar que efectivamente corren** — hay precedente de un gate escrito y nunca cableado (`test_cobranzas_reverso.sql`).
- [ ] 7.2 Ejecutar la migración contra `supabase db reset` local y comprobar que ningún gate preexistente se rompe. Atención especial a los gates que limpian con `DELETE FROM` en cascada sobre tablas de catálogo.

## 8. Backend — catálogo de categorías (FastAPI, 3 capas)

- [ ] 8.1 RED: tests de `ProductCategoryRepository` — listar por cuenta con/sin inactivas, crear, renombrar, reordenar, desactivar; aislamiento por cuenta.
- [ ] 8.2 GREEN: `repositories/product_category_repository.py`, espejo de `payment_method_repository.py`.
- [ ] 8.3 RED: tests de service — `require_role` en escritura, 403 para `member`, RFC 7807.
- [ ] 8.4 GREEN: `services/product_categories.py` + `schemas/product_categories.py` (Pydantic v2, nada de payloads sin schema).
- [ ] 8.5 GREEN: `routers/product_categories.py` con `GET ""` (`include_inactive`), `POST ""`, `PATCH /{id}`, `PATCH /{id}/deactivate`. Registrar el router en la app.
- [ ] 8.6 TRIANGULATE: categoría de otra cuenta → 404/403 sin revelar existencia; nombre duplicado → 409 legible; `member` lee pero no escribe.

## 9. Backend — producto: `category_id`, SKU y tri-estado

- [ ] 9.1 SAFETY NET: baseline de los tests vivos de `products` (repository, service, router).
- [ ] 9.2 RED: tests del contrato tri-estado (D12) — campo ausente conserva, con valor asigna, en nulo desasigna; para `sku` y `category_id`. Hoy imposible: `services/products.py` hace `model_dump(exclude_none=True)` y el repository vuelve a filtrar por `is not None` (**doble filtro**, hallazgo del propose).
- [ ] 9.3 GREEN: `ProductCreate`/`ProductUpdate` incorporan `category_id`; el router distingue los tres estados con `model_fields_set` (precedente exacto: `bank_account_id` en `PaymentMethodUpdate`), NUNCA por `is None`.
- [ ] 9.4 GREEN: retirar el doble filtro por `None` del camino de update **sólo** para `sku` y `category_id`; el resto de los campos conserva su comportamiento actual (no ampliar el alcance).
- [ ] 9.5 GREEN: normalizar el SKU (`trim`, vacío → `NULL`) en el service y validar `category_id` contra la cuenta.
- [ ] 9.6 GREEN: traducir la violación del índice único de SKU a **409** con mensaje legible que nombre el SKU en conflicto. La restricción de la base es la fuente de verdad; la comprobación previa sólo mejora el mensaje.
- [ ] 9.7 GREEN: la variante hereda `category_id` del padre **resuelto en el servidor**, ignorando lo que mande el cliente.
- [ ] 9.8 TRIANGULATE: alta sin SKU; alta con SKU; SKU sólo espacios → `NULL`; SKU duplicado → 409; borrar SKU; categoría de otra cuenta → rechazada; variante que contradice al padre → gana el padre.
- [ ] 9.9 Verificar coverage ≥87% (umbral de CI) en los módulos tocados.

## 10. Frontend — hook, selector y gestor del catálogo

- [ ] 10.1 RED: tests de `use-product-categories` (React Query) — listado, `includeInactive`, mutaciones e invalidación de la query tras crear/renombrar/desactivar.
- [ ] 10.2 GREEN: `hooks/data/use-product-categories.ts`, espejo de `use-payment-methods.ts`. Tipos explícitos en `lib/types.ts`; **prohibido `any`**.
- [ ] 10.3 RED: tests de `ProductCategorySelect` — ofrece sólo activas ordenadas por `sort_order`; alta inline crea, selecciona y conserva el formulario; cuenta sin categorías activas advierte y ofrece crear, sin bloquear.
- [ ] 10.4 GREEN: `components/product-categories/ProductCategorySelect.tsx`. El alta inline intercambia el `<Select>` por un `<Input>` **en el lugar** (D9) — NO abre un diálogo anidado sobre el diálogo del formulario, que es el bug raíz que `qa-integral-modulos` (G1) tuvo que arreglar.
- [ ] 10.5 RED: tests de `ProductCategoryManager` — lectura para todo miembro, acciones sólo para `isWriter`, desactivar, renombrar, reordenar.
- [ ] 10.6 GREEN: `components/product-categories/ProductCategoryManager.tsx`, molde de `PaymentMethodManager` (incluidos los objetivos táctiles de 44px en móvil). Autónomo respecto de la página que lo monta, para que montarlo en `/configuracion` sea una línea si el PO decide lo contrario en OQ-2.
- [ ] 10.7 GREEN: montar el gestor en `/productos` mediante acción propia en la cabecera que abre un `Dialog` (D8 — ruta y entrada de menú ya existentes; no se agrega una 10ª pestaña a `/configuracion`).

## 11. Frontend — formulario de producto

- [ ] 11.1 SAFETY NET: baseline de los tests de `product-form.tsx`.
- [ ] 11.2 RED: tests — el selector consume el catálogo (ya no `PRODUCT_CATEGORIES`); la variante no pide categoría y hereda la del padre; el campo SKU es opcional y se envía; el conflicto 409 se muestra sin perder lo cargado.
- [ ] 11.3 GREEN: reemplazar el `<Select>` de categoría (L196-205) por `ProductCategorySelect`, conservando **intacta** la regla vigente de L87-97 (categoría obligatoria salvo variante).
- [ ] 11.4 GREEN: agregar el campo SKU opcional, con la misma marcación y tokens que el campo de código de barras contiguo.
- [ ] 11.5 TRIANGULATE: alta base con categoría; alta de variante sin categoría; edición que no toca el SKU lo conserva; edición que lo vacía lo borra.

## 12. Frontend — alta inline de producto desde compras

- [ ] 12.1 SAFETY NET: baseline de los tests de `purchase-form.tsx`.
- [ ] 12.2 RED: test — el alta inline de producto ofrece el mismo catálogo por el mismo componente selector.
- [ ] 12.3 GREEN: reemplazar el `<Select>` de L950 por `ProductCategorySelect`. Verificar que el alta inline sigue funcionando dentro del contexto de diálogo del formulario de compra.
- [ ] 12.4 Retirar `PRODUCT_CATEGORIES` de `frontend/lib/constants.ts` una vez que sus **dos** consumidores migraron, y confirmar por búsqueda que no queda ninguna referencia.

## 13. Frontend — listado de productos

- [ ] 13.1 SAFETY NET: baseline de los tests de `product-catalog.tsx`.
- [ ] 13.2 RED: tests — buscar por SKU encuentra el producto; la búsqueda es case-insensitive; un producto sin SKU no muestra un código de relleno.
- [ ] 13.3 GREEN: sumar el SKU a los predicados de búsqueda (que hoy cubren nombre y categoría) y mostrarlo cuando existe. No agregar una columna nueva a la tabla si desbalancea el layout responsive — `responsive-shell` es una capability viva y el residuo `tablet-filtros-cta` sigue abierto.
- [ ] 13.4 TRIANGULATE: búsqueda que matchea sólo por SKU en una variante hija; búsqueda sin resultados; producto sin SKU.

## 14. Frontend — pipeline del importador

- [ ] 14.1 SAFETY NET: baseline de los tests de `lib/import/*`.
- [ ] 14.2 RED: tests de `validator.ts` — una categoría desconocida **ya no** se reescribe a "Otros" con warning; se marca como "a crear"; una categoría existente se resuelve case-insensitive; una fila con error fatal no aporta categoría a crear.
- [ ] 14.3 GREEN: retirar `VALID_CATEGORIES` de `lib/import/types.ts` y reescribir el bloque de categoría de `validator.ts:127-131`. El validador pasa a recibir el catálogo vivo de la cuenta en vez de un `Set` horneado.
- [ ] 14.4 RED: test — dos filas del mismo archivo con el mismo SKU producen una advertencia (hoy la segunda pisa a la primera en silencio).
- [ ] 14.5 GREEN: implementar esa advertencia en la validación.
- [ ] 14.6 GREEN: exponer desde el validador el resumen de categorías a crear (nombre + cuántas filas la usan) que consume el paso 2.
- [ ] 14.7 TRIANGULATE: archivo sin columna Categoría; archivo con categorías mezcladas nuevas y existentes; archivo que supera el tope; archivo con "ropa"/"Ropa "/"ROPA".

## 15. Frontend — diálogo de importación

- [ ] 15.1 RED: tests de `product-import-dialog.tsx` — el paso 2 lista las categorías a crear antes de confirmar; superar el tope muestra el error explicativo; el template se genera con las categorías de la cuenta.
- [ ] 15.2 GREEN: `TEMPLATE_CSV` deja de ser constante de módulo y pasa a generarse desde el catálogo de la cuenta, con las 7 legacy como respaldo si estuviera vacío (D10). Corregir de paso el espacio a la izquierda del SKU en la fila `Padre` (`;;;;;;; ZAP-NIKE`).
- [ ] 15.3 GREEN: actualizar el panel "Columnas del CSV" — `Categoría`: opcional, se crea si no existe; `SKU`: opcional, y si coincide con uno existente **actualiza** ese producto (hoy dice sólo "opcional", que es lo que hace creer que un SKU repetido duplica).
- [ ] 15.4 GREEN: bloque de anuncio en el paso 2 con las categorías a crear y su conteo de filas, con tokens semánticos y contraste AA.
- [ ] 15.5 TRIANGULATE: import sin categorías nuevas → sin bloque de anuncio; con categorías nuevas → listadas; superando el tope → bloqueado con explicación.

## 16. Verificación integral

- [ ] 16.1 Backend completo en verde y coverage ≥87%; anotar el delta contra el baseline de 9.1.
- [ ] 16.2 Frontend completo en verde; anotar el delta contra los baselines de 11.1/12.1/13.1/14.1. Aislar cualquier flaky conocido antes de atribuirle el fallo a este change (`AdminSegurosPage.test.tsx` es flaky-preexistente bajo carga).
- [ ] 16.3 `tsc` sin errores nuevos. **Cero `any`** en el código agregado.
- [ ] 16.4 Migración limpia contra `supabase db reset` local y los gates de `KPI_Validation.yml` en el orden real del workflow.
- [ ] 16.5 Pasada visual en las **4 combinaciones** (escritorio/móvil × claro/oscuro) sobre gestor, selector con alta inline, formulario de producto con SKU y paso 2 del importador. Verificar que ningún desplegable se sale del shard de scroll de su diálogo (regresión G1) y que no hay desborde horizontal (`responsive-shell`).
- [ ] 16.6 Prueba manual de punta a punta: crear categoría propia → dar de alta un producto con ella y con SKU → importar un CSV con una categoría nueva y un SKU existente → verificar que la categoría se creó, el producto se actualizó y ninguno perdió su categoría.

## 17. Verificación post-merge en producción

- [ ] 17.1 `MAX(version)` = la migración de este change, y el conteo total de migraciones esperado.
- [ ] 17.2 `product_categories` por cuenta = 7 en todas las cuentas existentes.
- [ ] 17.3 `COUNT(*) FROM products WHERE category_id IS NULL` = **0**, y cero productos cuya `category` (TEXT) difiera del `name` de su categoría.
- [ ] 17.4 Índices vivos de `products` sobre `sku`: sólo el alcanzado por `account_id`; el de `user_id` ausente.
- [ ] 17.5 ACLs vivas de `rpc_bulk_upsert_products` idénticas a las de 1.3, sin `EXECUTE` para `anon`.
- [ ] 17.6 Humo real del PO: crear una categoría propia, dar de alta un producto con SKU, y descargar el template para confirmar que trae sus categorías.

## 18. Cierre documental

- [ ] 18.1 Registrar en `CHANGES.md` la entrada del change con las decisiones, las mediciones de prod y los candidatos que deja.
- [ ] 18.2 Actualizar el puntero "próximo change" del `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` en el **mismo PR** (gate `Docs Sync`). Nunca editar `AGENTS.md` a mano.
- [ ] 18.3 Anotar los candidatos que este change deja abiertos: retiro de `products.category` TEXT (OQ-3), `idx_products_barcode_unique` con el mismo residuo `user_id` (4.5), reclasificación masiva de los 2.951 productos en "Otros" (OQ-5), y la migración del importador a FastAPI (D7).
- [ ] 18.4 Confirmar que `estadisticas-ventas` (propose en paralelo) puede apoyarse en `products.category_id` como identidad estable de agrupación.
