## Context

### El delete path vivo (verificado en código, 2026-08-21)

`SalesRepository.delete_by_id` y `PurchaseRepository.delete_by_id` son espejos byte a byte en su forma. Dentro de `async with self._conn.transaction()`:

1. `SELECT id, operation_id FROM sales|purchases WHERE id=$1 AND account_id=$2` → si no hay fila, `return False`.
2. `SELECT * FROM rpc_reverse_stock_movement(<row_id>, 'sale'|'purchase', <razón>)` — la reversa de stock, arreglada en #417.
3. `DELETE FROM sales|purchases WHERE id=$1`.
4. Si la operación se quedó sin filas, `DELETE FROM operation_idempotency`.

`delete_by_operation` es la misma secuencia iterando las filas de la operación. Los servicios (`delete_sale`, `delete_purchase`) sólo hacen `require_role(auth, ["user","admin"])` y traducen `False` a 404. Los routers exponen `DELETE /{id}` y `DELETE ?operation_id=` con 204.

**Cuatro huecos, todos confirmados**: (a) ningún guard fiscal — una venta con CAE se borra sin resistencia; (b) `customer_account_movements`, `cash_movements`, `bank_movements` y `journal_entries` no se tocan nunca; (c) la `sales_order` del POS queda viva apuntando a una venta que ya no existe; (d) la transaccionalidad es real (asyncpg abre una transacción de verdad), pero los guards que hoy no existen tendrían que evaluarse en round-trips separados de las escrituras.

### Las tres convenciones de referencia (medido en prod)

Cada libro referencia una cosa distinta. Esto es el hecho que gobierna todo el diseño:

| Libro | Columna | Apunta a | Evidencia en prod |
|---|---|---|---|
| `customer_account_movements` | `reference_id` | `sales.operation_id` | 2 de 3 filas `sale` matchean una operación viva; la tercera es el fantasma de Camila |
| `cash_movements` | `reference_id` | `sales_orders.id` | 63 de 63 |
| `bank_movements` | `source_doc_ref` (+ `source_doc_type`) | `operation_id` o `sales_orders.id` | 0 filas de venta todavía (el único movimiento es un cobro de cliente) |
| `journal_entries` | `source_doc_ref` (+ `source_doc_type`) | `operation_id` (`SaleOperation`) o `sales_orders.id` (`SalesOrder`) | 240 + 120 |
| `stock_movements` | `reference_id` (+ `reference_type`) | `sales.id` (la **fila**, no la operación) | resuelto por #417 |

El predicado que cubre las dos convenciones **ya existe y es canónico**: el guard `P0423` de `rpc_atomic_update_sale_operation` y su espejo de lectura en `SalesRepository.list_paginated_by_operation` (`is_payment_locked`), que consulta los tres libros por `s.operation_id` **y** por `so.id`. El change no inventa un localizador: reusa ese.

### Auditoría de daño histórico (prod `gxdhpxvdjjkmxhdkkwyb`, 2026-08-21)

| Libro | Huérfanos | Importe | Nota |
|---|---|---|---|
| Cuenta corriente cliente | 1 | $75.150 | Fantasma de Camila — **ya compensado** con el `adjustment` manual. Se excluye. |
| **Caja** | **2** | **$8.000** | Ventas POS borradas. Ambos en la sesión `85fc6698…`, **todavía abierta** desde el **2026-07-17** (más de un mes sin arqueo). Daño nuevo, no conocido. |
| Banco | 0 | — | El único candidato es un `transfer_in`/`payment_received` (cobro de cliente): falso positivo. |
| Journal `SaleOperation` | 3 | — | Asientos `posted` de operaciones inexistentes. |
| Journal `SalesOrder` | 3 | — | Asientos `posted` de ventas POS borradas (la orden sigue viva, el asiento no lo detecta). |
| Journal `Purchase` | 4 | — | Asientos `posted` de compras inexistentes. |
| `sales_orders` colgadas | 3 | — | `confirmed` con `sale_operation_id` apuntando a la nada. |

