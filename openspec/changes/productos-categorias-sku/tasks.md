# Tasks — productos-categorias-sku

> **Governance: MEDIA.** No se escribe dinero, pero se reescribe una RPC `SECURITY DEFINER` que escribe `products`/`branch_stock`, se cambia un índice único sobre una tabla caliente y se toca el trigger de provisioning de cuentas. Implementar en pasos, exponiendo las decisiones no obvias.
>
> **Strict TDD obligatorio.** Cada grupo que toque código sigue el ciclo SAFETY NET → RED → GREEN → TRIANGULATE → REFACTOR. Antes de modificar un archivo existente, correr sus tests y anotar el baseline (`N/N passing`); un fallo previo se reporta como *pre-existente* y NO se arregla en este change.
>
> **Reutilización antes que repetición.** El molde a copiar es `payment_methods` (tabla, seed, RLS, backend 3 capas, `PaymentMethodManager`, `PaymentMethodSelect`). No inventar patrones nuevos donde ya hay precedente.

## 1. Checkpoints previos — medir lo vivo antes de escribir SQL

- [x] 1.1 Volcar `pg_get_functiondef` **vivo en prod** de `rpc_bulk_upsert_products` y de `handle_new_user` a un archivo de trabajo; hashearlos. Toda reescritura parte de ese cuerpo, NUNCA del último archivo de migración (precedente: la divergencia del G3 de `rpc_create_purchase_operation` por una reescritura in-place).
- [x] 1.2 Confirmar contra prod las mediciones del design: 5.084 productos / 0 sin categoría / 0 fuera de la lista fija / 6 con SKU / 0 cuentas multiusuario con productos / 0 colisiones de `lower(trim(sku))` por cuenta. Si alguna cambió, revisar la decisión que se apoya en ella antes de seguir.
- [x] 1.3 Listar los índices únicos vivos de `products` sobre `sku` y sobre `barcode`, y las ACLs vivas de `rpc_bulk_upsert_products`, para reproducirlas exactas tras el `CREATE OR REPLACE`.
- [x] 1.4 Enumerar por búsqueda (no de memoria) TODOS los callers de `rpc_bulk_upsert_products` y todos los lectores de `products.category` (código, vistas, gates SQL, tests). El design nombra `v_products_with_stock`, `rpc_product_profitability`, `ProductOut`/`mapProduct` y `product-catalog.tsx`; confirmar que no hay más.
- [x] 1.5 Reservar el número de migración mirando `MAX(version)` vivo en prod **y** el último archivo del repo (precedente: `cuenta-corriente-party-guard` tuvo que renumerar tres veces por PRs en vuelo).

## 2. Migración — tabla `product_categories`

- [x] 2.1 RED: escribir el gate SQL `test_product_categories_catalog.sql` que exija tabla, columnas, unique case-insensitive parcial, índice por `account_id`, RLS habilitada y las tres policies (`member_select`, `writer_insert`, `writer_update`). Debe fallar antes de existir la tabla.
- [x] 2.2 GREEN: crear `product_categories` copiando la forma de `payment_methods` **sin** la columna `kind`: `id`, `account_id` NOT NULL FK `accounts`, `name` NOT NULL, `is_active` DEFAULT TRUE, `sort_order` DEFAULT 0, `created_at`, `deleted_at`, `deleted_by`. Índices: `(account_id)` y `UNIQUE (account_id, lower(name)) WHERE deleted_at IS NULL`.
- [x] 2.3 GREEN: RLS con las mismas tres policies que `cost_centers`/`payment_methods` — `SELECT` por `account_id IN (SELECT current_account_ids())`, `INSERT`/`UPDATE` por `is_account_writer(account_id)`.
- [x] 2.4 TRIANGULATE: casos de aislamiento por cuenta, duplicado case-insensitive rechazado, mismo nombre en dos cuentas permitido, y nombre reutilizable tras soft delete.
- [x] 2.5 Verificar que la migración es **idempotente** (`IF NOT EXISTS` / `DROP POLICY IF EXISTS` + `CREATE`): Supabase auto-aplica y puede reaplicar.

