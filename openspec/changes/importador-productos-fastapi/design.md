## Context

### Qué hay hoy, medido contra el código vivo

**El importador habla directo con Supabase, dos veces, desde el navegador.**

`frontend/lib/import/importer.ts:99-121` — `importProductsFromFile` hace `createClient()` (L99), trocea las filas resueltas en lotes de `IMPORT_BATCH_SIZE` (L100) y por cada trozo emite `supabase.rpc("rpc_bulk_upsert_products", { p_rows, p_user_id: userId })` (L108). El `userId` sale del contexto de auth del cliente y viaja en el body de PostgREST (`product-import-dialog.tsx:232`).

`frontend/lib/import/resolver.ts:74-97` — un **segundo** `createClient()` (L74) consulta `products` para resolver padres fuera del lote, filtrando por `.eq("user_id", userId)` (L80 y L92). Ese alcance es el que el catálogo dejó de tener: `productos-categorias-sku` movió la unicidad del SKU y del código de barras a `account_id` (`idx_products_sku_account_lower`, `idx_products_barcode_account_unique`), y el cuerpo vivo de la RPC resuelve **por cuenta**. El cliente y el servidor buscan al mismo padre con dos alcances distintos.

**El troceo hace que la atomicidad sea de 200 filas, no del archivo.** `IMPORT_BATCH_SIZE = 200` (`lib/import/types.ts:166`). Un archivo de 600 filas son tres transacciones independientes.

**El error de servidor no tiene número de fila.** `importer.ts:114-125` recibe `{inserted, updated, errors}` y empuja `lineNumber: 0` para cada error, porque el objeto de error de la RPC es `{sku, name, message}`. En prod hay **18 productos con SKU sobre 4.953 vivos**: para el 99,6 % del catálogo, `sku` y `name` no identifican una fila de la planilla de forma útil.

### El upsert, verificado contra el cuerpo vivo

`public.rpc_bulk_upsert_products(p_rows jsonb, p_user_id uuid)` — `SECURITY DEFINER`, `SET search_path TO 'public'`, `RETURNS jsonb`.
**`md5(pg_get_functiondef(...))` de la base local (`MAX(version) = 20261040000001`, 289 migraciones, con `20261041000001` de gastos aplicada sin registrar — el `CHECK` vivo de `operation_idempotency` ya contiene `'expense_import'`): `d76c6b6b232ef8b6fd956def9597005d`.**
Última reescritura: `20261040000001_productos_categoria_text_retiro.sql`. **`productos-costo-nullable` la va a reescribir otra vez en `20261042000001`** — el md5 de arriba caduca con ese merge (ver D12 y el checkpoint 1.2).

Lo que hace, en orden, y que este change **no puede duplicar ni una vez**:

| Bloque | Efecto / guard | Nota |
|---|---|---|
| (a) | `p_user_id IS DISTINCT FROM auth.uid()` → `RAISE` | sin ERRCODE propio (`P0001`) |
| (b) | cuenta desde `current_account_ids()` `LIMIT 1`; sin cuenta → `P0403` | **no hay `is_account_writer`** |
| (c) | sucursal por defecto de la cuenta (la más antigua); **lazy-create** de `'Casa Central'` si no hay ninguna | |
| (d) | categoría por defecto: `accounts.default_product_category_id` viva y activa → si no, heurística `'otros'`/último `sort_order` | `20261032000001` |
| (e) | tope de categorías nuevas: cuenta las distintas de **`p_rows`** que no existen en el catálogo; `> 50` → `P0400` que aborta la llamada entera | **por llamada, no por archivo** |
| (f) | por fila, dentro de `BEGIN … EXCEPTION WHEN OTHERS`: upsert por SKU (por cuenta, case-insensitive, vivas) → resolución de padre (`parent_id` → `sku_parent` → `parent_name`, todas por cuenta, con `RAISE` si no encuentra) → resolución/creación de categoría → `INSERT`/`UPDATE` en `products` → `branch_stock` de la sucursal por defecto (set absoluto, `ON CONFLICT (product_id, branch_id) DO UPDATE`) → `product_attributes` (`ON CONFLICT (product_id, key) DO UPDATE`) |  |
| (g) | el error de fila se acumula como `{sku, name, message}` y **el loop sigue** | sin número de fila |
| (h) | `RETURN {inserted, updated, errors}` | |

ACLs vivas: `EXECUTE` para `authenticated` y `service_role`, revocada para `anon`.

**La propiedad de (f)+(g) que hace barato todo este change:** la RPC **ya** reporta los errores fila por fila sin abortar y **ya** deshace la fila fallida (subtransacción por fila). Lo único que le falta para ser todo-o-nada es alguien que mire el reporte y decida. Ese alguien es la RPC de lote de D1.

### Los dos moldes de lote que el repo ya tiene

`public.rpc_import_bank_statement(text, uuid, text, text, jsonb)` (C3, `20260805000001`): guards → validación de metadata del archivo (`file_name`/`file_hash` obligatorios) → validación de forma del payload (`1..5000` líneas) → **dedupe de dominio** por `(bank_account_id, file_hash)` → **idempotencia técnica** por `operation_idempotency` con `ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS` → escritura. Su plomería HTTP está hecha: `backend/routers/bank_reconciliation.py:68-100` (con `require_idempotency_key(request, payload.idempotency_key)`) y `backend/repositories/bank_reconciliation_repository.py:35-53` (un solo `fetchrow`). El hash lo calcula el cliente: `hashFileSHA256`, `frontend/lib/bank-statement-parser.ts:213-219`.

`importador-gastos-transaccional` (en apply, migración `20261041000001`) aplica ese molde al gasto y agrega las dos piezas que este change también necesita: el **veredicto de lote por el `RETURN` normal** (nunca por excepción, para no dejar abortada la transacción del request) y el **`p_dry_run`** como simulación que ejecuta y deshace. Sus ERRCODEs son `P0427` (forma del payload / tope) y `P0429` (control de flujo del rollback de lote).

### Estado medido en producción (2026-09-10)

| Medición | Valor |
|---|---|
| Productos vivos | **4.953** en 16 cuentas |
| Productos con SKU | **18** (0,4 %) |
| Variantes / entradas padre | 2.031 / 644 |
| Categorías vivas | 271 |
| Cuenta más grande | **2.372** productos |
| Mayor lote real de importación (productos creados en el mismo minuto) | **1.393 filas** |
| Lotes históricos > 200 filas / > 500 / > 2.000 | **5 / 3 / 0** (sobre 1.035 lotes) |
| `plan_limits.max_products` | gratis 100 · inicial 500 · avanzado 2.000 · pro 5.000 |
| Cuentas con más de 100 productos vivos | **5** |
| Cuentas cuyo conteo supera el `max_products` de su plan **facturado** | **4** (todas con `trial_plan = 'pro'`; dos con `billing_exempt`) |

