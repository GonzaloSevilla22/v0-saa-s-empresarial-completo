# Design — asiento-contable-gastos

## Context

### De dónde viene

`gastos-forma-pago` (archivado 2026-08-30, `openspec/changes/archive/2026-08-30-gastos-forma-pago/`) dejó el gasto con forma de pago, con movimiento de caja bajo opt-in y con movimiento bancario incondicional, y **difirió explícitamente el asiento contable** (D10 de ese design): *"`_journal_post_from_event` no tiene rama de gasto y `public.events` no tiene ningún `event_type` de gasto. Este change deja lista la forma de pago, que es el dato que le falta al asiento futuro para elegir la contrapartida."* El PO aprobó cerrar el candidato el 2026-09-07 dentro del programa "cero candidatos".

### Inventario de la superficie viva

Todo lo que sigue se leyó del **cuerpo vivo** en la base local migrada (`supabase_db_v0-saa-s-empresarial-completo`, al día con `main` hasta `20261040000001` más la migración en vuelo de `importador-gastos-transaccional`), no de los archivos de migración. Los `md5` son de esa base; **el apply debe re-hashear contra producción antes de escribir SQL** (regla de integridad de función, `metodos-pago-operaciones`).

| Objeto vivo | `md5(pg_get_functiondef)` | Largo | Rol en este change |
|---|---|---|---|
| `rpc_create_expense(text,numeric,date,text,uuid,uuid,uuid,uuid,uuid)` | `4a31c7c6911fe247c76d243eff3e445e` | 12 944 | Productor de `ExpenseCreated` |
| `rpc_update_expense` | `e21c443ade72c915255a5aa8d3236330` | 7 708 | Productor de `ExpenseAdjusted` |
| `rpc_delete_expense(uuid)` | `b76e0fb7862f05aa610d049104fea45a` | 6 640 | Productor de `ExpenseDeleted` |
| `_journal_post_from_event(events)` | `da103f22ebcc1a33bf98c3c2c516a66c` | 39 009 | Tres ramas nuevas + filtro 11→14 |
| `rpc_process_outbox_dispatch(int)` | `8462768d81778e912d61a661b13072de` | 6 550 | Filtro del Consumer 3, 11→14 |
| `_journal_sale_debit_account(text)` | `6c3abe8028f0f4fac4d2495fbe73df5b` | — | **Molde** del helper nuevo (no se toca) |
| `rpc_import_expenses(...)` | `21d323a502f914127454b1d96b21b167` | 13 605 | **No se toca** — delega en `rpc_create_expense` |

Hechos verificados que gobiernan el diseño:

- **No existe tabla de plan de cuentas.** `select … information_schema.tables where table_name ilike '%chart%'` → 0 filas. Los códigos contables son literales de texto dentro de `_journal_post_from_event`; el encabezado de esa función documenta el plan mínimo PYME AR: `1100 Caja`, `1110 Banco`, `1300 Deudores por Ventas`, `2100 Proveedores`, `4100 Ventas`, `4200 IVA Débito Fiscal`, `5100 CMV/Compras`, `5200 IVA Crédito Fiscal` y — textual — **`5300 Gastos (reservado)`**.
- `journal_lines` tiene `CHECK (amount > 0)` y `side IN ('debit','credit')`; `journal_entries` tiene `CHECK (status IN ('posted','reversed'))`, `reversal_of` autorreferencial e **índice único parcial sobre `source_event_id`**. Las dos tablas sólo tienen política de `SELECT` por cuenta: se escriben únicamente desde `SECURITY DEFINER`.
- `public.events` **no tiene `CHECK` sobre `event_type`** → sumar tipos no requiere cambio de esquema.
- El relay es un `pg_cron` `* * * * *` que corre `rpc_process_outbox_dispatch(100)`, con `ORDER BY occurred_at … FOR UPDATE SKIP LOCKED`. **El orden de procesamiento respeta el orden de ocurrencia**, dato del que depende D6.
- `expenses.category` es `text NOT NULL` **sin `CHECK`**. La lista cerrada de 7 (`Alquiler`, `Servicios`, `Marketing`, `Logística`, `Personal`, `Impuestos`, `Otros`) vive sólo en el frontend, en `frontend/lib/constants.ts:161` (`EXPENSE_CATEGORIES`). La base acepta cualquier texto.
- `expenses` **no tiene `deleted_at`**: el borrado es físico (`rpc_delete_expense`, `DELETE FROM public.expenses` al final del cuerpo vivo).
- `rpc_update_expense` bloquea con `P0423` **sólo** si el gasto tiene movimiento de caja o movimiento bancario (dos `EXISTS`, líneas 47-60 del cuerpo vivo). Un gasto sin dinero posteado **es plenamente editable**, y la spec `expense-operation` lo declara normativo en dos escenarios.
- ACLs vivas: `_journal_post_from_event` y `rpc_process_outbox_dispatch` tienen `postgres` + `service_role`, **sin `authenticated`**; las tres RPC de gasto tienen además `authenticated`. `CREATE OR REPLACE` preserva ACLs; `DROP`+`CREATE` las resetea. Este change usa **sólo `CREATE OR REPLACE`** y no cambia ninguna firma.

