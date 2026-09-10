> **Gobernanza: MEDIA.** El change no escribe dinero, pero cierra dos huecos de autorización (rol de escritura y límite de plan) y **revoca** una función que hoy es el camino de importación en producción. Los grupos 3, 4 y 5 se implementan en pasos con checkpoint visible; nada de SQL se escribe antes de cerrar el grupo 1.
>
> **Sign-off previo obligatorio del PO sobre OQ-1** (aplicar el límite de plan al importar): rechaza importaciones de cuentas reales medidas. Sin su respuesta, el grupo 4.7 no se escribe y el resto del change sigue en pie.
>
> **Strict TDD activo.** Cada grupo con lógica arranca por su test en rojo. El grupo 2 es el SAFETY NET y no es opcional.

## 1. Checkpoints previos — medir el estado vivo antes de escribir una línea de SQL

- [ ] 1.1 Confirmar `MAX(version)` de `supabase_migrations.schema_migrations` en la base local **y en prod**, y fijar el número de la migración nueva **en ese momento**. El design apunta a `20261044000001` (tras gastos `…41`, costo-nullable `…42` y asiento contable de gastos `…43`), pero en changes anteriores se renumeró hasta tres veces por PRs en paralelo. Nunca asumir el número del design.
- [ ] 1.2 Hashear el cuerpo **vivo** de `public.rpc_bulk_upsert_products(jsonb, uuid)` y compararlo contra el registrado en el design (`d76c6b6b232ef8b6fd956def9597005d`, base local con `MAX(version) = 20261040000001`). **Se espera que difiera** si `productos-costo-nullable` ya mergeó: en ese caso el `CREATE OR REPLACE` de D2 parte del cuerpo vivo, **jamás** del que este design transcribe. (Comparar por líneas con `\r` stripped: el checkout Windows introduce CRLF y falsea el md5.)
- [ ] 1.3 Hashear el cuerpo vivo de `public.rpc_import_bank_statement(text,uuid,text,text,jsonb)` (el molde de idempotencia/dedupe) y, si ya está en `main`, el de `public.rpc_import_expenses(...)` de `importador-gastos-transaccional` (el molde de veredicto de lote + `p_dry_run`). Copiar de ellos, no reinventar.
- [ ] 1.4 Leer con `pg_get_constraintdef` la definición **viva** del `CHECK` de `operation_idempotency.operation_kind` y copiar de ahí la lista completa de kinds — **nunca** del último archivo de migración que lo tocó. Confirmar en la misma pasada qué ERRCODEs dejó efectivamente `importador-gastos-transaccional` (`P0427` / `P0429` según su design) y que `P0430` sigue libre; barrido de `P0[0-9]{3}` sobre `supabase/migrations/`, `backend/` y `frontend/lib`.
- [ ] 1.5 **Inventario de callers de `rpc_bulk_upsert_products`** — la lista sale del grep, no del design (lección de `cobranzas-catalogo-pagos` checkpoint 1.6). Barrer `frontend/`, `supabase/functions/`, `supabase/tests/` y `backend/`. Sin este inventario cerrado, el `REVOKE` de D4 no se escribe. Los gates SQL conocidos que la invocan son al menos `test_bulk_upsert_products_categories.sql`, `test_products_barcode_account_scope.sql` y `test_product_category_derived.sql`: verificar con qué rol corren (si corren como `postgres`, el `REVOKE` de `authenticated` no los afecta; si no, hay que ajustarlos).
- [ ] 1.6 Grep de callers reales de `importProductsFromFile`, `resolveHierarchy`, `validateImportRows`, `parseImportFile` y `IMPORT_BATCH_SIZE`. Confirmar que `parseImportText` sigue siendo usado sólo por tests.
- [ ] 1.7 Verificar contra el cuerpo vivo que `rpc_bulk_upsert_products` sigue **sin** guard de `is_account_writer` y que sigue haciendo el *lazy-create* de la sucursal `'Casa Central'` (los dos son supuestos del design que hay que reconfirmar, no dar por ciertos).
- [ ] 1.8 Medir en prod, para el registro del change (el "antes" del que se hablará al archivar): productos vivos por cuenta, cuántas cuentas superan el `max_products` de su **plan efectivo** (`get_effective_plan`, no el facturado), productos con SKU, y el mayor lote histórico por minuto. El design registra 4.953 / 5 cuentas > 100 / 18 con SKU / 1.393 filas al 2026-09-10.