Dos consecuencias directas: el tope de filas por lote **no puede ser 500** (rompería el caso real de 1.393 y el catálogo de 2.372), y el enforcement del límite de plan **va a rechazar importaciones de cuentas reales** (ver D5 y OQ-1).

### El resto del terreno

- El request de FastAPI corre **dentro de una transacción explícita** con `SET LOCAL ROLE authenticated` verificado *fail-closed* (`backend/core/database.py`, `tenancy_tx_scope_enabled` ON en prod). Consecuencia dura para el diseño del error: D3.
- `backend/services/products.py:88-96` aplica el límite de plan leyendo `auth.get("plan", "pro")` — **el claim del JWT, con fallback permisivo a `pro`**. La fuente canónica en base es `get_effective_plan(account_id)` (la misma que usa `reporting_plan_window`). D5 usa la canónica.
- `require_role(auth, ["user","admin"])` es el guard de **plataforma**; el guard de **tenant** es `require_account_role` / `is_account_writer`. El upsert no tiene ninguno de los dos.
- El diálogo vive en `/productos` (`components/products/product-catalog.tsx:1243-1250`, botón "Importar CSV" en L469). Ruta y menú ya existen: este change no crea navegación nueva.
- `parseImportFile` rechaza archivos > 10 MB (`lib/import/parser.ts:132`) y no impone tope de filas.

## Goals / Non-Goals

**Goals:**

1. Que el importador de productos escriba **por el backend**, no por el cliente de Supabase del navegador, y que la tenencia se derive del JWT y nunca del body.
2. Que el archivo sea **una sola unidad de trabajo de servidor**: o entra entero o no entra nada, sin trocear.
3. Que el usuario vea **el veredicto real del servidor antes de que se escriba nada**, con el número de fila de cada error.
4. Que el límite de productos del plan y el guard de rol de escritura **valgan también para la carga masiva**.
5. Que **ninguna regla del upsert se duplique**: una sola definición de "cómo se escribe un producto importado", la que ya existe.
6. Que subir dos veces el mismo archivo, o reintentar por red, **no duplique** el catálogo.

**Non-Goals:**

1. **No se reimplementa el upsert.** `rpc_bulk_upsert_products` recibe exactamente **una** adición (el número de fila en el error) y conserva su firma. Todo lo demás compone.
2. **No nace ninguna marca por producto** de qué importación lo creó (ver D8 y OQ-4). `product_imports` existe por el `operation_id` de la idempotencia y por el dedupe, no como historial navegable.
3. **No hay pantalla de historial de importaciones.** La superficie es el paso 3 del diálogo.
4. **No se soporta XLSX** ni cambia el esquema de columnas, las columnas dinámicas `Atributo: …`, el límite de 10 MB ni el template.
5. **No se toca la semántica del costo.** La distinción "celda vacía" vs. `"0"` es de `productos-costo-nullable`; este change sólo garantiza que el transporte no la destruya (D12).
6. **No se unifica el parseo de cantidades** con `lib/stock-import-parser.ts` (candidato abierto y ajeno: la Regla de Tres todavía no se alcanzó).
7. **No se migran los otros seis caminos** que siguen llamando `supabase.rpc(...)` desde el frontend (stock, sucursales, organización, reportes, admin). Este change cierra el del importador de productos.
8. **No se agrega deshacer una importación.** Cerrar el todo-o-nada elimina el caso en que más falta haría (el lote a medias).

## Decisions

### D1 — La unidad de trabajo es una RPC de lote nueva que **invoca `rpc_bulk_upsert_products` una sola vez con el archivo entero**

**Decisión.** Nace `public.rpc_import_products(p_idempotency_key text, p_rows jsonb, p_file_name text, p_file_hash text, p_dry_run boolean)`, `SECURITY DEFINER`, `SET search_path TO 'public'`, `RETURNS jsonb`. En el corazón:

```
v_result := public.rpc_bulk_upsert_products(p_rows, auth.uid());
```

Una llamada, con **todas** las filas del archivo. El upsert hace lo que siempre hizo; la función de lote se queda con tres responsabilidades que el upsert no tiene y que no son suyas: **decidir si el lote se confirma**, **resolver la identidad y la idempotencia**, y **aplicar los gates que hoy sólo existen en el backend** (rol de escritura, límite de plan).

**Por qué invocarla y no reimplementarla.** Es la regla dura del proyecto (*"reutilización antes que repetición"*, PO 2026-08-02) aplicada al caso más caro: la tabla del Context enumera ocho bloques, incluidos la resolución de jerarquía en tres estrategias, la creación de categorías, el `branch_stock` y los atributos. Copiarlos produciría una segunda definición del alta masiva de producto que divergiría en el primer fix que toque uno solo de los dos caminos — el mismo modo de falla que este repo ya pagó con "criticidad de stock rehecha en 5 lugares".

**Por qué esto funciona técnicamente.** `rpc_bulk_upsert_products` resuelve la cuenta desde la **sesión** (`current_account_ids()`) y valida `p_user_id` contra `auth.uid()`. Los dos leen GUCs (`request.jwt.claims`) que la conexión del request ya tiene seteados con alcance transaccional, y **siguen resolviendo igual dentro de una llamada `SECURITY DEFINER` anidada**: `SECURITY DEFINER` cambia el usuario *de privilegios*, no los GUCs de la sesión. El guard de tenencia no se debilita.

**Por qué una sola llamada y no una por fila.** Llamar al upsert fila por fila haría trivial la atribución del error (la de lote conocería el número de fila), pero rompería **el tope de categorías nuevas**: el bloque (e) del Context cuenta las categorías distintas de `p_rows`, y con `p_rows` de una fila el tope nunca se alcanza. La salvaguarda que `product-category` declara sobre el **archivo** quedaría convertida en letra muerta y habría que reimplementarla afuera. Además multiplicaría por N el trabajo de los bloques (b), (c), (d) y (e). Con una sola llamada, el tope **empieza a evaluarse sobre el archivo** —que es lo que la spec siempre dijo— sin escribir una línea de lógica de tope.

**Beneficio de riesgo.** La firma de `rpc_bulk_upsert_products` **no cambia**: la única modificación se hace con `CREATE OR REPLACE` sobre la misma firma → no hay `DROP FUNCTION` + `CREATE`, no hay riesgo de overload `42725` (el gotcha que ya mordió en `caja-compras-cobranzas` y `cobranzas-catalogo-pagos`) y **`CREATE OR REPLACE` preserva las ACLs**.

**Alternativas descartadas.**
- *Extender `rpc_bulk_upsert_products` con `p_idempotency_key` / `p_dry_run`.* Cambia la firma → `DROP` + `CREATE` → riesgo de overload, ACLs a re-emitir, y colisión frontal con la reescritura que `productos-costo-nullable` ya tiene planificada sobre esa misma función.
- *Endpoint FastAPI que abre una transacción y llama al upsert por trozos desde Python.* Contradice DEC-24 y desplaza la atomicidad a la capa que **no** es la autoridad: cualquier otro caller quedaría fuera de la garantía.
- *Copiar el cuerpo del upsert dentro de la función de lote.* Segunda definición. Descartado sin más.

