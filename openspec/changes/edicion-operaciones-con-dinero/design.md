## Context

### Pedido

PO, 2026-10-14: *«quiero que se puedan editar todas las ventas, compras y gastos, aunque sea por cuenta corriente o otras, la única excepción que no se puede cambiar si solo si ya tiene CAE para el caso de las ventas»*.

### Estado vivo (prod, 2026-10-14, sólo lectura)

Los cuerpos de partida se leyeron con `pg_get_functiondef` en prod. El `md5` es del texto de `pg_get_functiondef`; el apply compara sin `\r`, por el gotcha de CRLF de los checkouts locales.

| Función | md5 | Qué hace hoy con el dinero |
|---|---|---|
| `rpc_atomic_update_sale_operation` (11 args) | `ad4f4ecb…` | Toma las filas `FOR UPDATE` y recuenta. Guard de remito (`P0423 delivery_note_sale_locked`). Guard fiscal vía `_fiscal_void_pending_for_sale_edit`. Después, **tres `P0423`**: cuenta corriente, caja y banco, por `operation_id` o `sales_orders.id`. Luego REVERSE + DELETE + INSERT con un `operation_id` **nuevo**, re-apunta y re-sincroniza la orden, y resuelve el rastro contable: caso B, reemplaza el evento pendiente; caso C, emite `SaleOperationAdjusted`. El caso C **sólo** mira asientos `SaleOperation`: una venta del POS, cuyo asiento es `SalesOrder`, nunca se ajusta. |
| `rpc_atomic_update_purchase_operation` (12 args) | `ead2f1db…` | **Sin lock de filas.** Tres `P0423`: cuenta corriente, banco y caja `purchase_payment`. `credit_transition_not_allowed` y `credit_requires_supplier`. REVERSE + DELETE + INSERT con un `operation_id` nuevo. **No emite ningún evento contable**: el asiento `Purchase` del `operation_id` viejo queda vivo, y un `PurchaseDeleted` posterior del id nuevo reintentaría `P0451` para siempre. Hoy hay 0 casos (último edit de compra: 2026-08-19, antes de que existieran los asientos de compra), pero el defecto es latente. |
| `rpc_update_expense` (11 args) | `809a1799…` | `UPDATE` en el lugar, así que el id del gasto es estable. Dos `P0423`: caja y banco. Emite `ExpenseAdjusted` si existe `ExpenseCreated`, con el `kind` derivado de la existencia de un movimiento bancario. Sin lock de fila. |
| `rpc_delete_sale_operation` | `2d6c7df5…` | Compensa sumando sólo el tipo original (`movement_type = 'sale'`). La caja se agrupa por **sesión** y se lee con `SELECT … INTO`, que se queda con una sola fila. El banco hace un espejo por fila. |
| `rpc_delete_purchase_operation` | `4da7dfce…` | Mismo patrón: `purchase`, `purchase_payment` y espejo por fila. |
| `rpc_delete_expense` | `eae2e6c6…` | Mismo patrón: `expense` y espejo por fila. |
| `_journal_post_from_event` | `d7bfbb92…` | 14 ramas. Busca el asiento vigente así: `SaleOperationAdjusted` y `SaleOperationDeleted` por `status = 'posted'` sin filtrar `reversal_of`; `ExpenseAdjusted` sí filtra `reversal_of IS NULL`, porque el gasto ya tenía id estable; `CreditNoteIssued` resuelve **sólo** `SalesOrder`. |
| `_pay_reverse_party_charge` | `06e00244…` | Registra `credit_note` o `debit_note` con `-amount`. Traduce `P0409` a `P0425` y emite `*ChargeReversed`. |
| `_pay_register_party_charge`, `_pay_register_operation_bank_movement`, `c28_register_cash_movement` | `9ec98928…`, `89bd5f04…`, `1b0692ad…` | Helpers de alta, reutilizables tal cual. |

### Hallazgos que cambian el diseño

1. **La huella no es un `EXISTS`.** Con referencias estables, una operación editada tiene en un mismo libro el movimiento original, su compensación y el nuevo:
   - la venta del POS y la presupuestada referencian `sales_orders.id`;
   - el gasto referencia su propio id;
   - la venta y la compra también, si el id se vuelve estable (D2).

   El borrado actual suma sólo el tipo original y compensaría dos veces. La caja agrupada por sesión con `SELECT … INTO` compensaría sólo una de las sesiones. El borrado tiene que migrar a la huella **neta** en el mismo change (D3).
2. **El aging FIFO trata la reversión de un cargo como crédito general** (`credit_note` va al pozo, `rpc_receivables_report`). Revertir el cargo de una venta editada cancela el cargo **más viejo** del cliente, no el propio. El saldo total no cambia, pero el reparto por cargo sí, y con él:
   - el saldo abierto por fila en el historial;
   - los tramos de mora;
   - el aviso diario de deuda vencida;
   - el recordatorio de WhatsApp.

   Hoy pasa sólo con los borrados (6 `credit_note` en prod). Con la edición pasa a ser frecuente (D9).
3. **Las ventas del POS no ajustan su asiento al editarse.** Hoy casi nunca se editan: el efectivo del POS es automático y las bloquea. Con este change pasan a editarse, y el asiento `SaleConfirmed` quedaría con el importe viejo (D10).
4. **La edición de compra no tiene lock de filas.** Un doble "Guardar" compensaría el dinero dos veces (D12).

### Restricciones

- `CLAUDE.md`, reglas duras:
  - orden global de locks `sales → sales_orders → fiscal_documents → resto`;
  - toda RPC invocada por otras necesita un gate SQL que la **ejecute**;
  - nunca `CREATE OR REPLACE` con un `DEFAULT` nuevo sobre una firma viva (overload `42725`): `DROP` + `CREATE` + reafirmación explícita de ACL (`REVOKE` a `PUBLIC`/`anon`/`authenticated`).
- `journal-entry`: toda reescritura del consumidor parte de su definición viva, verificada por hash.
- Ledgers append-only (RN-99). Las sesiones de caja cerradas son intocables (RN-95, `cash-movement`). Un movimiento bancario conciliado no se modifica (`bank-movement`).
- El saldo de cuenta corriente nunca es negativo (`customer-account`, `supplier-account`).

