## Context

### Qué hay hoy, medido contra el código vivo

**El importador emite una llamada HTTP por fila, en serie, sin transacción de lote.**

`frontend/components/gastos/expense-import-dialog.tsx:325-345` — `handleApply` recorre las filas con un `for` y hace `await addExpenseMutation.mutateAsync({...})` por cada una (L336). Cada iteración es un `POST /expenses` independiente: si la fila 120 de 200 falla, las 119 anteriores **ya están escritas y confirmadas** y no hay forma de deshacerlas en bloque. El propio diálogo lo asume: acumula `imported: true/false` por fila y el paso 3 informa "N OK · M con error".

**El payload de esas filas es deliberadamente pobre.**

`frontend/hooks/data/use-expenses-query.ts:168-172` (`useBulkAddExpense`) usa el mismo `postExpense` que el formulario (L107-122), pero el diálogo sólo le pasa cuatro campos (`description`, `category`, `amount`, `date`). Quedan fuera `payment_method_id`, `branch_id`, `cost_center_id`, `cash_session_id` y `bank_account_id`. El comentario de L157-166 lo documenta como consecuencia de D13: *"por D13 las filas importadas viajan sin forma de pago, sin sesión de caja y sin cuenta bancaria, así que un alta por importación no puede tocar caja, banco ni el catálogo"*.

**El template son cuatro columnas** (`expense-import-dialog.tsx:46-53`): `Descripción;Categoría;Monto;Fecha`. `parseAndValidate` (L114-193) no busca ninguna otra.

**La spec vigente prohíbe explícitamente lo que este change viene a hacer.**

`openspec/specs/expense-operation/spec.md:501-527` — *"El sistema SHALL NOT aceptar forma de pago en el importador de gastos por archivo"*, con el motivo declarado: *"el importador emite una llamada por fila sin transacción que abarque el lote"*. Es una prohibición **condicionada a una limitación técnica**, y este change elimina la limitación. Tres tests la fijan (`frontend/__tests__/components/expense-import-dialog-no-payment-method.test.tsx`, `-invalidation.test.tsx`, `-parse-and-validate.test.ts`).

### El alta de gasto, verificada contra el cuerpo vivo

`public.rpc_create_expense(text, numeric, date, text, uuid, uuid, uuid, uuid, uuid)` — `SECURITY DEFINER`, `SET search_path TO 'public'`, `RETURNS jsonb`.
**`md5(pg_get_functiondef(...))` de la base local migrada a `main` (`MAX(version) = 20261039000001`, 2026-09-09): `4a31c7c6911fe247c76d243eff3e445e`.**
Reescrita por `20261015000001_gastos_forma_pago.sql` y otra vez por `20261016000001_qa_integral_fixes.sql` (G16/H11, la descripción como motivo en los dos libros).

Lo que hace, en orden, y que este change **no puede duplicar ni una vez**:

| Bloque | Guard / efecto | ERRCODE |
|---|---|---|
| (a) | `auth.uid()` no nulo; tenant desde `current_account_ids()`; `is_account_writer` | `insufficient_privilege` / `P0403` / `P0401` |
| — | `p_amount > 0` (la precondición de la que dependen las dos patas) | `P0400` |
| — | `kind` **derivado** de `payment_methods` por `id + account_id + is_active + deleted_at IS NULL` | `P0404` |
| — | `kind = 'credit'` rechazado (un gasto no tiene contraparte) | `P0400` |
| — | Sucursal: existe + de la cuenta + activa; `status='closed'` rechazado | `P0404` / `P0422` |
| — | `v_gate_branch := COALESCE(p_branch_id, c26_default_branch(cuenta))` | — |
| — | Centro de costo: existe + de la cuenta + activo | `P0404` |
| — | Cuenta bancaria exigida si `kind` bancario, no resuelve y la org tiene bancos activos | `P0412` |
| (b) | `INSERT INTO public.expenses (...)` con `branch_id` **resuelto** | — |
| (c) | Pata de caja **opt-in**: exige `kind='cash'` + sesión abierta de la sucursal efectiva + `p_date = reporting_local_today()`; luego `c28_register_cash_movement(sesión, -p_amount, 'expense', gasto, p_description)` | `P0422` |
| (d) | Pata bancaria **incondicional**: `_pay_register_operation_bank_movement(cuenta, kind, pm, ba, importe, 'out', 'expense', gasto, p_date, sucursal, p_description)` | `P0412` / `P0400` / `P0424` |

Devuelve `{expense_id, branch_id, payment_method_kind, cash_movement_id, bank_movement_id}`.

Helpers involucrados, también verificados vivos:
- `public._pay_resolve_bank_account(uuid, uuid, uuid)` — md5 `7f2eb5b2d77df3c4059b22914efafd01`. Resuelve **override → default de la forma de pago → `NULL`**, y valida la resuelta (`P0412`). Prefijo `_` = solo-DEFINER (sin `EXECUTE` para `authenticated`).
- `public.c28_register_cash_movement(uuid, numeric, text, uuid, text)` — usa `SELECT ... FOR UPDATE` sobre la sesión (bloqueo transaccional, **sin advisory locks**), `P0409` si la sesión no está abierta, `P0401` de tenencia, `P0422` de sucursal. Desde `20261038000001` está **revocada de `authenticated`**: sólo se la invoca desde dentro de otras `SECURITY DEFINER`.

### El molde de lote que el repo ya tiene probado

`public.rpc_import_bank_statement(p_idempotency_key text, p_bank_account_id uuid, p_file_name text, p_file_hash text, p_lines jsonb)` — md5 vivo `c02591027281475af21dc1600f7a1132`, creada por `20260805000001_bank_reconciliation.sql`.

Es **exactamente** la forma que necesita el gasto:
1. guards de sesión/tenant/writer;
2. validación de metadata del archivo (`file_name`/`file_hash` obligatorios → `P0400`);
3. validación de forma del payload: array `jsonb`, `1..5000` líneas (`P0400` con mensaje de tope excedido), y shape mínimo por línea vía `jsonb_to_recordset`;
4. **dedupe de dominio** por `(bank_account_id, file_hash)` → devuelve `replayed: true`;
5. **idempotencia técnica**: `INSERT INTO operation_idempotency (user_id, idempotency_key, operation_kind, operation_id) ... ON CONFLICT DO NOTHING` + `GET DIAGNOSTICS ROW_COUNT`; si 0 filas, recupera el `operation_id` previo y devuelve `replayed: true`;
6. escritura.

Su plomería HTTP también está hecha: `backend/routers/bank_reconciliation.py:68-100` toma la clave con `require_idempotency_key(request, payload.idempotency_key)` (v3-api-standards §3.3), serializa las líneas a JSON y llama al service; `backend/repositories/bank_reconciliation_repository.py:35-53` hace un solo `fetchrow` de la RPC. El hash lo calcula el cliente: `frontend/lib/bank-statement-parser.ts:108-115` (`hashFileSHA256`, SHA-256 hex con `crypto.subtle`).