---

### D2 — La **única** modificación de `rpc_bulk_upsert_products`: el error lleva su número de fila

**Decisión.** `CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(p_rows jsonb, p_user_id uuid)` con **la misma firma**, partiendo del `pg_get_functiondef` vivo al momento del apply, con exactamente un cambio en el bloque (g):

```
      v_error_detail := jsonb_build_object(
        'row',     (v_row->>'row_no')::int,   -- ← lo único que se agrega
        'sku',     v_row->>'sku',
        'name',    v_row->>'name',
        'message', SQLERRM
      );
```

`row_no` es un campo **opcional** de la fila del payload: si no viene, el error sale con `'row': null` y el comportamiento previo se conserva exactamente. Nada más de la función cambia — ni un guard, ni una resolución, ni el `RETURN`.

**Por qué es necesario y por qué no alcanza con mapear afuera.** Hoy el usuario recibe "no se pudo importar" sin poder ubicar la fila. Mapear el error a su fila desde la función de lote por `(sku, name)` es inviable: **18 de 4.953** productos vivos tienen SKU, y dos filas del mismo archivo pueden compartir nombre. El único identificador estable de una fila de la planilla es su número de línea, y el único que lo sabe es quien la parseó.

**Por qué el campo es opcional y no obligatorio.** Un caller viejo (o el propio gate SQL con fixtures mínimas) sigue funcionando sin cambios, y la modificación no puede romper nada que hoy ande. `(NULL)::int` es `NULL`, no un error.

**Riesgo asumido y su límite.** Esta función la reescribe también `productos-costo-nullable` (`20261042000001`). Las dos reescrituras son aditivas y no se pisan, pero **la que se aplique segunda tiene que partir del cuerpo vivo, no del archivo de su propio design** — es la regla de integridad de función del repo, y acá tiene un caso concreto. El checkpoint 1.2 la hace obligatoria.

---

### D3 — El lote es **todo o nada**, y el veredicto viaja en el **retorno normal**, no en una excepción

**Decisión.** El cuerpo de `rpc_import_products` tiene esta forma:

```
  <guards: auth.uid(), cuenta por current_account_ids(), is_account_writer>
  <validación de forma del payload: array, 1..2500 filas, shape mínimo>   -- RAISE normal (P0427)
  <validación de metadata: file_name y file_hash obligatorios>            -- RAISE normal (P0427)

  BEGIN                                    -- ← subtransacción del LOTE
    <dedupe por (account_id, file_hash) → replay, sin escribir>
    <slot en operation_idempotency ('product_import') → replay, sin escribir>
    <INSERT en product_imports>

    v_res := public.rpc_bulk_upsert_products(p_rows, auth.uid());

    <gate de plan sobre el estado RESULTANTE (D5)>                        -- suma a v_errors

    IF jsonb_array_length(v_res->'errors') > 0
       OR v_plan_exceeded
       OR p_dry_run THEN
      RAISE EXCEPTION 'batch_rollback' USING ERRCODE = 'P0429';
    END IF;
  EXCEPTION WHEN SQLSTATE 'P0429' THEN
    v_committed := false;                  -- todo el bloque quedó deshecho
  END;

  RETURN jsonb_build_object('committed', v_committed, 'import_id', …,
                            'inserted', …, 'updated', …, 'errors', …,
                            'new_categories', …, 'plan', …,
                            'replayed', …, 'dry_run', p_dry_run);
```

> **Nota (apply, OQ-1 sin sign-off):** el tope de filas es 1..2500 (bajado de 5.000, ver D6). La línea `<gate de plan sobre el estado RESULTANTE (D5)>`, `v_plan_exceeded` y el campo `'plan'` del `RETURN` son parte del diseño ORIGINAL de este pseudocódigo — el apply NO los escribió (OQ-1 sin sign-off del PO): el `rpc_import_products` real no tiene ninguna de las tres piezas. El resto del esqueleto (guards, validación de forma, subtransacción del lote, `RAISE`/`EXCEPTION` de P0429, `RETURN` sin `plan`) es exactamente lo que se implementó.

**Las dos propiedades de PL/pgSQL de las que depende, que hay que enunciar porque son sutiles:**

1. Un bloque `BEGIN … EXCEPTION` es una **subtransacción**: al capturar su excepción, **todo el estado de base escrito dentro del bloque se deshace** y la transacción exterior queda **sana** (no abortada).
2. **Las variables locales de PL/pgSQL NO se deshacen** con ese rollback. `v_res`, `v_errors`, `v_plan_exceeded` y los conteos sobreviven al `RAISE` deliberado. Ésa es la única razón por la que el reporte puede volver por el `RETURN` normal.

**Por qué el error NO viaja por excepción.** Con `tenancy_tx_scope_enabled` ON, **todo el request de FastAPI corre dentro de un `async with conn.transaction()`**. Si la RPC dejara escapar la excepción, la transacción del request quedaría **abortada**: cualquier consulta posterior sobre esa conexión daría `25P02 (in_failed_sql_transaction)`, y el service tendría que construir la respuesta sin volver a tocar la base — una restricción frágil, invisible en el código, que el primer `re-SELECT` agregado por distracción rompería en producción. Con el `RETURN` normal la transacción del request queda **limpia**.

**Qué se descarta explícitamente.**
- *Conservar "importar lo que se pueda".* Es el estado que este change viene a eliminar: con el troceo, hoy el usuario no sabe qué reintentar, y con SKU en el 0,4 % del catálogo, reintentar el archivo entero **duplica** todo lo que ya entró. El todo-o-nada + el dedupe por hash es lo que hace que reintentar sea seguro.
- *Dos pasadas (una en seco y otra real).* Duplica el trabajo y **no es equivalente**: cualquier efecto no transaccional de la primera pasada no se desharía.
- *Excepción con el reporte en `DETAIL`.* Deja la transacción del request abortada y mete JSON en un campo de diagnóstico.

**El precio, y por qué se paga.** Un archivo de 600 filas con una sola fila mala hoy escribe 599 productos; después de este change no escribe ninguno. Eso sería un castigo si el usuario se enterara *después* — y por eso D7 (la vista previa validada por el servidor) no es un adorno: **es la condición que hace que el todo-o-nada no sea punitivo**. Las dos decisiones se sostienen juntas o no se sostienen.

---

### D4 — Guard de rol de escritura en la función de lote, y `REVOKE` del upsert

**Decisión.** `rpc_import_products` exige `is_account_writer(v_account_id)` (`P0401` si no), como `rpc_create_expense`. Y en la **misma migración**, `REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM authenticated;`.