## Goals / Non-Goals

**Goals:**

- Que toda venta (formulario, POS, presupuestada), compra y gasto con dinero registrado sea editable, salvo la excepción fiscal y los bloqueos que no son de dinero (OQ-1 y OQ-5).
- Que la edición sea atómica en todos los libros y no escriba en los que no cambian.
- Que borrar después de editar compense exactamente lo vivo.
- Que el aging, la caja, el banco, el libro diario y el saldo de la parte queden coherentes con la operación editada.
- Que el usuario vea, **antes** de confirmar, qué se compensa y qué se registra en cada libro, calculado por el servidor.
- Que quede registrado quién cambió qué.

**Non-Goals:**

- Saldo a favor del cliente o del proveedor, es decir, saldo negativo en cuenta corriente (OQ-2).
- Editar la venta nacida de un remito o la que tiene conceptos de servicio de un presupuesto (OQ-5). Sus bloqueos no son por dinero y se conservan.
- Editar un movimiento de caja, banco o cuenta corriente suelto. Los ledgers siguen siendo append-only; sólo se edita el documento.
- Reabrir o corregir una sesión de caja cerrada o una conciliación bancaria cerrada.
- Un tipo de movimiento nuevo para la reversión por edición: se reutilizan los del borrado (D4).
- Importadores masivos (CSV de gastos y de productos): no editan operaciones.
- Cambiar la regla fiscal: autorizado, en vuelo y congelado siguen bloqueando, y el pendiente no enviado se anula (OQ-1).

## Decisions

### D1. Huella vigente frente a efecto deseado, libro por libro, y sin escritura cuando coinciden

Para cada libro —cuenta corriente de la parte, caja y banco— la edición calcula dos cosas:

- **Huella vigente (H)**: lo que la operación tiene neto en ese libro hoy, por cuenta del libro (cuenta corriente, caja o cuenta bancaria) y por referencia (D3).
- **Efecto deseado (E)**: lo que el estado editado tendría que tener, con las reglas del alta más la regla de herencia (D8) y las intenciones tri-estado (D6 y D7).

Con eso:

- Si **H = E** (misma cuenta del libro y mismo importe neto; en cuenta corriente, también la misma parte y el mismo vencimiento; en banco, además, la fecha de la operación sin cambios), la edición **no escribe nada en ese libro**. En banco se compara la fecha de la operación y no la fecha valor de la huella: después de una edición la huella puede sumar movimientos con fechas valor distintas, el original y los espejos, que van con fecha de hoy.
- Si **H ≠ E**, compensa H con los mismos helpers del borrado y registra E con los mismos del alta, en la misma transacción.

Por qué:

- Corregir el cliente, la descripción o un producto por otro del mismo precio en una venta en efectivo de la semana pasada **no puede exigir abrir la caja** ni dejar dos filas de caja en la sesión de hoy. Hoy 62 de los 77 movimientos de caja de ventas están en cajas sin sesión abierta.
- Lo mismo vale para el banco: no tiene sentido generar un espejo y un movimiento nuevo sin conciliar cuando nada cambió.

Alternativas descartadas:

- *Compensar y volver a registrar siempre* ("editar = borrar + crear"). Es más simple, pero bloquea con `P0426` cualquier corrección cosmética y llena caja y banco de pares que se anulan. Además rompe la regla de fecha del opt-in: la recarga de una venta de la semana pasada no podría volver a la caja.
- *Registrar sólo el delta* (un único movimiento por la diferencia). Deja un movimiento cuyo tipo no describe ni la venta ni su reversión, y obliga a calcular el delta por cuenta del libro cuando cambia la sucursal o la forma de pago. El par "compensación + nuevo" es el mismo instrumento del borrado y del alta.

### D2. La edición conserva el identificador de operación

La venta y la compra editadas **reutilizan su `operation_id`**. Las filas se siguen borrando y re-insertando, con ids de fila nuevos (la reversa de stock usa el id de fila viejo, igual que hoy). El gasto ya lo conservaba.

Excepción: una operación legacy sin `operation_id` (18 filas de venta y 13 de compra) recibe uno al editarse, y su huella se busca por el id de fila.

Por qué:

- **D1 necesita referencias estables.** Si el id cambia, el movimiento que no se tocó queda referenciando un id que ya no es de ninguna operación, y el borrado o la edición siguiente no lo encuentran. Sería una fuga de dinero silenciosa.
- La auditoría (D14), la vista previa (D13) y el emparejamiento del aging (D9) se resuelven por un id que no cambia.
- `operation_idempotency` deja de apuntar a una operación inexistente después de editar: el replay del alta hoy devuelve `items` vacío.

Consecuencias, todas parte de este change:

- `SaleOperationAdjusted` viaja con `old_operation_id = new_operation_id` (se conservan las dos claves por compatibilidad del payload).
- Toda búsqueda del **asiento vigente** excluye los contra-asientos (`reversal_of IS NULL`, ordenado por `posted_at` y `created_at` descendentes). Es el patrón que `ExpenseAdjusted` ya usa porque el gasto siempre tuvo id estable. Aplica a `SaleOperationAdjusted`, `SaleOperationDeleted`, `PurchaseDeleted`, `CreditNoteIssued` y la rama nueva `PurchaseAdjusted`.
- El re-apuntado de `sales_orders` pasa a ser un no-op, pero el recálculo (`_sales_order_sync_from_operation`) se mantiene.
- **BREAKING interno**: cambian los gates y tests que hoy asertan un `operation_id` distinto después de editar (por ejemplo `test_purchase_cash_optin.sql:410` y `test_asiento_venta_formulario.sql:267`).

Alternativas descartadas:

- *Mantener la regeneración y agregar una tabla de linaje viejo → nuevo.* Es una segunda fuente de verdad que cada lector tendría que recorrer.
- *Mantener la regeneración y compensar siempre.* Ver D1.

### D3. Huella neta: una sola definición

Una función interna, `_op_money_footprint`, devuelve por libro las filas `(libro, cuenta del libro, referencia, neto)` con neto ≠ 0, para una cuenta y un conjunto de referencias.

