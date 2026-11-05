# Exploración: productos padre / variantes — unidad en cascada, alta diferenciada, precio en lote y sugerencia de precio

> ## Revisión 2 — decisiones del PO 2026-11-05
> El PO leyó la revisión 1 y cambió el alcance:
> 1. **FUERA la herencia de precio y costo** (opción b entera). El padre `variant_only` no tiene precio ni costo: se quitan del formulario y del contrato, igual que stock inicial, stock mínimo, barcode, PLU y SKU. Nada de `inherits_*`, trigger de propagación ni "Alinear variantes".
> 2. **ENTRA un modificador de precios en lote** en `/productos` (espejo de la recategorización en lote): `rpc_bulk_adjust_prices`.
> 3. **ENTRA la sugerencia de precio = costo × 1,5** al cargar el costo en producto simple y variante.
> 4. **Se mantienen:** unidad editable en el padre con relabel sin convertir (A2) y el alta diferenciada.
> Las secciones 2 a 6 están reescritas; la 1 conserva la medición original y suma la 1.6 con los conteos nuevos.

> **Tipo:** exploración (thinking, sin implementación). No se escribió código, no hay migración, no hay change OPSX.
> **Fecha:** 2026-11-05 · **Prod:** `gxdhpxvdjjkmxhdkkwyb`, sólo `SELECT` vía `mcp__supabase__execute_sql`.
> **Pedido del PO (textual):** «cuando se modifique el producto padre se pueda modificar la unidad de medida a la que se le configuró a un inicio porque tal vez se equivocaron y no se puede cambiar, y a esto se cambie todos los productos hijos la medida también; y que el costo y precio del padre lo hereden automáticamente del padre, aunque se pueda modificar el costo y el precio del producto hijo para que tenga un precio diferente. También está confuso cuando se agrega un producto porque tiene muchas cosas para agregar al producto padre que no tiene sentido que tenga, como stock inicial, stock mínimo, código de barras, código de balanza, SKU. Tenemos que diferenciar cuando alguien quiere agregar un producto padre o un producto individual. Antes de implementar nada hagamos un plan de cómo sería la mejor forma.»
> **Governance esperado:** MEDIO (maestro de producto con escrituras en cascada; no toca caja/banco/cuenta corriente), con un tramo ALTO acotado: el cambio de unidad sobre stock/historia ya grabados reinterpreta cantidades.

---

## 1. Estado actual medido

### 1.1 Modelo de datos (`products`, prod 2026-11-05, filas vivas)

Columnas relevantes: `parent_id`, `is_variant`, `stock_control_type` (`tracked`/`untracked`/`variant_only`), `base_unit_id`, `price numeric NOT NULL DEFAULT 0`, `cost numeric NULL`, `sku`, `barcode`, `scale_plu`, `category_id`, `min_stock numeric NOT NULL DEFAULT 0`.

- `v_products_with_stock` ya resuelve la unidad por herencia: `COALESCE(p.base_unit_id, pp.base_unit_id)` (LEFT JOIN al padre). **Precio y costo NO se heredan en la vista**: salen de `p.price`/`p.cost` tal cual. El `min_stock` de la vista sale de `branch_stock.min_stock`, no de `products.min_stock` (columna casi vestigial).
- Triggers vivos sobre `products`: `trg_product_base_unit_guard` (BEFORE INSERT/DELETE/UPDATE OF base_unit_id, account_id, parent_id; md5 del cuerpo `89b462c5169f867da49610d84b4d4962`), `trg_guard_product_soft_delete`, `trg_product_category_tenancy_guard`.
- El frontend lee precio/costo del producto tal cual: `lib/cart-utils.ts:211` (`catalogPriceOf` → `product.price` / `product.cost ?? 0`), `lib/scale-cart.ts:114,156,170`. La variante aporta su propio precio; el padre sólo se usa para el rótulo (`getCanonicalLabel(product, parent)`).

### 1.2 Conteos de prod