**Por qué el `REVOKE` no es opcional.** Sin él, el guard de rol, el gate de plan, el tope de filas, la idempotencia y el todo-o-nada son todos **evitables con una llamada a PostgREST**, que es exactamente lo que el frontend hace hoy y cualquiera con el token de un usuario puede seguir haciendo. Un gate que se puede saltear no es un gate. Como `rpc_import_products` es `SECURITY DEFINER`, sigue pudiendo invocarla; el dueño de la función conserva su `EXECUTE`.

**Precedente y verificación.** Es el mismo movimiento que `20261038000001` hizo con `c28_register_cash_movement` (revocada de `authenticated`, invocable sólo desde otras `SECURITY DEFINER`). Y `service_role` conserva su `EXECUTE`: los jobs administrativos no dependen de esta decisión.

**Qué hay que verificar antes de revocar** (checkpoint 1.5, lección de `tenancy-guard-caja-outbox`): que no quede **ningún** caller de `rpc_bulk_upsert_products` fuera del backend. La lista sale de un grep sobre `frontend/`, `supabase/functions/` y `supabase/tests/`, no del design.

**Decisión de la ronda 3 (F1) — resolución de tenant determinística y cuenta única.** La corrección post-review de la ronda 1 sumó `ORDER BY cai` a la resolución de `v_account_id` de `rpc_import_products` para hacerla determinística — pero **sólo a esa**, no a la de `rpc_bulk_upsert_products` (que la sigue resolviendo sin orden, y que D2 prohíbe tocar más allá de sumar `row` al error). Para un usuario con más de una cuenta, eso las hace **divergir por construcción**: la revisión adversarial midió 6/8 usuarios multi-cuenta sintéticos con el guard evaluando `is_account_writer` sobre una cuenta distinta de la que el upsert usaba para escribir — una **regresión** real, no un candidato (un owner legítimo quedaba rechazado con `P0401`).

La opción determinística que se adopta: `rpc_import_products` vuelve a resolver `v_account_id` con la consulta **literal** de `rpc_bulk_upsert_products` (sin `ORDER BY` — miden 8/8 de acuerdo entre sí sin él) y, además, rechaza explícitamente la ambigüedad — si `current_account_ids()` devuelve más de una fila para el usuario, `rpc_import_products` corta con `P0403` (*"la importación en lote requiere una única cuenta activa"*) en vez de resolver una cualquiera. La importación en lote no tiene selector de cuenta en su contrato (a diferencia del alta de a uno, que no necesita uno porque el usuario ya está "parado" en una cuenta al abrir el formulario), así que ambigüedad honesta es mejor que una resolución que depende del plan de consulta.

Medido en prod el 2026-09-10: **0 usuarios pertenecen hoy a más de una cuenta** (y, por transitividad, 0 cuentas con más de un usuario tienen productos) — este guard no reproduce en ningún caso real hoy, pero cierra el hueco de raíz para cuando `v3-rbac-multirole` haga que la multi-cuenta por usuario deje de ser rara. Gate nuevo (13.x de `test_product_import_batch.sql`): usuario con dos membresías → `P0403`; usuario con una → sigue funcionando igual que en los bloques (2)/(3)/etc.

---

### D5 — El límite de productos del plan se evalúa **sobre el estado resultante**, no adivinando cuántas filas insertarían

**Decisión.** Después de la llamada al upsert y **dentro** del bloque de lote:

```
  SELECT count(*) INTO v_after
    FROM public.products
   WHERE account_id = v_account_id AND deleted_at IS NULL;

  SELECT pl.max_products INTO v_limit
    FROM public.plan_limits pl
   WHERE pl.plan = public.get_effective_plan(v_account_id);

  IF v_limit IS NOT NULL AND v_after > v_limit THEN
    v_plan_exceeded := true;   -- dispara el rollback del lote
  END IF;
```

**Por qué después y no antes.** Calcular *a priori* cuántas filas van a insertar exige replicar el predicado de upsert del bloque (f) —"¿existe un producto vivo de esta cuenta con este SKU, comparando sin distinguir mayúsculas?"— que es precisamente la regla que D1 se compromete a no duplicar. Evaluar el resultado es **exacto por construcción** y **cero duplicación**: el conteo posterior ya incorpora qué filas insertaron y cuáles actualizaron. El costo es un `count(*)` por lote, y el trabajo "desperdiciado" cuando el gate rechaza se deshace igual que cualquier otro rechazo.

**Por qué el plan sale de la base y no del JWT.** `backend/services/products.py:90` lee `auth.get("plan", "pro")` — un claim con **fallback permisivo**: sin claim, todo el mundo es `pro`. La fuente canónica es `get_effective_plan(account_id)`, la misma que usa `reporting_plan_window` para clampear el historial de estadísticas. El importador usa la canónica. (Que el alta de a uno siga usando el claim es un hallazgo lateral, no de este change: OQ-8.)

**Cómo se reconcilia esto con `plan-gating`, que dice las dos cosas.** La spec tiene dos requirements que parecen contradecirse y no lo hacen, porque hablan de capas distintas:

- *"El enforcement del backend deriva el plan del token, no de un valor optimista"* — habla del enforcement que hace **la capa de aplicación** (Python). Este change **no lo toca**.
- *"El límite de historial es enforceable en el servidor, no sólo en la interfaz"* — declara, para el enforcement que vive **dentro del read-model / de la base**, que *"la resolución del plan efectivo SHALL hacerse contra la base por la definición normativa única […] y NOT SHALL derivarse de la información de plan que viaja en el token de acceso: mientras esa información no viaje de forma garantizada, el camino que la lee cae a un valor por defecto permisivo y el límite deja de existir sin que nada falle"*.

El gate de este change vive **dentro de la RPC**, así que le aplica el segundo, palabra por palabra. El delta de `plan-gating` hace explícita esa distinción para que no vuelva a leerse como contradicción.

**Por qué un archivo que sólo actualiza nunca se bloquea.** Si todas las filas resuelven contra productos existentes, `v_after` no crece y el gate no dispara — aunque la cuenta ya esté por encima del tope. Es la conducta correcta: `plan-gating` acota el enforcement a la **creación**, y corregir precios de un catálogo que ya existe no es crear nada.

**Lo que esto rompe, medido.** Cuatro cuentas de prod tienen hoy más productos que el `max_products` de su plan facturado (2.372, 1.473, 545 y 323 contra topes de 100 y 5.000; dos de ellas con `billing_exempt` y todas con `trial_plan = 'pro'`). Para las que su plan efectivo resuelva a `gratis`, **cualquier importación que agregue un producto va a ser rechazada**. Eso ya es cierto en el formulario desde siempre; el importador era la puerta de atrás. Es una decisión de producto, no técnica → **OQ-1**.

---

### D6 — Tope de **2.500 filas por lote** (bajado de 5.000 post-review, ver task 6.9), con rechazo — y explícitamente **sin trocear**

**Decisión.** `p_rows` se acepta con `1..2500` elementos; por encima, `P0427` con el conteo y el tope en el mensaje. `IMPORT_BATCH_SIZE` y `chunkArray` se retiran del cliente.

