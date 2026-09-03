## Context

### Estado vigente, verificado (2026-09-03)

**Categoría.** `PRODUCT_CATEGORIES` (`frontend/lib/constants.ts:171`) es una tupla `as const` de 7 literales con exactamente **dos** consumidores: `product-form.tsx:202` y `purchase-form.tsx:955` (el alta inline de producto desde el formulario de compra). En DB, `products.category` es `TEXT NULL` — no hay tabla de categorías ni FK. El importador tiene su propia copia del vocabulario (`VALID_CATEGORIES`, `lib/import/types.ts:133`) y `validator.ts:129-131` reemplaza por `"Otros"` toda categoría que no esté en el `Set`, con un warning.

Medición en producción:

| Categoría | Productos | Cuentas |
|---|---:|---:|
| Otros | 2.951 | 9 |
| Ropa | 1.803 | 7 |
| Alimentos | 236 | 6 |
| Accesorios | 58 | 6 |
| Salud | 25 | 2 |
| Hogar | 8 | 2 |
| Electrónica | 3 | 1 |

**5.084 productos totales** (4.961 vivos), **0 sin categoría**, **0 con una categoría fuera de la lista fija**, 2.127 variantes, 16 cuentas con productos sobre 38 cuentas. El backfill tiene, por lo tanto, correspondencia total y sin residuo: no existe el caso "producto cuya categoría no mapea".

Que no haya ningún valor fuera de la lista **no es evidencia de que la lista alcance** — es la consecuencia mecánica de que el `<Select>` no deja escribir y de que el importador reescribe lo que no reconoce. La señal real es el 58% en "Otros".

**SKU.** La columna `products.sku TEXT NULL` existe, con índice `idx_products_sku` y **`idx_products_sku_user` = `UNIQUE (user_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL`**. Está cableada de punta a punta salvo el último tramo: `ProductCreate.sku`/`ProductUpdate.sku` la aceptan, `ProductRepository.create` la persiste, `search_by_sku` la consulta, `mapProduct` la devuelve como `Product.sku` — y **ningún formulario la escribe** (0 hits de `sku` en `components/forms/`). Sólo **6 de 5.084 productos** tienen SKU, todos por importación. `document-snapshots` ya especifica congelar `sku_snapshot` desde `products.sku`: ese snapshot viene siendo NULL por falta de dato de origen, no por falta de código.

**Importador.** `parser → validator → resolver → rpc_bulk_upsert_products(p_rows jsonb, p_user_id uuid)`. El RPC es `SECURITY DEFINER`, resuelve la cuenta por `current_account_ids()`, pero resuelve **el SKU existente, el `sku_parent` y el `parent_name` por `user_id`** — mismo residuo de tenencia que el índice único. En el `INSERT` hace `COALESCE(NULLIF(v_row->>'category',''), 'Otros')`, que es por qué en prod no hay ningún producto con categoría vacía. La jerarquía Padre/Variante/Standalone y el acarreo a `branch_stock` y `product_attributes` son territorio delicado y **no se tocan**.

**Precedentes de catálogo por cuenta.** `cost_centers` (más simple, escrito por supabase-js) y `payment_methods` (más reciente y más completo: `sort_order`, `is_active`, soft delete `deleted_at`/`deleted_by`, unique case-insensitive `(account_id, lower(name)) WHERE deleted_at IS NULL`, RLS `member_select` + `writer_insert`/`writer_update` sobre `current_account_ids()`/`is_account_writer()`, seed en `handle_new_user` en sub-bloque con `EXCEPTION WHEN OTHERS → RAISE WARNING`, backend FastAPI en 3 capas, `PaymentMethodManager` montado en `/configuracion`). Este change copia el molde de `payment_methods` casi literalmente; su única simplificación es que no hay `kind` — una categoría de producto no tiene semántica cerrada, es puro rótulo del usuario.

### Restricciones

- **Ningún producto puede perder su categoría** en ningún momento de la migración ni después.
- Este change es el **prerrequisito de `estadisticas-ventas`** (propose en paralelo), que va a agrupar y rankear por categoría. Debe entregar una identidad estable para agrupar, y nada de estadísticas.
- Mantenerlo **chico**: catálogo + SKU + importador. Todo lo demás es Non-Goal explícito.