El `CHECK` de `operation_idempotency.operation_kind` ya contiene `'bank_statement_import'` (extendido en `20260805000001:81-110`), y un segundo `CHECK` exige `operation_id IS NOT NULL` salvo para `'event_consumer'` y `'subscription_webhook'`.

### El otro importador del repo, y por qué NO es el molde

`rpc_bulk_upsert_products(jsonb, uuid)` sí recibe el lote en `jsonb`, pero:
- **trocea**: `frontend/lib/import/importer.ts:100` parte en chunks de `IMPORT_BATCH_SIZE = 200` (`lib/import/types.ts:166`) y llama una vez por chunk → la atomicidad es **por chunk**, no por archivo;
- **tolera fallos por fila**: su loop envuelve cada fila en `BEGIN ... EXCEPTION WHEN OTHERS THEN v_errors := v_errors || ...; END` y **sigue**, devolviendo `{inserted, updated, errors}` con lo que sí entró.

Para productos eso es aceptable (un producto mal cargado no descuadra un libro). Para gastos, no: un lote a medias deja movimientos bancarios sin su contraparte esperada por el usuario, y el usuario no tiene forma de saber cuáles reintentar. La técnica del bloque `BEGIN/EXCEPTION` por fila **sí** se reusa —es la única forma de atribuir un error a una fila— pero con el resultado invertido (ver D3).

### Estado medido que condiciona el diseño

- `payment_methods` sembrados por cuenta: `Efectivo` (cash), `Transferencia bancaria` (transfer), `Tarjeta` (card), `Cheque` (check), `Billetera virtual` (wallet), `Cuenta corriente` (credit), `Otro` (other). **Ninguno lleva tilde**, lo que hace que el matcheo por `lower(btrim(...))` alcance para el catálogo sembrado.
- La extensión **`unaccent` no está instalada** (extensiones vivas: `pg_cron`, `pg_stat_statements`, `pgcrypto`, `plpgsql`, `supabase_vault`, `uuid-ossp`). El matcheo insensible a tildes no está disponible sin agregar una extensión.
- `expenses` no tiene `deleted_at` ni columna de import: `id, user_id, category, amount, date (timestamptz), created_at, description, company_id, account_id, branch_id, cost_center_id, payment_method_id`.
- Desde `20261034000001_bank_default_destination.sql`, las cuentas con **exactamente un** banco activo tienen `payment_methods.bank_account_id` poblado en sus formas bancarias; las de 0 ó 2+ bancos siguen sin destino por decisión del PO ("no adivinar").
- Desde `20261035000001_revoke_anon_table_writes.sql`, `anon` conserva sólo `SELECT`/`REFERENCES`/`TRIGGER` sobre las tablas de aplicación.
- El request de FastAPI corre **dentro de una transacción explícita** (`backend/core/database.py:107-162`, `tenancy_tx_scope_enabled` ON en prod) con `SET LOCAL ROLE authenticated` verificado *fail-closed*. Esto tiene una consecuencia dura para el diseño del error: ver D4.

## Goals / Non-Goals

**Goals:**

1. Que el importador de gastos escriba **todo el archivo o nada**, en una sola transacción de servidor (DEC-24: la unidad de trabajo es una RPC `SECURITY DEFINER`).
2. Que el usuario vea **los errores de todas las filas problemáticas antes de que se escriba nada**, con el número de fila y el motivo.
3. Que un gasto importado pueda llevar **forma de pago, sucursal y centro de costo**, resueltos contra los catálogos de su cuenta.
4. Que el gasto importado por medio bancario **llegue a la conciliación bancaria** con fecha valor correcta.
5. Que **ninguna regla de negocio del alta se duplique**: una sola definición del alta de gasto, la que ya existe.
6. Que subir dos veces el mismo archivo, o reintentar por red, **no duplique** el lote.

**Non-Goals:**

1. **El lote no postea en caja.** Ver D6: no es una limitación técnica, es la forma del libro de caja.
2. **No se reescribe `rpc_create_expense`** (ni `rpc_update_expense`, ni `rpc_delete_expense`, ni los dos helpers de libros). Este change **compone**, no modifica.
3. **No se levanta D11**: la edición de un gasto sigue sin postear movimientos. Imputar la forma de pago a un gasto ya importado sigue siendo sólo una etiqueta — lo que cambia es que ahora hay un camino para que **no haga falta**.
4. **No se migra el importador de productos** a este patrón (candidato propio y declarado, D7 de `productos-categorias-sku`).
5. **No se toca la ambigüedad de miles con punto en precio/costo** ni se unifica el parseo de cantidades entre los dos importadores (candidatos abiertos de `product-import-decimal-stock`). El importador de gastos conserva su `parseAmount` + `amountAmbiguityWarning` actuales.
6. **No hay asiento contable de gasto** (sigue diferido a V2.6, D10 de `gastos-forma-pago`: no existe rama de gasto en `_journal_post_from_event` ni `event_type` de gasto).
7. **No hay pantalla de historial de importaciones.** La tabla `expense_imports` nace por necesidad técnica (el `operation_id` de la idempotencia) y de dedupe; su superficie es el paso 3 del diálogo, no una ruta nueva.
8. **No se soporta XLSX.** El importador sigue siendo CSV, como hoy.

## Decisions

### D1 — La unidad de trabajo es una RPC de lote nueva que **invoca `rpc_create_expense` por fila**

**Decisión.** Nace `public.rpc_import_expenses(p_idempotency_key text, p_rows jsonb, p_file_name text, p_file_hash text, p_default_payment_method_id uuid, p_default_branch_id uuid, p_default_cost_center_id uuid, p_fallback_bank_account_id uuid, p_dry_run boolean)`, `SECURITY DEFINER`, `SET search_path TO 'public'`, `RETURNS jsonb`. Por cada fila del array resuelve los nombres a uuids y ejecuta:

```
PERFORM public.rpc_create_expense(
  v_category, v_amount, v_date, v_description,
  v_branch_id, v_cost_center_id, v_payment_method_id,
  NULL,               -- p_cash_session_id: SIEMPRE null en el lote (D6)
  v_bank_account_id
);
```

**Por qué invocarla y no reimplementarla.** Es la regla dura del proyecto (*"reutilización antes que repetición"*, PO 2026-08-02) aplicada al caso más caro posible: la tabla del Context enumera **nueve** guards y dos patas de libros. Copiarlos produciría una segunda definición del alta de gasto que divergiría en el primer fix que toque uno solo de los dos caminos — exactamente el modo de falla que este repo ya pagó con "criticidad de stock rehecha en 5 lugares" y con "3 Edge Functions calculando su propio plan efectivo".