> **Corrección post-review (2026-09-10, antes de mergear):** el design original recomendaba 5.000 con la task 6.9 (medición del tope real) como precondición de merge — esa task nunca se escribió en el apply. La revisión de código la ejecutó: en la base local del apply, 5.000 filas tardó 33,1s de simulación + 34,2s de confirmación con escalado que reportó como superlineal (200→804ms, 1000→4189ms, 2000→9999ms, 5000→33101ms). Al corregir el hallazgo se aplicó el criterio que OQ-2 ya dejaba escrito ("bajarlo a 2.500 si la medición no acompaña") — **pero la re-medición independiente en la base reconciliada de este worktree no reprodujo esos números**: 200→81ms, 1000→302ms, 2000→566ms, 2500→718ms (dry+real combinado), y `rpc_bulk_upsert_products` invocada DIRECTO a 5.000 filas (bypaseando el tope de `rpc_import_products` para poder medir) tardó 752ms — escalado aproximadamente LINEAL (0,15-0,4 ms/fila), casi dos órdenes de magnitud más rápido que lo reportado. No se pudo determinar la causa de la discrepancia (¿base bajo carga distinta en el momento de la medición original, contención de otro worktree compartiendo el mismo Postgres, algo específico del entorno de esa corrida?) — **se deja 2.500 de todos modos**, no porque el riesgo de superlinealidad se haya confirmado, sino porque el propio D6 original ya lo justificaba en términos independientes de esa medición: sigue cubriendo el mayor lote real (1.393) y el catálogo más grande (2.372) con margen, cuesta cero en usabilidad real, y Docker local no es un proxy confiable del backend en Render free tier + la latencia de red real a Supabase en producción. Ver candidato en `CHANGES.md`: remedir en un entorno más parecido a prod antes de considerar subirlo de nuevo a 5.000.

**Por qué 2.500 y no 500.** El tope tiene que estar por encima del uso real y por debajo de lo absurdo. Medido: el mayor lote real de la historia del producto son **1.393 filas**, el catálogo más grande son **2.372 productos**, y **cero** lotes superaron 2.000. Un tope de 500 (el de gastos) rompería tres casos reales el primer día. (5.000 seguía siendo el `max_products` del plan más alto — con 2.500 el gate que muerde primero para el plan `pro` vuelve a ser el de transporte antes que el de plan, una inversión menor que D6 acepta a cambio del margen de seguridad.)

**Por qué no se trocea.** Trocear es exactamente el fallo parcial que este change viene a eliminar, y además es lo que hoy convierte el tope de 50 categorías nuevas del servidor en un tope por 200 filas. Un archivo por encima de 2.500 se rechaza con el motivo; no se parte en dos transacciones.

**Sobre el costo de las subtransacciones.** Un lote de 2.500 filas abre ~2.501 subtransacciones anidadas en la misma transacción — el upsert **ya** abre una por fila hoy, así que lo que cambia es cuántas viven en la misma transacción, no cuántas se abren. Es una operación puntual de un solo tenant y no compite con el hot path.

---

### D7 — El paso 2 del diálogo pasa a ser una **vista previa validada por el servidor**, usando la misma RPC en simulación

**Decisión.** Al entrar al paso 2, el diálogo llama `POST /products/import` con `dry_run: true`. La RPC ejecuta el lote completo —upsert, categorías, stock, atributos, gate de plan— y lo deshace, devolviendo:

- `errors[]` con `{row, sku, name, message}` — el veredicto real, no una aproximación;
- `inserted` / `updated` — cuántos productos nuevos y cuántas actualizaciones;
- `new_categories` — las que se crearían (**del servidor**, no de la conjetura del cliente);
- el veredicto del gate de plan, con el conteo resultante y el tope.

> **Corrección de la ronda 3 (F2).** El agrupamiento de `new_categories` normalizaba el nombre de cada fila pero no bajaba a minúsculas antes de agrupar — un archivo con "Zapatillas"/"zapatillas"/"ZAPATILLAS" se anunciaba como 3 categorías nuevas cuando el upsert, que sí agrupa case-insensitive, crea 1. Es justo la garantía que el párrafo de arriba promete ("el veredicto real, no una aproximación") y que el delta `product-category` declara normativa. Corregido a agrupar por `lower(product_category_normalize_name(...))`, con un nombre canónico elegido por `min(...)` sobre las variantes de capitalización y la suma de sus filas.

La validación de cliente que ya existe (`validateImportRows`) **se conserva**: es la que produce los avisos de ambigüedad de importes, los duplicados de SKU dentro del archivo y los errores fatales de fila, y es la que evita mandar al servidor un archivo que ya se sabe roto. Las dos capas conviven: el cliente filtra lo evidente, el servidor dicta el veredicto.

**Por qué el veredicto tiene que ser del servidor.** Hoy el paso 2 anuncia qué categorías se van a crear comparando contra el catálogo que el cliente tiene cacheado, y no puede anunciar nada sobre padres inexistentes, colisiones de código de barras, límites de plan o cualquier restricción de base. Con el todo-o-nada de D3, enterarse de eso *después* sería inaceptable. Con la simulación, el usuario ve exactamente lo que va a pasar.

**Costo.** La simulación ejecuta el trabajo dos veces (una que se deshace, una que se confirma). Para el lote más grande medido (1.393 filas) son dos pasadas de un trabajo que hoy ya son siete llamadas HTTP. Se dispara **una vez por archivo elegido**, no por click.

**Confirmar queda deshabilitado mientras haya una sola fila con error**, con el motivo visible. La lógica de "importar las que se pueda" se retira: ya no describe lo que el sistema hace.

---

### D8 — Idempotencia por clave **y** dedupe por archivo, sobre una tabla `product_imports` mínima

**Decisión.** Nace `public.product_imports (id, account_id, user_id, file_name, file_hash, rows_total, inserted, updated, created_at)`, con `UNIQUE (account_id, file_hash)`, RLS de `SELECT` por `current_account_ids()`, `GRANT SELECT` para `authenticated` y **nada de escritura para ningún rol de aplicación**. `operation_idempotency.operation_kind` suma `'product_import'` (la lista viva se lee con `pg_get_constraintdef`, nunca del último archivo que la tocó).

Dos mecanismos, dos modos de falla distintos:

- **Idempotencia técnica** (`operation_idempotency`, molde de `rpc_import_bank_statement`): protege el reintento por red del **mismo** request. `INSERT … ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS ROW_COUNT`; 0 filas → recupera el `operation_id` previo y devuelve `replayed: true`.
- **Dedupe de dominio** (`(account_id, file_hash)`): protege el modo de falla más probable, **volver a subir el mismo archivo**. Sin él, con SKU en el 0,4 % del catálogo, la segunda subida duplica todo.

`product_imports` da además el `operation_id` que el `CHECK` `operation_idempotency_operation_id_contract` exige (sólo `'event_consumer'` y `'subscription_webhook'` están exentos).