## 2. SAFETY NET — baseline antes de tocar nada

- [ ] 2.1 Correr `backend/tests/test_products*.py` y registrar el conteo.
- [ ] 2.2 Correr los archivos de frontend que tocan el importador y registrar sus conteos: `__tests__/importer-branch-stock-c21.test.ts`, `__tests__/components/product-import-dialog-categories.test.tsx`, `__tests__/lib/import-validator-{categories,quantities,amount-ambiguity}.test.ts`, `__tests__/components/product-catalog-sku-bulk.test.tsx`.
- [ ] 2.3 Correr la suite completa de backend y de frontend y registrar los dos totales. Todo fallo previo se declara **pre-existente** y no se arregla acá (conocidos: `AdminSegurosPage.test.tsx` flaky bajo carga).
- [ ] 2.4 Dejar por escrito, **antes** de tocar el código, qué aserciones de qué archivos van a cambiar y por qué (D13 del design). Sin esto, romperlas se leerá como "baseline distinto" en vez de como la inversión deliberada que es.
- [ ] 2.5 Correr la tanda completa de gates SQL en el orden real de `KPI_Validation.yml` contra una base recién reseteada y registrar los fallos pre-existentes conocidos (`test_cuentas_billetera_tipo.sql` por artefacto de invocación local; el paso de reaplicación de idempotencia roto en `main`).

## 3. Migración — tabla de importaciones, `CHECK` y permisos

- [ ] 3.1 RED: bloque del gate SQL que verifica la existencia y la forma de `public.product_imports` (columnas, PK, `UNIQUE (account_id, file_hash)`, RLS habilitada, policy de `SELECT` por `current_account_ids()`) y `'product_import'` dentro del `CHECK` vivo. Debe fallar.
- [ ] 3.2 Crear el archivo de migración con el número de 1.1 y el encabezado documentado del repo (qué hace, por qué, idempotencia, ERRCODEs).
- [ ] 3.3 `CREATE TABLE IF NOT EXISTS public.product_imports (...)` + índices + `ENABLE ROW LEVEL SECURITY` + `DROP POLICY IF EXISTS` / `CREATE POLICY` de `SELECT` — copia literal del alcance de `bank_statement_imports_select`.
- [ ] 3.4 `GRANT SELECT ON public.product_imports TO authenticated;` y **nada más**: sin `INSERT`/`UPDATE`/`DELETE` para ningún rol de aplicación, sin nada para `anon` (alineado con `20261035000001_revoke_anon_table_writes.sql`).
- [ ] 3.5 Extender el `CHECK` de `operation_idempotency.operation_kind` con `'product_import'` usando la lista viva de 1.4, con el molde `DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` + `COMMENT`.
- [ ] 3.6 GREEN: aplicar la migración contra la base local y ver el bloque de 3.1 en verde.
- [ ] 3.7 Verificar idempotencia: reaplicar el archivo completo sobre la misma base y confirmar que no falla ni duplica nada.

## 4. `rpc_import_products` — la unidad de trabajo