| Medida | Valor |
|---|---|
| Productos vivos | 5.521 |
| Padres `variant_only` | 644 (**258 con hijos**, 386 sin ningún hijo) |
| Padres `tracked` con hijos (el "padre" armado a mano desde el form) | 233 (con 1.075 hijos); 38 con movimientos de stock propios |
| Variantes | 2.507, en 494 padres distintos, en **9 cuentas** |
| Productos simples (raíz sin hijos, no `variant_only`) | 2.370 |
| Variantes con precio distinto del padre | 2.165 (1.953 son hijas de un padre con precio 0) |
| Variantes con precio igual al del padre y padre con precio ≠ 0 | 339 |
| Variantes con costo distinto del padre / costo `NULL` | 1.673 / 472 |
| Variantes con costo igual al del padre (padre con costo) | 370 |
| Padres `variant_only` con precio ≠ 0 / con costo cargado | 17 / 17 de 644: **el padre casi nunca tiene precio; el que cuenta es el de la variante** |
| Padres cuyos hijos tienen precios mezclados | 128 de 494 |
| Variantes con unidad propia (`base_unit_id` ≠ NULL) | 47 (45 peso, 2 unidad); todas distintas de la del padre |
| Padres `variant_only` con unidad cargada | **0** |
| Productos simples con unidad | 58 (57 `u`, 1 `kg`): casi nadie usa unidades todavía |
| Variantes con SKU / barcode / PLU | 144 / 2.077 / 0 |
| Padres `variant_only` con SKU / barcode | 0 / 71 |
| Variantes con movimientos de stock | 1.592 (1.473 con stock ≠ 0); **472 de los 494 padres tienen al menos un hijo con historia** |
| Variantes en ventas / compras | 631 / 567 |
| `sale_items` / `purchase_items` con `unit_id` explícito | 686 / 520 (439 productos distintos en ventas) |
| `stock_movements` totales | 5.362 |

Consecuencia directa: **si el cambio de unidad se sigue bloqueando por historia, el 96% de los padres con hijos queda trabado para siempre** (472/494).

### 1.3 Formulario (`frontend/components/forms/product-form.tsx`, 597 líneas)

Un único formulario sirve a producto simple, padre y variante. Campos: Nombre, selector "Producto Padre (Variante)" (L322), código de barras con escáner y generador EAN-13 (L341-360), PLU de balanza (oculto sólo si `stockControlType === "variant_only"`, L378), categoría (sólo si no es variante), SKU (L413, **siempre**, también en variante), tipo de inventario y unidad de medida (sólo `!isVariant`, L465-527), stock inicial / actual y stock mínimo (L534+), precio y costo.

Hallazgo que reordena el problema: **el formulario no puede crear un padre `variant_only`.** El select de tipo de inventario sólo ofrece `tracked`/`untracked` (L470 mapea `variant_only` a `tracked` para mostrarlo) y no hay forma de marcar "este producto es un padre". Los `variant_only` de prod (644) nacieron del **importador** (`lib/import/resolver.ts:103`). Un "padre" creado a mano es un producto `tracked` cualquiera al que después se le agregan hijos con "Nueva variante" (`handleAddVariant`, `productos/page.tsx:60`), con su propio stock, barcode, SKU, PLU y precio: justo lo que el PO dice que no tiene sentido en un padre. De ahí los 233 padres `tracked`.

### 1.4 Backend

- `backend/services/products.py`:
  - **Alta de variante** (`create_product`, L268-276): la categoría se toma del padre en el servidor y lo que mande el cliente se ignora. **No resuelve nada más del padre**: ni unidad (la hereda la vista), ni precio, ni costo.
  - **Edición** (`update_product`, L380-398): `base_unit_id` es tri-estado por `model_fields_set` (omitido conserva / uuid asigna / null desasigna) y pasa por `_guard_base_unit_change` (L185-217), que responde **409 `base_unit_locked`** si el producto (o las variantes que heredan) tiene stock ≠ 0 o algún `stock_movements`. La categoría de una variante se ignora al editar (L390-392).
  - `PUT /products` no ajusta stock (D9 de `stock-ledger-solo-rpc`).
- La base lo hace cumplir para cualquier escritor con `trg_product_base_unit_guard` (`P0409 base_unit_locked`), incluido re-parentar y borrar físicamente el padre de una variante que hereda. Documentado como **D-C, decisión provisoria pendiente de sign-off del PO** (`knowledge-base/05_reglas_de_negocio.md` L151, inciso g).
- `ProductUpdate` no tiene tri-estado de `price`; `cost` sí.
- Importador (`rpc_bulk_upsert_products`, última reescritura `20261086000001`): una fila "Padre" no lee precio, costo, stock ni PLU (`lib/import/importer.ts:92-110`, `validator.ts:176`). El import **ya** trata al padre como cabecera de catálogo.