### Dos hallazgos del propose que cambian el alcance

**(1) El gate del invariante canónico no corre en ninguna parte.** La spec `transactional-outbox` declara que el conjunto de tipos del consumidor contable *"SHALL verificarse con un gate automático … y SHALL NOT quedar sostenido únicamente por un comentario en el código"*. Ese gate existe y está bien hecho —`supabase/tests/test_cobranzas_reverso.sql`, bloque (11), con matriz de evasión ejecutada— pero `grep -n "test_cobranzas_reverso" .github/workflows/KPI_Validation.yml` **no devuelve nada**: el archivo nunca se cableó. Era un candidato heredado conocido; deja de ser opcional acá, porque este change es precisamente el que modifica el conjunto que ese gate custodia.

**(2) El libro diario es un backend sin puerta de entrada.** `GET /journal-entries` existe completo (router, service, repository, schemas Pydantic, tests) desde `journal-entry-outbox`. En el frontend, `journal` aparece **exclusivamente** en `frontend/lib/database.types.ts` (tipos generados). Cero páginas, cero hooks, cero componentes. Es el mismo anti-patrón que `CLAUDE.md` cita como origen de la regla de superficie obligatoria (`CostCenterManager` construido y jamás montado).

## Goals / Non-Goals

**Goals:**

- Que **todo** gasto —de alta manual, del importador, con o sin forma de pago— produzca su asiento de partida doble por el mismo mecanismo que la venta, la compra y los cobros: evento al outbox + rama en el consumidor contable.
- Que la corrección de un gasto (edición o borrado) deje rastro contable por contra-asiento, respetando RN-99 (*"ledgers append-only … se corrigen con contra-asiento"*, `knowledge-base/05_reglas_de_negocio.md:314`).
- Que el asiento del gasto sea **coherente con los libros de dinero** que el mismo gasto ya mueve: el crédito nombra la misma clase de cuenta a la que fue el `cash_movement` o el `bank_movement`.
- Que el invariante del conjunto canónico quede verificado por un gate que **efectivamente corre**.
- Que el usuario vea el rastro contable del gasto y pueda llegar al libro diario.

**Non-Goals:**

- **Tabla de plan de cuentas.** Los códigos siguen siendo literales en el helper, como las once ramas vivas. Convertir el plan en catálogo por cuenta es un change de modelo propio.
- **IVA crédito fiscal del gasto.** El gasto no tiene desglose de neto/IVA (`expenses` no tiene columnas de IVA) — el asiento es de dos líneas, sin `5200`. Discriminar IVA en gastos exige primero un modelo de comprobante de gasto.
- **Backfill de los gastos históricos** (ver OQ-3).
- **Sub-cuentas por categoría de gasto** (ver D3 y OQ-1).
- **Asiento del cierre de caja, del ajuste de stock ni de ningún otro tipo diferido.** El conjunto pasa de once a catorce y ni uno más.
- **Cambios en el importador de gastos.** Hereda el productor por delegación (D1).
- **Exportación contable del libro diario** (a CSV, a un formato de estudio contable). La pantalla es de consulta.

## Decisions

### D1 — El productor vive en las tres RPC de gasto, y el importador no se toca

`rpc_import_expenses` (la migración en vuelo de `importador-gastos-transaccional`) invoca `public.rpc_create_expense(...)` fila por fila y documenta en su propio cuerpo que *"invoca `rpc_create_expense`, NO la reimplementa (D1)"*. Poner el `INSERT INTO public.events` dentro de `rpc_create_expense` hace que **el gasto importado emita su evento sin una línea de código en el importador**, y sin una segunda definición de "qué evento produce un gasto".