**Por qué esto funciona técnicamente.** `rpc_create_expense` resuelve el tenant desde la **sesión** (`auth.uid()` + `current_account_ids()`), no por parámetro. Esos dos leen GUCs (`request.jwt.claims`) que la conexión del request ya tiene seteados con alcance transaccional, y **siguen resolviendo igual dentro de una llamada `SECURITY DEFINER` anidada**: `SECURITY DEFINER` cambia el usuario *de privilegios*, no los GUCs de la sesión. El guard de tenencia por lo tanto no se debilita: cada fila lo vuelve a evaluar.

**Beneficio de riesgo, no cosmético.** Al no tocar `rpc_create_expense`:
- no hay `DROP FUNCTION` + `CREATE`, y por lo tanto **no hay riesgo de overload `42725`** (el gotcha que ya mordió en `caja-compras-cobranzas` y `cobranzas-catalogo-pagos`);
- no hay reset de ACLs que re-emitir;
- **el formulario de gasto, que es el camino con tráfico real, no cambia de comportamiento en una sola línea**. La superficie de regresión del change se limita a código nuevo.

**Alternativas descartadas.**
- *Endpoint FastAPI que abre una transacción y llama a la RPC fila por fila desde Python.* Contradice DEC-24 (la unidad de trabajo es la RPC, no el service) y desplaza la atomicidad a la capa que **no** es la autoridad: cualquier otro caller (PostgREST, un job, otro cliente) quedaría fuera de la garantía. Además obliga al service a evaluar qué error de qué fila aborta el lote, que es lógica de dominio en la capa equivocada. El repo ya tiene el precedente contrario resuelto: `rpc_import_bank_statement`.
- *Copiar el cuerpo del alta dentro del loop.* Segunda definición del alta. Descartado sin más.
- *Extender `rpc_create_expense` con un parámetro `p_rows`.* Convierte la función del hot path del formulario en una función de dos modos, con `DROP`+`CREATE`, ACLs y riesgo de overload — todo el costo de D1 sin ninguno de sus beneficios.

---

### D2 — El lote es **todo o nada**, y el reporte de errores viaja en el **retorno normal**, no en una excepción

**Decisión.** El cuerpo de la RPC tiene esta forma:

```
  <guards de sesión/tenant/writer>
  <validación de forma del payload: array, 1..N filas, shape mínimo>   -- RAISE normal (P0400)

  BEGIN                                    -- ← subtransacción del LOTE
    <dedupe por file_hash → replay>
    <slot en operation_idempotency>
    <INSERT en expense_imports>
    FOR cada fila LOOP
      BEGIN                                -- ← subtransacción de la FILA
        <resolver nombres → uuids>
        PERFORM public.rpc_create_expense(...);
        UPDATE public.expenses SET import_id = v_import_id WHERE id = <expense_id>;
        v_imported := v_imported + 1;
      EXCEPTION WHEN OTHERS THEN
        v_errors := v_errors || jsonb_build_object(
          'row', v_row_no, 'code', SQLSTATE, 'message', SQLERRM);
      END;
    END LOOP;

    IF jsonb_array_length(v_errors) > 0 OR p_dry_run THEN
      RAISE EXCEPTION 'batch_rollback' USING ERRCODE = 'P0429';
    END IF;
  EXCEPTION WHEN SQLSTATE 'P0429' THEN
    v_committed := false;                  -- todo el bloque quedó deshecho
  END;

  RETURN jsonb_build_object('committed', v_committed, 'import_id', ...,
                            'imported', ..., 'errors', v_errors, 'dry_run', p_dry_run);
```

**Las dos propiedades que hacen que esto funcione, y que hay que enunciar porque son sutiles:**

1. Un bloque `BEGIN ... EXCEPTION` de PL/pgSQL es una **subtransacción**: cuando su excepción se captura, **todo el estado de base de datos escrito dentro del bloque se deshace**, y la transacción exterior queda **sana** (no abortada).
2. **Las variables locales de PL/pgSQL NO se deshacen** con el rollback de la subtransacción. `v_errors`, `v_imported` y `v_row_no` sobreviven al `RAISE` deliberado. Ésa es la única razón por la que el reporte puede volver por el `RETURN` normal.

**Por qué importa que el error NO viaje por excepción.** Con `tenancy_tx_scope_enabled` ON, **todo el request de FastAPI corre dentro de un `async with conn.transaction()`** (`backend/core/database.py:109`). Si la RPC dejara escapar la excepción, la transacción del request quedaría **abortada**: cualquier consulta posterior sobre esa conexión daría `25P02 (in_failed_sql_transaction)`, y el service tendría que construir la respuesta sin volver a tocar la base — una restricción frágil, invisible en el código, que el primer `re-SELECT` agregado por distracción rompería en producción. Con el `RETURN` normal la transacción del request queda **limpia**, el commit final del dependency no tiene nada que deshacer y el service es un traductor de `jsonb` como todos los demás.

**Qué se descarta explícitamente.**
- *Fallar en la primera fila mala.* El usuario corrige una fila, reintenta, descubre la siguiente. Con archivos de decenas de filas es inaceptable.
- *Semántica del importador de productos (escribir lo que se pueda, reportar el resto).* Es el estado que este change viene a eliminar: deja al usuario sin saber qué reintentar, y con dinero escrito a medias en el ledger bancario.
- *Dos pasadas (una "en seco" que se deshace y otra real).* Duplica el trabajo y, sobre todo, **no es equivalente**: cualquier efecto no transaccional de la primera pasada (un `nextval`, un contador) no se desharía. Hoy `rpc_create_expense` no usa secuencias, pero el diseño no debe depender de que eso no cambie nunca.
- *Excepción con el reporte en `DETAIL`.* Funciona, pero deja la transacción del request abortada (arriba) y mete JSON en un campo de texto de diagnóstico.

---

### D3 — La atribución de un error a **su fila** se hace con la subtransacción por fila, y el error se **traduce**, no se filtra en crudo

**Decisión.** Cada fila corre en su propio bloque `BEGIN ... EXCEPTION WHEN OTHERS`. El registro de error lleva `{row, column?, code, message}` donde `code` es el `SQLSTATE` (`P0400`, `P0404`, `P0412`, `P0422`, `P0424`, …) y `message` es el `SQLERRM` de la RPC de alta, tal cual — **más** un campo `hint` que el lote agrega para los casos que sólo el lote conoce (nombre de forma de pago que no existe, sucursal que no existe, tope excedido).

**Por qué se conserva el `SQLERRM` crudo y no se lo reescribe.** Los mensajes de `rpc_create_expense` ya están redactados para el usuario final y probados (*"elegí la cuenta bancaria de la que sale el dinero — sin ella el gasto no aparecería nunca en la conciliación bancaria"*). Reescribirlos en el lote sería una tercera redacción del mismo error, que divergiría.