**Conjunto de referencias** de la operación:

| Documento | Referencias |
|---|---|
| Venta | `operation_id` y el `sales_orders.id` de su orden (POS o presupuestada) |
| Compra | `operation_id` |
| Gasto | id del gasto |
| Operación legacy | id(s) de fila |

**Familias de tipos** que entran en el neto (las únicas que referencian una operación):

| Libro | Venta | Compra | Gasto |
|---|---|---|---|
| Cuenta corriente | `sale` y `credit_note` | `purchase` y `debit_note` | — |
| Caja | `sale` y `sale_reversal` | `purchase_payment` y `purchase_payment_reversal` | `expense` y `expense_reversal` |
| Banco | `source_doc_type` del documento, todos los tipos | ídem | ídem |

En caja el neto se agrupa **por caja (cashbox)**, no por sesión. En banco se agrupa por cuenta bancaria y por familia de tipo: transferencia (`transfer_in`/`transfer_out`) y tarjeta (`card_settlement`).

Consumidores, todos sobre la misma función:

- las tres ediciones;
- las tres RPCs de **borrado**, migradas (ver abajo);
- la vista previa;
- las proyecciones de los tres listados (`has_account_charge`, `has_cash_movement`, `has_bank_movement`, `is_delete_blocked`, que pasan a significar "neto ≠ 0").

El borrado migra porque, con referencias estables (D2) y con las de POS y gasto, que ya lo eran, sumar sólo el tipo original compensa dos veces lo ya compensado por una edición. Para los datos de hoy el resultado observable no cambia: no hay ninguna referencia con movimientos en más de una sesión (medido: 0), y las reversiones existentes son de operaciones ya borradas.

El principio de **disparo por existencia, nunca por signo** se conserva: la compensación se dispara cuando el **neto** es ≠ 0, por el opuesto exacto del neto. Un neto 0 significa "ya compensado", no "signo inesperado".

Nombre y ACL: los lectores de listado son `SECURITY INVOKER` y corren con RLS; las RPCs `SECURITY DEFINER` pasan la cuenta y filtran por ella explícitamente. El nombre y la ACL tienen que pasar el gate de ACLs (chequeo 4, convención de nombre): la variante legible por la aplicación no lleva `_` inicial.

### D4. Compensación con los helpers y tipos del borrado; registro con los helpers del alta

Compensación:

- **Cuenta corriente**: `_pay_reverse_party_charge` (`credit_note` o `debit_note`, `P0425`, evento `*ChargeReversed`).
- **Caja**: `c28_register_cash_movement` con `sale_reversal`, `purchase_payment_reversal` o `expense_reversal`.
- **Banco**: `_register_bank_movement`, espejo con la dirección invertida, fecha valor de hoy y `unreconciled`, igual que el borrado. Se usa el escritor crudo y no se reevalúa el período conciliado sobre la pata que compensa.
- Cada compensación **lleva la misma referencia que la fila de huella que compensa**, y lo mismo pasa a hacer el borrado (D3).
- Descripción: "Reversión por edición de …" donde la tabla tenga columna de descripción (caja y banco). El motivo opcional del usuario se agrega.

Registro:

- **Cuenta corriente**: `_pay_register_party_charge`.
- **Caja**: `c28_register_cash_movement` con `sale`, `purchase_payment` o `expense`.
- **Banco**: `_pay_register_operation_bank_movement`, con `P0412`, `P0400` y `P0424`.
- Todo con la referencia de la operación (`operation_id` o id del gasto).

**Sin tipos de movimiento nuevos.** La reversión por edición es económicamente la misma reversión que la del borrado.

Alternativa descartada: tipos propios (`sale_edit_reversal`, …). Implican ampliar `CHECK`s, etiquetas, filtros de la superficie de caja y el vocabulario de `cash-movement` sin una diferencia contable que lo justifique.

### D5. Cuenta corriente: primero el cargo nuevo y después la reversión; bloqueo de cuentas en orden

- Cuando la cuenta corriente cambia, la edición **primero** registra el cargo nuevo y **después** revierte la huella.
- El helper rechaza cualquier `balance_after < 0` por movimiento, así que en el orden inverso un cobro previo haría fallar con `P0425` la edición de 1000 a 1200 de una venta ya cobrada, aunque el saldo final (+200) sea válido. Con este orden, `P0425` salta **sólo** si el saldo final queda negativo (OQ-2).
- Si la edición cambia de parte (cliente A → cliente B), las dos cuentas corrientes se bloquean `FOR UPDATE` en orden ascendente de id **antes** de cualquier escritura, para que dos ediciones cruzadas no se bloqueen mutuamente (`40P01`).

### D6. Caja: intención tri-estado, corrección del efectivo existente y sesiones cerradas intocables

La intención de caja de la edición se expresa con `p_cash_session_id` + `p_cash_provided`:

- **Ausente (conservar).**
  - Si la operación tiene huella de caja y el `kind` final es `cash`, el efecto deseado es "caja, total nuevo":
    - si la sucursal efectiva es la de la caja de la huella, va en la **sesión abierta de esa misma caja**;
    - si la sucursal cambió, la edición exige una intención explícita: `P0422 cash_intent_required`, porque una sucursal puede tener varias cajas.
  - En cualquier otro caso no hay efecto de caja. Pasar de efectivo a otra forma de pago saca la operación de la caja.
- **Presente con sesión.** Registrar en esa sesión. Se valida que esté abierta, sea de la cuenta, sea de la sucursal efectiva y que el `kind` final sea `cash`. La **fecha = hoy** se exige sólo si la operación no tenía huella de caja (es un opt-in nuevo, D8). Si la tenía, se trata de corregir un efectivo que ya entró a una caja, y la regla de fecha —que existe para no atribuir a la caja de hoy el efectivo de un documento retroactivo— no aplica.
- **Presente con NULL.** Sin efecto de caja; si había huella, se compensa.

Compensación:

- Va siempre a la **sesión abierta de la misma caja** de la huella. Si no hay ninguna, `P0426`, con el mismo mensaje que el borrado.
- Una sesión cerrada nunca se modifica. Si la huella está en una sesión cerrada y el efectivo cambia, compensación y registro van a la sesión abierta de hoy (OQ-3).
- Si H = E (misma caja y mismo importe), no hay escritura y no se exige sesión abierta (D1).