Los tres `INSERT` son planos, sin `EXCEPTION`, en la misma transacción que la mutación. La spec `transactional-outbox` ya lo exige textualmente para los productores contables y explica por qué: *"tragarse un evento fallido mientras la anulación commitea dejaría los libros de dinero compensados y el libro diario no, en silencio y de forma irrecuperable."*

*Alternativa descartada*: un trigger `AFTER INSERT/UPDATE/DELETE` sobre `expenses`. Se descarta porque el evento necesita el `kind` derivado del catálogo y la sucursal efectiva, que el trigger tendría que recalcular —una segunda definición de lo que la RPC ya resolvió— y porque ningún otro productor del sistema usa triggers.

**Consecuencia medida**: un lote de importación de N filas emite N eventos. Con el relay en lotes de 100 por minuto, una importación de 500 gastos tarda ~5 minutos en asentarse por completo. Es aceptable —el outbox es asíncrono por diseño (DEC-20)— pero la pantalla del libro diario debe tolerar el desfase sin parecer rota (D9).

### D2 — Tres tipos de evento, no uno

`ExpenseCreated`, `ExpenseAdjusted`, `ExpenseDeleted`. Es exactamente el juego que la venta por formulario ya tiene (`SaleOperationCreated` / `SaleOperationAdjusted` / `SaleOperationDeleted`) y por la misma razón: las tres transiciones producen asientos de forma distinta (asiento nuevo / par contra-asiento + asiento nuevo / contra-asiento solo) y el consumidor tiene que poder distinguirlas sin inspeccionar el documento —que en el caso del borrado **ya no existe**.

*Alternativa descartada*: un único `ExpenseChanged` con un discriminador en el payload. Se descarta porque el filtro del Consumer 3 es por `event_type` y el gate del invariante compara conjuntos de `event_type`: meter el discriminador adentro del payload lo sacaría del alcance del gate, que es justamente la red que este change refuerza.

`aggregate_type = 'Expense'`, `aggregate_id = expense_id` en los tres.

### D3 — Débito: una sola cuenta `5300 Gastos`, con el centro de costo en la línea

El débito es una línea única a `5300 Gastos` por el total del gasto, llevando el `cost_center_id` del gasto — mismo trato que `5100 CMV/Compras` le da al centro de costo en la rama `PurchaseCreated`.

Contra la alternativa de mapear las 7 categorías a sub-cuentas `53xx`:

1. **`expenses.category` es texto libre en la base.** El `CHECK` no existe; la lista cerrada vive sólo en `frontend/lib/constants.ts`. Un mapa de códigos indexado por texto libre **caería silenciosamente al default** para cualquier categoría que llegue por la API, por el importador (que valida contra la misma constante, en el cliente) o por una edición futura de esa lista. Es el modo de falla exacto que este proyecto ya pagó caro varias veces.
2. **La dimensión analítica ya existe y es la correcta**: `cost_centers`, con catálogo por cuenta, activo, y ya presente en `journal_lines.cost_center_id`. Duplicarla en el código contable la haría divergir.
3. **`5300 Gastos` está reservada desde `journal-entry-outbox`**, con ese nombre y esa numeración, en el encabezado del helper. Usarla es cumplir un contrato ya escrito, no inventar uno.
4. Abrir sub-cuentas después es aditivo y no rompe nada: los asientos ya posteados a `5300` siguen siendo válidos como cuenta madre.

### D4 — Crédito: helper `_journal_expense_credit_account(kind)`, espejo del helper de venta

```
_journal_expense_credit_account(p_kind text) → text   -- LANGUAGE sql, IMMUTABLE
  kind IN ('transfer','card','check','wallet')  → '1110'   -- Banco
  ELSE (cash, other, NULL)                      → '1100'   -- Caja
```

Es `_journal_sale_debit_account` **menos el caso `credit`/`1300`**, que el gasto rechaza en la puerta (`P0400`, `credit_not_supported_for_expense`, ya vivo en las tres RPC y normativo en `expense-operation`). La simetría es real y no cosmética: la venta **debita** donde el dinero entra, el gasto **acredita** donde el dinero sale; para el mismo `kind`, es la misma cuenta.

Los cuatro `kind` bancarios no son una presunción: `rpc_create_expense` llama a `_pay_register_operation_bank_movement` de forma **incondicional** y el helper postea un `bank_movement` real justamente para esos cuatro. El asiento nombra la cuenta del libro que efectivamente se movió.