**El `code` viaja hasta el cliente.** El frontend ya tiene un mapa de errores de operación (`lib/operation-errors.ts`); el diálogo puede rotular por código sin volver a redactar. Para los códigos que no conoce, muestra `message`.

**Riesgo consciente y su límite.** `WHEN OTHERS` captura **todo**, incluido un error de programación (una columna que no existe, un `null` inesperado). Eso convertiría un bug en "error de fila" en vez de en un fallo ruidoso. Mitigación: el reporte incluye siempre el `SQLSTATE`, y el gate SQL incluye un caso que verifica que un error **estructural** (no de dominio) también aborta el lote y aparece con su código — el lote nunca escribe a medias, sea cual sea el origen del error.

**Sobre el costo de las subtransacciones.** Un lote de 500 filas abre ~501 subtransacciones anidadas en la misma transacción. Es el mismo orden de magnitud que `rpc_bulk_upsert_products` con un chunk de 200 y está muy por debajo del umbral en que el desbordamiento del caché de subxids (64) degrada la visibilidad de otras sesiones de forma medible. Es, además, uno de los argumentos del tope de D8.

---

### D4 — La forma de pago, la sucursal y el centro de costo se resuelven **por nombre**, con default de diálogo, y un nombre que no resuelve es **error de fila**

**Decisión.** El template pasa a siete columnas:

```
Descripción;Categoría;Monto;Fecha;Forma de pago;Sucursal;Centro de costo
```

Las tres nuevas son **opcionales**. Por cada fila:

| Valor de la celda | Resolución |
|---|---|
| vacía | se usa el **default elegido en el diálogo** para esa dimensión; si el diálogo tampoco eligió, se pasa `NULL` y decide `rpc_create_expense` (que para la sucursal aplica `COALESCE(..., c26_default_branch(cuenta))`) |
| con texto que resuelve | se usa el uuid resuelto |
| con texto que **no** resuelve | **error de fila**, con el motivo y la lista de nombres válidos |

La resolución es `lower(btrim(<celda>)) = lower(btrim(<name>))` sobre las filas **de la cuenta, activas y no borradas** — el mismo alcance y la misma normalización que el catálogo de categorías de producto usa hoy (`product_category_normalize_name` es `NULLIF(regexp_replace(btrim(...), '\s+', ' ', 'g'), '')`, y el matcheo es por `lower(name)`).

**Por qué un nombre que no resuelve es error y no un default silencioso.** Porque asigna **dinero**. Un archivo que dice "Transferenca" y termina imputado como "Efectivo" produce un movimiento en el libro equivocado y el usuario no tiene ninguna señal. Este repo ya pagó exactamente esa clase de bug (`_pay_register_operation_bank_movement` haciendo `RETURN NULL` sin error con la cuenta sin resolver, D5 de `gastos-forma-pago`). Un default se aplica sólo a la **ausencia** de dato, que es una intención inequívoca.

**Por qué NO se crea la forma de pago que falta** (a diferencia del importador de productos, que sí crea categorías). Una forma de pago tiene un `kind` de vocabulario cerrado que **no se puede derivar de un nombre**: "Mercado Pago" podría ser `wallet`, `transfer` o `card`, y de esa elección depende a qué libro va la plata. Crear catálogo desde un CSV sería adivinar el destino del dinero.

**Por qué también sucursal y centro de costo, y no sólo forma de pago.** (a) La sucursal es **load-bearing**: es la que se estampa en el `bank_movement` y la que RN-93 exige; hoy el importador la descarta al 100 % — el mismo bug que `gastos-forma-pago` corrigió para el formulario (0 de 175 gastos con sucursal) y que en el importador quedó vivo. (b) El centro de costo es la otra dimensión analítica que el importador tira, y su resolutor es el mismo código. Agregarlas cuesta dos ramas del mismo `CASE` y cierra el agujero entero en vez de la mitad. Es OQ-3.

**Sobre tildes.** El matcheo es sensible a tildes porque `unaccent` no está instalada y agregar una extensión por esto no se justifica. Los siete nombres sembrados no llevan tilde, así que el caso sembrado —el 100 % del uso real hoy— funciona. Un nombre creado por el usuario con tilde exige escribirlo con tilde; el mensaje de error lista los nombres válidos, así que el usuario ve exactamente qué escribir. Queda como OQ-6.

---

### D5 — La pata **bancaria** del lote se escribe, y se escribe por el mismo helper

**Decisión.** Las filas con `kind ∈ (transfer, card, check, wallet)` registran su movimiento en `bank_movements` **igual que un gasto cargado desde el formulario**, porque `rpc_create_expense` llama incondicionalmente a `_pay_register_operation_bank_movement` y este change no la modifica. Fecha valor = fecha del gasto; sucursal = sucursal efectiva; motivo = descripción del gasto.

**Por qué es correcto para un import retroactivo.** El ledger bancario **no tiene sesión, ni arqueo, ni "hoy"**: un movimiento lleva su propia `value_date` y se concilia contra el extracto por fecha e importe. Un egreso bancario del 12 de agosto cargado el 9 de septiembre es un dato **correcto y útil** — es, de hecho, la razón por la que la conciliación existe. El único límite es el que ya rige: `P0424` si la fecha cae dentro de una `reconciliation_sessions` cerrada, y ese rechazo aborta el lote entero con el motivo en la fila (D2).

**Consecuencia que hay que decir en voz alta**: éste es el tramo de gobernanza **ALTA** del change. Un archivo de 200 filas puede escribir 200 movimientos bancarios reales en una sola transacción. Por eso el lote tiene tope (D8), vista previa validada por el servidor (D9), idempotencia y dedupe de archivo (D7).

---

### D6 — El lote **nunca** postea en caja, y lo dice fila por fila

**Decisión.** `rpc_import_expenses` pasa **siempre** `p_cash_session_id := NULL` a `rpc_create_expense`. Las filas cuyo `kind` resuelto es `cash` se importan como gasto con su forma de pago imputada, **sin movimiento de caja**, y el reporte del lote las marca con un aviso propio (`cash_not_posted`) que el diálogo muestra en la vista previa y en el resultado.

**Por qué la asimetría con la pata bancaria no es una preferencia.** `cash_movements` es un libro **append-only por sesión**, y la sesión se cuenta, se arquea y se firma al cerrar (RN-95). De ahí salen tres hechos, no opiniones:

1. Un gasto en efectivo de una fecha pasada **no puede** ir a su sesión: esa sesión está cerrada y `c28_register_cash_movement` exige una sesión abierta (`P0409`).
2. Postearlo en la sesión **abierta de hoy** no lo corrige: **inventa una diferencia de arqueo** en un arqueo que sí se va a firmar. Es exactamente lo que la condición "sólo hoy" de `rpc_create_expense` protege, y la RPC lo rechazaría con `P0422` de todos modos.
3. El ledger bancario no tiene ninguna de esas dos propiedades. De ahí que uno admita el retroactivo y el otro no.