## 3. Migración — `products.category_id` y los triggers de espejo

- [x] 3.1 RED: gate `test_product_category_mirror.sql` — el espejo `products.category` debe coincidir siempre con el `name` de la categoría referenciada, por los tres caminos (INSERT de producto, UPDATE de `category_id`, UPDATE de `name` de la categoría).
- [x] 3.2 GREEN: agregar `products.category_id UUID NULL REFERENCES product_categories(id) ON DELETE RESTRICT` + índice `(category_id) WHERE category_id IS NOT NULL`.
- [x] 3.3 GREEN: trigger `BEFORE INSERT OR UPDATE ON products` que setea `NEW.category` desde `category_id` cuando está informado. Es el **choke point** que hace imposible desincronizar el espejo desde cualquier camino de escritura (D1).
- [x] 3.4 GREEN: trigger `AFTER UPDATE OF name ON product_categories` que propaga el nombre a `products.category` de las filas que la referencian. Guardar con `IS DISTINCT FROM` para no disparar cuando el nombre no cambió, y filtrar por `category_id` para no barrer la tabla (mitigación del riesgo de `UPDATE` masivo).
- [x] 3.5 TRIANGULATE: renombrar una categoría con productos → todos actualizados; renombrar sin cambio efectivo → cero filas tocadas; producto sin `category_id` → `category` intacta; categoría de otra cuenta → rechazada.
- [x] 3.6 Verificar que el trigger de espejo **no** rompe el guard de soft delete `fn_guard_product_soft_delete` ya vivo sobre `products`.

## 4. Migración — alcance de unicidad del SKU (`user_id` → `account_id`)

- [x] 4.1 RED: gate `test_product_sku_uniqueness_scope.sql` — debe existir el índice único por `(account_id, lower(sku))` parcial sobre filas vivas y **no** debe sobrevivir ningún índice único de `sku` alcanzado por `user_id`.
- [x] 4.2 GREEN: verificación defensiva en la migración — si existe alguna colisión con el criterio nuevo, abortar ruidosamente con mensaje explicativo en vez de crear el índice a medias.
- [x] 4.3 GREEN: crear `UNIQUE (account_id, lower(sku)) WHERE sku IS NOT NULL AND sku <> '' AND deleted_at IS NULL` y dropear `idx_products_sku_user`.
- [x] 4.4 TRIANGULATE: mismo SKU en dos cuentas → permitido; mismo SKU distinta caja en la misma cuenta → rechazado; SKU de un producto soft-deleteado → recreable (invariante RN-B3 de `soft-delete-policy`); dos miembros de la misma cuenta → rechazado.
- [x] 4.5 Decidir y documentar en el archivo si `idx_products_barcode_unique` (mismo residuo `user_id`) se toca o no. **Recomendación: NO** — el código de barras no es superficie de este change y ampliar el alcance ahí es gratis de postergar. Anotarlo como candidato.

## 5. Migración — `rpc_bulk_upsert_products`

- [x] 5.1 SAFETY NET: correr los tests/gates existentes que ejercitan la importación y anotar el baseline. Si alguno ya falla, reportarlo como pre-existente.
- [x] 5.2 RED: tests que cubran las **tres** estrategias de vinculación de padre (`parent_id` explícito, `sku_parent`, `parent_name`) más el acarreo a `branch_stock` y `product_attributes`, ANTES de tocar el cuerpo. Son el contrato que no debe moverse.
- [x] 5.3 RED: tests de lo nuevo — categoría desconocida se crea e imputa; categoría existente se reutiliza case-insensitive sin duplicar; fila sin categoría va a la default; fila con error fatal no crea su categoría; superar el tope rechaza la importación sin crear nada.
- [x] 5.4 GREEN: reescribir la RPC partiendo del cuerpo vivo de 1.1. Dos ejes y sólo dos: (a) `user_id` → `account_id` en las tres resoluciones (SKU existente, `sku_parent`, `parent_name`); (b) resolución/creación de categoría + seteo de `category_id`. Ni una línea del resto.
- [x] 5.5 GREEN: la firma `(p_rows jsonb, p_user_id uuid)` **no cambia** → `CREATE OR REPLACE` alcanza y no hay riesgo de overload `42725`. Re-declarar las ACLs exactas de 1.3 en el mismo archivo (el gate de ACLs del proyecto las verifica).
- [x] 5.6 GREEN: implementar el tope de categorías nuevas por importación (**50**, confirmado por el PO en OQ-1) como constante única, con error explicativo que sugiera revisar el mapeo de la columna.
- [x] 5.7 TRIANGULATE: re-correr la matriz de 5.2 completa — la jerarquía y el stock deben quedar idénticos al baseline.
- [x] 5.8 REFACTOR: normalización del nombre de categoría (`trim` + colapso de espacios internos) en **un** helper, usado por el mismo camino que usa el resto del sistema.