## Goals / Non-Goals

**Goals:**

1. Cada cuenta define sus propias categorías de producto, eligiendo de una lista (la suya), nunca escribiendo texto libre por producto.
2. Ningún producto existente cambia de categoría ni la pierde: el backfill es una traducción exacta de texto a identidad.
3. Renombrar una categoría se refleja en todas partes sin partir los agrupamientos en dos.
4. SKU opcional, visible y editable en el alta y la edición de producto, buscable en el listado.
5. La carga masiva deja de descartar la categoría del usuario y deja de discrepar con el formulario.
6. El template de ejemplo describe lo que el importador realmente hace.
7. Cero regresiones en la jerarquía Padre/Variante ni en el acarreo de stock del importador.

**Non-Goals:**

- **Estadísticas, ranking o reportes por categoría** — es `estadisticas-ventas`, que se apoya en este change. Acá no se escribe ni una consulta de agregación.
- **Categorías de gastos** (`expenses.category`, texto libre, con su propia lista y sus propios lectores en `ai-insights` y `generate-export`) **ni categorías de clientes**. Familias distintas, cada una con su historia; mezclarlas triplicaría el alcance.
- **Jerarquía de categorías** (subcategorías, árbol). El catálogo es plano, igual que `cost_centers` y `payment_methods`. Si alguna vez hace falta, `parent_id` es aditivo.
- **Rediseño del importador** más allá de categoría y SKU: la resolución Padre/Variante, el parser, el chunking y el acarreo a `branch_stock`/`product_attributes` quedan como están.
- **Retiro de `products.category` (TEXT)** — se conserva deliberadamente (D1) y su eventual retiro es un change propio (OQ-3).
- **Backfill de `sku_snapshot`** en líneas históricas de documentos.
- **Reglas por categoría** (márgenes, alícuotas, precios sugeridos) y **imágenes de producto**.

## Decisions

### D1 — `products.category_id` FK como fuente de verdad, y `products.category` (TEXT) conservado como **espejo mantenido por trigger**

La imputación pasa a vivir en `products.category_id UUID NULL REFERENCES product_categories(id)`. La columna `products.category TEXT` **no se elimina y no se congela**: un trigger la mantiene sincronizada con el nombre de la categoría referenciada.

*Por qué una FK y no seguir con texto libre por producto:* `estadisticas-ventas` va a agrupar por categoría. Agrupar por texto significa que renombrar "Ropa" a "Indumentaria" parte el ranking histórico en dos filas que el usuario cree que son una. La identidad estable es justamente lo que el reporte necesita, y es el mismo argumento por el que `payment_methods` obligó a que la lectura fuera `payment_method_id → payment_methods.kind` y no un texto.

*Por qué conservar `category` en vez de migrar del todo:* la columna la leen `v_products_with_stock` (la vista que **todo** el backend consulta: `list_by_org`, `get_by_id`, `search_by_sku`, `search_by_barcode`), `ProductOut.category` → `mapProduct` → los filtros y la presentación de `product-catalog.tsx`, el propio `rpc_bulk_upsert_products` y `rpc_product_profitability`. Dropearla obligaría a reescribir la vista y a tocar cada uno de esos lectores en un change que debe quedarse chico — con el riesgo, además, de que algún lector quede resolviendo `NULL` en silencio. Conservarla como espejo hace que **ningún lector legacy cambie una línea** y que todos vean el nombre correcto. Es el mismo criterio de compatibilidad que RN-97 aplicó al header plano de `sales`/`purchases`.

*Por qué espejo y no snapshot congelado:* un snapshot (congelar el nombre al momento del alta) es lo correcto para una **línea de documento** —`document-snapshots`, donde el valor probatorio exige que el pasado no cambie— y es lo incorrecto para el **maestro**: si el usuario renombra su categoría y la columna espejo se queda con el nombre viejo, la pantalla de productos muestra un nombre y el selector otro. La categoría del maestro es un rótulo vivo, no un hecho histórico.