**El caso "importo gastos en efectivo de hoy y tengo la caja abierta".** Existe y es legítimo, pero es marginal: quien tiene la caja abierta *ahora* está cargando *ahora*, y para eso está el formulario, que además pre-marca el opt-in (D1 de `gastos-forma-pago`). Habilitarlo en el lote exigiría un opt-in de lote más una elegibilidad **por fila** (sólo las de hoy) más un aviso por cada fila no elegible: una superficie desproporcionada para un caso que ya tiene camino. **Es OQ-2**, con recomendación explícita de dejarlo fuera.

**Por qué el aviso es obligatorio y no opcional.** Sin él, el importador reproduce el pecado que D5 y D3 de `gastos-forma-pago` argumentan evitar: el no-op silencioso. El usuario tiene que saber que su gasto en efectivo importado **tiene etiqueta pero no movió el cajón**, y que si quiere el arqueo debe cargarlo desde el formulario. Es la misma verdad que ya dice el texto actual del paso 1, ahora acotada a la caja en lugar de valer para todo.

---

### D7 — Idempotencia por clave **y** dedupe por archivo, sobre una tabla `expense_imports` mínima

**Decisión.** Nace `public.expense_imports` — espejo reducido de `bank_statement_imports`:

```
id           uuid  PK  default gen_random_uuid()
account_id   uuid  NOT NULL → accounts(id)
imported_by  uuid  NOT NULL          -- auth.uid()
file_name    text  NOT NULL
file_hash    text  NOT NULL
row_count    integer NOT NULL
imported_count integer NOT NULL
created_at   timestamptz NOT NULL default now()
UNIQUE (account_id, file_hash)
```

más `public.expenses.import_id uuid NULL REFERENCES expense_imports(id) ON DELETE SET NULL` (+ índice), y `'expense_import'` sumado al `CHECK` de `operation_idempotency.operation_kind`.

**Por qué hace falta una tabla y no alcanza con la clave.** El segundo `CHECK` de `operation_idempotency` exige `operation_id IS NOT NULL` para todo `operation_kind` que no sea `'event_consumer'` ni `'subscription_webhook'`. Un lote de gastos **no tiene una operación** a la que apuntar: son N gastos. O se crea la entidad de lote, o se agrega una tercera excepción a ese `CHECK` — y esa excepción degradaría el replay a "ya se hizo algo" sin poder decir qué. Con la tabla, el replay devuelve el lote real.

**Qué compra, además del `operation_id`:**
- **Dedupe de dominio por `(account_id, file_hash)`**, que es la protección contra el modo de falla **más probable** en la vida real: volver a subir el mismo archivo la semana siguiente. La clave de idempotencia sólo protege el reintento de *esa* request; el hash protege el error humano. Es literalmente lo que hace `rpc_import_bank_statement`.
- **Trazabilidad**: `expenses.import_id` responde "estos 40 gastos vinieron de `gastos-agosto.csv`". Sin ella, "todo o nada" no es auditable después del hecho.

**Permisos.** RLS habilitada con una policy de `SELECT` por `account_id IN (SELECT current_account_ids())` — copia literal de `bank_statement_imports_select`. `GRANT SELECT` a `authenticated`; **sin `INSERT`/`UPDATE`/`DELETE`** para ningún rol de aplicación (la escritura es exclusiva de la RPC `SECURITY DEFINER`) y sin nada para `anon`, alineado con `20261035000001`.

**Alternativa descartada.** *Sin tabla, agregando `'expense_import'` a la lista de kinds que admiten `operation_id NULL`.* Ahorra ~40 líneas de SQL y pierde el dedupe por archivo, la trazabilidad y la capacidad de responder qué se importó en el replay. El costo evitado es menor que el valor perdido.

**Non-goal recordado:** no hay pantalla de historial de importaciones. La tabla es infraestructura.

---

### D8 — Tope de **500 filas por lote**, con rechazo — y explícitamente **sin trocear**

**Decisión.** `p_rows` debe ser un array `jsonb` de **1 a 500** elementos. Fuera de rango → `P0400` con el mensaje que nombra el tope y sugiere partir el archivo. El cliente aplica el mismo tope antes de subir (para no mandar 5 MB y recibir un rechazo) y el servidor es la autoridad.

**Por qué no se trocea.** Trocear es exactamente lo que hace el importador de productos (`IMPORT_BATCH_SIZE = 200`, `lib/import/importer.ts:100`) y es **la razón por la que su atomicidad no sirve acá**: dos chunks son dos transacciones, y el fallo del segundo deja el primero escrito. Trocear un lote de gastos sería reintroducir el problema que este change viene a resolver, con más pasos.

**Por qué 500 y no 5000 (el tope del extracto bancario).** Una línea de extracto es una fila; una fila de gasto son hasta **tres** escrituras (gasto + movimiento bancario + su fila de auditoría) más una subtransacción (D3) más los ~9 guards del alta. 500 filas es un archivo de gastos grande de verdad (el mes entero de un microemprendedor cabe holgado) y mantiene la transacción en el orden de segundos. Es **OQ-4**: si el PO prefiere 1000, es un número en una constante y en el gate.

**Límite de tamaño de archivo.** Sigue rigiendo `MAX_IMPORT_SIZE_BYTES = 5 MB` (`frontend/lib/excel.ts:17`).

---

### D9 — El paso 2 del diálogo pasa a ser una **vista previa validada por el servidor**, usando la misma RPC en modo simulación

**Decisión.** `p_dry_run boolean DEFAULT false`. Con `true`, la RPC hace **exactamente lo mismo** (resuelve, llama al alta fila por fila, colecta errores) y al final fuerza siempre el rollback del bloque de lote (D2), devolviendo `{committed: false, dry_run: true, imported: <las que habrían entrado>, errors: [...], notices: [...]}`. Nada queda escrito, ni siquiera el slot de idempotencia ni la fila de `expense_imports`, porque ambos viven dentro del bloque.

El diálogo lo dispara **automáticamente al pasar al paso 2**, con estado de carga. La vista previa deja de ser una validación de forma hecha en el navegador y pasa a ser **el veredicto del servidor**: incluye el período conciliado (`P0424`), la sucursal cerrada (`P0422`), el centro de costo inactivo (`P0404`), la cuenta bancaria faltante (`P0412`) y la forma de pago que no existe — nada de lo cual el cliente puede saber.

**Por qué no un botón "Validar" aparte.** Sería un cuarto paso para el usuario y una decisión que puede saltearse. La vista previa **ya existe** como paso 2; lo único que cambia es de dónde sale la verdad que muestra.