## 6. Migración — seed de provisioning y backfill

- [x] 6.1 RED: gate `test_product_categories_seed.sql` — toda cuenta tiene las 7 categorías; el sub-bloque de seed no aborta el signup ante fallo; re-ejecución no duplica.
- [x] 6.2 GREEN: sub-bloque nuevo en `handle_new_user` con el molde **exacto** del bloque §6 de `payment_methods`: `INSERT … SELECT FROM (VALUES …) WHERE NOT EXISTS (…)`, envuelto en `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING`. Semilla: las 7 legacy con `sort_order` 1..7, "Otros" al final.
- [x] 6.3 GREEN: backfill idempotente paso 1 — sembrar las 7 categorías en cada cuenta existente que no las tenga.
- [x] 6.4 GREEN: backfill idempotente paso 2 — `UPDATE products SET category_id = …` resolviendo por `lower(trim(category))` contra el catálogo de **su propia** cuenta. Escribirlo tolerante: un producto que no resolviera queda con `category_id NULL` y su `category` intacta, **nunca** con la categoría de otra cuenta.
- [x] 6.5 TRIANGULATE: reaplicar el backfill completo → cero categorías duplicadas y cero productos re-escritos.
- [x] 6.6 Verificar el criterio de aceptación duro: tras el backfill, `COUNT(*) FROM products WHERE category_id IS NULL` = **0**.

## 7. Gates SQL en CI

- [x] 7.1 Cablear los gates nuevos (2.1, 3.1, 4.1, 6.1) a `KPI_Validation.yml`. **Verificar que efectivamente corren** — hay precedente de un gate escrito y nunca cableado (`test_cobranzas_reverso.sql`).
- [x] 7.2 Ejecutar la migración contra `supabase db reset` local y comprobar que ningún gate preexistente se rompe. Atención especial a los gates que limpian con `DELETE FROM` en cascada sobre tablas de catálogo.

## 8. Backend — catálogo de categorías (FastAPI, 3 capas)

- [x] 8.1 RED: tests de `ProductCategoryRepository` — listar por cuenta con/sin inactivas, crear, renombrar, reordenar, desactivar; aislamiento por cuenta.
- [x] 8.2 GREEN: `repositories/product_category_repository.py`, espejo de `payment_method_repository.py`.
- [x] 8.3 RED: tests de service — `require_role` en escritura, 403 para `member`, RFC 7807.
- [x] 8.4 GREEN: `services/product_categories.py` + `schemas/product_categories.py` (Pydantic v2, nada de payloads sin schema).
- [x] 8.5 GREEN: `routers/product_categories.py` con `GET ""` (`include_inactive`), `POST ""`, `PATCH /{id}`, `PATCH /{id}/deactivate`. Registrar el router en la app.
- [x] 8.6 TRIANGULATE: categoría de otra cuenta → 404/403 sin revelar existencia; nombre duplicado → 409 legible; `member` lee pero no escribe.

## 9. Backend — producto: `category_id`, SKU y tri-estado