**`cash` acredita `1100` aunque no haya habido movimiento de caja.** El opt-in de caja gobierna el *arqueo* (que el egreso quede en una sesión conciliable), no el hecho de que la plata salió en efectivo. Es además el precedente literal de la rama `PurchaseCreated`, que acredita `1100` para `cash` sin consultar si existe el movimiento —y la compra tiene el mismo opt-in desde `caja-compras-cobranzas`—. Ver OQ-2.

**Sin forma de pago imputada → `1100 Caja`**, por el `ELSE` del helper. No `2100 Proveedores`: un gasto no tiene contraparte con cuenta corriente (es la premisa del rechazo de `credit`), así que acreditar Proveedores inventaría una deuda con un proveedor que no existe. Es además el precedente literal del lado de la venta (`_journal_sale_debit_account`, comentario D3: *"cash, other, NULL (sin imputar) — espejo de los subledgers"*). Ver OQ-1.

*Se crea un helper y no un `CASE` embebido* porque el helper es lo que hace testeable el mapeo sin montar un gasto completo, y porque duplicar un `CASE` de cuatro ramas en tres lugares de la misma función es exactamente lo que la regla de reutilización prohíbe.

### D5 — El asiento se fecha por el gasto, no por la corrida del relay

`posted_at` del asiento de alta = la fecha del gasto. Se reutiliza el idioma exacto de `SaleOperationCreated`, que ya está vivo y resuelto:

```sql
v_posted_at := ((v_payload->>'expense_date')::date + TIME '12:00:00')
               AT TIME ZONE 'America/Argentina/Mendoza';
```

El mediodía evita que un gasto fechado hoy caiga en el día anterior o el siguiente al convertir a `timestamptz`, y la zona es la del negocio (`business-day-timezone`). Si el payload no trae fecha, `now()` — mismo degradado que la venta.

Los contra-asientos (edición y borrado) llevan `posted_at = now()`: **la corrección data la corrección, no el documento original**. Es la regla ya escrita en las cinco ramas de reversión vivas y normativa en `journal-entry` (*"El contra-asiento de anulación se fecha en el momento de la anulación"*).

⚠️ Nota de tipos que el apply no puede pasar por alto: `rpc_create_expense` recibe `p_date date` pero **`expenses.date` es `timestamp with time zone`**. El payload debe llevar la fecha como `date` pura (la que entró por parámetro en el alta; `(v_expense.date)::date` en la edición y el borrado). Nunca el `timestamptz` crudo: el cast se resolvería en la zona de la *sesión* del relay (UTC), que es el bug de corrimiento de día que `gastos-forma-pago` documentó a lo largo de veinte líneas en su propio cuerpo.

### D6 — El gasto sigue siendo editable: se ajusta el asiento, no se congela el documento

El asiento posteado **no** se suma a los guards `P0423`. Un gasto sin movimiento de caja ni bancario sigue siendo plenamente editable, y su edición emite `ExpenseAdjusted`, que postea el par contra-asiento + asiento nuevo (molde `SaleOperationAdjusted`).

Es la única opción compatible con lo que ya está escrito y firmado:

- La spec `expense-operation` declara normativos dos escenarios —*"Editar un gasto sin dinero posteado → la edición procede normalmente"* y *"Los gastos históricos siguen siendo editables"*—. Sumar el asiento a `P0423` los rompería a los dos, y volvería inmutable **todo** gasto: una regresión de producto que nadie pidió.
- El PO ya decidió este mismo trade-off para la venta el 2026-08-20 (`asiento-venta-formulario` D7, "override del PO"), y la spec `journal-entry` lo dejó escrito: *"los backfilleados siguen siendo editables exactamente como cualquier otra operación con asiento posteado … una edición después del backfill simplemente produce el par contra-asiento/asiento nuevo."*

*Alternativa descartada*: extender `P0423` al asiento. Más simple de implementar y **peor producto**; además contradice dos cláusulas normativas vigentes y un override firmado.

### D7 — Los productores de ajuste y borrado se emiten **sólo si el gasto tiene un `ExpenseCreated` previo**

Este es el hallazgo de diseño más importante del propose, y sin él el change introduce un evento envenenado en producción.