### 1.5 Specs y reglas que tocan el tema

`product-sku` (único por cuenta), `product-cost` (cost nullable, ausente ≠ 0), `units-of-measure`, `product-category` (la variante hereda la categoría del padre), `product-import` (referencia de padre por código/nombre; fila Padre sin precio/stock/PLU), `product-profitability`; RN-25 (padre `variant_only` sin stock propio); RN de unidades, inciso (e) "una variante hereda la unidad base de su padre (`COALESCE(propia, padre)`)" e inciso (g) el bloqueo D-C; `modelo-dominio-aliadata-v2.md` §2.2: variantes "parte del agregado Product, un solo nivel".

---

### 1.6 Mediciones de la revisión 2 (prod 2026-11-05)

| Medida | Valor |
|---|---|
| Padres `variant_only` con precio ≠ 0 o costo cargado | 17, en **2 cuentas**: 16 en `3834e5d7…` (suma de precios 599.400, **ninguno con ventas**) y 1 en `c4145451…` (precio 39.900, **con 1 línea de venta histórica**) |
| Esos 17 padres con hijos vivos | 17 de 17 (las variantes llevan su propio precio, así que ningún lector pierde información al limpiar el padre) |
| Productos con precio ≠ 0 / con costo / con ambos (raíz no `variant_only`) | 1.087 / 787 / 782 |
| Relación precio/costo entre 1,3 y 1,7 | 65 de 782 (exactamente 1,5: 4). **El markup real es muy disperso: 1,5 sólo puede ser una sugerencia, nunca un valor aplicado en silencio** |
| Productos con precio no entero | 5 de 3.610 con precio (casi todo el catálogo ya trabaja en pesos enteros) |
| Selección múltiple de `/productos` | ya existe: `selectedIds` en `components/products/product-catalog.tsx` (L165-370, barra de acción L515+) con checkbox por fila y "seleccionar visibles"; troceo de 500 en `lib/product-bulk-category.ts`; UPDATE único por `account_id` con expansión padre a variantes (`_BULK_SET_CATEGORY_SQL`, `product_repository.py` L130; hoy es SQL del repositorio, no una RPC) |
| Importador sin precio | fila sin precio: el alta queda con `price = 0` y la edición conserva el vigente (spec `product-import`); el padre ya no lee precio ni costo (`importer.ts:92-110`) |

## 2. Problemas confirmados frente a los pedidos

| Pedido | Qué pasa hoy | Evidencia |
|---|---|---|
| **A. Corregir la unidad del padre y que llegue a los hijos** | La unidad del padre se puede escribir, pero el guard D-C la traba apenas algún hijo tiene stock o un movimiento: 472/494 padres. La propagación ya existe por construcción (la vista usa `COALESCE(propia, padre)`), salvo en 47 variantes con unidad propia. | `services/products.py:185-217`, `fn_product_base_unit_guard`, §1.2 |
| **B. Padre sin precio ni costo** | El contrato y el form hoy permiten precio y costo en el padre; 17 padres lo tienen cargado, en 2 cuentas. El padre no se vende ni valoriza stock (RN-25): el dato es ruido que confunde. | `product-form.tsx`, §1.6 |
| **C. Alta confusa padre vs individual** | Un solo form con todos los campos; `variant_only` no se puede elegir desde la UI; SKU y barcode se piden en el padre; 233 padres `tracked` armados a mano. | `product-form.tsx:322,341,413,465,534` |
| **D. Cambiar precios de muchos productos** | No hay forma masiva: sólo editar de a uno (hay recategorización en lote, no de precio). | `product-catalog.tsx` sólo expone `onBulkRecategorize` |
| **E. Precio a mano en cada alta** | El usuario carga costo y precio sin ayuda; el precio queda en 0 si no lo escribe. | `product-form.tsx`: precio y costo independientes |

---

## 3. Opciones de diseño

### 3.a Unidad editable en el padre, con cascada (se mantiene sin cambios)