- [x] 9.1 SAFETY NET: baseline de los tests vivos de `products` (repository, service, router).
- [x] 9.2 RED: tests del contrato tri-estado (D12) — campo ausente conserva, con valor asigna, en nulo desasigna; para `sku` y `category_id`. Hoy imposible: `services/products.py` hace `model_dump(exclude_none=True)` y el repository vuelve a filtrar por `is not None` (**doble filtro**, hallazgo del propose).
- [x] 9.3 GREEN: `ProductCreate`/`ProductUpdate` incorporan `category_id`; el router distingue los tres estados con `model_fields_set` (precedente exacto: `bank_account_id` en `PaymentMethodUpdate`), NUNCA por `is None`.
- [x] 9.4 GREEN: retirar el doble filtro por `None` del camino de update **sólo** para `sku` y `category_id`; el resto de los campos conserva su comportamiento actual (no ampliar el alcance).
- [x] 9.5 GREEN: normalizar el SKU (`trim`, vacío → `NULL`) en el service y validar `category_id` contra la cuenta.
- [x] 9.6 GREEN: traducir la violación del índice único de SKU a **409** con mensaje legible que nombre el SKU en conflicto. La restricción de la base es la fuente de verdad; la comprobación previa sólo mejora el mensaje.
- [x] 9.7 GREEN: la variante hereda `category_id` del padre **resuelto en el servidor**, ignorando lo que mande el cliente.
- [x] 9.8 TRIANGULATE: alta sin SKU; alta con SKU; SKU sólo espacios → `NULL`; SKU duplicado → 409; borrar SKU; categoría de otra cuenta → rechazada; variante que contradice al padre → gana el padre.
- [x] 9.9 Verificar coverage ≥87% (umbral de CI) en los módulos tocados.

### Recategorización en lote (D14)

- [x] 9.10 RED: tests del repository de lote — `UPDATE … WHERE id = ANY($1) AND account_id = $2 AND category_id IS DISTINCT FROM $3` actualiza sólo lo propio; ids ajenos quedan fuera sin error; repetir no reescribe filas.
- [x] 9.11 RED: tests de service — categoría destino inexistente / de otra cuenta / borrada / inactiva → **404** RFC 7807 con mensaje que no revela si existe en otra cuenta; ningún producto modificado.
- [x] 9.12 GREEN: implementar el método de lote en `ProductRepository` **como un solo `UPDATE`** (atómico por definición) con el filtro explícito por `account_id` — es el guard de tenencia, no la RLS sola (regla dura del proyecto). Expandir cada padre a sus variantes y normalizar un id de variante suelto a su padre, en la misma sentencia.
- [x] 9.13 GREEN: endpoint `PATCH /products/bulk-category` (schema Pydantic v2, tope de 500 ids por request) que devuelve `solicitados` y `actualizados`.
- [x] 9.14 TRIANGULATE: lote mixto propio/ajeno; padre con variantes propaga a todo el grupo; variante suelta recategoriza el grupo; idempotencia; tope excedido rechazado; el espejo `products.category` queda correcto en todas las filas tocadas (lo garantiza el trigger de 3.3 — verificarlo, no asumirlo).

## 10. Frontend — hook, selector y gestor del catálogo

- [x] 10.1 RED: tests de `use-product-categories` (React Query) — listado, `includeInactive`, mutaciones e invalidación de la query tras crear/renombrar/desactivar.
- [x] 10.2 GREEN: `hooks/data/use-product-categories.ts`, espejo de `use-payment-methods.ts`. Tipos explícitos en `lib/types.ts`; **prohibido `any`**.
- [x] 10.3 RED: tests de `ProductCategorySelect` — ofrece sólo activas ordenadas por `sort_order`; alta inline crea, selecciona y conserva el formulario; cuenta sin categorías activas advierte y ofrece crear, sin bloquear.
- [x] 10.4 GREEN: `components/product-categories/ProductCategorySelect.tsx`. El alta inline intercambia el `<Select>` por un `<Input>` **en el lugar** (D9) — NO abre un diálogo anidado sobre el diálogo del formulario, que es el bug raíz que `qa-integral-modulos` (G1) tuvo que arreglar.
- [x] 10.5 RED: tests de `ProductCategoryManager` — lectura para todo miembro, acciones sólo para `isWriter`, desactivar, renombrar, reordenar.
- [x] 10.6 GREEN: `components/product-categories/ProductCategoryManager.tsx`, molde de `PaymentMethodManager` (incluidos los objetivos táctiles de 44px en móvil).
- [x] 10.7 GREEN: montar el gestor como **décima pestaña "Categorías" de `/configuracion`** (D8, sign-off del PO en OQ-2), junto a Centros de costo y Formas de pago. La `TabsList` pasa de `lg:grid-cols-9` a `lg:grid-cols-10`; los breakpoints menores (`grid-cols-3 sm:grid-cols-5`) no cambian.
- [ ] 10.8 Verificar en móvil y tablet que la décima pestaña no rompe el envoltorio de la `TabsList` — es la deuda que `qa-integral-modulos` arregló y sobre la que sigue abierto `tablet-filtros-cta`. Si se degrada, corregirlo acá y no dejarlo para después.

