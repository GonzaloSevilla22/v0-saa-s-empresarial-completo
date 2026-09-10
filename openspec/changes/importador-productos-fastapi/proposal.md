## Why

El importador de productos es **la última escritura masiva que el frontend hace directo contra Supabase**. `frontend/lib/import/importer.ts:99-121` crea un cliente de Supabase en el navegador, trocea el archivo en lotes de 200 (`IMPORT_BATCH_SIZE`, `lib/import/types.ts:166`) y llama `supabase.rpc("rpc_bulk_upsert_products", { p_rows, p_user_id })` una vez por trozo. `lib/import/resolver.ts:74-97` abre un **segundo** cliente y consulta `products` directo, filtrando por `user_id` — un alcance que el catálogo dejó de tener hace tres changes (el SKU y el código de barras son únicos **por cuenta**; `productos-categorias-sku` D4 y task 4.5). El modelo híbrido del proyecto (DEC-12..15) dice lo contrario: el frontend consume FastAPI para datos y mutaciones, y habla directo con Supabase sólo para Auth y Storage.

No es una deuda cosmética. Al saltear el backend, el importador **saltea todo lo que el backend hace**:

1. **El límite de productos del plan no se aplica.** `plan-gating` es explícita: *"El enforcement de los límites de recursos maestros (productos, clientes, proveedores) SHALL aplicarse en la creación"*. `backend/services/products.py:88-96` lo cumple para el alta de a uno; el importador no pasa por ahí. Medido en prod (2026-09-10): la cuenta más grande tiene **2.372 productos vivos** con `plan_limits.max_products = 100` para su plan facturado, y hay **5 cuentas por encima de 100 productos**. El formulario les dice que no; el importador les dice que sí.
2. **No hay guard de rol de escritura.** El cuerpo vivo de `rpc_bulk_upsert_products` valida `p_user_id = auth.uid()` y resuelve la cuenta por `current_account_ids()`, pero **nunca llama `is_account_writer`** — a diferencia de `rpc_create_expense`, que sí. Un miembro de sólo lectura puede cargar 5.000 productos.
3. **La atomicidad es por trozo de 200, no por archivo.** Un archivo de 600 filas son tres llamadas independientes: si la tercera falla entera, las 400 primeras quedan escritas y confirmadas. El propio importador lo asume — acumula errores y sigue.
4. **El tope de 50 categorías nuevas es, en el servidor, un tope por trozo.** `product-category` lo declara como salvaguarda del **archivo** (*"cuando el archivo introduzca más categorías nuevas distintas que el tope admitido"*); el cliente sí lo evalúa sobre el archivo entero (`validator.ts`), pero la defensa en profundidad del servidor se evalúa sobre 200 filas por vez. Con el troceo, la única barrera real es el cliente.
5. **El error de servidor no dice en qué fila está.** `importer.ts:120` empuja `lineNumber: 0` porque la RPC devuelve `{sku, name, message}` sin número de fila — y sólo **18 de 4.953** productos vivos tienen SKU, así que en la práctica el usuario recibe un error sin ninguna forma de ubicarlo en su planilla.
6. **No hay idempotencia ni dedupe de archivo.** Subir dos veces el mismo archivo crea todo dos veces (salvo que las filas traigan SKU, que casi ninguna trae).

El PO aprobó cerrarlo dentro del programa "cero candidatos" (2026-09-07, *"sí a todo"*). El candidato viene con nombre y apellido de `productos-categorias-sku` (D7): *"el importador SIGUE por RPC (no FastAPI) […] migrarlo entero es un change propio"*. Y el molde ya está probado dos veces en el repo: `rpc_import_bank_statement` (C3) y, en marcha ahora mismo, `importador-gastos-transaccional`.

## What Changes