**Un lote rechazado no quema la clave ni el hash**: el `INSERT` en `product_imports` y el slot de idempotencia viven **dentro** del bloque de lote, así que el rollback los deshace junto con todo lo demás. Corregir el archivo y reintentar tiene que funcionar.

**Por qué no hay `products.import_id`.** El upsert devuelve conteos, no ids: marcar cada producto con su importación exigiría o cambiar su contrato de retorno (una modificación mucho mayor que la de D2) o inferir los ids por comparación, que es adivinar. Y a diferencia del gasto, un producto no tiene contraparte en ningún libro que haga falta rastrear. Se declara Non-Goal → **OQ-4**.

---

### D9 — La resolución de jerarquía deja de consultar la base desde el navegador; una referencia **explícita** que no resuelve es **error de fila**

**Decisión.** `resolveHierarchy` conserva sus tres estrategias pero **retira las dos consultas a `products`** (`resolver.ts:74-97`):

| Caso | Hoy | Después |
|---|---|---|
| Referencia (SKU o nombre) que resuelve **dentro del lote** | se resuelve en el cliente | igual, sin cambios |
| Referencia explícita que **no** está en el lote | consulta a `products` por `user_id`; si aparece → `parent_id`; si no → cae a estrategia 3 u huérfano | viaja como `sku_parent` / `parent_name`; **el servidor la resuelve por cuenta** y, si no existe, es **error de fila** |
| **Sin** referencia alguna | agrupación secuencial (Padre más cercano arriba); sin ninguno → producto independiente con aviso | igual, sin cambios |

**Por qué se puede retirar la consulta.** Es redundante: el bloque (f) del upsert **ya** resuelve `sku_parent` y `parent_name` contra `products` filtrando por `account_id`, con vivos y con el mismo criterio case-insensitive para el SKU. El cliente estaba haciendo la misma búsqueda con un alcance peor.

**Por qué el cambio de conducta es el correcto.** Un `SKU Padre` que el usuario escribió y que no existe en ningún lado es un error de tipeo; hoy termina creando un **producto independiente en silencio**, que es la clase de default silencioso que el proyecto ya decidió no aceptar (`gastos-forma-pago` D5, `importador-gastos-transaccional` D4: *"un nombre que no resuelve es error de fila, nunca un default silencioso"*). La **ausencia** de referencia sí es una intención inequívoca y conserva su fallback. Con la vista previa de D7, el error se ve antes de escribir nada.

**BREAKING de tenencia, silencioso hoy.** El alcance pasa de `user_id` a `account_id`: un padre creado por **otro miembro de la misma cuenta** empieza a resolver. Hoy no resuelve y la variante se importa huérfana. Es una corrección, no una regresión, pero cambia el resultado de archivos que hoy "andan".

---

### D10 — Plomería HTTP: `POST /products/import`, tres capas, `Idempotency-Key` por header

**Decisión.** Calcado de `bank_reconciliation.py:68-100`:

- **Router** (`backend/routers/products.py`): `idempotency_key = await require_idempotency_key(request, payload.idempotency_key)`, serializa `rows` a JSON y delega. Cero lógica.
- **Service** (`backend/services/products.py`): `require_role(auth, ["user","admin"])` y traducción de los ERRCODEs que sí escapan (los de forma y guards, que son `RAISE` normales). **Cero reglas de dominio nuevas en Python** — si aparece un `if` de negocio, está en la capa equivocada.
- **Repository** (`backend/repositories/product_repository.py`): un solo `fetchrow` de `SELECT public.rpc_import_products($1::text, $2::jsonb, $3::text, $4::text, $5::boolean) AS result`.

**Schemas Pydantic v2** (`backend/schemas/products.py`): `ProductImportRowIn` (la fila normalizada), `ProductImportIn` (`rows` acotado al tope, `file_name`, `file_hash`, `dry_run`, `idempotency_key` como fallback deprecado) y `ProductImportOut` (`committed`, `import_id`, `inserted`, `updated`, `errors[]`, `new_categories[]`, `plan`, `replayed`, `dry_run`).

**El body no lleva `user_id`.** El `p_user_id` que el upsert sigue exigiendo lo pone la RPC de lote desde `auth.uid()`. Es el punto entero del change: la tenencia deja de ser un dato del cliente.

**Un lote rechazado responde `200` con `committed: false` y `errors[]`, no `4xx`.** El rechazo por reglas de fila es un **resultado** del procesamiento, no un error de protocolo; los `4xx` quedan para lo que impide procesar (forma del payload, tope, guards, falta de clave de idempotencia).

---

### D11 — ERRCODEs: se **reutiliza** el vocabulario de lote que `importador-gastos-transaccional` está fijando

**Decisión.** `P0427` (forma del payload / tope de filas / metadata de archivo faltante) y `P0429` (control de flujo del rollback de lote, nunca escapa a la aplicación) — los mismos dos y con la misma semántica que la RPC de lote de gastos. Los guards reusan los que ya existen: `P0403` (sin cuenta), `P0401` (sin rol de escritura), `P0404` (referencia inexistente).

**Por qué reusar y no inventar.** Dos importadores de lote con la misma semántica y dos códigos distintos obligan a dos entradas en el mapa de errores del cliente y a dos redacciones que divergen. El barrido de `P0[0-9]{3}` sobre el repo da hoy `P0001 P0002 P0400 P0401 P0403 P0404 P0409-P0414 P0422-P0426 P0428 P0431-P0434 P0450 P0451 P0999`: `P0427` y `P0429` están libres y `importador-gastos-transaccional` los reserva. El checkpoint 1.4 **re-verifica cuáles quedaron efectivamente en `main`** — si gastos cambió de opinión, este change toma los dos siguientes libres y lo registra.

**Nace un código propio**: `P0430` para el rechazo por límite de plan, porque no es un error de forma ni de fila sino de **cuota**, y el cliente tiene que poder ofrecer "subí de plan" sin parsear un texto.

---

### D12 — Coexistencia con `productos-costo-nullable`: el transporte es **null-preserving** por contrato

**Contexto.** `productos-costo-nullable` (propose ya en `main`, migración `20261042000001`) hace `products.cost` nullable, reescribe `rpc_bulk_upsert_products` para que **deje de imputar `0`** en el alta, y toca `lib/import/validator.ts` + `importer.ts` + `types.ts` para que el validador **deje de defaultear a `0`**. Este change toca los mismos tres archivos y la misma función.

**Decisión.** Este change **se aplica después** y no toca la semántica del costo, pero fija una obligación de contrato que lo hace inmune al orden real: **`ProductImportRowIn.cost` es `Decimal | None` y el transporte propaga `null` como `null`, nunca como `0`**. Lo mismo para `price` y para cualquier campo que el modelo declare opcional. Un schema Pydantic que declarara `cost: Decimal = 0` destruiría la distinción entre "celda vacía" y "cero" **en el transporte**, silenciosamente y sin que ningún test de costo lo note — porque el defecto no estaría en el costo sino en el tubo.