Total contable huérfano: **10 asientos**. `supplier_account_movements` está vacía (0 proveedores en prod), así que la pata de proveedor se cablea sin daño histórico que reparar.

### Restricciones de esquema que deciden por nosotros

Consultadas en prod, no supuestas:

- `customer_account_movements`: CHECK **de tabla** `balance_after >= 0`. No es una preferencia del helper — es un invariante del modelo. Y el vocabulario ya incluye `credit_note`, que es exactamente el tipo de una reversión de venta: **no hace falta ampliar el CHECK**.
- `cash_movements.movement_type` CHECK: `sale | purchase_payment | expense | advance | withdrawal`. **No hay tipo de reversión** — hay que ampliarlo.
- `bank_movements.movement_type` CHECK: incluye `transfer_in` y `transfer_out`. El espejo es invertir la dirección: **no hace falta ampliarlo**.
- `sales_orders.status` CHECK: `draft | confirmed | canceled` (una sola `l`). El vocabulario para cancelar ya está.
- `c28_register_cash_movement` exige sesión `open` (`no_open_session`, `P0409`) y `auth.uid()` para `created_by` (NOT NULL).
- MAX(version) en prod: **`20261004000002`**, 254 migraciones.
- **Códigos de error ocupados (censo en prod, `pg_get_functiondef` sobre todo `public`)**: `P0400, P0401, P0403, P0404, P0409, P0410, P0411, P0412, P0422, P0423, P0424, P0431, P0432, P0433, P0434, P0450, P0451`. **`P0424` YA ESTÁ TOMADO** por `pos-banco-movimientos` (D4: `value_date` dentro de un período de conciliación bancaria cerrado) y ya está mapeado a 409 en `backend/core/errors.py:113`. Por eso los dos bloqueos nuevos de este change toman los primeros libres, **`P0425`** (saldo negativo) y **`P0426`** (sin caja abierta). Un borrador previo de este mismo diseño los numeraba `P0424`/`P0425` y habría colisionado en producción: dos condiciones distintas bajo un mismo código, con un solo mensaje en la UI. El censo se re-corre antes de escribir la migración (task 1.4).

## Goals / Non-Goals

**Goals:**
- Que borrar una operación con dinero posteado deje los cuatro libros exactamente como estaban antes de crearla.
- Que "borrar y recrear" — el camino de corrección que la inmutabilidad de #423/#425 le dejó al usuario — sea seguro.
- Que una venta facturada deje de ser borrable.
- Que el usuario sepa **antes de confirmar** qué se va a compensar.
- Reparar el daño histórico medido, con conteos verificados y política explícita por libro.