- **El importador pasa a FastAPI**: nace `POST /products/import` en las tres capas (router → service → repository), con `Idempotency-Key` por header (v3-api-standards §3) y envelope de error RFC 7807. El frontend deja de instanciar clientes de Supabase para importar.
- **La unidad de trabajo es una RPC de lote nueva**, `rpc_import_products(...)` `SECURITY DEFINER` (DEC-24), que **invoca `rpc_bulk_upsert_products` una sola vez con el archivo completo** y convierte su reporte por fila en un **veredicto de lote**. No se copia ni una regla del upsert: ni la clave por SKU, ni la resolución/creación de categorías, ni la jerarquía padre→variante, ni el `branch_stock` de la sucursal por defecto.
- **Todo o nada, sin trocear**: `IMPORT_BATCH_SIZE = 200` y el troceo del cliente se retiran. O entra el archivo entero o no entra nada. Como efecto colateral **el tope de 50 categorías nuevas del servidor pasa a evaluarse sobre el archivo**, que es lo que la spec `product-category` siempre dijo.
- **La tenencia se deriva del JWT, nunca del cliente**: el body del endpoint **no** lleva `user_id`. La RPC de lote resuelve `auth.uid()` y se lo pasa al upsert; el parámetro `p_user_id` sigue existiendo en la función interna y sigue validándose contra `auth.uid()`, pero deja de venir del navegador.
- **Guard de rol de escritura** (`is_account_writer`) en la RPC de lote — el hueco (2) se cierra en el único punto de paso.
- **El límite de productos del plan se aplica al importar**, evaluado **después** de escribir y **antes** de confirmar, contra `get_effective_plan` + `plan_limits` (las mismas fuentes canónicas): si el archivo dejaría la cuenta por encima de su tope, el lote se rechaza entero con el conteo exacto. Evaluarlo sobre el resultado —y no adivinando cuántas filas insertarían— evita duplicar el predicado de upsert del que depende.
- **Vista previa validada por el servidor**: el paso 2 del diálogo deja de ser sólo validación de cliente. La misma RPC en modo simulación (`p_dry_run`) ejecuta el lote completo y lo deshace, devolviendo el veredicto real —incluidos los errores de fila, las categorías que se crearían y el veredicto de plan— **antes** de escribir nada.
- **El error de servidor viaja con su número de fila**: `rpc_bulk_upsert_products` recibe **una sola modificación quirúrgica**, con la **misma firma** (`CREATE OR REPLACE`, sin `DROP`, sin riesgo de overload `42725`, sin reset de ACLs): el objeto de error suma el número de fila que la fila del payload ya puede traer. Nada más de su cuerpo cambia.
- **Idempotencia y dedupe de archivo**: nace `public.product_imports` (espejo mínimo de `bank_statement_imports` / `expense_imports`), `operation_idempotency.operation_kind` suma `'product_import'`, y volver a subir el mismo archivo devuelve `replayed: true` sin escribir.
- **La resolución de jerarquía deja de consultar la base desde el navegador**: `resolveHierarchy` conserva su cascada pura (referencia en el lote → agrupación secuencial) y **retira el round-trip a Supabase**. Una referencia **explícita** (`SKU Padre` / `Producto Padre`) que no resuelve en el lote la resuelve el servidor por cuenta y, si tampoco existe ahí, es **error de fila** visible en la vista previa — en vez del producto independiente que hoy se crea en silencio. La ausencia total de referencia sigue cayendo en la agrupación secuencial y, sin padre arriba, sigue siendo producto independiente con aviso.
- **BREAKING (de tenencia, silencioso hoy)**: la búsqueda de padres fuera del lote pasa de `user_id` a `account_id`. Un padre creado por otro miembro de la misma cuenta empieza a resolver; hoy no resuelve y la variante se importa huérfana.
- **`rpc_bulk_upsert_products` se revoca de `authenticated`**: con el backend como único camino, deja de ser invocable desde PostgREST. Es lo que hace que los huecos (1) y (2) queden cerrados de verdad y no sólo tapados por la UI.
- **El parseo y la validación de celdas se quedan en el frontend** (`lib/import/parser.ts`, `validator.ts` y los helpers canónicos `parseAmount` / `parseQuantity` / `amountAmbiguityWarning` de `lib/excel.ts`), que ya tienen los avisos de ambigüedad y sus tests. Es el mismo reparto que `rpc_import_bank_statement` fijó (D2 de C3: *"parseo en el cliente"*).
- **Non-Goals declarados**: no se soporta XLSX (sigue CSV); no cambia el esquema de columnas ni las columnas dinámicas de atributos; no nace ninguna marca por producto de qué importación lo creó; no se toca la semántica del costo (ver la coexistencia con `productos-costo-nullable` abajo); no se unifica el parseo de cantidades con el importador de ajustes de stock (candidato abierto y ajeno).