- [ ] 4.1 RED: bloque del gate "**todo o nada**" — lote de 3 filas con la 2.ª inválida (referencia a un padre inexistente) → `committed=false`, `errors[].row = 2`, y **cero** filas nuevas en `products`, `product_categories`, `branch_stock`, `product_attributes`, `product_imports` y `operation_idempotency`.
- [ ] 4.2 GREEN mínimo: crear la función con guards (`auth.uid()`, cuenta por `current_account_ids()`, `is_account_writer` → `P0401`), validación de forma del payload y de metadata del archivo (`P0427`: array, `1..5000`, `file_name`/`file_hash` obligatorios) y el bloque de lote con `EXCEPTION WHEN SQLSTATE 'P0429'`. Dejar por escrito en el cuerpo **las dos propiedades de PL/pgSQL de las que depende el diseño** (la subtransacción deshace el estado de base; las variables locales sobreviven).
- [ ] 4.3 Implementar el corazón: **una sola** invocación `v_res := public.rpc_bulk_upsert_products(p_rows, auth.uid());`. Comentar en el cuerpo por qué es una sola y no una por fila (el tope de categorías nuevas de D1). **Cero reglas del upsert copiadas.**
- [ ] 4.4 TRIANGULAR: bloque del **camino feliz** — 3 filas válidas (un producto simple, un padre y su variante) → 3 productos, jerarquía resuelta, `branch_stock` en la sucursal por defecto, fila en `product_imports`, `committed=true`.
- [ ] 4.5 RED + GREEN: **el tope de categorías nuevas se evalúa sobre el archivo**. Caso obligatorio: un archivo con más de 50 categorías nuevas distintas cuya **primera mitad por sí sola no las supera** → rechazo, y **cero** categorías de la primera mitad creadas. Sin este caso, "el tope pasó a ser por archivo" sería verdadero por omisión.
- [ ] 4.6 RED + GREEN: **error estructural** (no de dominio) en una fila → aborta el lote entero y aparece con su `SQLSTATE` y su número de fila. El `WHEN OTHERS` del upsert no puede convertir un bug en "una fila que no entró".
- [ ] 4.7 RED + GREEN (**sólo con sign-off de OQ-1**): gate de plan sobre el estado resultante — `count(*)` de productos vivos de la cuenta contra `plan_limits.max_products` de `get_effective_plan(account_id)`, con `P0430`. Tres casos: lote que cruza el tope → rechazo entero con el conteo y el tope; lote que **sólo actualiza** con la cuenta ya en excedente → **permitido**; plan sin fila en `plan_limits` → no bloquea (fail-open explícito y comentado, para no romper un plan nuevo sin límite cargado).
- [ ] 4.8 RED + GREEN: idempotencia por clave (`ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS`, molde de 1.3) y dedupe por `(account_id, file_hash)`; y el caso de que un **lote rechazado no queme la clave ni el hash**.
- [ ] 4.9 RED + GREEN: `p_dry_run` — sobre un lote válido devuelve `committed=false` con `inserted`/`updated`/`new_categories` de lo que habría entrado y **cero** escrituras en las seis tablas de 4.1.
- [ ] 4.10 RED + GREEN: **equivalencia con la llamada directa** — el mismo archivo importado por `rpc_import_products` y por `rpc_bulk_upsert_products` produce los mismos productos, la misma jerarquía y el mismo `branch_stock`. Es la verificación de que la llamada anidada `SECURITY DEFINER` no cambia la resolución de `auth.uid()` / `current_account_ids()`.
- [ ] 4.11 RED + GREEN: **tenencia** — un archivo que referencia por SKU un padre de **otra** organización → error de fila, lote rechazado, y **nada tocado en la otra organización**.
- [ ] 4.12 RED + GREEN: tope (5.001 filas → `P0427`) y lote vacío → rechazo sin escrituras.
- [ ] 4.13 ACLs en el **mismo archivo** de migración: `REVOKE ALL FROM PUBLIC`, `REVOKE EXECUTE FROM anon`, `GRANT EXECUTE TO authenticated` sobre `rpc_import_products`. Bloque de gate que lo verifica.
- [ ] 4.14 REFACTOR: releer el cuerpo completo buscando cualquier regla del upsert que se haya colado duplicada (resolución de SKU, de padre, de categoría, sucursal por defecto). Si aparece una, se borra y se delega — es el invariante del change.

## 5. La única modificación del upsert, y el `REVOKE`