El espejo se mantiene con dos disparadores:
- `BEFORE INSERT OR UPDATE ON products`: cuando `category_id` está informado, `NEW.category := (SELECT name FROM product_categories WHERE id = NEW.category_id)`.
- `AFTER UPDATE OF name ON product_categories`: propaga el nombre nuevo a `products.category` de las filas que la referencian.

Alternativa descartada: columna generada (`GENERATED ALWAYS AS`). Postgres no admite subconsultas a otras tablas en una columna generada.

### D2 — `category_id` es NULLABLE en la base, y siempre informado por la aplicación

La FK queda nullable. *Por qué:* un `NOT NULL` convierte cualquier camino que no resuelva la categoría en un fallo duro de escritura de producto — y el camino que más importa (`rpc_bulk_upsert_products`) procesa fila por fila dentro de un `BEGIN … EXCEPTION` que degrada a error de fila. Un `NOT NULL` ahí transformaría "no supe resolver la categoría" en "el producto no se importa", que es exactamente el resultado que este change viene a evitar.

La garantía de que ningún producto pierda su categoría no se apoya en el `NOT NULL` sino en tres hechos concurrentes: el backfill cubre el 100% (medido), `category` (TEXT) sigue poblada pase lo que pase, y la baja de una categoría es desactivación o soft delete — **nunca** borrado físico, así que la FK no puede quedar colgando. La FK se declara `ON DELETE RESTRICT` como cinturón sobre el tirante.

### D3 — La baja de una categoría es desactivación / soft delete, y preserva la imputación histórica

Espejo literal de `payment-method` y de la categoría **maestros** de `soft-delete-policy`: `is_active = false` la retira de los selectores de altas nuevas; `deleted_at`/`deleted_by` para el soft delete; los productos ya imputados conservan su `category_id` y su nombre sigue siendo legible. Una categoría inactiva **sigue apareciendo** en los listados y filtros de lo que ya la usa. Nunca hay borrado físico de una categoría referenciada.

Esto agrega `product_categories` a la enumeración normativa de maestros de `soft-delete-policy`, que hoy dice `clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`.

### D4 — El alcance de unicidad del SKU pasa de `user_id` a `account_id`, y `rpc_bulk_upsert_products` se migra en la misma pasada

El índice vivo es `UNIQUE (user_id, sku) WHERE sku IS NOT NULL AND deleted_at IS NULL`, y el RPC de importación resuelve `sku`, `sku_parent` y `parent_name` por `user_id`. Ambos son residuos de tenencia anteriores a C-19 (la propia RPC lleva un comentario sobre "products huérfanos" por haber resuelto la cuenta mal).

*Por qué corregirlo acá y no dejarlo anotado:* hoy el defecto es **inerte** —medición en prod: **0 cuentas con productos tienen más de un usuario** (máximo 1), y **0 colisiones** de SKU dentro de una misma cuenta con criterio case-insensitive— y deja de serlo exactamente cuando este change convierte el SKU en un campo que la gente carga a mano en un producto multiusuario. Exponer un campo cuya unicidad está mal alcanzada es shippear el bug. Es la lección ya registrada del proyecto: *al endurecer un contrato, migrar TODOS los callers* — y acá el caller y la clave estarían discrepando entre sí.

El índice pasa a `UNIQUE (account_id, lower(sku)) WHERE sku IS NOT NULL AND sku <> '' AND deleted_at IS NULL`. Se agrega `lower(...)` porque, con el SKU visible, "REM-001" y "rem-001" son el mismo código para cualquier persona y dos productos distintos para el índice actual; en prod no hay ninguna colisión con el criterio nuevo, así que el endurecimiento no rompe a nadie. El índice viejo se dropea en la misma migración, para que no queden dos reglas de unicidad discrepando.

`rpc_bulk_upsert_products` se reescribe **partiendo de su `pg_get_functiondef` vivo en producción** (regla dura del proyecto tras el hallazgo del G3 de compras, donde el archivo de migración había divergido del cuerpo vivo). La firma `(p_rows jsonb, p_user_id uuid)` **no cambia**, así que basta `CREATE OR REPLACE` y no hay riesgo de overload `42725`; las ACLs se re-declaran igual en el mismo archivo, porque el gate de ACLs del proyecto las verifica.