La rama de borrado localiza el asiento vigente y, si no lo encuentra, levanta `P0451` para que el evento quede *pending* y se reintente. Es el comportamiento correcto ante una carrera (el borrado procesado antes que el alta). Pero como **no se backfillean los gastos históricos** (OQ-3), esos gastos **nunca** van a tener asiento: borrar uno emitiría un `ExpenseDeleted` que falla con `P0451` en cada corrida del relay, **cada minuto, para siempre**, sin que nada lo note salvo el ruido en `internal_logs`.

Solución: el productor de `ExpenseAdjusted` y el de `ExpenseDeleted` emiten **sólo si existe un evento `ExpenseCreated` para ese `expense_id` en `public.events`**:

```sql
IF EXISTS (SELECT 1 FROM public.events
           WHERE event_type = 'ExpenseCreated'
             AND aggregate_id = p_expense_id
             AND account_id = v_account_id) THEN
   -- emitir
END IF;
```

El predicado es sobre la **existencia del evento**, no sobre la del asiento, y esa distinción es la que resuelve la carrera: un gasto creado y borrado dentro del mismo minuto tiene su `ExpenseCreated` sin procesar, así que el `ExpenseDeleted` **sí** se emite; el relay procesa `ORDER BY occurred_at` (verificado en el cuerpo vivo) y ve el alta antes que el borrado dentro del mismo lote. Si quedaran en lotes distintos, el `P0451` de reintento resuelve — que es literalmente el caso (10) del gate de `cobranzas-reverso`.

Un gasto histórico no tiene `ExpenseCreated` → no emite nada → no hay evento envenenado, y el gasto se borra exactamente como hoy.

### D8 — Once a catorce, en los dos filtros, con el gate corriendo de verdad