**Qué es "cascada".** Escribir la unidad una sola vez en el padre y que los hijos la lean por herencia (ya es la regla de lectura). Falta (i) limpiar las 47 variantes con unidad propia y (ii) decidir qué pasa con stock/historia ya grabados.

| Opción | Qué hace | A favor | En contra |
|---|---|---|---|
| **A1. Mantener el bloqueo (hoy)** | 409 si hay stock/movimientos | Cero riesgo | Deja sin resolver el pedido para el 96% de los padres |
| **A2. Relabel (recomendada)** | Cambia la unidad base **sin tocar ninguna cantidad** (12 pasa a leerse "12 kg"). Corrección de error de carga. Confirmación con impacto; sólo dueño/administrador | Es lo que el PO describe; barato | kg a g sin conversión queda 1000 veces mal: la confirmación lo explica con ejemplo |
| **A3. Convertir** | Multiplica stock y reexpresa movimientos | Correcto para kg a g | Reescribe un ledger append-only; es `v3-uom-conversion`, change propio |

**Recomendación: A2** en `rpc_relabel_product_unit` (`SECURITY DEFINER`).
- No se relaja `trg_product_base_unit_guard`: la RPC lo supera con un GUC local (`products.allow_base_unit_relabel`), patrón que el trigger ya usa en su rama DELETE. Rol: owner/admin (`CAN_CORRECT_MONEY`).
- Escribe `base_unit_id` en el padre y pone NULL en el de las variantes (las 47 pasan a heredar), con `FOR UPDATE` del padre y los hijos por orden de id.
- Rechaza con `P0409` `unit_relabel_conflict` si el grupo tiene líneas con `unit_id` explícito distinto de la unidad nueva (686 `sale_items` y 520 `purchase_items` con `unit_id`); medir antes del apply cuántos de los 472 padres caen de cada lado.
- Auditoría en `audit_logs` (`product_unit_relabel`: unidades, variantes y stock afectados, usuario).
- Alta de variante: el servidor ignora la unidad del cliente y deja NULL.
- Formaliza D-C: el bloqueo por historia sigue siendo el default; el relabel es la excepción explícita, confirmada y auditada.

### 3.b Contrato del padre sin precio ni costo (reemplaza a la herencia)

Decisión del PO: el padre `variant_only` no tiene precio ni costo. Qué pasa con lo existente y con los lectores:

| Opción | Qué hace | A favor | En contra |
|---|---|---|---|
| **P1. El servidor fuerza `price = 0` y `cost = NULL` en un `variant_only` y se limpian los 17** | `create_product`/`update_product` descartan lo que mande el cliente para un `variant_only`; backfill de los 17 padres | Contrato explícito y sin dato fantasma; ningún lector pierde información (los 17 tienen hijos con precio propio) | Toca 17 filas de 2 cuentas; una tiene una venta histórica de ese padre: su `sale_items` conserva el precio de línea y no se reescribe |
| **P2. Sólo ignorar a futuro, dejar los 17** | Sin backfill | Cero escritura de datos | Quedan 17 padres con precio que el form ya no muestra ni deja corregir |
| **P3. CHECK en la base (`variant_only` implica `price = 0 AND cost IS NULL`)** | Lo hace cumplir la base para cualquier escritor | Red para PostgREST/importador | Exige limpiar los 17 antes |

**Recomendación: P1 + P3 en la misma migración**, con el backfill de los 17 antes del CHECK (idempotente, con gate que verifique 0 padres con precio/costo). Lectores:
- **Vista `v_products_with_stock`:** sin cambio (devuelve 0 y NULL del padre).
- **Ranking, rentabilidad, estadísticas:** leen `sale_items` y el snapshot de costo de la línea, no el precio del padre; sin impacto. La única venta de un padre (cuenta `c4145451…`) conserva su línea.
- **POS, ventas, balanza:** el padre no se vende ni se exporta (`scale-export.ts:109`, RN-25).
- **Importador:** la fila Padre ya no lee precio ni costo (`importer.ts:92-110`); en el servidor se deja de aceptarlos.
- **Formulario y listado:** el padre no muestra ni edita precio/costo; el listado muestra en el padre un rango "desde $X" tomado de los hijos.