La validación del opt-in vive en **un solo helper**, `_cash_optin_assert`, con los predicados copiados del cuerpo vivo de las tres altas. Lo consumen las tres ediciones y **las tres altas**, que migran a él en este change (D16).

### D7. Banco: intención tri-estado; espejo como el borrado, movimiento nuevo como el alta

`p_bank_account_id` + `p_bank_account_provided`:

- **Ausente.** Si hay huella bancaria y el `kind` final es bancario, el efecto va a la **misma cuenta bancaria** de la huella. Si no hay huella y cambió el contrato de pago (D8), se resuelve como el alta: el destino por defecto de la forma de pago. En otro caso no hay efecto.
- **Presente.** La cuenta explícita, validada como en el alta (`P0412`, y `P0400` si el `kind` no es bancario).

Si H ≠ E:

- el espejo va con fecha valor de hoy y `unreconciled`, también cuando el original está conciliado, igual que el borrado;
- el movimiento nuevo lleva la fecha de la operación y respeta el guard de período conciliado (`P0424`, igual que el alta, OQ-6).

Si H = E (misma cuenta, mismo importe neto y la fecha de la operación sin cambios), no hay escritura: la conciliación firmada no se ensucia.

### D8. Regla de herencia: no inventar un efecto que la operación nunca tuvo

Un libro **sin huella** recibe efecto en una edición sólo si:

- la edición **cambia el contrato de pago**: la forma de pago final es distinta de la vigente, o la parte final (cliente o proveedor) es distinta de la vigente, comparado **por valor y no por presencia** (el formulario siempre envía la forma de pago); o
- la edición trae una **intención explícita** para ese libro (caja o banco presentes).

Así, editar la cantidad de una de las 241 ventas a crédito históricas del formulario que nunca postearon cargo no le crea deuda al cliente. Tampoco una compra a crédito histórica sin cargo, ni una venta por transferencia registrada antes de configurar el destino bancario. Es el mismo principio que ya rige en `operation-edit-context` para la compra a crédito sin proveedor: la edición **hereda** el estado, no lo introduce.

`credit_requires_client` y `credit_requires_supplier` (`P0400`) se evalúan cuando el efecto deseado de cuenta corriente existe, es decir, cuando hay huella o cuando cambió el contrato de pago.

Se **retira** `credit_transition_not_allowed`: la edición ya puede postear el cargo.

### D9. Cuenta corriente: vencimiento y emparejamiento en el aging

Vencimiento (`p_due_date` + `p_due_date_provided`):

- **Ausente.** Se conserva el vencimiento del cargo vigente si la parte no cambió y ese vencimiento no es anterior a la fecha final. Si no, se resuelve por la cascada, pasando `NULL` al helper, que es el único que la resuelve.
- **Presente.** El vencimiento explícito, con la misma validación que el alta (no anterior a la fecha de la operación, `P0400`). NULL limpia el vencimiento.

Emparejamiento en la derivación FIFO:

- **Regla.** El crédito de una reversión de cargo —`credit_note` en cliente, `debit_note` en proveedor— cancela **primero los cargos de su misma referencia y de la misma cuenta corriente**, en el orden FIFO de esos cargos. Sólo el remanente (si lo hubiera) va al pozo general. El invariante de cierre (suma de lo abierto = saldo) se conserva, porque el emparejamiento sólo mueve importe entre "cargo neto" y "pozo".
- **Encadenamiento.** Con D2, cargo, reversión y cargo nuevo comparten referencia. Una cadena de ediciones (c1, r1, c2, r2, c3) deja abierto sólo c3, sin tocar los cargos de otras operaciones.
- **Dónde se aplica.** Siete lugares, todos desde su cuerpo vivo:
  - `backend/repositories/_account_aging_sql.py`, una definición con cuatro consumidores;
  - `rpc_receivables_report`;
  - `rpc_payables_report`;
  - `_produce_receivables_overdue_digest`;
  - las dos RPCs de cambio de vencimiento de `20261033000001`.
- **Datos existentes.** Las 6 `credit_note` de borrados históricos pasan a emparejarse con su cargo cuando comparten referencia (camino formulario). Es más correcto, pero cambia el reparto por tramo de esas cuentas. El apply lo mide antes y después y lo informa.
- **Etiquetas.** Una nota de crédito fiscal (`CreditNoteIssued`, referencia `sales_orders.id`) también se empareja con el cargo de su venta del POS. Es semánticamente correcto, porque anula esa venta.

### D10. Rastro contable

**Venta.**

- Se mantienen el caso B (reemplazar en el lugar el `SaleOperationCreated` o el `SaleOperationAdjusted` pendientes) y el caso C.
- El caso C se extiende a la venta del POS o presupuestada: si existe un `SaleConfirmed` de su orden (procesado o no), se emite `SaleOperationAdjusted` con `sales_order_id`.
- La rama del consumidor resuelve el asiento vigente con las **dos convenciones**: primero `(SaleOperation, operation_id)` y después `(SalesOrder, sales_order_id)`, ambas con `reversal_of IS NULL`. Es el mismo orden que ya usa `SaleOperationDeleted`.
- El asiento nuevo es `SaleOperation` con el `operation_id` estable.
- Si el `SaleConfirmed` todavía no se procesó, el ajuste reintenta `P0451` hasta que se postee. El relay procesa en orden de ocurrencia.

**Compra.**

- Evento nuevo **`PurchaseAdjusted`**, emitido si existe `PurchaseCreated` para la operación. Es la regla de `ExpenseAdjusted`: evita el evento envenenado de una compra histórica sin asiento.
- El payload tiene la forma de `SaleOperationAdjusted`: `old_operation_id` para el asiento a revertir y `new_operation_id` para el nuevo. En la tanda A todavía son distintos, porque el id de la compra recién se vuelve estable en la tanda B; desde la tanda B son iguales.
- La rama del consumidor es la mitad "revertir" de `PurchaseDeleted` más el posteo de `PurchaseCreated` con su mapeo (centro de costo y `kind` declarado). Comparte la resolución de la contrapartida para que las dos ramas no diverjan.
- El conjunto canónico pasa a **15 tipos**: filtro del despachador, filtro del helper, gate y specs.