El conjunto canónico pasa a: `SaleConfirmed`, `PurchaseCreated`, `SaleOperationCreated`, `SaleOperationAdjusted`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`, `SaleOperationDeleted`, `PurchaseDeleted`, `PaymentReceivedReversed`, `PaymentMadeReversed`, **`ExpenseCreated`, `ExpenseAdjusted`, `ExpenseDeleted`** — catorce, listados idénticos en `_journal_post_from_event` y en el Consumer 3 de `rpc_process_outbox_dispatch`.

El gate del bloque (11) de `test_cobranzas_reverso.sql` extrae los dos conjuntos de los cuerpos vivos por `substring(... from 'v_event_type NOT IN \(([^)]*)\)')` y `'Consumer 3: JournalEntry.*?IN \(([^)]*)\)'`. **Los dos anclajes de texto sobreviven** al cambio (no se toca el `NOT IN` del helper ni la marca de comentario `Consumer 3: JournalEntry`), así que sólo hay que actualizar `v_expected` de once a catorce entradas — y **cablear el archivo a `KPI_Validation.yml`**, que es lo que hoy falta.

*Alternativa considerada*: extraer el bloque (11) a un `test_outbox_canonical_event_types.sql` propio y cablear sólo ése, dejando `test_cobranzas_reverso.sql` sin correr. Se descarta: el resto de ese archivo son doce bloques de cobertura real del reverso de cobranzas que también deberían estar corriendo, y separarlos deja la mitad del problema en pie. Se cablea el archivo entero. **Riesgo asumido y explícito**: es la primera corrida en CI de ~950 líneas de gate que nunca corrieron; el apply debe correrlo local contra `supabase db reset` **antes** de cablearlo, y tratar cualquier rojo preexistente que aparezca como hallazgo a reportar, no como algo que este change rompió.

### D9 — Superficie frontend: el estado en `/gastos` y una pantalla de libro diario

Dos superficies, porque una sola no alcanza: un distintivo que dice "hay asiento" sin ningún lugar donde verlo es un callejón sin salida, y un libro diario que no se conecta con el gasto obliga a buscar a mano.

**(a) `/gastos`** — la fila gana el estado contable del gasto, en las **dos** renderizaciones que la página ya tiene (tabla de escritorio ~L349 y tarjetas móviles ~L389 de `frontend/app/(dashboard)/gastos/page.tsx`). Tres estados, con tokens semánticos y sin color literal:
- **Asentado** — hay asiento vigente; enlaza al libro diario filtrado por ese gasto.
- **Pendiente** — hay evento sin procesar; el relay corre cada minuto (D1: una importación grande se asienta de a lotes). El texto tiene que decir "en unos minutos", no parecer un error.
- **Sin asiento** — gasto histórico, anterior a este change. Estado legítimo y explicado, no un fallo.

**(b) `/reportes/libro-diario`** — pantalla nueva en el grupo **Reportes** del `frontend/components/app-sidebar.tsx` (donde ya viven "Centros de costo" y "Formas de pago", `app-sidebar.tsx:83-87`), sin gate de plan, por el mismo criterio que esos dos: es la lectura de datos que el usuario ya generó. Lista de asientos con fecha, tipo de documento, estado, y sus líneas de débito/crédito expandibles; filtros por rango de fechas, tipo de documento y estado. Ambos temas y ambos anchos, verificados antes del merge.

*Alternativa descartada*: sólo el distintivo, dejando el libro diario como candidato. Se descarta porque el endpoint sin superficie es el anti-patrón que la regla del PO existe para prevenir, y este change es el primero que le da al usuario una razón concreta para querer mirar el diario.

### D10 — El endpoint del libro diario suma filtros; no nace un endpoint nuevo

`GET /journal-entries` ya existe con envoltura `{items,total,page,pages}` (`backend/routers/journal_entries.py`) y **no tiene ningún filtro**: devuelve todo, `ORDER BY posted_at DESC`. Se le suman `from`, `to`, `source_doc_type`, `source_doc_ref` y `status` como `Query` opcionales, empujados hasta el `WHERE` del repositorio. No se crea un endpoint paralelo (regla de reutilización). El filtro por `source_doc_ref` es el que hace posible el enlace desde la fila del gasto.

### D11 — Los derivados contables se calculan en SQL, en el repositorio del gasto

`ExpenseOut` suma `has_journal_entry` y `journal_pending`, calculados con `EXISTS` en la consulta de `backend/repositories/expense_repository.py`, junto a los tres derivados que ese archivo ya calcula así (`has_cash_movement`, `has_bank_movement`, `is_payment_locked`, líneas 68-85). Es el patrón establecido y evita una segunda consulta por fila.

`cobranzas-reverso` dejó la lección explícita de que **hay que agregar el derivado en todas las consultas que alimentan pantallas reales**, no sólo en la paginada: en aquel caso los derivados se sumaron a `list_movements_page` y las pantallas usaban `list_movements`, así que la acción nunca habría aparecido pese a tests unitarios en verde. El apply debe inventariar los caminos de lectura de gasto antes de dar por cerrado el punto.

### D12 — Migración idempotente, `CREATE OR REPLACE` en todo, y un solo archivo

Un archivo, reservando **`20261042000001_asiento_contable_gastos.sql`**. ⚠️ El número está en disputa: `main` está en `20261040000001` y `importador-gastos-transaccional` está en vuelo sin número fijado en su design. **El apply debe re-verificar `MAX(version)` en producción y renumerar si hace falta** — este proyecto ya renumeró una migración tres veces (`cuenta-corriente-party-guard`).

Todo el SQL es re-ejecutable: `CREATE OR REPLACE FUNCTION` para las cinco funciones reescritas y para el helper nuevo. Ninguna cambia de firma → **ninguna necesita `DROP`+`CREATE`** → las ACLs se preservan y no hace falta re-`REVOKE` (a diferencia del gotcha `42725` que este proyecto arrastra en las RPC con `DEFAULT` nuevos). El helper nuevo sí necesita su `REVOKE ... FROM anon, authenticated` explícito en el mismo archivo, para pasar el gate de ACLs: es `IMMUTABLE` y de lectura pura, pero `_journal_sale_debit_account` tampoco tiene `authenticated` y la simetría se mantiene.

**Regla de integridad de función**: cada una de las cinco reescrituras parte del `pg_get_functiondef` **vivo de producción**, no del último archivo de migración. `compras-proveedor-cuenta-corriente` encontró un cuerpo vivo divergido del archivo por una reescritura in-place; el apply debe re-hashear y comparar contra la tabla de esta sección antes de escribir una línea.

### D13 — Idempotencia: la que ya hay alcanza

`_journal_post_from_event` reclama `(event_id, 'JournalEntry')` en `operation_idempotency` antes de despachar, reforzado por el índice único parcial sobre `journal_entries.source_event_id`. Las tres ramas nuevas entran **después** de ese reclamo, igual que las once vivas: no necesitan idempotencia propia. Reprocesar un `ExpenseCreated` no postea un segundo asiento.

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **Se escriben registros contables sobre datos reales por un camino asíncrono** (governance MEDIA, tramo ALTO). | El fallo de posteo deja el evento *pending* y no aborta el lote (`BEGIN/EXCEPTION` por evento, ya vivo). El `ASSERT` de balance `P0450` cubre las tres ramas nuevas sin código adicional. Verificación post-merge en producción obligatoria (conteos de eventos, asientos y balance). |
| **Evento envenenado al borrar un gasto histórico** — reintento infinito cada minuto. | D7: el productor de borrado/ajuste sólo emite si existe `ExpenseCreated`. Cubierto por caso de gate dedicado. |
| **El asiento del alta se postea con la fecha corrida un día.** | D5: el payload lleva `date` pura, nunca `timestamptz`; el idioma de `posted_at` se copia literal del que ya está vivo. Caso de gate con un gasto fechado en el borde del día. |
| **Cablear ~950 líneas de gate que nunca corrieron pone `KPI_Validation` en rojo por algo ajeno.** | D8: correrlo local contra `supabase db reset` **antes** de cablearlo. Si aparece un rojo preexistente, se reporta como hallazgo con su causa; no se silencia el gate ni se cablea a medias. |
| **La importación de un lote grande deja gastos "Pendiente" varios minutos.** | D9: el estado pendiente se comunica como espera, no como error. La página no bloquea ninguna acción por él. |
| **`5300` no distingue categorías, y el PO podría querer el desglose.** | D3: el centro de costo ya da la dimensión analítica; abrir sub-cuentas después es aditivo. OQ-1 lo pone en decisión explícita. |
| **`test_cobranzas_reverso.sql` deja huérfanos de fixture al correr en CI.** | Es el patrón conocido de `test_admin_kpis.sql`. El apply verifica que su bloque de limpieza final resuelva por email y no deje filas; si deja, se reporta. |
| **El número de migración choca con el change en vuelo.** | D12: re-verificar `MAX(version)` en el apply y renumerar. |

## Migration Plan

1. **Antes de escribir SQL**: re-hashear en producción las cinco funciones de la tabla de inventario y comparar con esta página. Cualquier divergencia se resuelve partiendo del cuerpo vivo, y se reporta.
2. **Mediciones de producción** (lectura, ejecutables por el orquestador — alimentan OQ-3):
   ```sql
   -- (a) universo de gastos y cobertura de forma de pago
   SELECT count(*) AS total,
          count(payment_method_id) AS con_forma_pago,
          count(*) FILTER (WHERE payment_method_id IS NULL) AS sin_forma_pago
   FROM public.expenses;

   -- (b) reparto por kind (el que decide la contrapartida)
   SELECT COALESCE(pm.kind,'(sin imputar)') AS kind, count(*), sum(e.amount)
   FROM public.expenses e
   LEFT JOIN public.payment_methods pm ON pm.id = e.payment_method_id
   GROUP BY 1 ORDER BY 2 DESC;

   -- (c) cuántos gastos ya movieron dinero de verdad (candidatos "honestos" a backfill)
   SELECT count(*) FROM public.expenses e
   WHERE EXISTS (SELECT 1 FROM public.cash_movements cm
                 WHERE cm.reference_id = e.id AND cm.movement_type = 'expense')
      OR EXISTS (SELECT 1 FROM public.bank_movements bm
                 WHERE bm.source_doc_type = 'expense' AND bm.source_doc_ref = e.id);

   -- (d) control: que hoy no exista ningún asiento de gasto ni evento de gasto
   SELECT count(*) FROM public.journal_entries WHERE source_doc_type = 'Expense';
   SELECT event_type, count(*) FROM public.events
   WHERE event_type LIKE 'Expense%' GROUP BY 1;

   -- (e) salud del outbox antes de sumarle tres tipos
   SELECT count(*) AS pendientes, min(occurred_at) AS mas_viejo
   FROM public.events WHERE processed_at IS NULL;
   ```
3. **Apply**: migración única, `supabase db reset` local limpio, gates SQL en el orden real del workflow, backend `pytest`, frontend `vitest` + `tsc`, pasada visual en las cuatro combinaciones.
4. **Merge → despliegue automático** (`deploy.yml` corre `supabase db push --include-all`).
5. **Verificación post-merge en producción** (lectura): `MAX(version)`; una sola definición viva de cada función reescrita, sin sobrecargas; ACLs de las seis funciones sin `EXECUTE` para `anon` y sin `authenticated` en las dos contables; los dos filtros de `event_type` con los catorce tipos; y, tras el primer gasto real, un asiento balanceado con `source_doc_type='Expense'`.
6. **Rollback**: revertir la migración reescribiendo las cinco funciones a su cuerpo previo (los `md5` de esta página son el ancla). Los asientos ya posteados **no se borran** —RN-99, los ledgers son append-only—: se revierten con contra-asiento si el PO lo pide. Los eventos ya emitidos quedan fuera del conjunto canónico y pasan a ser no-op, sin error.

## Open Questions

**OQ-1 — ¿Qué acredita un gasto sin forma de pago imputada?**
(a) **`1100 Caja`** — espejo literal del `ELSE` de `_journal_sale_debit_account` (*"cash, other, NULL (sin imputar)"*), y el supuesto más razonable para un microemprendedor que carga un gasto sin decir cómo lo pagó. (b) `2100 Proveedores`, tratándolo como deuda. (c) No asentarlo.
→ **Recomendación: (a)**. (b) inventa una deuda con un proveedor inexistente —el gasto no tiene contraparte, que es la premisa por la que se rechaza `credit`—; (c) deja el resultado del período incompleto, que es el problema que este change vino a cerrar.

**OQ-2 — ¿El `kind='cash'` sin opt-in de caja acredita igual `1100`?**
(a) **Sí, siempre** — el opt-in gobierna el arqueo, no el hecho de que el efectivo salió; y es el precedente literal de `PurchaseCreated`, que acredita `1100` para `cash` sin consultar el movimiento, teniendo la compra el mismo opt-in. (b) Sólo si existe el `cash_movement`; si no, tratarlo como sin imputar.
→ **Recomendación: (a)**, por precedente vivo en la misma función y porque (b) haría que dos gastos idénticos posteen cuentas distintas según si había una caja abierta, que es una regla difícil de explicar.

**OQ-3 — ¿Se backfillean los gastos históricos?**
(a) **No** — ningún asiento retroactivo. (b) Sólo los que movieron dinero de verdad (medición (c) del plan). (c) Todos.
→ **Recomendación: (a)**, con la medición sobre la mesa antes de firmar. `gastos-forma-pago` midió **0 de 175** gastos con forma de pago y el PO firmó dejarlos sin backfill; `caja-compras-cobranzas` dejó sus 11 documentos sin backfill por tres razones independientes. Un backfill de gastos sin forma de pago postearía el 100 % contra `1100 Caja` por el `ELSE` de OQ-1 — es decir, afirmaría que salieron en efectivo gastos de los que **no se sabe** cómo se pagaron, y lo dejaría escrito en un ledger append-only. Si el PO prefiere (b), es aditivo y se hace después con la vía que la spec ya exige: emitir eventos con `source='backfill'`, nunca `INSERT` directo a `journal_entries`.

**OQ-4 — ¿La pantalla del libro diario entra en este change o queda como candidato?**
(a) **Entra, mínima** (lista + filtros + líneas expandibles). (b) Sólo el distintivo en `/gastos`, y el libro diario aparte.
→ **Recomendación: (a)**. El endpoint lleva desde `journal-entry-outbox` sin un solo consumidor en el frontend; es el anti-patrón textual de la regla de superficie del PO, y este change es el primero que le da al usuario un motivo concreto para abrir el diario. Si el PO prefiere (b), el distintivo debe dejar de prometer un enlace que no existiría.

**OQ-5 — ¿El estado contable del gasto se muestra a todos los roles o sólo a los que pueden escribir?**
(a) **A todos los miembros de la cuenta** — `journal_entries` ya tiene política de `SELECT` por cuenta y el endpoint es de lectura para cualquier autenticado. (b) Sólo a roles de escritura.
→ **Recomendación: (a)**, por coherencia con la RLS y el endpoint ya vivos; restringir en el cliente lo que el servidor entrega es un candado decorativo.

**OQ-6 — Al cablear `test_cobranzas_reverso.sql`, ¿qué se hace si aparece un rojo preexistente?**
(a) **Reportarlo y arreglarlo en este PR** si es de una línea. (b) Reportarlo y abrir candidato, cableando igual. (c) No cablear.
→ **Recomendación: (a) con salida a (b)**. (c) queda descartada: dejaría el invariante que este change amplía sin verificación real, que es justo lo que la spec prohíbe.