**Consecuencia operativa.** Si por lo que fuera este change se aplicara **antes**, la obligación sigue en pie y no hay nada que rehacer. Si se aplica después (lo esperado), el checkpoint 1.2 obliga a partir del cuerpo vivo ya reescrito por costo-nullable, y las tasks del grupo 8 obligan a **conservar** las aserciones de tri-estado del costo que costo-nullable haya dejado en el validador. → **OQ-9**.

---

### D13 — Qué pasa con lo que hoy existe y este change retira

| Pieza | Destino | Por qué |
|---|---|---|
| `IMPORT_BATCH_SIZE` + `chunkArray` (`types.ts:166`, `importer.ts:100`) | **se retiran** | el troceo es el fallo parcial que el change elimina |
| `createClient()` en `importer.ts:99` y `resolver.ts:74` | **se retiran** | es el objeto del change |
| Las dos consultas a `products` del resolver (L78-97) | **se retiran** | redundantes con el bloque (f) del upsert, y con peor alcance (D9) |
| `lineNumber: 0` (`importer.ts:120`) | **se retira** | el error trae su fila (D2) |
| `parseImportFile`, `validateImportRows`, `parseAmount`/`parseQuantity`/`amountAmbiguityWarning` | **se conservan enteros** | son el parseo canónico y tienen sus tests; D7 los mantiene como primera capa |
| `MAX_NEW_CATEGORIES_PER_IMPORT = 50` y su chequeo de cliente | **se conservan** | siguen siendo el rechazo temprano; lo que cambia es que el del servidor ahora vale también |
| `buildTemplateCsv` y el template de 9 columnas | **sin cambios** | el esquema de columnas no se toca |
| `__tests__/importer-branch-stock-c21.test.ts` | **se reescribe** | assertea el payload contra el mock de `supabase.rpc`; el transporte cambia, el invariante (el stock va a `branch_stock`) no |
| `__tests__/components/product-import-dialog-categories.test.tsx` | **se extiende** | conserva sus casos y suma el veredicto del servidor |

## Risks / Trade-offs

**1. El gate de plan puede dejar sin importar a cuentas reales.** Medido: 4 cuentas por encima del `max_products` de su plan facturado. Si su plan efectivo resuelve a `gratis`, cualquier importación que agregue un producto se rechaza. *Mitigación*: el veredicto aparece en la vista previa, con el conteo y el tope, antes de escribir nada; y la conducta ya es la del formulario desde siempre. *Residuo*: es una decisión de producto, no técnica → OQ-1 con sign-off explícito del PO antes de escribir el gate.

**2. El todo-o-nada es un cambio de UX sobre un flujo que la gente usa.** Un archivo de 600 filas con una mala hoy escribe 599. *Mitigación*: D7 (la vista previa del servidor) es lo que convierte el rechazo en información previa en vez de en una sorpresa. *Residuo*: sigue habiendo un caso en que el usuario prefiere "meté lo que puedas" — declarado fuera por OQ-3.

**3. Dos changes reescriben `rpc_bulk_upsert_products` en la misma ventana.** *Mitigación*: firmas idénticas, adiciones disjuntas, y el checkpoint 1.2 obliga a hashear el cuerpo vivo y a partir de él. *Residuo*: si los dos se aplican el mismo día en paralelo, el segundo tiene que rehacer su `CREATE OR REPLACE` sobre el cuerpo del primero. Es exactamente el escenario que la regla de integridad de función existe para atrapar.

**4. 2.500 subtransacciones en una sola transacción** (bajado de 5.000 post-review — ver D6). El upsert ya abre una por fila; lo que cambia es cuántas conviven. Un backend con más de 64 subxids abiertos desborda su caché y obliga a los demás a consultar `pg_subtrans`. *Mitigación*: la corrección post-review midió el tope real (200/1000/2000/2500/5000, ver D6) — la degradación superlineal que motivó bajar el tope NO se reprodujo en la re-medición independiente, pero el tope se dejó en 2.500 igual, por costar cero en usabilidad real y no depender de esa medición para justificarse (D6 original ya lo hacía). *Residuo*: es una operación puntual, no un hot path; la medición de prod real (Render + latencia de red a Supabase) sigue pendiente — candidato en `CHANGES.md`.

**5. La simulación duplica el trabajo.** *Mitigación*: una vez por archivo elegido, no por click; y el trabajo que duplica hoy son siete round-trips HTTP para el mismo archivo.

**6. `REVOKE` sobre una función del camino de importación.** Si queda un caller no inventariado (una Edge Function, un gate SQL, un script), deja de funcionar sin aviso. *Mitigación*: checkpoint 1.5, grep sobre `frontend/`, `supabase/functions/` y `supabase/tests/`, y la verificación post-merge en prod. *Residuo*: `service_role` conserva su `EXECUTE`, así que ningún job administrativo se ve afectado.

**7. El cambio de alcance de la resolución de padres (D9) altera archivos que hoy "andan".** Una variante que hoy se importa huérfana puede pasar a colgar de un padre de otro miembro de la cuenta, y un `SKU Padre` mal escrito pasa de producto independiente silencioso a error. *Mitigación*: los dos casos son visibles en la vista previa. *Residuo*: es un BREAKING de dominio declarado.

**8. `WHEN OTHERS` del upsert convierte un bug en "error de fila".** Riesgo preexistente que este change **reduce**: hoy un error de programación en una fila deja las otras escritas; después, aborta el lote entero y sale con su `SQLSTATE` y su número de fila. La task 4.6 fija un caso de error estructural para que eso no sea verdadero sólo por omisión.

## Migration Plan

1. **Número de migración**: el siguiente libre en el momento del apply. Hoy están tomadas `20261041000001` (importador de gastos), `20261042000001` (`productos-costo-nullable`) y `20261043000001` (asiento contable de gastos) → **`20261044000001`**, salvo que el checkpoint 1.1 mida otra cosa. Nunca se asume el número del design: en changes anteriores se renumeró hasta tres veces.
2. **Un solo archivo**, idempotente, en este orden:
   a. `CREATE TABLE IF NOT EXISTS public.product_imports` + índices + `ENABLE ROW LEVEL SECURITY` + `DROP POLICY IF EXISTS` / `CREATE POLICY` de `SELECT` + `GRANT SELECT TO authenticated` (y nada más, alineado con `20261035000001_revoke_anon_table_writes.sql`).
   b. `CHECK` de `operation_idempotency.operation_kind` extendido con `'product_import'`, partiendo de la lista **viva** (`pg_get_constraintdef`), con el molde `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` + `COMMENT`.
   c. `CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid)` — **misma firma**, cuerpo vivo + la única adición de D2.
   d. `CREATE OR REPLACE FUNCTION public.rpc_import_products(...)` + ACLs explícitas (`REVOKE ALL FROM PUBLIC`, `REVOKE EXECUTE FROM anon`, `GRANT EXECUTE TO authenticated`).
   e. `REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM authenticated;` — **al final**, después de que la de lote exista.