### D5 — SKU duplicado: **error** en el formulario, **upsert** en el importador

Son dos intenciones distintas y merecen dos respuestas distintas.

- **Formulario**: el usuario está creando o editando *este* producto. Un SKU que ya pertenece a otro producto vivo de la cuenta es un error — `409` con mensaje legible que nombra el producto en conflicto. La violación del índice único es la fuente de verdad; el chequeo previo en el service es sólo para dar un buen mensaje, nunca la garantía.
- **Importador**: el SKU **ya es hoy la clave de upsert** por diseño explícito (`validator.ts`: *"When present it is used as an upsert key"*), y el RPC actualiza la fila existente. Ese comportamiento se conserva intacto — cambiarlo rompería a quien reimporta su catálogo para actualizar precios, que es el caso de uso principal de la carga masiva. Lo que se agrega es una **advertencia en la vista previa** cuando dos filas *del mismo archivo* traen el mismo SKU con nombres distintos: hoy la segunda pisa a la primera en silencio.

### D6 — Una categoría desconocida en el importador **se crea**, anunciada antes de confirmar y con tope por importación

Hoy `validator.ts:129-131` la descarta y asigna `"Otros"`. Eso pasa a ser: se crea la categoría en el catálogo de la cuenta y se imputa el producto a ella.

*Por qué crear y no seguir asignando una default:* el pedido literal del PO es que cada usuario tenga su propia categoría, y la carga masiva es la vía principal de entrada de catálogo. Mantener el descarte dejaría al importador contradiciendo al formulario: lo que el usuario puede elegir a mano se lo borraría el CSV. Y el 58% en "Otros" **es la medición de esa política funcionando como está diseñada** — es el efecto acumulado, no un accidente.

*Por qué no es una barra libre:* la autocreación viene con tres frenos, y son la diferencia entre libertad y basura.
1. **Anuncio previo obligatorio.** El paso 2 (Revisión) lista las categorías que se van a crear, con su nombre y cuántas filas las usan, antes de que el usuario confirme. Nada se crea sin haber sido mostrado.
2. **Tope por importación.** Superado el tope de categorías nuevas distintas en un mismo archivo, la importación se detiene con un error explicativo en vez de crearlas. El modo de fallo que esto ataca es concreto y frecuente: el usuario mapea la columna equivocada (un código, una descripción, un precio) a `Categoría` y genera cientos de categorías basura de las que después no tiene forma cómoda de salir. Valor propuesto: **50** (OQ-1).
3. **Sólo desde filas que ya son válidas**, con el nombre normalizado (`trim`, colapso de espacios internos) y resuelto case-insensitive contra el catálogo vivo — de modo que "ropa", "Ropa " y "Ropa" imputen a la misma categoría existente en vez de crear tres.

La creación ocurre **dentro de `rpc_bulk_upsert_products`**, en la misma transacción por lote que inserta los productos, no en el cliente antes de llamar. Así la tenencia la impone el servidor y no puede quedar una categoría creada cuyo lote de productos falló.

`VALID_CATEGORIES` (el `Set` de 7 literales de `lib/import/types.ts`) se retira: deja de existir un vocabulario de categorías propio del importador. Ese es el mismo principio que `payment-method` fijó como requirement — *"ninguna función de registro conserva una taxonomía propia"*.

### D7 — El catálogo por FastAPI en 3 capas; el importador sigue por RPC

El CRUD del catálogo (`GET/POST/PATCH /product-categories`) va por el backend Python en las 3 capas, espejo exacto de `payment_methods`: `require_role` en el service, RFC 7807 según `api-standards`, `include_inactive` en el listado para la pantalla de gestión, `PATCH .../deactivate` para la baja. Es el precedente más reciente y el CRUD de productos ya vive ahí (`/products`), así que el catálogo y su consumidor comparten transporte.