### 3.c Alta diferenciada: padre vs individual (se mantiene; el padre pierde también precio y costo)

Paso previo **"¿Qué querés crear?"** con dos tarjetas dentro del diálogo existente de `/productos` (sin entrada nueva de menú): **Producto simple** (form actual, sin selector de padre) y **Producto con variantes** (crea el padre `variant_only` y pasa a "Agregar la primera variante"). "Nueva variante" desde la fila del padre sigue (padre fijo, sin selector).

| Campo | Simple | Padre (`variant_only`) | Variante |
|---|---|---|---|
| Nombre | sí | sí | sí (puede precargar "Nombre padre - atributo") |
| Categoría | sí | sí | hereda (sólo lectura) |
| Unidad de medida | sí | **sí: es la de la familia** (editable con 3.a) | hereda (sólo lectura) |
| Tipo de inventario | sí | fijo `variant_only` | fijo `tracked` |
| Precio / Costo | sí (con sugerencia 3.e) | **no** | **propios** (con sugerencia 3.e) |
| Stock inicial / Stock mínimo | sí | **no** | sí |
| SKU / Código de barras / PLU | sí | **no** | sí |
| Atributos (color, talle) | — | — | sí |

- **SKU del padre:** 0/644 lo usan; se saca del form (columna y unicidad intactas; el importador puede seguir resolviendo `sku_parent`). No se agrega prefijo de SKU (Regla de Tres).
- **Barcode del padre:** 71 lo tienen (legado); se deja de pedir y se conservan (OQ-3).
- **Edición espeja el modo** según `stockControlType`, `parentId` y existencia de hijos.
- **233 padres `tracked` legados:** se muestran en modo padre cuando tienen hijos, sin conversión automática (38 tienen stock propio; RN-25) (OQ-4). Siguen siendo editables como producto, con un aviso.
- **Servidor:** rechazar en un padre stock inicial, barcode, PLU, SKU, precio y costo (hoy sólo rechaza PLU), con el molde de 422 tipado existente.

### 3.d Modificador de precios en lote (nuevo)

Espejo de la recategorización en lote (D14 de `productos-categorias-sku`):

- **Flujo:** la selección múltiple de `/productos` ya existe (checkbox por fila, "seleccionar visibles", barra de acción). Se agrega la acción "Modificar precios" junto a "Recategorizar". El diálogo pide dirección (aumentar o bajar), modo (**porcentaje** o **importe fijo**) y valor, y muestra la **previsualización** (cuántos productos cambian, cuántos se omiten, ejemplo antes/después de los primeros) antes de confirmar.
- **Alcance:** sólo **precio**. El costo lo carga la compra; el costo de catálogo no se toca en lote (recomendado; si el PO lo pide, es otro change).
- **Selección y expansión:** como la categoría: un padre seleccionado se expande a sus variantes y una variante suelta se normaliza a su raíz. **Matiz propio:** el padre no tiene precio, así que el UPDATE sólo toca filas con precio (variantes y simples) y excluye a los `variant_only`; el contador cuenta sólo filas realmente cambiadas.
- **Troceo:** 500 ids por request, reutilizando `chunkIds` de `lib/product-bulk-category.ts` (se generaliza el helper, no se copia). Cada bloque es atómico; el lote completo no (mismo criterio que la categoría): si un bloque falla, el diálogo informa cuántos se aplicaron.
- **RPC `rpc_bulk_adjust_prices(p_product_ids uuid[], p_mode text, p_direction text, p_value numeric, p_dry_run boolean)`** `SECURITY DEFINER`: guard de tenant con `is_account_writer` (`P0401`), un único `UPDATE` filtrado por `account_id` y `deleted_at IS NULL`, `p_dry_run` devuelve conteo y muestra sin escribir (la misma función da la vista previa, como en `edicion-operaciones-con-dinero`) y una fila de `audit_logs` por lote (modo, valor, productos tocados, usuario). Reglas: porcentaje entre -90 y +1000, importe fijo que nunca deja el precio negativo (se acota a 0 y se informa cuántos se acotaron), `p_value <> 0`.
- **Redondeo (decisión):** **a entero de pesos**; "sin redondeo" no se recomienda: sólo 5 de 3.610 precios tienen centavos, así que redondear no altera el criterio del catálogo y evita precios como 1.234,57. Una sola regla de redondeo compartida entre SQL y TypeScript, usada tal cual por la previsualización.
- **Rol:** owner/admin (cambiar muchos precios es una corrección con efecto en el dinero de las ventas futuras); `stock` y `cajero` no.
- **Gate SQL:** ejecuta la RPC de verdad (aumento por porcentaje, baja por importe con acotado a 0, redondeo, expansión padre a variantes, exclusión del padre, tenencia ajena sin efecto, `dry_run` sin escritura, fila de auditoría, ACL sin `anon`).
- **Specs:** capability nueva `product-bulk-pricing`; `product-sku` y `product-cost` sin cambios de fondo.