**Gasto.** `ExpenseAdjusted` deriva la contrapartida de la huella bancaria **posterior** a la edición (neto ≠ 0), no de un `EXISTS`, que vería también el movimiento ya compensado.

**`CreditNoteIssued`.** Resuelve el asiento también por `(SaleOperation, sales_orders.sale_operation_id)`, con `reversal_of IS NULL`. Una venta del POS editada, facturada y con nota de crédito, o una venta del formulario promovida, tiene su asiento vigente como `SaleOperation`. Hoy ese caso reintentaría `P0451` para siempre (latente, 0 eventos pendientes hoy).

### D11. Excepción fiscal sin cambios

`_fiscal_void_pending_for_sale_edit` sigue siendo la única definición: bloquea el autorizado (CAE), el `pending_cae` con marca de envío y el congelado; anula el pendiente no enviado. El PO dijo "sólo si ya tiene CAE", y la recomendación es mantener el bloqueo del que está en vuelo (OQ-1). Hoy hay 0 en vuelo y 0 congelados; 19 tienen CAE.

### D12. Orden de pasos y de bloqueos

En las tres ediciones, en este orden:

1. Identidad y cuenta.
2. Filas `FOR UPDATE` en orden ascendente de id, con recuento y `P0404` si faltan:
   - la venta ya lo hace;
   - la **compra, nuevo**;
   - el **gasto, nuevo**: su fila `FOR UPDATE`.
3. Guards que no son de dinero, en el orden vivo de cada RPC:
   - tenencia de la parte;
   - remito;
   - fiscal (venta).
4. Resolución de los valores finales y del total, que se calcula del payload antes de escribir.
5. Huella y efecto deseado: el plan (D13), con todas las validaciones de dinero.
6. Bloqueo en orden fijo de los recursos que el plan va a escribir:
   - cuentas corrientes en orden ascendente de id;
   - sesiones de caja en orden ascendente;
   - cuentas bancarias en orden ascendente.

   Va antes que el stock, igual que el borrado.
7. Resolución del rastro contable, con el lock del evento pendiente (caso B).
8. Stock REVERSE, DELETE, INSERT y stock APPLY (sin cambios, salvo el id estable).
9. Escrituras de dinero según el plan: cuenta corriente (nuevo y después reversión), caja (compensación y después nuevo), banco (espejo y después nuevo).
10. Recálculo de la orden.
11. Eventos.
12. Auditoría.

El orden global de `CLAUDE.md` (`sales → sales_orders → fiscal_documents → resto`) se respeta. "Resto" queda definido como cuentas corrientes → caja → banco → stock → eventos, el mismo que ya sigue el borrado.

### D13. El plan lo calcula el servidor, con la misma función que ejecuta

Una función interna arma el **plan** de dinero antes de cualquier escritura. Por libro devuelve:

- huella;
- efecto deseado;
- acción: sin cambio, compensar, registrar o compensar y registrar;
- importes y cuenta del libro;
- vencimiento;
- sesión de caja destino;
- bloqueos de negocio:
  - `P0426` sin sesión abierta;
  - `P0425` saldo final negativo, con el saldo proyectado;
  - `P0424` período conciliado;
  - `P0403` rol (OQ-4).

Las tres ediciones aceptan `p_dry_run boolean DEFAULT false` (precedente: `rpc_import_expenses`):

- **Con `true`** ejecutan los pasos 1–5 sin escribir y devuelven el plan, con los bloqueos como datos.
- **Con `false`** ejecutan el plan, y cada bloqueo levanta su código. La transacción vuelve a evaluar todo: si algo cambió entre la vista previa y el guardado, **manda el servidor**. Es el mismo principio de `venta-editable-sin-cae`.

El stock (`P0409`) no forma parte de la vista previa: se evalúa al aplicar, como hoy.

Alternativa descartada: derivar la confirmación en el cliente a partir de los indicadores del listado, como hace el diálogo de borrado. El cliente no puede saber si H = E, ni el saldo proyectado, ni si hay sesión abierta en una caja concreta, ni los períodos conciliados.

### D14. Auditoría en `audit_logs`, visible en el detalle

Cada edición, con o sin dinero, inserta en `audit_logs` en la misma transacción:

- `action`: `sale_operation.edited`, `purchase_operation.edited` o `expense.edited`;
- `entity_type` y `entity_id`: el `operation_id` estable (D2) o el id del gasto;
- `user_id`: `auth.uid()`;
- `metadata`:
  - `before` y `after`: cabecera, líneas resumidas, total, forma de pago, parte, fecha y sucursal;
  - `money`: el plan ejecutado;
  - `voided_fiscal_document`;
  - `reason`, el motivo opcional `p_reason`.

La tabla ya existe y ya la usan `cobranzas-reverso` y el cambio de vencimiento. Se lee con un endpoint por dominio que comparte un único repositorio de lectura de auditoría. La superficie muestra un "Historial de cambios" en el detalle expandido de la operación.

### D15. Contrato de lectura

- Se retira `is_payment_locked` de `SaleOut`, `PurchaseOut` y `ExpenseOut`, y de todos sus callers en el frontend y los tests. **BREAKING de API**: mantenerlo con otro significado sería una mentira.
- Los tres listados exponen **`edit_locked_reason`**, un token del servidor que falla cerrado: un token desconocido también bloquea. Lo derivan los mismos predicados que los guards:
  - `delivery_note_sale_locked` (vivo);
  - el `delivery_note_purchase_locked` de `remitos-compra`;
  - `service_lines_locked` (hoy se deriva en el cliente desde `has_service_lines`; pasa al servidor);
  - y, si se firma OQ-4 (a), `money_edit_requires_admin` según el rol del que consulta.
- El bloqueo fiscal sigue viajando por sus derivados actuales (`is_fiscally_locked` y la evidencia del comprobante).
- `has_account_charge`, `has_cash_movement`, `has_bank_movement` e `is_delete_blocked` pasan a semántica de **huella neta** (D3).
- Se agregan los datos que el formulario necesita para mostrar el estado vigente:
  - `charge_due_date` y `charge_party_id`;
  - `cash_cashbox_id` y la sesión abierta de esa caja, si la hay;
  - `bank_account_id` de la huella.