La **carga masiva no se migra a FastAPI**: sigue llamando a `rpc_bulk_upsert_products` con supabase-js. La resolución y creación de categorías tiene que ocurrir en la misma transacción que inserta los productos, y ese es justamente el punto fuerte de la RPC. Migrar el importador entero al backend es un change propio y no es éste. La consecuencia —dos caminos de escritura de producto, uno por FastAPI y otro por RPC— es preexistente y se declara, no se introduce acá.

### D8 — El gestor de categorías vive en `/productos`, no como 10ª pestaña de `/configuracion`

`/configuracion` ya tiene **9 pestañas** con `grid w-full grid-cols-3 sm:grid-cols-5 lg:grid-cols-9` desde `cobranzas-vencimientos`. Una décima empeora una `TabsList` que `qa-integral-modulos` acaba de tener que arreglar en responsive, y que todavía arrastra el residuo `tablet-filtros-cta`.

Además hay una razón de producto, no sólo de layout: `cost_centers` y `payment_methods` son catálogos **financieros y transversales** —se usan desde ventas, compras, gastos y cobranzas—, por eso viven en Configuración. Las categorías de producto son un catálogo **del catálogo de productos**: se descubren y se necesitan exactamente donde el usuario está mirando sus productos y no encuentra la suya. El gestor se abre desde una acción propia en la cabecera de `/productos` (ruta y entrada de menú ya existentes — no hace falta navegación nueva), en un `Dialog` con el mismo molde visual que `PaymentMethodManager`.

El componente se escribe autónomo (sin depender de la página que lo monta), de modo que montarlo también en Configuración más adelante sea agregar una línea, no reescribirlo.

### D9 — El alta inline no abre un diálogo anidado

`ProductForm` ya se renderiza dentro de un `Dialog` en `/productos`, y el alta inline de producto de `purchase-form` también. Un "Nueva categoría" que abra otro `Dialog` encima produce diálogo anidado, y el desplegable portalizado fuera del shard de scroll del modal es precisamente el bug raíz que `qa-integral-modulos` (G1) tuvo que arreglar para los popovers.

El alta inline se resuelve **en el lugar**: una opción "+ Nueva categoría" al pie de la lista del selector que intercambia el `<Select>` por un `<Input>` con confirmar/cancelar en la misma fila del formulario. Al confirmar, crea por el endpoint, invalida la query del catálogo y **deja la categoría nueva seleccionada**. Sin navegación, sin capa nueva, sin perder lo ya tipeado en el formulario.

### D10 — El template de ejemplo se genera desde el catálogo real de la cuenta

`TEMPLATE_CSV` es hoy una constante de módulo con categorías literales ("Ropa", "Alimentos") que pueden no existir en la cuenta que lo descarga. `ProductImportDialog` es un client component y ya tiene acceso al catálogo, así que el template pasa a ser una función de él: las filas de ejemplo usan las primeras categorías activas de la cuenta, con las legacy como respaldo si el catálogo estuviera vacío.

En la misma pasada, el bloque "Columnas del CSV" del paso 1 pasa a decir la verdad sobre las dos columnas que este change toca: `Categoría` — opcional, se crea si no existe; `SKU` — opcional, y si coincide con uno existente **actualiza** ese producto en vez de crear uno nuevo (hoy el panel dice sólo "opcional", que es lo que hace pensar que un SKU repetido duplica). Se corrige además el espacio a la izquierda del SKU en la fila `Padre` del template vigente (`;;;;;;; ZAP-NIKE`), hoy inofensivo sólo porque el validador hace `trim`.

### D11 — La categoría sigue siendo obligatoria salvo en variantes, y la pantalla degrada en vez de bloquear

Se conserva exactamente la regla vigente (`product-form.tsx:87-97`): categoría obligatoria para un producto base, y **la variante hereda la del padre** (ahora por `category_id`, resuelto en el servidor y no confiando en lo que mande el cliente).

Caso borde nuevo que el catálogo por cuenta habilita: un `owner` puede desactivar todas sus categorías. La pantalla entonces **no bloquea el alta**: muestra el aviso con acceso al gestor y permite crear la categoría desde ahí mismo por el alta inline. Es el criterio ya fijado por `payment-method` para el POS sin formas de pago activas — *degradar, nunca impedir*.