## 11. Frontend — formulario de producto

- [x] 11.1 SAFETY NET: baseline de los tests de `product-form.tsx`.
- [x] 11.2 RED: tests — el selector consume el catálogo (ya no `PRODUCT_CATEGORIES`); la variante no pide categoría y hereda la del padre; el campo SKU es opcional y se envía; el conflicto 409 se muestra sin perder lo cargado.
- [x] 11.3 GREEN: reemplazar el `<Select>` de categoría (L196-205) por `ProductCategorySelect`, conservando **intacta** la regla vigente de L87-97 (categoría obligatoria salvo variante).
- [x] 11.4 GREEN: agregar el campo SKU opcional, con la misma marcación y tokens que el campo de código de barras contiguo.
- [x] 11.5 TRIANGULATE: alta base con categoría; alta de variante sin categoría; edición que no toca el SKU lo conserva; edición que lo vacía lo borra.

## 12. Frontend — alta inline de producto desde compras

- [x] 12.1 SAFETY NET: baseline de los tests de `purchase-form.tsx`.
- [x] 12.2 RED: test — el alta inline de producto ofrece el mismo catálogo por el mismo componente selector.
- [x] 12.3 GREEN: reemplazar el `<Select>` de L950 por `ProductCategorySelect`. Verificar que el alta inline sigue funcionando dentro del contexto de diálogo del formulario de compra.
- [x] 12.4 Retirar `PRODUCT_CATEGORIES` de `frontend/lib/constants.ts` una vez que sus **dos** consumidores migraron, y confirmar por búsqueda que no queda ninguna referencia.

## 13. Frontend — listado de productos

- [x] 13.1 SAFETY NET: baseline de los tests de `product-catalog.tsx`.
- [x] 13.2 RED: tests — buscar por SKU encuentra el producto; la búsqueda es case-insensitive; un producto sin SKU no muestra un código de relleno.
- [x] 13.3 GREEN: sumar el SKU a los predicados de búsqueda (que hoy cubren nombre y categoría) y mostrarlo cuando existe. No agregar una columna nueva a la tabla si desbalancea el layout responsive — `responsive-shell` es una capability viva y el residuo `tablet-filtros-cta` sigue abierto.
- [x] 13.4 TRIANGULATE: búsqueda que matchea sólo por SKU en una variante hija; búsqueda sin resultados; producto sin SKU.

## 14. Frontend — recategorización en lote en `/productos`

> Alcance sumado por el PO el 2026-09-03 (D14). Es la herramienta que hace accionable el hallazgo de los 2.951 productos en "Otros".

