> **Gobernanza: MEDIA con tramo ALTO.** El lote escribe dinero real en `bank_movements` desde una RPC `SECURITY DEFINER`. Los grupos 3, 4 y 5 se implementan en pasos con checkpoint visible; nada de SQL se escribe antes de cerrar el grupo 1.
>
> **Strict TDD activo.** Cada grupo con lógica arranca por su test en rojo. El grupo 2 es el SAFETY NET y no es opcional: hay tests vivos que assertan **exactamente lo contrario** de lo que este change implementa (D13 del design).

## 1. Checkpoints previos — medir el estado vivo antes de escribir una línea de SQL

- [ ] 1.1 Confirmar `MAX(version)` de `supabase_migrations.schema_migrations` en la base local y en prod, y fijar el número de la migración nueva **en ese momento** (se corrió tres veces en changes anteriores por PRs en paralelo; nunca asumir el número del design).
- [ ] 1.2 Hashear el cuerpo **vivo** de `public.rpc_create_expense(text,numeric,date,text,uuid,uuid,uuid,uuid,uuid)` y compararlo contra el registrado en el design (`4a31c7c6911fe247c76d243eff3e445e`). Si difiere: **parar** y releer el cuerpo vivo antes de seguir — el lote depende de sus guards y de su firma posicional exacta. (Recordatorio: comparar por líneas con `\r` stripped; el checkout Windows introduce CRLF y falsea el md5.)
- [ ] 1.3 Hashear el cuerpo vivo de `public._pay_resolve_bank_account(uuid,uuid,uuid)` (`7f2eb5b2d77df3c4059b22914efafd01`) y de `public.rpc_import_bank_statement(text,uuid,text,text,jsonb)` (`c02591027281475af21dc1600f7a1132`), que es el molde que se copia.
- [ ] 1.4 Leer la definición **viva** del `CHECK` de `operation_idempotency.operation_kind` con `pg_get_constraintdef` y copiar de ahí la lista completa de kinds — **nunca** del último archivo de migración que lo tocó.
- [ ] 1.5 Confirmar que `P0427` y `P0429` siguen libres (barrido de `P0[0-9]{3}` sobre `supabase/migrations/`, `backend/` y `frontend/lib`).
- [ ] 1.6 Grep de callers reales de `useBulkAddExpense` y de `parseAndValidate` del importador: la lista de consumidores a migrar tiene que salir del grep, no del design (lección de `cobranzas-catalogo-pagos`, checkpoint 1.6, que encontró 4 callers no previstos).
- [ ] 1.7 Medir en prod, para el registro del change: cuántos gastos existen hoy con `payment_method_id IS NULL`, cuántos con `branch_id IS NULL` y cuántos con `cost_center_id IS NULL` (el "antes" del que se hablará al archivar).

## 2. SAFETY NET — baseline antes de tocar nada

- [ ] 2.1 Correr `backend/tests/test_expenses.py` y registrar el conteo. Es el archivo que cubre el CRUD que este change extiende.
- [ ] 2.2 Correr los cinco archivos de frontend que tocan el importador y el hook y registrar sus conteos: `expense-import-dialog-{no-payment-method,invalidation,parse-and-validate,amount-ambiguity}.test.*` y `hooks/use-expenses.test.ts` + `hooks/use-expenses-payment-method.test.ts`.
- [ ] 2.3 Correr la suite completa de backend y de frontend y registrar los dos totales. Todo fallo previo se declara **pre-existente** y no se arregla acá.
- [ ] 2.4 Dejar por escrito, antes de tocar el código, **qué aserciones de qué archivos van a cambiar y por qué** (D13 del design): sin esto, romper esas aserciones se leerá como "baseline distinto" en vez de como la inversión deliberada que es.

## 3. Migración — tabla, columna, `CHECK` y permisos