## Capabilities

### New Capabilities
- `product-import`: la importación de productos por archivo como **operación de lote atómica servida por la API**: contrato de la fila normalizada, reparto de responsabilidades entre parseo de cliente y validación de servidor, todo-o-nada con reporte de errores por fila numerada, vista previa validada por el servidor, tope de filas, enforcement del límite de plan al importar, idempotencia por clave y dedupe por archivo, y superficie del diálogo de importación.

### Modified Capabilities
- `product-category`: el tope de categorías nuevas pasa a evaluarse sobre el archivo completo también en el servidor (hoy la salvaguarda del servidor se aplica por sub-lote de 200 filas, de modo que la única barrera efectiva es el cliente), y las categorías que se crearían se anuncian con el veredicto del servidor y no sólo con el del cliente.
- `product-sku`: la resolución de la clave de upsert y de las referencias de padre se declara alcanzada por la **cuenta** en todos sus tramos, incluida la búsqueda de padres fuera del lote, que hoy sigue alcanzada por `user_id` en el cliente.
- `plan-gating`: el enforcement del límite de productos deja de estar acotado al alta de a uno y alcanza a la carga masiva, con la conducta declarada para el lote que cruzaría el tope.

## Impact

**Base de datos** (migración nueva, la que corresponda tras `20261043000001`)
- `public.product_imports` (tabla nueva) + RLS de `SELECT` por cuenta + `GRANT SELECT` para `authenticated` y nada más (escritura sólo por la RPC `SECURITY DEFINER`).
- `operation_idempotency`: el `CHECK` de `operation_kind` suma `'product_import'`.
- `public.rpc_import_products(...)` (función nueva) + ACLs explícitas en el mismo archivo.
- `public.rpc_bulk_upsert_products(jsonb, uuid)`: `CREATE OR REPLACE` **con la misma firma**, partiendo del cuerpo vivo, con una única adición (el número de fila en el objeto de error) + `REVOKE EXECUTE FROM authenticated`.

**Backend**
- `backend/routers/products.py` (endpoint nuevo), `backend/services/products.py`, `backend/repositories/product_repository.py`, `backend/schemas/products.py`, `backend/core/errors.py`.

**Frontend**
- `frontend/lib/import/importer.ts` (deja de hablar con Supabase y de trocear), `resolver.ts` (retira el round-trip y el alcance por `user_id`), `types.ts` (retira `IMPORT_BATCH_SIZE`, tipos del lote), `frontend/components/products/product-import-dialog.tsx` (pasos 2 y 3), `frontend/hooks/data/use-products.ts` (mutación de lote), `frontend/lib/types.ts`. Reuso de `hashFileSHA256` (`lib/bank-statement-parser.ts:213`) — **sin escribir un segundo hasher**.

**CI / verificación**
- Gate SQL nuevo cableado en `.github/workflows/KPI_Validation.yml`.
- `openspec validate --specs --strict`: 98 → **99** capabilities (100 y 101 si `expense-import` y `product-cost` llegan antes).

**Secuenciación**: este change se aplica **después** de `productos-costo-nullable` (que reescribe `rpc_bulk_upsert_products` y `lib/import/validator.ts`) y **después** de `importador-gastos-transaccional` (que fija el vocabulario de ERRCODEs del lote y el molde de las tres capas). El contrato de transporte de este change es null-preserving por diseño, de modo que el orden real no pueda romper la distinción entre "celda vacía" y "cero".

**Riesgo de dominio**: gobernanza **MEDIA**. No escribe dinero: escribe catálogo, stock y categorías. El tramo delicado no es contable sino de **disponibilidad** — el enforcement del límite de plan puede dejar sin importar a cuentas que hoy importan, y el todo-o-nada convierte un archivo con una fila mala en un archivo rechazado.