- [ ] 5.1 RED: bloque del gate que importa un lote con una fila inválida y assertea que el error trae `row` con el número de fila de esa fila. Debe fallar contra el cuerpo actual.
- [ ] 5.2 `CREATE OR REPLACE FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid)` partiendo del **cuerpo vivo de 1.2**, con **la misma firma**, agregando únicamente `'row', (v_row->>'row_no')::int` al `jsonb_build_object` del error. Nada más. Diff revisado línea por línea contra el cuerpo vivo antes de aplicar.
- [ ] 5.3 GREEN + caso de compatibilidad: una fila **sin** `row_no` produce `row: null` y todo lo demás idéntico — un caller viejo no puede romperse.
- [ ] 5.4 (**sólo con el inventario de 1.5 cerrado**) `REVOKE EXECUTE ON FUNCTION public.rpc_bulk_upsert_products(jsonb, uuid) FROM authenticated;` al **final** del archivo, después de que `rpc_import_products` exista. Confirmar que `service_role` conserva su `EXECUTE`.
- [ ] 5.5 Bloque de gate de ACLs: `rpc_bulk_upsert_products` **sin** `EXECUTE` para `authenticated` ni `anon`; `rpc_import_products` con `EXECUTE` para `authenticated` y sin él para `anon`. Verificar que el chequeo (3)/(4) del gate de ACLs existente no se rompa con la función nueva.
- [ ] 5.6 Ajustar los gates SQL de 1.5 que invocan `rpc_bulk_upsert_products` si el `REVOKE` los afecta, y volver a correrlos.

## 6. Gate SQL y cableado en CI