**Por qué esto no duplica la lógica de validación.** Es el mismo código, el mismo camino y las mismas funciones. La única diferencia es un `IF` al final. Un validador separado sería una segunda definición de las reglas.

**Costo aceptado.** Un lote válido se ejecuta dos veces (simulación + real). Con el tope de D8 son segundos, y a cambio se elimina la categoría entera de "el usuario descubre el problema después de escribir". La validación en cliente que ya existe (descripción obligatoria, importe positivo, ambigüedad de miles, fecha) **se conserva** y corre antes: filtra lo obvio sin round-trip.

---

### D10 — La superficie: el mismo diálogo, en el mismo lugar, con cuatro controles nuevos

**Decisión.** No hay ruta nueva ni entrada de menú nueva: la puerta es la que ya existe, `/gastos` → botón **"Importar CSV"** (`app/(dashboard)/gastos/page.tsx:153-156`, montado en L458-462). Cambia el contenido del diálogo:

- **Paso 1 (Archivo)**: la descarga del template baja el CSV de **siete** columnas. El texto de ayuda se reescribe: ya no dice "los gastos importados quedan sin forma de pago", dice qué columnas admite, que el lote es **todo o nada** y que **los gastos en efectivo no impactan la caja** (D6). Bajo el drop zone aparecen los cuatro **valores por defecto del lote**, todos opcionales:
  - `PaymentMethodSelect` con `context="expense"` (ya existe y ya oculta `credit` en gastos),
  - `BranchSelect`,
  - `CostCenterSelect`,
  - `BankAccountDestinationSelect` — visible sólo si la organización tiene cuentas bancarias activas, como en el formulario (`expense-form-v2.tsx:64-66, 195-200`).
- **Paso 2 (Revisión)**: tabla por fila con las columnas resueltas y **el veredicto del servidor** (D9): estado `ok` / `aviso` / `error`, el motivo, y los avisos `cash_not_posted`. Cabecera con el resumen (`N listas · M con aviso · K con error`) y el botón de confirmación **deshabilitado si hay una sola fila con error** — porque el lote es todo o nada, ya no tiene sentido "importar las que se pueda".
- **Paso 3 (Resultado)**: `N gastos importados`, el nombre del archivo, y —si el lote fue un replay— el aviso de que ese archivo ya se había importado.

**Reutilización.** Los cuatro selectores, `hashFileSHA256` (`lib/bank-statement-parser.ts:108`) y `useCashOptin` no se reescriben. El único componente nuevo es la fila de la tabla de revisión, y sólo porque gana columnas.

**Verificación visual obligatoria** (regla PO 2026-08-02): los tres pasos en **desktop y móvil**, en **claro y oscuro**. Atención específica al paso 2: la tabla gana tres columnas y el diálogo mide `sm:max-w-[680px]` — a 375 px tiene que scrollear **dentro** de su contenedor (`responsive-shell`), nunca estirar el documento. Los badges de estado usan hoy literales `text-emerald-400` / `text-yellow-400` / `text-red-400` (`expense-import-dialog.tsx:206-212`): se migran a los **tokens semánticos** del sistema de diseño, que es lo que exige el gate `token-contrast-aa`.

---

### D11 — Plomería HTTP: `POST /expenses/import`, tres capas, `Idempotency-Key` por header

**Decisión.** Endpoint nuevo en `backend/routers/expenses.py`, calcado de `backend/routers/bank_reconciliation.py:68-100`:

```
POST /expenses/import        Idempotency-Key: <uuid>
{ file_name, file_hash, dry_run,
  default_payment_method_id?, default_branch_id?, default_cost_center_id?,
  fallback_bank_account_id?,
  rows: [{ row_no, description, category, amount, date,
           payment_method_name?, branch_name?, cost_center_name? }] }
```

- **router**: `require_idempotency_key(request, payload.idempotency_key)` (v3-api-standards §3.3), serializa `rows` a JSON, delega.
- **service**: `require_role(auth, ["user","admin"])` —el mismo guard que el alta suelta— y el `_pg_errors_as_problems()` que **ya existe** (`backend/services/expenses.py:53-67`) para los ERRCODEs que sí escapan (los de forma del payload, D2). Ninguna regla de dominio nueva en Python.
- **repository**: un `fetchrow` de la RPC, espejo de `BankReconciliationRepository.import_statement`.
- **schemas**: `ExpenseImportRowIn` / `ExpenseImportIn` / `ExpenseImportOut` en `backend/schemas/expenses.py`, con `amount: Decimal = Field(gt=0)` reusando la misma restricción que `ExpenseCreate` (`schemas/expenses.py:20`) y `rows` con `max_length` = el tope de D8.

**Respuesta.** Siempre `200` con el reporte (`committed`, `import_id`, `imported`, `errors[]`, `notices[]`, `replayed`, `dry_run`) — **no** `422`. Un lote rechazado no es un error de protocolo: es un resultado de negocio con estructura, y devolverlo como `200` evita tener que meter un array de errores por fila dentro de un `problem+json` que está pensado para **un** problema. Los `4xx` quedan para lo que sí lo es: payload malformado, tope excedido, sin rol de escritura, sin cuenta.

**El frontend** usa `pythonClient.post(path, body, extraHeaders)` — el tercer parámetro para `Idempotency-Key` ya existe (`lib/api/python-client.ts:52-57`). La clave se genera **una vez por archivo elegido** (no por click), para que reintentar el mismo lote sea un replay y no un segundo lote.

**Invalidación de caché.** El lote toca gastos y banco, así que al confirmar se llama **una sola vez** a `useInvalidateExpenseLedgers()` (`hooks/data/use-expenses-query.ts:144-154`), que ya invalida las seis claves correctas. `useBulkAddExpense` (L168-172) queda sin consumidores y **se retira**.

---

### D12 — ERRCODEs nuevos: sólo dos, y los dos son de **control de flujo o de forma**

**Decisión.**

| Código | Significado | HTTP | Dónde |
|---|---|---|---|
| `P0429` | señal interna de rollback del lote (errores de fila o simulación) | — | **nunca sale de la RPC**: se captura en su propio `EXCEPTION` (D2) |
| `P0427` | forma del payload del lote inválida (no es array, vacío, tope excedido, fila sin campos mínimos) | `422` | `RAISE` normal, antes del bloque de lote |

Verificado contra los códigos ya usados en el repo (`P0001 P0002 P0400 P0401 P0403 P0404 P0409 P0410 P0411 P0412 P0413 P0414 P0422 P0423 P0424 P0425 P0426 P0428 P0431 P0432 P0433 P0434 P0450 P0451 P0999`): `P0427` y `P0429` están **libres**. Los dos tienen exactamente 5 caracteres, como exige el requirement de `api-standards`.