### D12 — `ProductUpdate` pasa a tri-estado por `model_fields_set` para SKU y categoría

Hallazgo de este propose: `services/products.py` llama `payload.model_dump(exclude_none=True)` y `ProductRepository.update` vuelve a filtrar con `{k: v for k, v in data.items() if v is not None}`. **Doble filtro por `None`: hoy es imposible vaciar un campo de producto.** Mientras el SKU no se podía escribir daba igual; con el SKU editable, "me equivoqué de SKU y lo quiero borrar" es una acción que el usuario va a intentar y que la API no puede expresar.

Se adopta el contrato tri-estado ya usado por `payment_methods.bank_account_id` y por `payment_method_id` en la edición de operaciones: **campo ausente** conserva, **campo con valor** asigna, **campo en `null`** desasigna, distinguidos por `model_fields_set` y nunca por `is None`. Se aplica a `sku` y `category_id`; el resto de los campos conserva su comportamiento actual, para no ampliar el alcance.

### D13 — Seed de provisioning y backfill

Sub-bloque nuevo en `handle_new_user`, con el molde exacto del bloque de `payment_methods` (§6 de la función viva): `INSERT … SELECT FROM (VALUES …) WHERE NOT EXISTS (…)` idempotente, envuelto en su propio `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING`, de modo que **un fallo del seed jamás aborte el signup**. Semilla: las 7 categorías legacy con `sort_order` 1..7, "Otros" al final.

Backfill en la misma migración, idempotente y en dos pasos: (1) sembrar las 7 categorías en cada cuenta existente que no las tenga; (2) `UPDATE products SET category_id = …` resolviendo por `lower(trim(category))` contra el catálogo de **su propia** cuenta. La medición garantiza cobertura total (0 vacías, 0 fuera de lista); igualmente el backfill se escribe tolerante: un producto cuya categoría no resolviera queda con `category_id NULL` y su `category` (TEXT) intacta, nunca con la categoría de otra cuenta.

## Risks / Trade-offs

- **[El trigger de renombre dispara un `UPDATE` masivo sobre `products`]** → Renombrar una categoría toca todas las filas del tenant que la referencian (peor caso medido: 2.951 filas en una cuenta). Es una acción administrativa rara, no un hot path, y el `UPDATE` está acotado por `account_id` + `category_id` con índice. Mitigación: el trigger es `AFTER UPDATE OF name`, dispara sólo si el nombre efectivamente cambió (`IS DISTINCT FROM`), y filtra por `category_id` para no barrer la tabla.

- **[La autocreación de categorías genera basura por una columna mal mapeada]** → Es el riesgo central de D6. Mitigación en tres capas: anuncio previo obligatorio en el paso de revisión, tope de categorías nuevas por importación (OQ-1) que convierte el desastre en un error explicativo, y normalización case-insensitive que evita el goteo de duplicados por mayúsculas o espacios. Además, una categoría creada por error se desactiva desde el gestor sin tocar los productos.

- **[Endurecer la unicidad del SKU a case-insensitive rechaza altas que antes pasaban]** → Medición: **0 colisiones** en prod con el criterio nuevo, y sólo 6 productos tienen SKU. El riesgo es sobre datos futuros, y ahí el rechazo es el comportamiento deseado. Mitigación: la migración verifica la ausencia de colisiones antes de crear el índice y falla ruidosamente si aparece alguna, en vez de crear el índice a medias.

- **[Reescribir `rpc_bulk_upsert_products` rompe la jerarquía Padre/Variante o el acarreo de stock]** → Es el tramo más delicado del change: esa RPC resuelve tres estrategias de vinculación de padre y escribe `branch_stock` y `product_attributes`. Mitigación: se parte del `pg_get_functiondef` **vivo** (no del último archivo de migración, que ya divergió una vez en este repo); el cambio se limita a dos ejes —`user_id` → `account_id` en las tres resoluciones, y resolución/creación de categoría— sin tocar una línea del resto; y las tres estrategias de vinculación entran a la matriz de tests antes de escribir el SQL.