- [ ] 6.1 Consolidar los bloques de los grupos 3, 4 y 5 en `supabase/tests/test_product_import_batch.sql`, con el estilo de los ~40 gates existentes (fixtures propias, cleanup que se assertea, `RAISE EXCEPTION` con mensaje explícito por bloque).
- [ ] 6.2 Verificar que el cleanup del gate **no deja huérfanos** (lección de `test_admin_kpis.sql`: `session_replication_role = replica` no cascadea; ojo con `product_categories`, `branch_stock` y `product_attributes`).
- [ ] 6.3 Cablearlo en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1`, junto a los demás.
- [ ] 6.4 Correr el gate nuevo y **la tanda completa de gates SQL en el orden real del workflow** contra una base recién reseteada; comparar contra el baseline de 2.5.

## 7. Backend — schemas, repository, service, router (3 capas)

- [ ] 7.1 RED: test en `backend/tests/test_product_import.py` que assertea el contrato del repository (una sola llamada, orden posicional exacto de los parámetros de la RPC, `rows` serializado a JSON).
- [ ] 7.2 Schemas en `backend/schemas/products.py`: `ProductImportRowIn`, `ProductImportIn` (`rows` acotado al tope, `file_name`, `file_hash`, `dry_run`, `idempotency_key` como fallback deprecado) y `ProductImportOut` (`committed`, `import_id`, `inserted`, `updated`, `errors[]`, `new_categories[]`, `plan`, `replayed`, `dry_run`). **Sin ningún campo opcional con default numérico** (D12).
- [ ] 7.3 **Test dedicado del contrato null-preserving** (D12): una fila con `cost` ausente llega al repository como `null`, **no** como `0`. Este test es el que impide que el transporte destruya en silencio la distinción de `productos-costo-nullable`, y ninguna prueba de costo lo cubriría.
- [ ] 7.4 `ProductRepository.import_batch(...)` — un `fetchrow`, espejo de `BankReconciliationRepository.import_statement` (`backend/repositories/bank_reconciliation_repository.py:35-53`).
- [ ] 7.5 Service: `require_role(auth, ["user","admin"])` + traducción de los ERRCODEs que sí escapan. **Cero reglas de dominio nuevas en Python** — si aparece un `if` de negocio, está en la capa equivocada. El `user_id` **no** se lee del payload: la RPC lo deriva de `auth.uid()`.
- [ ] 7.6 Router `POST /products/import` con `require_idempotency_key(request, payload.idempotency_key)`, calcado de `backend/routers/bank_reconciliation.py:68-100`. Declarado **antes** de las rutas `/{product_id}` para que `"import"` nunca se lea como un id (mismo cuidado que `bulk-category`, `routers/products.py:49`).
- [ ] 7.7 Registrar `P0427` (si no lo dejó gastos) y `P0430` en `backend/core/errors.py` con su status (422 y 403 respectivamente) y su `field`.
- [ ] 7.8 TRIANGULAR: tests de service/router para lote aplicado, lote rechazado (**`200` con `errors[]`, no `4xx`**), simulación, replay por clave, replay por hash, sin rol de plataforma, y sin clave de idempotencia (422).
- [ ] 7.9 Test que verifica explícitamente que **después de un lote rechazado la conexión sigue usable** (no queda en `25P02`): es la razón de ser de D3 y hoy no hay nada que lo fije.
- [ ] 7.10 Test del lote en el tope (5.000 filas) que mide que la transacción termina en un tiempo razonable — el insumo de OQ-2.

## 8. Frontend — pipeline de importación

- [ ] 8.1 RED: test del transporte (payload exacto, `Idempotency-Key` en `extraHeaders`, **una sola** llamada para todo el archivo, `row_no` por fila).
- [ ] 8.2 Tipos del lote en `frontend/lib/types.ts` — **sin `any`**, en la capa canónica y no dentro del componente.
- [ ] 8.3 `importer.ts`: retirar `createClient()` (L99), `chunkArray` y el bucle de trozos (L100-133); una sola llamada por `pythonClient.post(path, body, extraHeaders)` (`lib/api/python-client.ts:52-57`). `toPayload` suma `row_no` desde `lineNumber` y **preserva `null`** donde el modelo lo admita.
- [ ] 8.4 `types.ts`: retirar `IMPORT_BATCH_SIZE`. Confirmar por grep que no queda ningún consumidor (regla: nada de código muerto exportado).
- [ ] 8.5 `resolver.ts`: retirar `createClient()` (L74) y las dos consultas a `products` (L78-97). La firma deja de necesitar `userId`; una referencia explícita no resuelta en el lote viaja como `sku_parent` / `parent_name` y la resuelve el servidor (D9). Conservar intactas la agrupación secuencial y la política de huérfano sin referencia.
- [ ] 8.6 Hash del archivo con `hashFileSHA256` (`frontend/lib/bank-statement-parser.ts:213`). **No escribir un segundo hasher.**
- [ ] 8.7 La clave de idempotencia se genera **una vez por archivo elegido**, no por click: reintentar el mismo lote tiene que ser un replay, no un segundo lote. Y la simulación y la confirmación del mismo archivo NO comparten clave (la simulación no debe quemarla).
- [ ] 8.8 Mutación de lote en `frontend/hooks/data/use-products.ts` con invalidación **una sola vez** al confirmar (productos, categorías y stock por sucursal — el importador escribe los tres).
- [ ] 8.9 Reescribir `__tests__/importer-branch-stock-c21.test.ts`: el invariante que assertea (el stock del CSV va a `branch_stock`) **no cambia**; lo que cambia es el mock (deja de ser `supabase.rpc` y pasa a ser el cliente HTTP). Justificar por escrito cada aserción que cambie.

## 9. Frontend — el diálogo de importación

- [ ] 9.1 RED: extender `__tests__/components/product-import-dialog-categories.test.tsx` con el veredicto del servidor, **conservando** sus casos actuales.
- [ ] 9.2 Paso 2: disparar la **simulación** al entrar, con estado de carga, y renderizar el veredicto del servidor por fila (número de fila, estado, motivo) **además** de la validación de cliente que ya existe (`validateImportRows`, `product-import-dialog.tsx:187`).
- [ ] 9.3 Paso 2: el anuncio de categorías a crear pasa a leerse del veredicto del servidor (conservando el del cliente como aviso temprano), y el veredicto del gate de plan se muestra con el conteo resultante y el tope, con CTA de upgrade cuando corresponda.
- [ ] 9.4 Paso 2: **deshabilitar la confirmación mientras haya una sola fila con error**, con el motivo visible. Retirar la lógica y la redacción de "importar las que se pueda".
- [ ] 9.5 Paso 3: resultado del lote (creados, actualizados, categorías creadas, aviso de repetición si corresponde). Retirar `lineNumber: 0` de la lista de errores: ahora todos tienen fila.
- [ ] 9.6 Paso 1: revisar el texto de ayuda — el tope de filas nuevo y el todo-o-nada tienen que estar dichos ahí, no descubrirse en el paso 2. El template y el esquema de columnas **no cambian**.
- [ ] 9.7 Verificar que los estados de fila usan tokens semánticos (`RowStatusIcon`, L96-104, ya usa `text-destructive`/`text-warning`/`text-success` — confirmar que ninguna adición nueva vuelve a literales) — es lo que exige el gate `token-contrast-aa`.
- [ ] 9.8 Test de a11y del diálogo (estado de carga anunciado, tabla de revisión navegable, motivo del bloqueo asociado al botón deshabilitado).

## 10. Verificación

- [ ] 10.1 Backend: suite completa verde y cobertura ≥ el umbral de CI. Comparar contra el baseline de 2.3.
- [ ] 10.2 Frontend: suite completa verde. Comparar contra 2.3 y justificar por escrito **cada** aserción que cambió (el listado de 2.4).
- [ ] 10.3 `tsc` sin errores nuevos.
- [ ] 10.4 `supabase db reset` local con la migración nueva incluida: aplica limpio desde cero.
- [ ] 10.5 Tanda completa de gates SQL en el orden real del workflow (6.4).
- [ ] 10.6 **Pasada visual obligatoria** (regla PO 2026-08-02): los tres pasos del diálogo en **desktop y móvil (375 px)**, en **claro y oscuro** — cuatro combinaciones. Verificar explícitamente que a 375 px la tabla del paso 2 scrollea **dentro de su contenedor**, que el documento no se ensancha y que el botón de confirmación queda alcanzable.
- [ ] 10.7 Humo local de punta a punta con un CSV real de ≥ 50 filas mezclando: producto simple, padre + variantes, variante con `SKU Padre` inexistente, categoría nueva, stock decimal, precio ambiguo (`1.500`), SKU repetido dentro del archivo. Verificar en la base que el rechazo no dejó **nada** y que el archivo corregido dejó **todo**.
- [ ] 10.8 Humo de repetición: reintentar el mismo lote (misma clave) y volver a subir el mismo archivo (otra clave) — las dos veces sin segundo lote y sin catálogo duplicado.
- [ ] 10.9 Humo del `REVOKE`: intentar `rpc_bulk_upsert_products` directamente con un token de usuario autenticado contra el stack local y confirmar el rechazo por permiso.
- [ ] 10.10 Humo de rol: un miembro de sólo lectura intenta importar → rechazado, cero escrituras.

## 11. Documentación y cierre del propose

- [ ] 11.1 Entrada propia en `CHANGES.md` con lo verificado, los hallazgos reales del apply y los candidatos que el change deje abiertos (al menos OQ-4 y OQ-8).
- [ ] 11.2 Actualizar el puntero de "próximo change" en `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** (gate `Docs Sync`).
- [ ] 11.3 Registrar las respuestas del PO a las nueve OQs del design (cuáles se aplicaron y cuáles quedaron abiertas), con OQ-1 explícitamente firmada antes del grupo 4.7.
- [ ] 11.4 `npx openspec validate --changes --strict` y, al archivar, `--specs --strict` con el conteo de capabilities que corresponda (98 + 1 por este change, más las que hayan aportado los changes que mergeen antes).