### D16. Un solo helper del opt-in de caja

Hoy los predicados del opt-in (`kind = 'cash'`, sesión abierta de la sucursal efectiva y de la cuenta, fecha de hoy) están copiados en tres altas: `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` (o `_purchase_operation_core` después de `remitos-compra`) y `rpc_create_expense`. La edición los necesita con una variante (D6).

En vez de una cuarta copia, nace `_cash_optin_assert(p_account_id, p_session_id, p_kind, p_branch_id, p_date, p_had_cash_footprint)`, con los mismos tokens y códigos que hoy (`cash_optin_requires_cash_kind`, `cash_optin_requires_open_session`, `cash_optin_requires_today`, `P0422`). Las seis funciones lo consumen. Un gate ejecuta la matriz de las tres condiciones contra las tres altas antes y después, con el mismo veredicto.

### D17. Superficie frontend

Rutas y menú **existentes**: `/ventas`, `/compras` y `/gastos`. No hay ruta ni entrada de menú nueva.

- **Listados** (`components/ventas/sale-operations-list.tsx`, `components/compras/purchase-operations-list.tsx`, `app/(dashboard)/gastos/page.tsx`):
  - "Editar" ya no se deshabilita por dinero;
  - el motivo sale de `edit_locked_reason` y de los derivados fiscales;
  - se retiran `PAYMENT_LOCKED_REASON` y sus equivalentes en compra y gasto;
  - el lápiz con dinero registrado muestra como `title` "Editar — la operación tiene dinero registrado; vas a ver qué se ajusta antes de guardar".
- **Formularios** (`components/forms/sale-form.tsx`, `purchase-form.tsx`, `expense-form-v2.tsx`). En modo edición se habilitan los bloques hoy ocultos con `!isEdit`, reutilizando los mismos componentes del alta:
  - selector de cuenta bancaria (`BankAccountDestinationSelect`);
  - bloque de cuenta corriente: saldo actual y proyectado, y vencimiento precargado con el vigente;
  - bloque de caja: "Registrado en caja X" marcado cuando hay huella; desmarcarlo saca la operación de la caja; sesión de la sucursal nueva si cambió;
  - campo opcional "Motivo del cambio".
- **Confirmación** (componente nuevo `OperationEditPlanDialog`, en PascalCase):
  - al guardar, si la operación tiene huella o el plan escribe dinero, se pide la vista previa y se muestra el plan por libro, en lenguaje del usuario y con el sentido real del movimiento (entra o sale de la caja);
  - con un bloqueo, el botón de confirmar se deshabilita y el motivo queda visible: "Abrí la caja X para…", "El cliente ya pagó $N: anulá primero el cobro…", "La fecha cae en un período conciliado…";
  - la lista de compensaciones se extrae a un componente compartido con `DeleteOperationDialog`;
  - la redacción vive en un único módulo `lib/money-plan.ts`, consumido por los dos diálogos, en vez de sumarse a `lib/delete-compensation.ts`.
- **Historial de cambios** (`OperationEditHistory`): en el detalle expandido, carga diferida, con fecha, quién y resumen ("Total $1.000 → $1.200; caja: +$200 en la sesión de hoy").
- **Errores**: tokens nuevos en `lib/operation-errors.ts` (`cash_intent_required`, `money_edit_requires_admin`, y `P0425`, `P0426` y `P0424` en contexto edición).
- **Caché**: las mutaciones de edición invalidan las mismas claves que el borrado y las altas de cada documento, reutilizándolas: caja, banco, conciliación, cuentas corrientes de cliente y proveedor, cobranzas (`receivables.*`), libro diario y formas de pago.
- **Diseño**:
  - tokens semánticos y componentes base vía cva, sin colores literales;
  - verificado en escritorio y móvil (375 px) y en tema claro y oscuro, con el diálogo y el historial operables por teclado;
  - el foco vuelve al control que abrió la confirmación (mismo criterio que `venta-editable-sin-cae`).

### D18. Backend en tres capas

Esquemas Pydantic v2:

- `SaleOperationUpdateIn`, `PurchaseOperationUpdateIn` y `ExpenseUpdate` suman `cash_session_id`, `bank_account_id`, `due_date` y `reason`.
- El tri-estado se resuelve por `model_fields_set`, nunca por `is None`.

Endpoints nuevos:

| Endpoint | Para qué |
|---|---|
| `POST /sales/operation/edit-preview` | Vista previa |
| `POST /purchases/operation/edit-preview` | Vista previa |
| `POST /expenses/{id}/edit-preview` | Vista previa |
| `GET /sales/operation/{operation_id}/edits` | Historial |
| `GET /purchases/operation/{operation_id}/edits` | Historial |
| `GET /expenses/{id}/edits` | Historial |

Los routers sólo validan e inyectan; los servicios aplican el guard de rol de OQ-4, espejo de `backend/core/rbac.py`, y los repositorios llaman a la RPC. Sin `service_role`. Los errores van en formato RFC 7807, con el mapeo existente de `P04xx`.

## Risks / Trade-offs