3. **Sin backfill.** No hay datos históricos que reinterpretar: `product_imports` nace vacía y ningún producto existente cambia.
4. **Reversibilidad.** El único paso no trivialmente reversible es el `REVOKE` (e): re-`GRANT` lo deshace en una línea. La adición de D2 es aditiva y compatible hacia atrás por construcción (`row_no` opcional).
5. **Orden de despliegue.** El backend nuevo y la migración viajan en el mismo PR; el frontend sigue funcionando contra el camino viejo hasta que el `REVOKE` se aplica, así que **el `REVOKE` y el corte del frontend tienen que estar en el mismo merge**. No hay ventana de convivencia: es un merge atómico o una ventana en la que el importador está roto.

## Open Questions

**OQ-1 — ¿El importador aplica el límite de productos del plan?** (D5)
*Recomendación: sí, evaluado sobre el estado resultante y anunciado en la vista previa.* Es lo que `plan-gating` ya declara y lo que el formulario ya hace; el importador es la puerta de atrás. **Pero rechaza importaciones de 4 cuentas reales medidas**, así que necesita sign-off explícito del PO antes de escribirse. Alternativa (b): dejarlo fuera y anotarlo como candidato — el change cierra el resto de los huecos igual.

> **Estado al apply (2026-09-10): SIN SIGN-OFF — NO implementado.** El orquestador del apply no recibió una respuesta explícita del PO sobre esta OQ, así que se aplicó la instrucción por defecto: la task 4.7 (el bloque de código de D5 dentro de `rpc_import_products`) **no se escribió**. Todo lo demás del change está completo e independiente de esta decisión: el todo-o-nada, la idempotencia, el `REVOKE`, el guard de rol de escritura, el número de fila en los errores, la vista previa de servidor y la resolución de jerarquía por cuenta funcionan igual sin el gate de plan.
>
> Lo que quedó preparado para cuando el sign-off llegue, sin que actives esta OQ tengas que rehacer nada:
> - `P0430` está **reservado** en `backend/core/errors.py` (403) con un comentario explícito — activar el gate no exige inventar ni renumerar un ERRCODE.
> - El diseño de D5 (evaluar sobre el estado **resultante**, después de la llamada al upsert, nunca *a priori*) sigue siendo la recomendación vigente — no cambió nada que lo invalide.
> - El frontend NO tiene ningún camino que asuma la ausencia del gate: no hay lógica de "esto nunca se va a rechazar por plan" — simplemente el veredicto de plan no existe todavía en la respuesta (`ProductImportOut` no tiene el campo `plan`).
>
> Candidato para un change de una sola task cuando el PO responda: agregar el bloque de D5 a `rpc_import_products` (dentro de la subtransacción del lote, después de `v_res := ...`), sumar el campo `plan` a `ProductImportOut`/`ProductImportResult`, y un CTA de upgrade en el paso 2 del diálogo. Ninguna otra pieza del change necesita tocarse.

**OQ-2 — ¿El tope por lote es 5.000 filas?** (D6)
*Recomendación original: sí.* Cubre el mayor lote real (1.393), el catálogo más grande (2.372) y coincide con el `max_products` del plan más alto, de modo que el gate que muerde primero sea el de negocio. Si la medición de la task 6.9 muestra degradación, bajarlo a 2.500 sigue cubriendo todo el uso histórico.

> **Resuelta post-review (2026-09-10): bajado a 2.500.** La task 6.9 nunca se ejecutó en el apply original; la revisión de código la corrió y reportó degradación superlineal a 5.000 filas (33,1s + 34,2s). Se aplicó el propio criterio de esta OQ y se bajó a 2.500 — pero la re-medición independiente en la base reconciliada de este worktree **no reprodujo** esa degradación (escalado ~lineal, 5.000 filas en 752ms invocando `rpc_bulk_upsert_products` directo). El tope queda en 2.500 de todos modos: no depende de la medición en disputa para justificarse (ya lo hacía D6 por cobertura de uso real) y no tiene costo real de usabilidad. Detalle completo de ambas mediciones en D6 y `CHANGES.md`.

**OQ-3 — ¿Se conserva algún modo "importar las que se pueda"?** (D3)
*Recomendación: no.* Con SKU en el 0,4 % del catálogo, un import parcial no se puede reintentar sin duplicar; el todo-o-nada + dedupe por hash es lo que hace seguro el reintento. Alternativa (b): un checkbox "importar las filas válidas igual" en el paso 2 — es un segundo modo de escritura con su propia semántica de idempotencia y duplica la superficie de test.

**OQ-4 — ¿Se marca cada producto con la importación que lo creó?** (D8)
*Recomendación: no en este change.* Exige cambiar el contrato de retorno del upsert (una modificación mucho mayor que la de D2) y no habilita ninguna conducta que el change necesite. Si el PO quiere "deshacer una importación", es un change propio.

**OQ-5 — ¿Una referencia explícita de padre que no existe es error de fila?** (D9)
*Recomendación: sí.* Hoy crea un producto independiente en silencio, que es la clase de default silencioso que el proyecto ya decidió no aceptar. Alternativa (b): conservarlo como aviso — pero entonces el usuario nunca se entera de su error de tipeo.

**OQ-6 — ¿El alcance de la resolución de padres pasa a la cuenta?** (D9, BREAKING)
*Recomendación: sí.* Es coherente con la unicidad del SKU y del código de barras, que ya son por cuenta, y con lo que el servidor hace hoy. Hoy conviven dos alcances distintos para la misma búsqueda.

**OQ-7 — ¿Se revoca `rpc_bulk_upsert_products` de `authenticated`?** (D4)
*Recomendación: sí, en la misma migración.* Sin el `REVOKE`, todos los gates que este change agrega son evitables con una llamada a PostgREST. Alternativa (b): diferirlo a un change de hardening — pero entonces este change no cierra los huecos que dice cerrar, sólo los tapa con la UI.

**OQ-8 — El alta de a uno lee el plan del claim del JWT con fallback a `pro`** (`backend/services/products.py:90`), mientras el importador va a usar `get_effective_plan`. ¿Se unifica?
*Recomendación: no en este change* — es un cambio en el hot path del alta de producto, con su propia superficie de test. Anotarlo como candidato con el hallazgo medido.

**OQ-9 — Secuenciación con `productos-costo-nullable` y `importador-gastos-transaccional`.** (D12, D11)
*Recomendación: aplicar este change después de los dos.* Costo-nullable fija la semántica del costo en la misma función y en los mismos archivos del validador; gastos fija los ERRCODEs del lote y el molde de las tres capas. El contrato null-preserving de D12 hace que el orden no pueda romper nada en silencio, pero el orden recomendado ahorra dos reconciliaciones.