## 12. Post-merge en producción (sólo lectura, salvo el humo del PO)

- [ ] 12.1 `MAX(version)` en prod = la migración de 1.1, y el conteo total de migraciones esperado.
- [ ] 12.2 ACLs vivas: `rpc_import_products` con `EXECUTE` para `authenticated` y sin él para `anon`; **`rpc_bulk_upsert_products` sin `EXECUTE` para `authenticated` ni `anon`**, con `service_role` intacto; `product_imports` sin `INSERT`/`UPDATE`/`DELETE` para ningún rol de aplicación.
- [ ] 12.3 Una sola definición viva de `rpc_import_products` (sin overload) y `rpc_bulk_upsert_products` **con la misma firma** que antes del change — la prueba de que la modificación fue quirúrgica y no un `DROP` + `CREATE` encubierto.
- [ ] 12.4 Auditoría del punto de partida: cero filas en `product_imports` antes del primer uso real.
- [ ] 12.5 Re-medir el conteo de cuentas que superan el `max_products` de su plan efectivo (1.8) y dejarlo registrado: es la población que el gate de OQ-1 va a empezar a rechazar.
- [ ] 12.6 **Humo real del PO**: importar un archivo propio de su catálogo, con al menos un padre con variantes y una categoría nueva. Verificar con él: que la revisión muestra el veredicto del servidor antes de confirmar, que un archivo con una fila mala no escribe nada, que el archivo corregido entra completo, y que volver a subir el mismo archivo no duplica nada.