- **[Blast radius alto: ~20 funciones SQL, 3 proyecciones, 3 formularios, 3 listados.]** → Se aplica en **tres tandas, cada una un PR** (Migration Plan). Toda función parte de su cuerpo vivo, verificado por hash el día del apply. Cada función que otra invoca se ejecuta en un gate.
- **[Cambiar la regeneración del `operation_id` rompe supuestos implícitos.]** → La tanda A agrega `reversal_of IS NULL` a todos los lectores del asiento vigente antes de que exista un solo caso con id estable. El apply barre `operation_id` en `backend/`, `frontend/` y `supabase/tests/` buscando comparaciones de "id nuevo". `remitos-compra` ya razona con el id derivado por `source_delivery_note_id`, no por un puntero.
- **[`P0425` va a ser frecuente.]** 50 de 77 cargos están en cuentas cuyo saldo ya es menor que el cargo. → La vista previa lo anticipa con el saldo proyectado y nombra el camino (anular el cobro desde la cuenta corriente, que ya existe por `cobranzas-reverso`). La edición hacia arriba no lo dispara (D5).
- **[Corregir efectivo de sesiones cerradas mueve el arqueo de hoy (OQ-3).]** → Sólo cuando el efectivo cambia (D1). El diálogo lo dice antes de confirmar. Los movimientos llevan tipo de reversión y descripción "por edición", y la diferencia del arqueo de hoy queda explicada en el historial de la caja.
- **[El aging cambia para las 6 reversiones históricas de borrados (D9).]** → El apply mide el reparto por tramo antes y después en esas cuentas y lo informa al PO. El saldo total no cambia (gate del invariante de cierre).
- **[El conjunto canónico de 14 a 15 rompe el gate del outbox si se toca un solo filtro.]** → La tanda A cambia los dos filtros y el gate en el mismo PR, con la matriz de evasión.
- **[Bloques de reaplicación de `KPI_Validation.yml` que fijan cuerpos de estas funciones.]** → Primer paso de cada tanda: inventariar los bloques que referencian las funciones que la tanda redefine y aplicar su "REGLA PARA EL PR SIGUIENTE" (retirarlos o actualizarlos en el mismo PR), como hizo `remitos-compra`.
- **[Una venta editada después de facturada y con nota de crédito.]** → D10 resuelve las dos convenciones en `CreditNoteIssued`, con gate.
- **[La etiqueta "Nota de crédito" en el historial de cuenta corriente para una reversión por edición puede confundirse con una NC fiscal.]** → Es el comportamiento vigente del borrado. Queda como candidato (rotular derivado sin tipo nuevo), fuera de este change.
- **["Último cargo" del panel de cobranzas.]** Usa el `created_at` del cargo, así que un cargo re-registrado por edición cuenta como reciente. → Efecto menor y declarado; candidato.
- **[Concurrencia con el relay.]** El caso B ya bloquea el evento pendiente `FOR UPDATE` (sin `SKIP LOCKED`). → `PurchaseAdjusted` no reemplaza en el lugar: se emite siempre que exista `PurchaseCreated` y el relay procesa en orden.
- **[`document-snapshots` declara inmutables las líneas de una orden confirmada.]** Editar una venta del POS re-sincroniza las líneas de su orden. El mecanismo ya existe desde `venta-editable-vs-promocion-legacy` (N3); este change no lo cambia, pero lo vuelve más frecuente. → Sigue acotado a órdenes sin comprobante vivo, que es la condición que la edición ya exige. El apply verifica que la re-sincronización reemplace las líneas y no haga `UPDATE` sobre ellas.
- **[Rol (OQ-4) en conflicto con `multiusuario`.]** → Se decide junto con ese change. Si `multiusuario` define otra matriz, esta OQ se reescribe antes del apply.

## Migration Plan

Tres tandas, cada una un PR, aplicadas por **un** agente en serie. Merge = deploy + `supabase db push` automáticos.

**Tanda A — cimientos sin cambio de comportamiento visible.** Cada pieza vale por sí sola.

- `_op_money_footprint` y su variante de lectura.
- Las tres RPCs de **borrado** migradas a huella neta, con resultado idéntico sobre los datos de hoy (gate de equivalencia).
- Emparejamiento FIFO en los 7 lugares, con gate del invariante de cierre y medición de las 6 reversiones.
- Consumidor contable:
  - `reversal_of IS NULL` en las cinco búsquedas;
  - `CreditNoteIssued` con las dos convenciones;
  - rama `PurchaseAdjusted`;
  - conjunto de 15 en los dos filtros y el gate.
- Lock de filas en la edición de compra y de gasto.
- La edición de compra emite `PurchaseAdjusted`, lo que cierra el defecto latente aunque la compra siga bloqueada por dinero.

**Tanda B — la edición con dinero.**

- Las tres ediciones reescritas: id estable, plan, `p_dry_run`, intenciones tri-estado, regla de herencia, escrituras y auditoría.
- `_cash_optin_assert` con las tres altas migradas.
- Backend: esquemas, vista previa, historial, proyecciones y retiro de `is_payment_locked` (el frontend se migra en la misma tanda en lo mínimo necesario para no romper: los listados dejan de leer el campo).

**Tanda C — superficie.**

- Formularios en modo edición, diálogo del plan, historial, errores e invalidaciones.
- Pasada visual en las cuatro combinaciones (escritorio y móvil, claro y oscuro).
- Humo real del PO.

**Rollback.** Cada tanda es revertible con un PR que restaure los cuerpos previos, guardados en `evidence/` en el checkpoint de cuerpo vivo. Nada de este change reescribe filas de datos: no hay backfill. Los movimientos que una edición ya haya generado son compensaciones válidas y legibles por el código anterior: son los mismos tipos del borrado.

**Verificación post-merge en prod** (por tanda):

- `MAX(version)`;
- una sola firma viva por función y sus ACLs;
- `md5` del cuerpo vivo igual al de la migración (sin `\r`);
- 0 eventos `PurchaseAdjusted`, `SaleOperationAdjusted` o `CreditNoteIssued` pendientes con `P0451`;
- invariante de cierre del aging en todas las cuentas corrientes.

## Dependencias y orden de apply