### 3.e Sugerencia de precio al cargar el costo (nueva)

- **Lógica pura** en `frontend/lib/product-pricing.ts`: `suggestPriceFromCost(cost, factor = SUGGESTED_MARKUP_FACTOR)` con la constante única `SUGGESTED_MARKUP_FACTOR = 1.5` y el mismo `roundToPesos` del lote (una sola definición del redondeo, también consumida por la previsualización del modificador en lote).
- **Regla de pisado:** en el form de producto simple y de variante, al escribir el costo se sugiere `costo × 1,5` en el precio **sólo si el precio está vacío/0 o es todavía igual a la última sugerencia aplicada**. Un precio escrito por el usuario nunca se pisa: el form guarda `lastSuggestedPrice` en estado local y editar el precio a mano lo invalida. En la edición de un producto con precio ya cargado no se sugiere.
- **Costo vacío o 0:** no se sugiere nada (costo ausente ≠ 0 en `product-cost`).
- **Transparencia:** ayuda junto al campo ("Sugerido: costo × 1,5; podés cambiarlo").
- **Factor configurable por cuenta:** no ahora. Lo que lo justifica a futuro: la relación real precio/costo es muy dispersa (65 de 782 entre 1,3 y 1,7). **Candidato** `markup-por-cuenta` (por cuenta o por categoría); anotado, no se hace.
- **Importador: no aplica.** El CSV trae precio explícito; si falta, hoy el alta queda con `price = 0` y la edición conserva el vigente (§1.6). Sugerir ahí sería escribir un dato que el usuario no declaró.

---

## 4. Impacto

**Base de datos (una migración, número a reservar al proponer):**
- Backfill de los 17 padres (`price = 0`, `cost = NULL`) y CHECK `products_variant_only_no_price_cost`; el gate verifica 0 filas fuera de regla.
- `rpc_relabel_product_unit(product_id, new_unit_id)` y `rpc_bulk_adjust_prices(...)`, ambas `SECURITY DEFINER`, con guards de tenant/rol, `audit_logs` y ACL sin `EXECUTE` para `anon`; reescritura de lo que toque desde `pg_get_functiondef` vivo.
- `trg_product_base_unit_guard` no se modifica (el relabel lo supera con un GUC local).
- El CHECK debe convivir con `rpc_bulk_upsert_products` (la fila Padre ya llega con `price`/`cost` nulos): verificar con el gate del importador.
- Gates SQL nuevos que *ejecuten* las dos RPCs (regla del proyecto), test de carrera del relabel análogo a `test_ventas_unidades_conversion_race.sh` y re-ejecución de los gates que introspectan el guard de unidad.

**Backend:** `schemas/products.py` (esquemas del lote de precios y del relabel), `services/products.py` (rechazo de precio/costo/stock/barcode/PLU/SKU en el padre, alta de variante sin unidad propia, relabel y lote con rol owner/admin), `repositories/product_repository.py`, routers `PATCH /products/bulk-price` y `POST /products/{id}/relabel-unit`. Tests unitarios y de integración contra Postgres real.

**Frontend:** `product-form.tsx` se parte en selector de modo + tres formularios por composición; `productos/page.tsx` (paso "¿Qué querés crear?"); `components/products/product-catalog.tsx` (acción "Modificar precios", diálogo con vista previa, rango "desde $X" en el padre); `lib/product-pricing.ts` (nuevo: `suggestPriceFromCost`, `roundToPesos`, `SUGGESTED_MARKUP_FACTOR`); `lib/product-bulk-category.ts` (generalizar el troceo); `hooks/data/use-products.ts`; diálogo de confirmación del relabel (patrón de vista previa de `edicion-operaciones-con-dinero`). **Superficie frontend: sí**, sobre `/productos`; verificación en desktop y móvil, claro y oscuro.