**Ningún ERRCODE de dominio nuevo.** Todo lo que puede fallar en una fila ya tiene su código en `rpc_create_expense`, y el lote lo propaga tal cual (D3). Un código nuevo por "forma de pago inexistente" sería una segunda forma de decir `P0404`.

*Nota:* si el PO prefiere reusar `P0400` para el payload malformado en vez de estrenar `P0427`, es una línea; se registra como parte de OQ-5.

---

### D13 — Qué pasa con los tests que fijan el comportamiento viejo

**Decisión.** Los tres archivos que hoy assertan que el importador **no** imputa forma de pago se reescriben, y cada aserción retirada queda justificada por escrito en el apply:

| Archivo | Qué assertaba | Qué pasa |
|---|---|---|
| `expense-import-dialog-no-payment-method.test.tsx` | el payload **no** lleva `paymentMethodId` / `cashSessionId` / `bankAccountId`; el texto promete "sin impacto en caja ni en banco" | **Se invierte**: el payload sí lleva forma de pago y cuenta bancaria; `cashSessionId` **sigue ausente** (D6) y eso pasa a ser una aserción *permanente* del nuevo régimen. El texto se reescribe. |
| `expense-import-dialog-invalidation.test.tsx` | una sola invalidación por lote, no una por fila | **Sigue valiendo**, con menos esfuerzo: ahora hay una sola llamada. Se adapta al nuevo hook. |
| `expense-import-dialog-parse-and-validate.test.ts` | `parseAndValidate` sobre 4 columnas | **Se extiende** a 7 columnas; los casos viejos siguen (un CSV de 4 columnas tiene que seguir importándose). |

**Compatibilidad hacia atrás del template, explícita**: un CSV con las cuatro columnas de siempre **sigue funcionando** — las tres nuevas son opcionales. Es requisito, no cortesía: hay usuarios con su planilla armada.

---

## Risks / Trade-offs

**[Un archivo escribe hasta 500 movimientos bancarios reales en una transacción]** → Tope duro de 500 (D8) + vista previa validada por el servidor antes de confirmar (D9) + todo-o-nada (D2) + dedupe por hash de archivo e idempotencia por clave (D7). Y el gate SQL incluye el control negativo: un lote con una sola fila mala **no deja ni una fila escrita**.

**[`WHEN OTHERS` puede tragarse un bug y disfrazarlo de "error de fila"]** → El reporte lleva siempre el `SQLSTATE`, y el gate verifica que un error estructural también aborte el lote entero. Nunca hay escritura parcial, sea cual sea el origen.

**[La simulación de D9 duplica el trabajo del lote]** → Acotado por el tope de D8. El beneficio (ningún usuario descubre un `P0424` después de escribir) supera el costo. Si el tiempo molestara, la palanca es bajar el tope, no sacar la simulación.

**[Una llamada `SECURITY DEFINER` anidada podría comportarse distinto de la directa]** → Es el punto que más hay que verificar, no suponer: el gate SQL ejecuta el lote **como `authenticated` con claims de un usuario real** y compara el resultado fila a fila contra el mismo alta hecha directo por `rpc_create_expense` (mismos guards, mismos ERRCODEs, mismos movimientos). Si `auth.uid()` o `current_account_ids()` se comportaran distinto anidados, ese gate lo muestra antes del merge.

**[El lote corre dentro de la transacción del request (`tenancy_tx_scope_enabled`), que además tiene `idle_in_transaction_session_timeout`]** → Un lote de 500 filas es trabajo **activo**, no idle, así que ese timeout no aplica. Aun así el tope de D8 mantiene la duración en segundos; y el test de integración del backend mide el lote máximo.

**[Retirar el requirement de `expense-operation` es un BREAKING de spec]** → Se retira con `Reason` y `Migration` explícitas (formato ya usado por `cobranzas-vencimientos` en `receivables-panel`), y lo que ese requirement protegía —que la ayuda del importador no prometa efectos que el sistema no produce— **se conserva y se refuerza**: pasa a `expense-import` como la cláusula del aviso de caja de D6.

**[La resolución por nombre es sensible a tildes]** → Los siete nombres sembrados no llevan tilde; el error de fila lista los nombres válidos. OQ-6 si el PO quiere insensibilidad real.

**[`useBulkAddExpense` desaparece]** → Es exportado y su único consumidor es el diálogo (verificado por grep). Se retira en el mismo PR junto con su test, para no dejar código muerto — el precedente contrario (`CostCenterManager` construido y nunca montado) es justamente lo que originó la regla de superficie del PO.

**[Un lote grande puede tardar y el usuario cerrar el diálogo]** → El diálogo bloquea el cierre mientras el lote está en vuelo (estado `applying`, ya existe en L268). Si igual se pierde la respuesta, la clave de idempotencia hace que el reintento sea un replay, no un duplicado.

## Migration Plan

**Migración única**, numerada a continuación de la última vigente (`20261039000001`; verificar `MAX(version)` en el momento de escribir el archivo — el número se corrió tres veces en changes anteriores por PRs en paralelo).

Orden dentro del archivo, todo idempotente:

1. `CREATE TABLE IF NOT EXISTS public.expense_imports (...)` + índices + `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + policy de `SELECT` con `DROP POLICY IF EXISTS` previo.
2. `GRANT SELECT ON public.expense_imports TO authenticated;` — **sin** `INSERT`/`UPDATE`/`DELETE` para ningún rol de aplicación, **nada** para `anon` (alineado con `20261035000001`).
3. `ALTER TABLE public.expenses ADD COLUMN IF NOT EXISTS import_id uuid;` + FK con `DROP CONSTRAINT IF EXISTS` previo + `CREATE INDEX IF NOT EXISTS`.
4. Extensión del `CHECK` de `operation_idempotency.operation_kind` con `'expense_import'`, con el **mismo molde** que `20260805000001:81-110` (`ALTER TABLE ... DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT` con la lista completa + `COMMENT`). Ojo: la lista debe copiarse de la **definición viva** (`pg_get_constraintdef`), no del último archivo de migración que la tocó.
5. `CREATE OR REPLACE FUNCTION public.rpc_import_expenses(...)` — función **nueva**, así que `CREATE OR REPLACE` alcanza y **no hace falta `DROP`** (no hay firma previa que colisione, no hay riesgo de `42725`).
6. ACLs explícitas en el mismo archivo: `REVOKE ALL FROM PUBLIC`, `REVOKE EXECUTE FROM anon`, `GRANT EXECUTE TO authenticated`.
7. **Sin backfill.** Los gastos ya importados conservan `import_id IS NULL` y su ausencia de imputación: no hay dato del que derivar con qué se pagaron. Es el mismo criterio, ya firmado, de D7 de `gastos-forma-pago` (175 gastos históricos) y de `caja-compras-cobranzas` (11 documentos).

**Gates.**

- **Gate SQL nuevo** `supabase/tests/test_expense_import_batch.sql`, cableado en `.github/workflows/KPI_Validation.yml` con `psql -v ON_ERROR_STOP=1` como los ~40 que ya están. Bloques mínimos:
  1. **Todo o nada**: lote de 3 filas con la 2.ª inválida → `committed=false`, `errors[].row = 2`, y **0 filas** nuevas en `expenses`, `bank_movements`, `cash_movements`, `expense_imports`, `operation_idempotency`.
  2. **Camino feliz**: lote de 3 filas válidas (una `cash`, una `transfer`, una sin forma de pago) → 3 gastos, **1** movimiento bancario, **0** movimientos de caja, `import_id` poblado en las tres.
  3. **Caja jamás** (control negativo de D6): fila `cash` **de hoy**, con sesión de caja **abierta** en la sucursal → el gasto entra y `cash_movements` **no crece**. Sin este caso, D6 sería verdadero por omisión.
  4. **Equivalencia con el alta directa**: el mismo gasto por el lote y por `rpc_create_expense` producen el mismo gasto y el mismo movimiento bancario (verifica la llamada anidada).
  5. **Simulación**: `p_dry_run := true` sobre un lote válido → `committed=false` y **cero** filas nuevas en las cinco tablas.
  6. **Tope**: 501 filas → `P0427`, cero escrituras.
  7. **Nombre que no resuelve**: `Forma de pago = 'Transferenca'` → error de fila con el código, y nada escrito.
  8. **Tenencia**: forma de pago / sucursal / centro de costo / cuenta bancaria de **otra** cuenta → error de fila (`P0404`/`P0412`), nada escrito, nada tocado en la otra cuenta.
  9. **Idempotencia y dedupe**: mismo `Idempotency-Key` dos veces → `replayed`, sin segundo lote. Mismo `file_hash` con otra clave → `replayed`.
  10. **ACLs**: `anon` sin `EXECUTE` sobre `rpc_import_expenses`; `authenticated` sin `INSERT` sobre `expense_imports`.
- **Gate de ACLs existente**: sus chequeos (2) y (4) ya barren por convención de nombre; la función nueva entra sola.
- **Anti-overload**: no aplica (función nueva, sin firma previa) — se deja constancia para que nadie lo agregue por inercia.

**Rollback.** El change es aditivo: retirar la migración implica `DROP FUNCTION public.rpc_import_expenses(...)`, revertir el `CHECK`, `DROP COLUMN expenses.import_id` y `DROP TABLE expense_imports`. Ningún dato existente cambia, así que el rollback no pierde nada escrito antes del change. Con el frontend desplegado y la RPC ausente, el importador fallaría con 500 — por eso el orden de despliegue es el habitual del repo (merge → migración automática → build), sin ventana en la que el cliente exista sin su RPC.

## Open Questions

**OQ-1 — ¿La RPC de lote o un endpoint FastAPI transaccional?** *(la pregunta que el brief pide decidir explícitamente)*
**Recomendación: RPC de lote (D1).** Es DEC-24 aplicada tal cual, es el molde ya probado de `rpc_import_bank_statement`, y deja la garantía de atomicidad en la capa que es autoridad para todos los callers presentes y futuros, no sólo para el frontend. Ya está decidido en D1; se lista acá para que el PO pueda objetarlo antes del apply.

**OQ-2 — Gastos importados en efectivo: ¿sin movimiento de caja con aviso, o rechazo de la fila?**
**Recomendación: sin movimiento de caja + aviso explícito por fila (D6), nunca rechazo.** Rechazar una fila en efectivo convertiría un problema de arqueo en un problema de registro —el error que D1 de `gastos-forma-pago` argumenta evitar— y dejaría fuera del sistema justo los gastos que el microemprendedor carga en planilla. Falsear el arqueo posteando retroactivo está descartado por RN-95. *Variante disponible si el PO la pide*: un opt-in de lote que postee **sólo** las filas de hoy con caja abierta; cuesta una elegibilidad por fila y un aviso más, y no lo recomiendo (el formulario ya cubre ese caso).

**OQ-3 — ¿El template suma también `Sucursal` y `Centro de costo`, o sólo `Forma de pago`?**
**Recomendación: las tres (D4).** La sucursal no es decorativa: es la que se estampa en el movimiento bancario y la que RN-93 exige, y hoy el importador la descarta al 100 % —el mismo bug que `gastos-forma-pago` corrigió para el formulario—. El centro de costo comparte resolutor. El costo marginal es bajo y la alternativa deja el agujero a medio cerrar.

**OQ-4 — ¿Tope de 500 filas por lote?**
**Recomendación: 500, con rechazo y sin trocear (D8).** Si el PO conoce archivos reales más grandes, 1000 es un cambio de constante (RPC + gate + cliente). Lo que **no** se negocia es trocear: rompe la atomicidad que motiva el change.

**OQ-5 — ¿Se estrena `P0427` para el payload malformado, o se reusa `P0400`?**
**Recomendación: `P0427`.** Distingue "el archivo está mal armado" (acción: rehacer el archivo) de "esta fila viola una regla de negocio" (acción: corregir la fila), y el frontend puede rotularlos distinto sin adivinar por el texto. `P0400` funcionaría igual; es una preferencia de diagnóstico.

**OQ-6 — ¿Matcheo de nombres insensible a tildes?**
**Recomendación: no, por ahora.** Exigiría instalar `unaccent` (extensión nueva en producción) para cubrir un caso que hoy no existe: ninguno de los siete nombres sembrados lleva tilde. El error de fila lista los nombres válidos, así que el usuario ve exactamente qué escribir. Si aparecen catálogos con tildes en uso real, es un cambio de una función.

**OQ-7 — ¿Se conserva el botón "Exportar" / `ExportButton` como camino de ida y vuelta?**
**Recomendación: sí, y sin tocarlo.** Fuera de alcance, pero vale decirlo: el CSV que `/gastos` exporta hoy **no** tiene el mismo juego de columnas que el template de importación, así que "exportar → editar → reimportar" no es un ciclo cerrado. Alinearlos sería útil y es un candidato barato para después; meterlo acá ensancharía el diff sobre `data-export`.

**OQ-8 — ¿Se necesita alguna verificación en producción después del merge?**
**Recomendación: sí, tres, todas de lectura**: (a) `MAX(version)` = la migración nueva; (b) ACLs vivas de `rpc_import_expenses` (sin `EXECUTE` para `anon`) y de `expense_imports` (sin `INSERT` para `authenticated`); (c) humo real del PO con un archivo suyo de gastos del mes, con al menos una fila por transferencia, verificando que el movimiento aparece en `/banco` y que la caja **no** se movió.