1. **`fix/stock-edicion-sucursal-y-piso`** (otro agente, PR propio, en curso). Reescribe `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` (stock por sucursal, `P0409`) y el piso al borrar compra. **Va antes.** Este change parte de los cuerpos que ese fix deje vivos.
2. **`remitos-compra` tanda B** (change activo, 45 de 79 tareas). Redefine `rpc_create_purchase_operation`, que pasa a ser un wrapper de `_purchase_operation_core`; `rpc_atomic_update_purchase_operation`, que gana `P0423 delivery_note_purchase_locked` antes de los `P0423` de dinero; y `rpc_delete_purchase_operation`, que deja de reponer stock en la compra nacida de un remito y reabre el remito. **Va antes.** Su requirement "La compra nacida de un remito es inmutable" se conserva: es un bloqueo por stock, no por dinero, y su motivo tiene precedencia en `edit_locked_reason`. Los requirements de dinero que este change retira de `operation-edit-context` y `supplier-account` no chocan con sus deltas, pero el archive del segundo que llegue tiene que reconciliar los encabezados de `operation-edit-context` (gotcha de `openspec archive` con dos deltas sobre la misma capability).
3. **`remitos-venta`** (change activo, 77 de 82 tareas). El bloqueo `delivery_note_sale_locked` ya está vivo en prod. Este change lo conserva (OQ-5) y no toca su conversión.
4. **`multiusuario`** (propose en paralelo). Agrega guards `products.user_id` y `sales.user_id = auth.uid()` en las mismas RPCs de alta y edición y cambia la resolución de la cuenta activa. Solapamiento directo:
   - `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` (guard de propiedad de filas y de productos);
   - `rpc_create_sale_operation_v2`, `rpc_create_purchase_operation` / `_purchase_operation_core` y `rpc_create_expense` (este change las toca por D16);
   - el rol para corregir dinero (OQ-4).

   **Orden recomendado: `multiusuario` se aplica antes** que la tanda B de este change, por dos razones: define a quién pertenece una operación, que es la premisa de OQ-4, y es el cambio más chico sobre esas firmas. La tanda A de este change no toca esas RPCs de alta y edición, así que **puede ir en paralelo** con `multiusuario`.

Numeración de migraciones: se reserva en el apply, después de medir `MAX(version)` en prod y en `main` (último hoy: `20261078000001`). Los tres cambios de arriba pueden ocupar números intermedios.

## Open Questions

> Todas con recomendación. El PO las firma antes del apply (governance ALTA).

**OQ-1 — Comprobante en vuelo.**
- **Pregunta:** el PO dijo "sólo si ya tiene CAE". ¿Una venta cuyo comprobante ya salió hacia ARCA pero todavía no tiene respuesta (en vuelo) o quedó congelada se puede editar?
- **(a) Recomendado: mantener el bloqueo.** Editarla mientras ARCA puede estar autorizando produciría una factura real que no coincide con la venta, y anularla a ciegas puede dejar una factura emitida sin venta. El estado dura segundos o minutos. El congelado se resuelve a mano con la reconciliación (`FECompConsultar`), y después la venta queda editable (si ARCA no la tiene) o con CAE. Medido hoy: 0 en vuelo y 0 congelados.
- **(b)** Sólo el CAE bloquea. Exigiría cambiar `_fiscal_void_pending_for_sale_edit` y la regla dura de `CLAUDE.md` ("un envío a ARCA no confirmado se congela, nunca se reintenta a ciegas").

**OQ-2 — Nuevo total por debajo de lo ya cobrado.**
- **Pregunta:** si el saldo final de la cuenta corriente quedaría negativo, ¿qué pasa?
- **(a) Recomendado: rechazar con `P0425`.** El mensaje dice cuánto ya pagó el cliente o cuánto se le pagó al proveedor, y que primero hay que anular el cobro o el pago. Con eso el saldo nunca es negativo, que es el invariante de las dos cuentas corrientes y de todo lo que las lee (panel de cobranzas, aging, aviso diario, recordatorio). Medido: 50 de 77 cargos están en cuentas cuyo saldo ya es menor que el cargo, así que va a pasar seguido, y la vista previa lo anticipa.
- **(b)** Permitir saldo a favor. Es una feature nueva: saldo negativo en el ledger, tramo "a favor" en el aging, compensación contra cargos futuros y su asiento. Corresponde a un change propio.

**OQ-3 — Cambiar el efectivo de una operación cuya sesión de caja ya cerró.**
- **(a) Recomendado: registrar en la caja abierta de hoy** la reversión del importe viejo y el importe nuevo (o sólo la reversión, si dejó de ser efectivo). Es el mismo criterio que el borrado: una sesión cerrada nunca se toca y la corrección va al período abierto. A lo largo del tiempo las diferencias de arqueo se compensan, porque la sobra o el faltante de aquel día queda explicado por la corrección de hoy. Sólo ocurre cuando el efectivo cambia (D1), y el diálogo lo dice antes de confirmar. Medido: 72 de 77 movimientos de caja de ventas están en sesiones cerradas.
- **(b)** No tocar la caja: la huella queda como se registró. Pasar esa venta a transferencia contaría la plata dos veces (caja y banco), y el asiento diría banco mientras la caja dice efectivo.

**OQ-4 — ¿Quién puede corregir dinero?**
- **(a) Recomendado: dueño o administrador** para una edición cuyo plan **escribe** en algún libro de dinero. Sería una capacidad nueva con nombre propio, `CAN_CORRECT_MONEY = owner, admin`, espejo de `CAN_VOID_DELIVERY_NOTE` y de la transición `confirmed → canceled` que ya exige el borrado de una venta del POS. Es una señal antifraude: el cajero no puede bajar después el importe de una venta en efectivo. Una edición que no toca dinero (H = E en todos los libros) sigue con la autorización de hoy. Se decide junto con `multiusuario`.
- **(b)** Cualquiera que pueda vender o comprar.

**OQ-5 — Ventas nacidas de un remito y ventas con conceptos de servicio de un presupuesto.**
- **(a) Recomendado: conservar su bloqueo.** No es por dinero:
  - el remito ya entregó la mercadería, y editar las líneas repondría y descontaría stock que el remito retiene; el camino existe: borrar la venta, editar el remito y reconvertir;
  - el editor no sabe representar una línea de servicio.

  Medido: 0 ventas nacidas de un remito en prod hoy. La compra nacida de un remito (`remitos-compra`) queda igual.
- **(b)** Permitir editar sólo cabecera y precios (forma de pago, cliente, fecha, precio), sin tocar las líneas. Es un change propio sobre el editor.

**OQ-6 — Movimiento bancario nuevo con fecha dentro de un período conciliado y cerrado.**
- **(a) Recomendado: rechazar con `P0424`** y sugerir el ajuste manual, igual que el alta. Sólo ocurre cuando el efecto bancario cambia (D1).
- **(b)** Fechar el movimiento nuevo hoy. Desacoplaría la fecha valor de la operación.
- Medido: 1 sesión de conciliación cerrada que cubre 12 movimientos de operaciones; 0 movimientos conciliados.