- [x] 14.1 SAFETY NET: baseline de los tests de `product-catalog.tsx` (compartido con el grupo 13 — anotarlo una sola vez si se hacen seguidos).
- [x] 14.2 RED: tests de selección — seleccionar y deseleccionar productos; seleccionar todo lo filtrado; la selección se limpia al cambiar la búsqueda; el contador refleja lo seleccionado.
- [x] 14.3 GREEN: selección múltiple reutilizando el patrón que ya existe en el repo — `useState<Set<string>>` + `Checkbox` + helper `toggle`, tal como `ReconciliationBoard.tsx`; `product-catalog.tsx` ya usa `Set<string>` para `expandedIds`, así que no se introduce un idioma nuevo. `stopPropagation` en la casilla para no duplicar el toggle con el `onClick` de la fila (mismo detalle que resolvió el precedente).
- [x] 14.4 GREEN: las casillas se ofrecen sobre **padres y productos simples**; las variantes no se seleccionan por separado, porque su categoría es derivada (D11/D14). Verificar que funciona en las **dos** presentaciones del listado (tarjetas y tabla).
- [x] 14.5 RED: tests de la barra de acción — aparece sólo con selección activa; declara conteo y categoría destino; pide confirmación; al aplicar limpia la selección e invalida la query de productos.
- [x] 14.6 GREEN: barra de acción con el conteo, `ProductCategorySelect` como selector de destino (**el mismo componente**, nunca una lista paralela) y confirmación explícita antes de aplicar.
- [x] 14.7 GREEN: trocear la selección en requests de hasta 500 ids y agregar los resultados, de forma transparente para el usuario (D14).
- [x] 14.8 GREEN: informar el resultado real — si `actualizados < solicitados`, decirlo en vez de afirmar un éxito total.
- [x] 14.9 TRIANGULATE: recategorizar un grupo padre+variantes; recategorizar productos simples; selección mayor al tope (troceo); aplicar la categoría que los productos ya tienen (0 actualizados, sin error); cancelar la confirmación no cambia nada.
- [x] 14.10 Verificar accesibilidad de la selección: las casillas tienen nombre accesible, la barra de acción es alcanzable por teclado y anuncia el conteo.

## 15. Frontend — pipeline del importador

- [x] 15.1 SAFETY NET: baseline de los tests de `lib/import/*`.
- [x] 15.2 RED: tests de `validator.ts` — una categoría desconocida **ya no** se reescribe a "Otros" con warning; se marca como "a crear"; una categoría existente se resuelve case-insensitive; una fila con error fatal no aporta categoría a crear.
- [x] 15.3 GREEN: retirar `VALID_CATEGORIES` de `lib/import/types.ts` y reescribir el bloque de categoría de `validator.ts:127-131`. El validador pasa a recibir el catálogo vivo de la cuenta en vez de un `Set` horneado.
- [x] 15.4 RED: test — dos filas del mismo archivo con el mismo SKU producen una advertencia (hoy la segunda pisa a la primera en silencio).
- [x] 15.5 GREEN: implementar esa advertencia en la validación.
- [x] 15.6 GREEN: exponer desde el validador el resumen de categorías a crear (nombre + cuántas filas la usan) que consume el paso 2.
- [x] 15.7 TRIANGULATE: archivo sin columna Categoría; archivo con categorías mezcladas nuevas y existentes; archivo que supera el tope; archivo con "ropa"/"Ropa "/"ROPA".

## 16. Frontend — diálogo de importación

- [x] 16.1 RED: tests de `product-import-dialog.tsx` — el paso 2 lista las categorías a crear antes de confirmar; superar el tope muestra el error explicativo; el template se genera con las categorías de la cuenta.
- [x] 16.2 GREEN: `TEMPLATE_CSV` deja de ser constante de módulo y pasa a generarse desde el catálogo de la cuenta, con las 7 legacy como respaldo si estuviera vacío (D10). Corregir de paso el espacio a la izquierda del SKU en la fila `Padre` (`;;;;;;; ZAP-NIKE`).
- [x] 16.3 GREEN: actualizar el panel "Columnas del CSV" — `Categoría`: opcional, se crea si no existe; `SKU`: opcional, y si coincide con uno existente **actualiza** ese producto (hoy dice sólo "opcional", que es lo que hace creer que un SKU repetido duplica).
- [x] 16.4 GREEN: bloque de anuncio en el paso 2 con las categorías a crear y su conteo de filas, con tokens semánticos y contraste AA.
- [x] 16.5 TRIANGULATE: import sin categorías nuevas → sin bloque de anuncio; con categorías nuevas → listadas; superando el tope → bloqueado con explicación.