- [ ] 3.1 RED: escribir el bloque del gate SQL que verifica la existencia y la forma de `public.expense_imports` (columnas, PK, `UNIQUE (account_id, file_hash)`, RLS habilitada, policy de `SELECT` por `current_account_ids()`), de `public.expenses.import_id` (nullable, FK, índice) y de `'expense_import'` dentro del `CHECK`. Debe fallar.
- [ ] 3.2 Crear el archivo de migración con el número de 1.1 y el encabezado documentado del repo (qué hace, por qué, idempotencia, ERRCODEs).
- [ ] 3.3 `CREATE TABLE IF NOT EXISTS public.expense_imports (...)` + índices + `ENABLE ROW LEVEL SECURITY` + `DROP POLICY IF EXISTS` + `CREATE POLICY` de `SELECT` — copia literal del alcance de `bank_statement_imports_select`.
- [ ] 3.4 `GRANT SELECT ON public.expense_imports TO authenticated;` y **nada más**: sin `INSERT`/`UPDATE`/`DELETE` para ningún rol de aplicación, sin nada para `anon` (alineado con `20261035000001_revoke_anon_table_writes.sql`).
- [ ] 3.5 `ALTER TABLE public.expenses ADD COLUMN IF NOT EXISTS import_id uuid;` + FK con `DROP CONSTRAINT IF EXISTS` previo + `CREATE INDEX IF NOT EXISTS`.
- [ ] 3.6 Extender el `CHECK` de `operation_idempotency.operation_kind` con `'expense_import'` usando la lista viva de 1.4, con el molde de `20260805000001:81-110` (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` + `COMMENT`).
- [ ] 3.7 GREEN: correr la migración contra la base local y ver el bloque de 3.1 en verde.
- [ ] 3.8 Verificar idempotencia: reaplicar el archivo completo sobre la misma base y confirmar que no falla ni duplica nada.

## 4. `rpc_import_expenses` — la unidad de trabajo

- [ ] 4.1 RED: bloque del gate "**todo o nada**" — lote de 3 filas con la 2.ª inválida → `committed=false`, `errors[].row = 2`, y **cero** filas nuevas en `expenses`, `bank_movements`, `cash_movements`, `expense_imports` y `operation_idempotency`.
- [ ] 4.2 GREEN mínimo: crear la función con guards de sesión/tenant/writer, validación de forma del payload (`P0427`: array, 1..500, shape mínimo por fila) y el bloque de lote con `EXCEPTION WHEN SQLSTATE 'P0429'`. Dejar por escrito en el cuerpo **las dos propiedades de PL/pgSQL de las que depende el diseño** (la subtransacción deshace el estado de base; las variables locales sobreviven).
- [ ] 4.3 TRIANGULAR: bloque del **camino feliz** — 3 filas válidas (una `cash`, una `transfer`, una sin forma de pago) → 3 gastos, **1** movimiento bancario, **0** movimientos de caja, `import_id` poblado en las tres, fila en `expense_imports`.
- [ ] 4.4 Implementar el loop por fila con su subtransacción y el `PERFORM public.rpc_create_expense(...)` — con `p_cash_session_id := NULL` **literal y comentado** (D6), y el `UPDATE expenses SET import_id = ...` posterior.
- [ ] 4.5 RED + GREEN: resolución por **nombre** de forma de pago, sucursal y centro de costo (`lower(btrim(...))`, sólo filas activas y no borradas de la cuenta), con defaults de lote y **error de fila** —nunca default silencioso— cuando el nombre no resuelve; el mensaje lista los nombres válidos.
- [ ] 4.6 RED + GREEN: respaldo de cuenta bancaria — el destino configurado en la forma de pago **conserva la precedencia**; el respaldo del lote sólo se aplica cuando `_pay_resolve_bank_account(cuenta, pm, NULL)` devuelve `NULL`. Caso negativo obligatorio: con destino configurado y respaldo distinto, el movimiento va contra el **configurado**.
- [ ] 4.7 RED + GREEN: **control negativo de D6** — fila en efectivo **fechada hoy** con sesión de caja **abierta** en la sucursal → el gasto entra y `cash_movements` **no crece**. Sin este caso, "el lote nunca toca caja" sería verdadero por omisión.
- [ ] 4.8 RED + GREEN: idempotencia por clave (`ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS`, molde de `rpc_import_bank_statement`) y dedupe por `(account_id, file_hash)`; y el caso de que un lote **rechazado no queme la clave**.
- [ ] 4.9 RED + GREEN: `p_dry_run` — sobre un lote válido devuelve `committed=false` con el conteo de las filas que habrían entrado y **cero** escrituras en las cinco tablas.
- [ ] 4.10 RED + GREEN: **equivalencia con el alta directa** — el mismo gasto creado por el lote y por `rpc_create_expense` produce el mismo gasto y el mismo movimiento bancario. Es la verificación de que la llamada anidada `SECURITY DEFINER` no cambia la resolución de `auth.uid()` / `current_account_ids()`.
- [ ] 4.11 RED + GREEN: **tenencia** — forma de pago, sucursal, centro de costo y cuenta bancaria de **otra** organización → error de fila, lote rechazado, y **nada tocado en la otra organización**.
- [ ] 4.12 RED + GREEN: tope (501 filas → `P0427`) y lote vacío → rechazo sin escrituras.
- [ ] 4.13 ACLs en el **mismo archivo** de migración: `REVOKE ALL FROM PUBLIC`, `REVOKE EXECUTE FROM anon`, `GRANT EXECUTE TO authenticated`. Bloque de gate que lo verifica.
- [ ] 4.14 REFACTOR: releer el cuerpo completo buscando cualquier regla del alta que se haya colado duplicada. Si aparece una, se borra y se delega — es el invariante del change.

## 5. Gate SQL y cableado en CI

- [ ] 5.1 Consolidar los bloques de los grupos 3 y 4 en `supabase/tests/test_expense_import_batch.sql`, con el estilo de los ~40 gates existentes (fixtures propias, cleanup que se assertea, `RAISE EXCEPTION` con mensaje explícito por bloque).
- [ ] 5.2 Verificar que el cleanup del gate **no deja huérfanos** (lección de `test_admin_kpis.sql`: `session_replication_role = replica` no cascadea).
- [ ] 5.3 Cablearlo en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1`, junto a los demás.
- [ ] 5.4 Correr el gate nuevo y **la tanda completa de gates SQL en el orden real del workflow** contra una base recién reseteada; registrar los fallos pre-existentes conocidos (`test_cuentas_billetera_tipo.sql` por artefacto de invocación local, el paso de reaplicación de idempotencia roto en `main`) para no confundirlos con regresiones propias.

## 6. Backend — schemas, repository, service, router (3 capas)

- [ ] 6.1 RED: test de `backend/tests/test_expense_import.py` que assertea el contrato del repository (una sola llamada, orden posicional exacto de los parámetros de la RPC, `rows` serializado a JSON).
- [ ] 6.2 Schemas en `backend/schemas/expenses.py`: `ExpenseImportRowIn` (con `amount: Decimal = Field(gt=0)`, reusando la misma restricción que `ExpenseCreate`), `ExpenseImportIn` (con `rows` acotado al tope) y `ExpenseImportOut` (`committed`, `import_id`, `imported`, `errors[]`, `notices[]`, `replayed`, `dry_run`).
- [ ] 6.3 `ExpenseRepository.import_batch(...)` — un `fetchrow`, espejo de `BankReconciliationRepository.import_statement` (`backend/repositories/bank_reconciliation_repository.py:35-53`).
- [ ] 6.4 Service: `require_role(auth, ["user","admin"])` + el `_pg_errors_as_problems()` **que ya existe** (`backend/services/expenses.py:53-67`) para los ERRCODEs que sí escapan. **Cero reglas de dominio nuevas en Python** — si aparece un `if` de negocio, está en la capa equivocada.
- [ ] 6.5 Router `POST /expenses/import` con `require_idempotency_key(request, payload.idempotency_key)`, calcado de `backend/routers/bank_reconciliation.py:68-100`.
- [ ] 6.6 Registrar `P0427` en `backend/core/errors.py` con su status (422) y, si corresponde, su `field`.
- [ ] 6.7 TRIANGULAR: tests de service/router para lote aplicado, lote rechazado (respuesta `200` con `errors[]`, **no** `4xx`), simulación, replay por clave, replay por hash, sin rol de escritura, y sin clave de idempotencia (422).
- [ ] 6.8 Test que verifica explícitamente que **después de un lote rechazado la conexión sigue usable** (no queda en `25P02`): es la razón de ser de D2 y hoy no hay nada que lo fije.
- [ ] 6.9 Test del lote en el tope (`500` filas) para medir que la transacción termina en un tiempo razonable.

## 7. Frontend — datos y tipos

- [ ] 7.1 RED: test del hook de lote (payload exacto, `Idempotency-Key` en `extraHeaders`, una sola invalidación al terminar).
- [ ] 7.2 Tipos del lote en `frontend/lib/types.ts` — **sin `any`**, en la capa canónica y no dentro del componente.
- [ ] 7.3 Mutación de lote en `frontend/hooks/data/use-expenses-query.ts` usando `pythonClient.post(path, body, extraHeaders)` (el tercer parámetro ya existe, `lib/api/python-client.ts:52-57`) y `useInvalidateExpenseLedgers()` (L144-154) **una sola vez** al confirmar.
- [ ] 7.4 La clave de idempotencia se genera **una vez por archivo elegido**, no por click: reintentar el mismo lote tiene que ser un replay, no un segundo lote.
- [ ] 7.5 Retirar `useBulkAddExpense` (L168-172) y su test, una vez que el diálogo dejó de usarlo. Confirmar por grep que no queda ningún consumidor (regla: nada de código muerto exportado).

## 8. Frontend — el diálogo de importación

- [ ] 8.1 RED: extender `expense-import-dialog-parse-and-validate.test.ts` a las siete columnas, **conservando** los casos de cuatro columnas (compatibilidad hacia atrás, requirement explícito).
- [ ] 8.2 Paso 1: template de siete columnas (`Descripción;Categoría;Monto;Fecha;Forma de pago;Sucursal;Centro de costo`) y reescritura del texto de ayuda — todo o nada, columnas admitidas, y el aviso de caja de D6. Retirar la redacción vieja ("quedan sin forma de pago y sin impacto en caja ni en banco"), que a partir de acá es falsa para el banco.
- [ ] 8.3 Paso 1: los cuatro valores por defecto del lote reusando `PaymentMethodSelect` (`context="expense"`), `BranchSelect`, `CostCenterSelect` y `BankAccountDestinationSelect` — este último visible sólo si hay cuentas bancarias activas, con la misma condición que `expense-form-v2.tsx:64-66`.
- [ ] 8.4 Hash del archivo con `hashFileSHA256` (`frontend/lib/bank-statement-parser.ts:108-115`). **No escribir un segundo hasher.**
- [ ] 8.5 Paso 2: disparar la **simulación** al entrar, con estado de carga, y renderizar el veredicto del servidor por fila (estado, motivo, aviso `cash_not_posted`) además de la validación de cliente que ya existe.
- [ ] 8.6 Paso 2: **deshabilitar la confirmación mientras haya una sola fila con error**, con el motivo visible. Retirar la lógica de "importar las que se pueda" (`handleApply`, L325-345), que ya no describe lo que el sistema hace.
- [ ] 8.7 Paso 3: resultado del lote (importados, archivo, aviso de replay si corresponde).
- [ ] 8.8 Migrar los badges de estado de literales (`text-emerald-400` / `text-yellow-400` / `text-red-400`, L206-212) a **tokens semánticos** — es lo que exige el gate `token-contrast-aa`.
- [ ] 8.9 Reescribir `expense-import-dialog-no-payment-method.test.tsx` invirtiendo lo que corresponde e **incorporando como aserción permanente** que el payload nunca lleva sesión de caja (D6). Adaptar `-invalidation.test.tsx` al hook nuevo.
- [ ] 8.10 Test de a11y del diálogo en `frontend/__tests__/a11y/gastos.a11y.test.tsx` (etiquetas de los cuatro selectores nuevos, tabla de revisión anunciada).

## 9. Verificación

- [ ] 9.1 Backend: suite completa verde y cobertura ≥ el umbral de CI. Comparar contra el baseline de 2.3.
- [ ] 9.2 Frontend: suite completa verde. Comparar contra 2.3 y justificar por escrito **cada** aserción que cambió (el listado de 2.4).
- [ ] 9.3 `tsc` sin errores nuevos.
- [ ] 9.4 `supabase db reset` local con la migración nueva incluida: aplica limpio desde cero.
- [ ] 9.5 Tanda completa de gates SQL en el orden real del workflow (5.4).
- [ ] 9.6 **Pasada visual obligatoria** (regla PO 2026-08-02): los tres pasos del diálogo en **desktop y móvil (375 px)**, en **claro y oscuro** — cuatro combinaciones. Verificar explícitamente que a 375 px la tabla del paso 2 scrollea **dentro de su contenedor** y el documento no se ensancha, y que el botón de confirmación queda alcanzable.
- [ ] 9.7 Prueba de humo local de punta a punta con un CSV real de ≥ 20 filas mezclando: efectivo, transferencia, sin forma de pago, nombre inexistente, importe negativo, fecha vieja. Verificar en la base que el rechazo no dejó **nada** y que el lote corregido dejó **todo**.
- [ ] 9.8 Prueba de replay real: reintentar el mismo archivo (misma clave) y volver a subirlo (otra clave) — las dos veces sin segundo lote.

## 10. Documentación y cierre del propose

- [ ] 10.1 Entrada propia en `CHANGES.md` con lo verificado, los hallazgos reales del apply y los candidatos que el change deje abiertos.
- [ ] 10.2 Actualizar el puntero de "próximo change" en `CLAUDE.md` y correr `python scripts/ci/check_docs_sync.py --fix` **en el mismo PR** (gate `Docs Sync`).
- [ ] 10.3 Registrar las respuestas del PO a las ocho OQs del design (cuáles se aplicaron y cuáles quedaron abiertas).
- [ ] 10.4 `npx openspec validate --changes --strict` y, al archivar, `--specs --strict` → **99/99**.

## 11. Post-merge en producción (sólo lectura, salvo el humo del PO)

- [ ] 11.1 `MAX(version)` en prod = la migración de 1.1, y el conteo total de migraciones esperado.
- [ ] 11.2 ACLs vivas: `rpc_import_expenses` sin `EXECUTE` para `anon` y con `EXECUTE` para `authenticated`; `expense_imports` sin `INSERT`/`UPDATE`/`DELETE` para `authenticated` ni `anon`.
- [ ] 11.3 Una sola definición viva de `rpc_import_expenses` (sin overload) y `rpc_create_expense` **sin cambios** respecto del md5 de 1.2 — la prueba de que el change compuso en vez de modificar.
- [ ] 11.4 Auditoría de daño histórico: cero filas en `expense_imports`, cero gastos con `import_id` no nulo **antes** del primer uso real (el "cero" del que se parte).
- [ ] 11.5 **Humo real del PO**: importar un archivo propio de gastos del mes, con al menos una fila por transferencia y una en efectivo. Verificar con él: que el movimiento aparece en `/banco` con la fecha correcta, que `/caja` **no** se movió, que `/reportes/formas-pago` ahora incluye esos gastos, y que volver a subir el mismo archivo no duplica nada.