**Non-Goals:**
- Modelar saldo acreedor (crédito a favor del cliente) en cuentas corrientes. Requiere cambiar el CHECK `balance_after >= 0` y el modelo de saldo — es un change propio.
- Soft delete de operaciones. El borrado sigue siendo físico sobre `sales`/`purchases`; lo que se vuelve append-only compensado son los libros.
- Flujo de Nota de Crédito para ventas facturadas. Este change bloquea; el camino fiscal correcto ya está especificado en `afip-fiscal-document`.
- Reparar los 139 huérfanos históricos de stock que el PO decidió dejar (RN-21, decisión de #417).

## Decisions

### D1 — Una RPC atómica `SECURITY DEFINER` por operación, no orquestación en Python

`rpc_delete_sale_operation(p_operation_id, p_sale_id, p_reason)` y `rpc_delete_purchase_operation(...)` concentran guard fiscal → guard de saldo → guard de caja → compensación de los cuatro libros → reversa de stock → cancelación de la orden → `DELETE` → limpieza de idempotencia. El repositorio Python queda como *caller* fino de una sola llamada.

**Por qué sobre la alternativa** (mantener la orquestación en Python con cada pata en un helper SQL, que es lo que el brief propuso evaluar):

1. **Los guards y las escrituras tienen que compartir lock.** El predicado de "tiene dinero posteado" se evalúa contra tres libros. Evaluado desde Python es un round-trip separado del `DELETE`: entre uno y otro, otra sesión puede postear un cobro que vuelve inválida la reversión que ya decidimos hacer. Dentro de la RPC, el `FOR UPDATE` que `c30_register_customer_account_movement` y `c28_register_cash_movement` ya toman sobre la cabecera de cuenta y de sesión serializa guard y escritura en el mismo instante. Esto es lo que decide la elección — no la elegancia.
2. **DEC-24 ya lo fijó**: UoW = RPCs `SECURITY DEFINER`. Las hermanas de esta operación (`rpc_create_sale_operation_v2`, `rpc_atomic_update_sale_operation`) ya viven así. Un delete orquestado en Python sería el único de los tres caminos con arquitectura distinta.
3. **Testeable con pgTAP** junto al resto, en `supabase/tests/`, sin mockear asyncpg.

**El punto delicado, verificado**: `rpc_reverse_stock_movement`, `c30_register_customer_account_movement` y `c28_register_cash_movement` dependen de `auth.uid()`. `SECURITY DEFINER` cambia el **rol**, no los GUC del JWT — `auth.uid()` sigue resolviendo al usuario real bajo el pool JWT-passthrough. Es exactamente lo que ya hace `rpc_atomic_update_sale_operation`. Por eso `created_by` de los contra-movimientos queda correctamente atribuido al usuario que borra, sin trabajo extra.

### D2 — Localización por el predicado canónico de las dos convenciones

La RPC resuelve una vez, al principio, el par `(operation_id, sales_order_id)` de la operación, y busca en cada libro por **ambos**. Es el mismo predicado del guard `P0423` y del `is_payment_locked` de lectura. Esto resuelve de paso el caso de la operación editada: la edición regenera `operation_id`, pero el predicado se evalúa sobre la operación **vigente**, que es la que tiene los movimientos vigentes; los movimientos de un `operation_id` anterior ya fueron compensados por el contra-asiento de la edición (#431) y por el REVERSE+APPLY de stock (#418).

### D3 — Fiscal: bloquear, no compensar (`P0423`)

Mismo predicado y mismo errcode que la edición. Borrar una operación con CAE es incoherencia ante ARCA: el comprobante existe en el organismo con independencia de nuestra base. El camino es la Nota de Crédito. Reusar `P0423` en vez de inventar un código nuevo mantiene un solo concepto — "esta operación está congelada por el fisco" — con una sola traducción en `backend/core/errors.py` y un solo mensaje en la UI.

### D4 — Cuenta corriente: `credit_note` negativo, y bloqueo `P0425` si dejaría saldo negativo

El tipo `credit_note` **ya está en el CHECK** y es semánticamente exacto. La reversión es un movimiento nuevo por el importe negativo: el ledger sigue append-only, el original permanece.

El bloqueo cuando el cliente ya pagó **no es una decisión de producto, es el esquema**: `balance_after >= 0` es un CHECK de tabla. Las tres salidas posibles eran (a) auto-generar un crédito a favor — inventa una devolución de dinero que nunca ocurrió y además viola el CHECK igual; (b) cambiar el modelo a saldo con signo — change propio, mucho mayor; (c) bloquear con un mensaje que nombre la acción real que falta. Elegimos **(c)**: `P0425`, *"El cliente ya canceló esta venta. Registrá primero la devolución del pago."* Es honesto: el sistema no puede deshacer una venta cuyo dinero ya entró sin que alguien diga qué pasó con ese dinero.

### D5 — Caja: contra-movimiento en la sesión abierta, nunca en un arqueo firmado (`P0426` si no hay)

Tres opciones estaban sobre la mesa. La elegida es **contra-movimiento en la sesión abierta actual de la misma caja**, por tres razones que apuntan al mismo lado:

- **RN-95 antifraude**: el arqueo de una sesión cerrada está firmado. Insertar un movimiento dentro de ella cambia retroactivamente un conteo que alguien ya validó y firmó. Es exactamente el escenario que la regla existe para impedir.
- **Fidelidad física**: el efectivo sale del cajón el día que se anula la venta, no el día que se hizo. La sesión abierta es donde el dinero realmente está.
- **El esquema lo fuerza a medias**: `cash_movements.session_id` es NOT NULL, así que "movimiento sin sesión" no existe como opción.

Si no hay sesión abierta en esa caja → `P0426`, *"Abrí la caja para poder anular esta venta."* Abrir la caja es la acción del mundo real que corresponde antes de sacar plata del cajón; el bloqueo no inventa fricción, la nombra.

Evidencia que respalda la elección: los 2 huérfanos históricos están en una sesión **abierta desde el 2026-07-17**, así que el grupo de reparación puede usar el mismo mecanismo.

Requiere ampliar el CHECK de `movement_type` con `sale_reversal`. Descartamos reusar `withdrawal` porque contaminaría los reportes de retiros con anulaciones, que son otra cosa.

### D6 — Banco: espejo siempre, `unreconciled`, incluso si el original está conciliado

Aquí la decisión es **opuesta** a la de caja, y la asimetría es deliberada. Una conciliación bancaria vincula una línea de extracto con un movimiento del libro: es **por movimiento**, no un cierre de período firmado. El movimiento original conciliado describe plata que efectivamente entró al banco — eso pasó y sigue siendo cierto. La reversión es un hecho **nuevo** (la devolución), que tendrá su propia línea de extracto y su propia conciliación. Bloquear sería negar un hecho ocurrido; auto-conciliar el espejo sería inventar una línea de extracto que no existe.

Por eso: espejo con dirección invertida (`transfer_in` ↔ `transfer_out`, vocabulario ya existente), `reconciliation_status='unreconciled'`, original intacto. Blast radius hoy: cero — no hay movimientos bancarios de venta en prod todavía.

### D7 — Contable: eventos nuevos `SaleOperationDeleted` / `PurchaseDeleted`, no reutilización de `Adjusted`

Rama nueva en `_journal_post_from_event`, calcada de la **primera mitad** de `SaleOperationAdjusted` (#431): localizar el asiento `posted` vigente, insertar la contra-entry con lados invertidos y `reversal_of`, marcar el original `reversed`. La segunda mitad (asiento nuevo de reemplazo) no aplica.

**Por qué evento nuevo y no reusar `Adjusted` con `new_operation_id` nulo**: además de la claridad, hay una ventaja concreta. `Adjusted` tiene que dejar la contra-entry con `source_event_id = NULL` porque el índice único parcial sobre esa columna admite una sola fila por evento, y se la lleva el asiento nuevo. En el borrado la contra-entry es la **única** entry del evento, así que **puede llevar su `source_event_id`** — la trazabilidad evento→asiento queda completa, mejor que en `Adjusted`.

La rama resuelve el asiento original probando las dos convenciones en orden: `('SaleOperation', operation_id)` y luego `('SalesOrder', sales_order_id)`. Así el borrado de una venta POS revierte su asiento de `SaleConfirmed`, que es el hueco que produjo 3 de los 10 huérfanos.

**Gate de integridad de función (regla del proyecto, 5 incidentes previos)**: la reescritura de `_journal_post_from_event` parte de `pg_get_functiondef` del **vivo en prod**, no del archivo de migración. Las ramas existentes — en particular el bloque fiscal de `SaleConfirmed` con su lookup a `fiscal_documents` — se conservan byte a byte, y un test lo verifica.

**Task 1.1-1.4, ejecutadas 2026-08-22** — Baseline capturado vía `pg_get_functiondef` **en vivo** sobre prod (`gxdhpxvdjjkmxhdkkwyb`) para las 7 funciones tocadas o invocadas por este change (`_journal_post_from_event`, `_pay_register_party_charge`, `c30_register_customer_account_movement`, `c28_register_cash_movement`, `_register_bank_movement`, `_pay_register_operation_bank_movement`, `rpc_reverse_stock_movement`), guardado byte a byte en `openspec/changes/delete-guard-ledgers/baseline/*.sql`. `MAX(supabase_migrations.schema_migrations.version)` re-confirmado en `20261004000002` (sin drift respecto de lo escrito arriba) → la migración de este change usa timestamp `20261005000001`. Censo de errcodes `P04xx` re-corrido sobre `pg_get_functiondef` de todo `public`: idéntico al listado de arriba (`P0400,401,403,404,409,410,411,412,422,423,424,431,432,433,434,450,451` — sin drift); `P0425`/`P0426` confirmados libres.

### D8 — POS: cancelar la `sales_order` en la misma transacción

Hoy borrar una venta POS deja la orden `confirmed` apuntando a la nada (3 casos en prod). La RPC la pasa a `canceled` y desvincula `sale_operation_id`, registrando la transición por el helper de historial de estados de `v3-document-status-history`. Si la orden tiene comprobante fiscal, D3 ya bloqueó antes de llegar acá.

### D9 — Reparación histórica: grupo gateado, escritura directa, `created_by` heredado

El grupo de reparación corre como migración, sin sesión de usuario: `auth.uid()` es NULL y `created_by` es NOT NULL en los dos ledgers de dinero. Por eso **no puede pasar por los helpers** — escribe directo, copiando `created_by` del movimiento original. Es el patrón que ya se usó a mano ayer para el ajuste de Camila.

Política por libro: los 2 movimientos de caja se compensan en su sesión (abierta, así que el arqueo no se toca); los 10 asientos se revierten con contra-asiento y pasan a `reversed`; las 3 órdenes se cancelan; el par de Camila se excluye por estar ya compensado; banco no tiene nada que reparar. Cada paso va gateado por su conteo verificado — si el conteo no coincide con lo medido, la migración no escribe.

### D10 — Frontend: diálogo que enumera, botón que explica su bloqueo

El `confirm()` nativo (*"¿Eliminar esta venta? Esta acción no se puede deshacer."*) no dice nada de dinero. Se reemplaza por un `AlertDialog` del design system que lista las compensaciones concretas ("se revertirá el cargo de $X en la cuenta de Fulano", "se registrará la salida de $Y en la caja abierta"), leídas del estado de borrabilidad que el listado ya expone. Cuando la operación no es borrable, el botón se deshabilita con su razón — mismo patrón visual que el lock de edición ya montado en `sale-operations-list.tsx`. Verificación en escritorio y móvil, tema claro y oscuro.

## Risks / Trade-offs

- **Reescribir `_journal_post_from_event` es tocar la función más cargada del sistema contable (7 ramas, 240+120+80 asientos vivos)** → Partir del `pg_get_functiondef` vivo, no del archivo; test que compara las ramas preexistentes byte a byte; el bloque fiscal declarado intocable.
- **`P0425` puede leerse como "el sistema no me deja arreglar mi error"** → El mensaje nombra la acción concreta que destraba (registrar la devolución del pago). Aun así es la OQ-1 para el PO: es el único bloqueo del change que no viene de un organismo externo sino de nuestro modelo de saldo.
- **`P0426` agrega fricción a un borrado que hoy es instantáneo** → Sólo aplica a operaciones que efectivamente movieron caja; abrir la caja es un clic y es la acción real que corresponde. Alternativa descartada: permitir el borrado sin compensar caja, que es exactamente el bug que este change viene a cerrar.
- **Bloquear el borrado de ventas facturadas cambia un comportamiento existente** → Es intencional y es **BREAKING**. Hoy hay 1 comprobante vivo en prod, así que el blast radius inmediato es mínimo, pero el PO debe saber que el camino pasa a ser la NC.
- **La compensación de caja cae en una sesión distinta de la original** → El arqueo del día de la anulación mostrará una salida que no corresponde a una venta de ese día. Es correcto contablemente y es el precio de no tocar arqueos firmados; el tipo `sale_reversal` propio permite explicarlo en el reporte.
- **La RPC concentra mucha responsabilidad** → Mitigado porque **no escribe lógica de libro nueva**: cada pata delega en el helper que ya existe y ya está probado. La RPC es orquestación y guards, no aritmética de saldos.

## Migration Plan

1. **Baseline**: capturar `pg_get_functiondef` de `_journal_post_from_event` y de las funciones tocadas en `openspec/changes/delete-guard-ledgers/baseline/`, desde prod.
2. **Migración idempotente** con timestamp > `20261004000002`: ampliación del CHECK de `cash_movements.movement_type`; helper de reversión de cargo de tercero; ramas nuevas del consumidor contable; las dos RPCs de borrado. Firmas nuevas ⇒ `DROP` + `CREATE` + `GRANT` explícito a `anon` y `authenticated` en el mismo archivo (el `DROP+CREATE` resetea las ACLs — gotcha con 5 antecedentes).
3. **Backend**: repositorios a *caller* fino; `errors.py` mapea `P0425`/`P0426`; el bloqueo `P0423` del delete reusa el mapeo existente.
4. **Frontend**: diálogo y estado de borrabilidad.
5. **Grupo de reparación histórica, gateado por conteos** (D9), en migración separada para poder mergearlo en un PR propio.
6. **Rollback**: las RPCs nuevas se pueden `DROP` y revertir los repositorios a la secuencia anterior; los contra-movimientos ya posteados **no se revierten** (son append-only y correctos). La ampliación del CHECK es aditiva y no requiere rollback.

## Open Questions

- **OQ-1 (la que más importa) — ¿`P0425` bloquea, o el PO prefiere otra salida cuando el cliente ya pagó?** Recomendación fundada: bloquear, porque el CHECK `balance_after >= 0` es de tabla y la alternativa (saldo acreedor) es un change de modelo propio. Si el PO quiere que "borrar y recrear" funcione también en ese caso, el camino es un change posterior de saldo con signo, no un parche acá.
- **OQ-2 — ¿El borrado de ventas del POS debería existir, o el POS debería tener su propio flujo de anulación?** Este change lo hace seguro (cancela la orden, revierte caja y asiento). La pregunta es de producto: si el PO prefiere que el POS anule en vez de borrar, la RPC ya deja la mitad hecha.
- **OQ-3 — ¿`P0426` (sin caja abierta) bloquea, o el PO acepta que la anulación quede pendiente hasta la próxima apertura?** Recomendación: bloquear — una anulación "pendiente" es un estado nuevo que hoy no existe y que habría que modelar.
- **OQ-4 — Reparación histórica: ¿se compensan los 2 movimientos de caja ($8.000) aunque alteren el saldo corriente de una sesión abierta desde el 2026-07-17?** Recomendación: sí, y avisar al PO antes de correrla, porque el saldo de esa caja va a bajar $8.000 y alguien puede estar mirándolo. Alternativa: cerrar esa sesión primero con el arqueo real y compensar en la siguiente.
- **OQ-5 — ¿Los 4 asientos huérfanos de `Purchase` y los 3 de `SaleOperation` se revierten con `posted_at` de hoy o de la operación original?** Recomendación: hoy, por el mismo criterio que ya usan `CreditNoteIssued` y la contra-entry de `SaleOperationAdjusted` — la reversión data la corrección, no el hecho original.