**Specs:** `units-of-measure` (relabel como excepción formal del bloqueo), `product-sku` (no se pide en padre), `product-cost` (el padre no lleva costo), `product-import` (fila Padre sin precio/costo, ya vigente), capabilities nuevas `product-variants` (alta diferenciada, padre sin precio/costo, cascada de unidad) y `product-bulk-pricing`. KB: RN-25 y RN de unidades.

**No cambia:** `v_products_with_stock`, snapshots de líneas, POS, ventas, compras y reportes.

---

## 5. Riesgos y preguntas abiertas (con recomendación)

| # | Riesgo / OQ | Recomendado |
|---|---|---|
| R1 | Relabel entre unidades convertibles (kg a g) deja el stock 1000 veces mal | Confirmación con ejemplo; conversión real fuera (`v3-uom-conversion`) |
| R2 | Líneas con `unit_id` explícito distinto de la nueva (686 + 520) | Rechazar con `unit_relabel_conflict`; medir cuántos padres caen ahí antes del apply |
| R3 | Carrera: venta/compra concurrente durante el relabel | Mismo orden de locks que el trigger + test de carrera |
| R4 | Un aumento en lote mal elegido (por ejemplo 100 en vez de 10) | Vista previa obligatoria con ejemplo antes/después, tope de porcentaje, auditoría del lote; deshacer = aplicar el porcentaje inverso (no es exacto por el redondeo: se dice en el diálogo) |
| R5 | El redondeo del lote difiere del de la sugerencia | Una sola función de redondeo y una sola constante |
| R6 | El CHECK del padre rompe un escritor que mande precio en un `variant_only` | Backfill de los 17 primero; gate del importador; el servidor lo descarta antes del CHECK |
| R7 | 386 padres sin hijos | No tocarlos acá (candidato aparte) |
| R8 | 233 padres `tracked` legados | Mostrar como padre sin convertir (OQ-4) |
| OQ-1 | ¿Cambio de unidad con historia como relabel (A2)? | A2, dueño/administrador, con confirmación y auditoría (cierra D-C) |
| OQ-2 | Costo en el lote | No: sólo precio |
| OQ-3 | Padres con código de barras (71) | Conservar, no pedir más |
| OQ-4 | Padres `tracked` legados (233) | No convertir automáticamente |

### Tandas propuestas

- **Tanda A (DB + backend, sin UI):** backfill y CHECK del padre sin precio/costo, `rpc_relabel_product_unit`, `rpc_bulk_adjust_prices`, rechazos del contrato del padre en servidor, alta de variante sin unidad propia, endpoints, gates SQL y tests de integración. Sin cambio visible.
- **Tanda B (frontend):** "¿Qué querés crear?", tres formularios por modo, sugerencia costo × 1,5 (`lib/product-pricing.ts`), acción y diálogo "Modificar precios" con vista previa, diálogo del relabel, edición espejando el modo. Verificación en las 4 combinaciones.
- **Tanda C (opcional, sin cambios):** conversión asistida de los padres `tracked` y limpieza de los 386 padres sin hijos, sólo si el PO lo pide.

Candidatos que deja anotados: `markup-por-cuenta` (factor de sugerencia configurable) y `v3-uom-conversion`.

---

## 6. Preguntas al PO que siguen abiertas

1. **Unidad con historia:** ¿se puede corregir aunque haya stock y movimientos, sin convertir cantidades (12 "u" pasan a leerse "12 kg"), sólo dueño/administrador y con confirmación que muestra el impacto? Recomendado: sí. La alternativa es que siga bloqueada.
2. **Padres con código de barras (71):** ¿se conservan sin pedirlo más (recomendado) o se limpian?
3. **Padres "producto base" creados a mano (233, algunos con stock propio):** ¿se dejan mostrados como padre (recomendado) o querés una conversión asistida más adelante?

(Resueltas por el PO: herencia de precio/costo fuera; el modificador en lote y la sugerencia de precio entran.)