- **[Dos columnas de categoría conviviendo se desincronizan]** → `category_id` y `category` pueden divergir si alguien escribe `category` directamente por un camino que no pase por el trigger. Mitigación: el trigger es `BEFORE INSERT OR UPDATE` sobre `products`, o sea un punto de paso obligado para **todos** los caminos de escritura, incluidos la RPC y el backend — la misma estrategia de choke point que `cuenta-corriente-party-guard` usó para el guard de tenencia. Trade-off aceptado: mientras las dos columnas convivan, la deuda existe (OQ-3).

- **[La FK `ON DELETE RESTRICT` bloquea un borrado que alguien intente por SQL directo]** → Es el comportamiento buscado: un producto no puede quedar sin categoría porque alguien borró la fila del catálogo. La baja soportada es la desactivación / soft delete (D3).

- **[El cambio de alcance de tenencia habilita una vinculación que antes no existía]** → Con la resolución por `account_id`, en una cuenta multiusuario una variante podrá vincularse a un padre creado por otro miembro. Es la semántica correcta (el catálogo es de la cuenta, no de la persona) y es la que el resto del sistema ya asume, pero es un cambio de comportamiento real y por eso se declara. Impacto hoy: nulo — no hay ninguna cuenta multiusuario con productos.

## Migration Plan

1. Migración única, idempotente (Supabase auto-aplica y puede reaplicar): tabla + índices + RLS → `products.category_id` + FK + índice → triggers de espejo → seed en `handle_new_user` → backfill de catálogos por cuenta → backfill de `products.category_id` → verificación de colisiones de SKU → swap del índice único → `CREATE OR REPLACE` de `rpc_bulk_upsert_products` con re-declaración de ACLs.
2. Backend y frontend detrás de la migración; el frontend sólo deja de leer `PRODUCT_CATEGORIES` cuando el endpoint del catálogo ya responde.
3. **Rollback**: el orden hace que cada paso sea reversible sin pérdida — `category` (TEXT) nunca deja de ser la columna que todo lector consume, así que revertir el frontend y el backend deja el sistema exactamente en el comportamiento previo aunque la tabla nueva siga en la base. El único paso no trivialmente reversible es el swap del índice de SKU; se revierte recreando el índice anterior, que no puede fallar porque su criterio es más laxo que el nuevo.
4. Verificación post-merge en prod (rutina ya establecida en este repo): `MAX(version)`; conteo de `product_categories` por cuenta (esperado: 7 × cuentas); **`COUNT(*) FROM products WHERE category_id IS NULL` esperado 0**; ningún producto con `category` (TEXT) distinta del nombre de su categoría; ACLs de `rpc_bulk_upsert_products` sin `anon`.

## Open Questions

- **OQ-1 — ¿Cuál es el tope de categorías nuevas por importación?** Propuesta: **50**. Por encima de eso, lo más probable es una columna mal mapeada y no un catálogo legítimo. Cerrable sin bloquear el apply: el valor vive en una constante.
- **OQ-2 — ¿El gestor de categorías va también a `/configuracion`?** Recomendación: **no** (D8), para no llevar la `TabsList` a 10 pestañas. El componente queda autónomo por si el PO prefiere lo contrario, y montarlo ahí sería una línea.
- **OQ-3 — ¿Cuándo se retira `products.category` (TEXT)?** No en este change (D1). Queda como deuda declarada, con el mismo perfil que las columnas legacy de RN-97: su retiro es un change propio que debe migrar `v_products_with_stock` y sus lectores de una sola vez.
- **OQ-4 — ¿Las 7 categorías legacy son el seed correcto, o el PO prefiere otro juego inicial?** Se siembran las 7 vigentes porque son las que los 5.084 productos ya usan y cualquier otra elección obligaría a decidir qué hacer con los que quedan fuera. Es puramente un valor por defecto: cada cuenta las renombra o desactiva.
- **OQ-5 — "Otros" concentra el 58% de los productos.** Este change habilita corregirlo pero **no reclasifica nada**: mover 2.951 productos a categorías reales es una decisión de negocio de cada tenant, no una migración de datos que podamos inferir. ¿Quiere el PO alguna ayuda posterior (reclasificación masiva desde el listado, por ejemplo)? Sería un change propio.