## 17. Verificación integral

- [x] 17.1 Backend completo en verde y coverage ≥87%; anotar el delta contra el baseline de 9.1.
- [x] 17.2 Frontend completo en verde; anotar el delta contra los baselines de 11.1/12.1/13.1/14.1/15.1. Aislar cualquier flaky conocido antes de atribuirle el fallo a este change (`AdminSegurosPage.test.tsx` es flaky-preexistente bajo carga).
- [x] 17.3 `tsc` sin errores nuevos. **Cero `any`** en el código agregado.
- [x] 17.4 Migración limpia contra `supabase db reset` local y los gates de `KPI_Validation.yml` en el orden real del workflow.
- [ ] 17.5 Pasada visual en las **4 combinaciones** (escritorio/móvil × claro/oscuro) sobre: pestaña Categorías de `/configuracion`, **la `TabsList` completa de `/configuracion` con sus 10 pestañas** (riesgo declarado en D8, aunque no sea pantalla nueva), selector con alta rápida inline, formulario de producto con SKU, selección múltiple y barra de acción en lote, y paso 2 del importador. Verificar que ningún desplegable se sale del shard de scroll de su diálogo (regresión G1) y que no hay desborde horizontal (`responsive-shell`).
- [ ] 17.6 Prueba manual de punta a punta: crear categoría propia → dar de alta un producto con ella y con SKU → **seleccionar varios productos de "Otros" y recategorizarlos en lote** → importar un CSV con una categoría nueva y un SKU existente → verificar que la categoría se creó, los productos se movieron, el producto se actualizó y ninguno perdió su categoría.

## 18. Verificación post-merge en producción

- [ ] 18.1 `MAX(version)` = la migración de este change, y el conteo total de migraciones esperado.
- [ ] 18.2 `product_categories` por cuenta = 7 en todas las cuentas existentes.
- [ ] 18.3 `COUNT(*) FROM products WHERE category_id IS NULL` = **0**, y cero productos cuya `category` (TEXT) difiera del `name` de su categoría.
- [ ] 18.4 Índices vivos de `products` sobre `sku`: sólo el alcanzado por `account_id`; el de `user_id` ausente.
- [ ] 18.5 ACLs vivas de `rpc_bulk_upsert_products` idénticas a las de 1.3, sin `EXECUTE` para `anon`.
- [ ] 18.6 Humo real del PO: crear una categoría propia desde `/configuracion`, dar de alta un producto con SKU, **recategorizar en lote un puñado de productos de "Otros"**, y descargar el template para confirmar que trae sus categorías.
- [ ] 18.7 Medir de nuevo el reparto por categoría en prod y anotarlo junto al baseline del 2026-09-03 (2.951 en "Otros" sobre 5.084). Es el número que dice si la herramienta se está usando; sin la re-medición no hay forma de saberlo.

## 19. Cierre documental

- [x] 19.1 Registrar en `CHANGES.md` la entrada del change con las decisiones, las mediciones de prod y los candidatos que deja.
- [x] 19.2 Actualizar el puntero "próximo change" del `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` en el **mismo PR** (gate `Docs Sync`). Nunca editar `AGENTS.md` a mano.
- [x] 19.3 Anotar los candidatos que este change deja abiertos: retiro de `products.category` TEXT (OQ-3), `idx_products_barcode_unique` con el mismo residuo `user_id` (4.5), y la migración del importador a FastAPI (D7). **OQ-5 ya no es candidato**: la herramienta de recategorización entró en alcance (D14); lo que sigue fuera es que el sistema reclasifique por su cuenta, que es decisión de negocio de cada tenant.
- [x] 19.4 Registrar en `CHANGES.md` las cinco OQs con su resolución por sign-off del PO del 2026-09-03, incluida **OQ-2 resuelta en contra de la recomendación del design** (el gestor va a `/configuracion`, no a `/productos`) — para que la próxima sesión no reabra la discusión.
- [x] 19.5 Confirmar que `estadisticas-ventas` (propose en paralelo) puede apoyarse en `products.category_id` como identidad estable de agrupación.
