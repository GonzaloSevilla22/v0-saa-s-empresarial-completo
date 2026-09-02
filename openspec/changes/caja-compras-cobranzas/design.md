## Context

### Lo que está roto, medido contra producción (2026-09-01)

Todo lo que sigue se verificó contra el `pg_get_functiondef` **vivo** de producción (`gxdhpxvdjjkmxhdkkwyb`), no contra los archivos de migración del repo. Es la regla de la casa desde `metodos-pago-operaciones`: el cuerpo vivo y el último archivo de migración **divergieron al menos una vez** (el G3 de `20261003000001` reescrito in-place), y el checkpoint que lo atrapó fue justamente éste.

| RPC | `toca_caja` | `toca_banco` | md5 del functiondef | chars |
|---|---|---|---|---|
| `rpc_create_purchase_operation` | **false** | true | `058f4d291d85bec0ae46589bde49e3a3` | 19.438 |
| `rpc_delete_purchase_operation` | **false** | true | `e10a1505250d1d6d9301de38a719ee75` | 4.165 |
| `rpc_register_payment_received` | **false** | true | `3af320ebaf30a94eaa7bbf8e3cd05404` | 7.031 |
| `rpc_register_payment_made` | **false** | true | `f4b6bdfa06f4c35c487459c24a143b31` | 6.148 |
| `rpc_create_expense` (referencia) | **true** | true | `c8f2ef987a6efe06ba0303e93d367d6a` | 12.701 |
| `rpc_delete_expense` (referencia) | **true** | true | `4d78ee3b241bea2f4df34ceb0afb7cce` | 6.498 |

Las dos últimas filas son el molde: `gastos-forma-pago` ya resolvió exactamente este problema para el gasto, hace dos días. Este change **copia ese molde a tres caminos más**; no inventa uno nuevo.

El helper bancario compartido explica por qué el efectivo cae en el vacío:

```sql
v_is_bank_kind := p_kind IS NOT NULL AND p_kind IN ('transfer','card','check','wallet');
IF NOT v_is_bank_kind THEN RETURN NULL; END IF;   -- cash | credit | other: etiqueta, sin efecto
```

No es un bug del helper — es su contrato correcto. El efectivo no va al banco. Simplemente **nadie escribió la otra rama** para la compra ni para las cobranzas.

### Estado de los datos

| Medición | Valor |
|---|---|
| Compras imputadas a `kind='cash'` | **4** (0 movimientos de caja) |
| `payments_received` | **6** (0 movimientos de caja) |
| `payments_made` | **1** (0 movimientos de caja) |
| Sesiones de caja `open` ahora | **3** |
| `cash_movements` vivos | 71 (`sale` 65, `expense` 3, `sale_reversal` 2, `expense_reversal` 1) |
| Filas con `movement_type='purchase_payment'` | **0** — tipo reservado y muerto |
| Compras con `branch_id` | **0 de 507** |
| Última migración (`origin/main` y prod) | `20261017000001` (266 filas) |

### Restricciones que enmarcan el diseño

- **DEC-24**: la unidad de trabajo es la RPC `SECURITY DEFINER`. Nada de orquestar dos libros desde Python.
- **RN-90**: venta → stock → caja en la **misma transacción**. Vale igual para compra → stock → caja.
- **RN-95**: `expected_balance = opening_balance + Σ(cash_movements)` y su `difference` es **señal antifraude**. Inyectar en una sesión abierta plata que nadie puso en el cajón convierte toda diferencia en ruido. De ahí que el camino sea **opt-in** y no automático.
- **RN-99**: el ledger de caja es **append-only por sesión**. Una compensación jamás se escribe dentro de una sesión cerrada.
- **RN-93**: toda venta, compra, gasto y movimiento de caja lleva `branch_id`.
- **Regla de reutilización (PO 2026-08-02)**: `useCashOptin`, `c28_register_cash_movement` y los helpers `_pay_*` se usan tal cual. Cero paralelos.

## Goals / Non-Goals

**Goals:**

1. Que una compra pagada en efectivo descuente de la caja, con el mismo opt-in de tres condiciones verificadas en servidor que ya tienen la venta y el gasto.
2. Que un cobro de cuenta corriente en efectivo **ingrese** a la caja y un pago a proveedor en efectivo **egrese** de ella, atómicamente con el movimiento de cuenta corriente.
3. Que borrar una compra con caja posteada compense la caja en la misma transacción, o se rechace.
4. Que la compra deje de perder su sucursal (RN-93), porque es el ancla de la condición 2 del opt-in.
5. Que el arqueo, el historial de `/caja` y los diálogos de borrado digan la verdad sobre estos tres caminos.

**Non-Goals:**

1. **Reverso/anulación de un cobro o pago de cuenta corriente.** Verificado en prod: no existe `rpc_delete_payment_received`/`_made` ni endpoint `DELETE` en los dos routers de cuentas. No hay flujo que compensar. Cuando se cree, la compensación de caja nace con él (queda anotado como candidato).
2. **Asiento contable** de los movimientos nuevos. Diferido a V2.6 con el resto del plan de cuentas, igual que el gasto (D10 de `gastos-forma-pago`). Ningún payload de evento cambia.
3. **Migrar los modales de cobro/pago al catálogo `payment_methods`.** Las dos RPCs usan una taxonomía `text` cerrada `{cash,transfer,card,check}` ajena al catálogo. Unificarla es el espejo de `pos-catalogo-pagos` y merece su propio change.
4. **Opt-in de caja en la edición de una compra.** La edición no ofrece cuenta bancaria (D8 de `pos-banco-movimientos`) y D8 de este change vuelve inmutable a la compra con caja posteada: el caso no existe.
5. **Backfill de los 11 documentos históricos.** Ver D11.
6. **Tocar el POS.** El mostrador ya alimenta la caja automáticamente y no está en el pedido.

## Decisions

### D1 — El vocabulario de caja suma tres tipos y renombra uno muerto

**Decisión.** El `CHECK` de `cash_movements.movement_type` pasa de 8 a 11 valores:

| Tipo | Estado | Signo (`backend/schemas/cash.py`) | Familia UI (`cash-movement-meta.ts`) | Etiqueta |
|---|---|---|---|---|
| `purchase_payment` | ya en el CHECK, **0 filas** | egreso (ya está en `_EXPENSE_TYPES`) | Egresos | **"Compra en efectivo"** |
| `purchase_payment_reversal` | **nuevo** | **ingreso** | **Reversas** | "Reversa de compra" |
| `payment_received` | **nuevo** | ingreso | Ingresos | "Cobro de cliente" |
| `payment_made` | **nuevo** | egreso | Egresos | "Pago a proveedor" |

**Por qué el relabel.** `purchase_payment` dice hoy "Pago a proveedor" en `CASH_MOVEMENT_META` — que es exactamente lo que significa el tipo **nuevo** `payment_made`. Con los dos vivos y la etiqueta vieja puesta, el arqueo tendría dos filas rotuladas igual con significados distintos. El tipo tiene **0 filas en producción**, así que el renombre no reescribe la historia de nadie: es el mejor momento posible para hacerlo, y el único.

**Por qué no reusar tipos existentes.** Tres alternativas descartadas:
- **Cobro como `sale`**: contaminaría el rubro "Ventas" del arqueo y del reporte de caja con plata que no es una venta de hoy — es la cobranza de una venta de hace un mes.
- **Cobro como `advance`**: `advance` es "Adelanto / depósito", plata que todavía no tiene documento. Un cobro sí lo tiene.
- **Pago a proveedor y compra al contado compartiendo `purchase_payment`**: dos hechos económicos distintos (comprar mercadería vs. cancelar un pasivo) que además van a contrapartidas contables distintas cuando llegue el asiento de V2.6. Indistinguibles en el arqueo, e indistinguibles justo cuando el usuario quiere saber en qué se le fue la plata.

**Por qué un tipo de reversa propio y no `adjustment`.** La spec `cash-movement` ya lo fija como normativo: *"Cada contra-movimiento automático SHALL tener su tipo propio en lugar de reutilizar `adjustment`, que está reservado para la corrección manual y exige motivo"*. `adjustment` además tiene un `CHECK` de `description` obligatoria.

**Las dos taxonomías siguen separadas** (D9 de `gastos-forma-pago`, ya normativa). `purchase_payment_reversal` es **ingreso por signo** (revertir un egreso repone plata) y **Reversas por familia** (junto a `sale_reversal` y `expense_reversal`). Conjuntos finales:
- ingresos: `{sale, advance, expense_reversal, purchase_payment_reversal, payment_received}`
- egresos: `{purchase_payment, expense, withdrawal, sale_reversal, payment_made}`
- signo libre: `{adjustment}`

**Alternativa considerada y descartada:** un solo tipo genérico `party_payment` con el signo distinguiendo cobro de pago. Rechazada porque el filtro de familia del historial de caja agrupa por tipo, no por signo, y "Cobro de cliente" y "Pago a proveedor" caerían en la misma casilla.

### D2 — El opt-in de caja de la compra es una copia literal del de gasto, no una variante

**Decisión.** `rpc_create_purchase_operation` suma `p_cash_session_id uuid DEFAULT NULL` **trailing** y, cuando viene informado, evalúa las tres condiciones en este orden, con los tres mensajes de error **textualmente iguales** a los de `rpc_create_expense`:

1. `v_kind = 'cash'` → si no, `P0422 cash_optin_requires_cash_kind`
2. sesión `open` cuya `cashbox.branch_id` = sucursal efectiva de la compra → si no, `P0422 cash_optin_requires_open_session`
3. `p_date = public.reporting_local_today()` → si no, `P0422 cash_optin_requires_today`

y sólo entonces `c28_register_cash_movement(p_cash_session_id, -v_total, 'purchase_payment', v_new_op_id)`.

**Por qué copia literal.** Los tres predicados ya están escritos, probados y en producción en dos RPCs. Reescribirlos "mejor" es cómo divergen. El comentario de la migración de gastos deja además una trampa documentada que hay que respetar al pie: la condición 3 compara **`p_date date`** contra `reporting_local_today()`, y está **prohibido** convertirla a `timestamptz` — el `::date` implícito usa la timezone del servidor (UTC) mientras `reporting_local_today()` usa `America/Argentina/Mendoza`, y una compra cargada entre las 21:00 y las 23:59 de Mendoza se rechazaría con `P0422` justo cuando el usuario está seguro de que es hoy.

**Por qué ausencia = NO-OP y no error.** El alta no se bloquea porque no haya caja abierta. La compra se registra igual, sin arqueo. Bloquearla convertiría un cambio de contabilidad en un cambio de disponibilidad del sistema de compras. Mismo contrato que venta y gasto.

**Lo que el helper aporta gratis y no hay que reimplementar:** sesión abierta (`P0409 no_open_session`), **tenencia de la sesión** (`P0401`, agregado por `tenancy-guard-caja-outbox` — la compra es literalmente el "caller futuro" que ese guard fue escrito para cubrir), sucursal operativa (`P0422 branch_closed`), `balance_after` bajo lock y `created_by`.

### D3 — La compra empieza a persistir `branch_id`, y eso es parte del change, no un extra

**Decisión.** Se cablea la cadena entera que hoy descarta la sucursal en el alta de compra. **Sin SQL nuevo**: la RPC ya recibe y valida `p_branch_id` desde `20261009000001` (activa y de la cuenta).

**Por qué no es scope creep.** La condición 2 del opt-in es *"hay una sesión abierta en la sucursal efectiva de la operación"*. Con `branch_id` siempre `NULL`, "sucursal efectiva" degrada al fallback `c26_default_branch`, y la compra quedaría registrada sin sucursal mientras su movimiento de caja sí tiene una (vía la caja). Un usuario con dos locales podría pagar del cajón de Showroom una compra que el sistema no atribuye a ninguna sucursal. Es exactamente el mismo agujero que `gastos-forma-pago` cerró en gastos (0/175), y por la misma razón.

**Dónde está la fuga, punto por punto** (los cuatro eslabones fallan en cadena, así que arreglar uno solo no alcanza):
1. `frontend/hooks/data/use-purchases.ts` — el `meta` acepta `branchId` y el `payload` no lo incluye.
2. `backend/schemas/purchases.py` — `PurchaseOperationIn` no tiene el campo.
3. `backend/services/purchases.py` `create_purchase_operation` — no lo lee.
4. `backend/repositories/purchase_repository.py` — pasa **`NULL` literal** como 5.º argumento en `create_operation` **y** en `create_operation_with_event`.

**Sin backfill de las 507 compras históricas.** Mismo criterio que la sucursal de los gastos: la sucursal correcta de una compra de hace seis meses no es derivable de nada que esté guardado.

### D4 — Los tres opt-in nacen **pre-marcados**

**Decisión.** El checkbox arranca tildado en el formulario de compra, en el modal de cobro y en el modal de pago — cuando las tres (o dos) condiciones se cumplen.

**Por qué.** El precedente ya está partido y la razón que lo parte aplica acá:
- La **venta** arranca destildada (D4 de un change anterior) porque el formulario de venta se usa masivamente para carga retroactiva de back-office, donde la plata no pasó por el cajón de hoy.
- El **gasto** arranca pre-marcado (D1 de `gastos-forma-pago`), firmado por el PO, porque **0 de 175** gastos históricos tocaban caja y el default correcto de "pagué esto en efectivo" es que salió del cajón.

Los tres caminos de este change están del lado del gasto, y el cobro es el caso más nítido de todos: *cobrar en efectivo es, literalmente, poner plata en el cajón*. Con el guard de fecha ya filtrando lo retroactivo, un default destildado haría que el arqueo siga sin ver la plata **salvo que el usuario se acuerde de tildar** — que es exactamente el estado de hoy con un paso más.

**El motivo se muestra siempre, nunca se oculta en silencio** (D1 de gastos): cuando alguna condición no se cumple, el bloque aparece igual explicando cuál falta.

### D5 — El cobro y el pago tienen **dos** condiciones, no tres, y la diferencia es de datos

**Decisión.** En `rpc_register_payment_received` y `rpc_register_payment_made` el opt-in evalúa:

1. `p_payment_method = 'cash'` → si no, `P0422 cash_optin_requires_cash_kind`
2. sesión `open` y de la cuenta → si no, `P0422 cash_optin_requires_open_session`

y **no** evalúa la condición de fecha.

**Por qué.** Verificado contra `information_schema`: `payments_received` es `(id, account_id, customer_account_id, client_id, amount, reference_sale_id, movement_id, created_by, created_at)` y `payments_made` su espejo. **No tienen columna `date` ni `branch_id`.** El cobro se registra con `created_at = now()`: "la fecha es hoy" es verdadera por construcción, no una condición que se pueda violar. Especificar un guard que no puede fallar es peor que no tenerlo: sugiere que existe un caso retroactivo que en realidad el modelo no admite.

**Y la sucursal.** El cobro **no declara sucursal propia**, así que no hay dos valores que puedan discrepar: la sucursal la aporta la sesión elegida (`sesión → cashbox → branch`). El guard que sí queda es el de **tenencia**, y viene gratis del backstop `P0401` que `tenancy-guard-caja-outbox` puso dentro de `c28_register_cash_movement` — el punto de paso obligado de todo movimiento de caja del sistema.

**Alternativa considerada y descartada:** agregarle `branch_id` a `payments_received`/`payments_made` para poder exigir la coincidencia. Rechazada: agrega dos columnas, un backfill imposible y un guard, todo para verificar una coincidencia que el modelo hace imposible violar. Si algún día el cobro gana sucursal propia por otra razón, el guard se agrega ahí.

### D6 — Firma aditiva trailing, con `DROP` explícito de la firma anterior

**Decisión.** Las tres RPCs de alta suman `p_cash_session_id uuid DEFAULT NULL` como **último** parámetro. La migración hace `DROP FUNCTION` de la firma anterior **antes** del `CREATE`, no un `CREATE OR REPLACE`.

**Por qué el `DROP`.** Agregar un parámetro con `DEFAULT` a una función existente **no reemplaza** la función: crea un **overload**. Quedarían dos definiciones vivas y las llamadas con la aridad vieja resolverían a la vieja — el bug `42725` (`function is not unique`) o, peor, el silencioso: el backend llamando a la versión sin caja y nadie notándolo. La spec `cash-movement` ya lo fija como normativo para su propio caso (*"existe exactamente una firma viva de cada una"*) y la memoria del proyecto lo tiene registrado como gotcha.

**`REVOKE` explícito de `PUBLIC`, `anon` **y** `authenticated`, y `GRANT` selectivo, en la misma migración.** No basta con revocar el pseudo-rol público: el proyecto hospedado otorga `EXECUTE` a los roles de aplicación de forma directa, así que una revocación limitada a `PUBLIC` deja la función abierta en producción aunque se vea cerrada en local. Es literalmente el requirement de `party-account-charge`, y el gate de ACLs ya lo verifica en CI.

**`rpc_delete_purchase_operation` no cambia de firma** — `CREATE OR REPLACE` alcanza. Igual se reescribe partiendo del cuerpo vivo hasheado.

### D7 — La compensación del borrado copia el molde de `rpc_delete_expense`, con disparo por existencia

**Decisión.** `rpc_delete_purchase_operation` suma una cuarta pata, **antes** de la de banco para mantener el orden "de lo más caro de deshacer a lo más barato":

```
1. cuenta corriente del proveedor  (_pay_reverse_party_charge, P0425 si dejaría saldo negativo)
2. CAJA  ← NUEVO
3. banco (espejo invertido por cada bank_movement source_doc_type='purchase')
4. stock (rpc_reverse_stock_movement)
5. evento PurchaseDeleted
6. DELETE físico
```

La pata de caja: localizar el `cash_movement` de la compra por `reference_id` bajo las **dos convenciones** que ya usa el resto de la RPC (`operation_id` y, si aplica, el `id` de la orden); si existe, buscar la sesión `open` de **esa misma caja**; si no hay ninguna → `P0426`, el borrado entero se rechaza; si hay → `c28_register_cash_movement(sesión_abierta, -importe_original, 'purchase_payment_reversal', operation_id)`.

**El disparo es por existencia, jamás por signo.** La spec `cash-movement` ya lo tiene como escenario normativo para el gasto, y la razón está escrita en la propia migración de gastos: si el bloque se condicionara a `amount < 0`, un movimiento que llegara con el signo contrario por cualquier camino **saltearía el bloque entero**, no se registraría la reversa, **nunca se lanzaría `P0426`** y el `DELETE` procedería igual. Se reintroduciría el cargo fantasma que motivó `delete-guard-ledgers`.

**Por qué contra la sesión abierta de hoy y no la original.** RN-99: el ledger es append-only por sesión y el arqueo firmado de una sesión cerrada es intocable. Es el mismo criterio que ya rige para venta y gasto, ya normativo en `cash-movement`.

### D8 — La compra con caja posteada es inmutable (`P0423`)

**Decisión.** El predicado que hoy bloquea la edición de una compra con cargo en cuenta corriente o movimiento bancario suma la pata de caja, en `rpc_atomic_update_purchase_operation` y en el derivado de lectura `is_payment_locked` del listado — **el mismo predicado en los dos lados**, que es la única forma de que el listado no mienta.

**Por qué.** Editar el total de una compra cuyo egreso de caja ya está en el arqueo dejaría el movimiento apuntando a un importe que ya no existe, y el ledger es append-only: no se puede corregir en su lugar. Es exactamente el argumento de `pagos-cableados-restantes` (`P0423` por cargo posteado), de `gastos-forma-pago` (D11) y del bloqueo fiscal. El camino de corrección es borrar y recargar, que D7 vuelve seguro.

**BREAKING de dominio, acotado**: hoy hay 4 compras en efectivo y ninguna tiene movimiento de caja, así que **ninguna compra existente cambia de comportamiento**. El bloqueo sólo aplica a las que se creen con el opt-in tildado de acá en adelante.

### D9 — Los derivados de bloqueo se calculan en el servidor, nunca en el cliente

**Decisión.** `PurchaseItemOut` suma `has_cash_movement` e `is_delete_blocked` — los dos `EXISTS` que `ExpenseItemOut` ya tiene — calculados en `list_paginated_by_operation` junto a los tres que ya están (`has_account_charge`, `has_bank_movement`, `is_payment_locked`).

**Por qué en el servidor.** `is_delete_blocked` es *"hay movimiento de caja de esta compra **y** no hay sesión abierta en esa caja"*: depende del estado de `cash_sessions`, que el cliente no tiene. Derivarlo en el frontend obligaría a traer las sesiones de todas las cajas para pintar una lista de compras. Es el mismo `EXISTS` que precede al `P0426` en la RPC — el servidor sigue siendo la autoridad; el derivado sólo evita que el usuario descubra el bloqueo con un 409.

**Y el consumidor ya existe**: `frontend/lib/delete-compensation.ts` declara `hasCashMovement` e `isDeleteBlocked` en `DeletableOperationFlags` desde `gastos-forma-pago`, con el texto del bloqueo redactado. El listado de compras simplemente nunca se los pasó. **Cero lógica nueva de cliente**: hay que pasar dos flags y ajustar la redacción para el documento "compra".

### D10 — Ni ERRCODEs nuevos ni eventos nuevos

**Decisión.** El change no agrega **ni un solo** ERRCODE. `P0400/P0401/P0409/P0412/P0422/P0423/P0426` ya existen, ya están mapeados en `backend/core/errors.py` y ya tienen su traducción de cliente. Tampoco agrega tipos de evento al outbox: el `PurchaseCreated`/`PurchaseDeleted` no cambian de payload y `_journal_post_from_event` no gana ramas.

**Por qué importa decirlo.** Cada ERRCODE nuevo obliga a tocar el mapeo HTTP, la traducción de cliente y el gate de ERRCODEs. Que este change no necesite ninguno es la mejor evidencia de que está copiando un molde existente en vez de inventar uno.

### D11 — Sin backfill de los 11 documentos históricos

**Decisión.** Las 4 compras `kind='cash'`, los 6 cobros y el 1 pago históricos quedan **sin movimiento de caja**, sin backfill.

**Tres razones independientes, cualquiera de ellas alcanza:**

1. **Es imposible saber cuáles fueron en efectivo.** `payments_received` y `payments_made` **no persisten el método de pago** (verificado: la columna no existe — el método se usa para rutear el movimiento bancario y se descarta). De los 6 cobros no hay forma de derivar cuáles fueron `cash`.
2. **Falsearía el arqueo vivo.** Un movimiento de caja tiene que ir contra una sesión, y las sesiones donde ocurrieron esos cobros ya cerraron con su arqueo firmado (RN-99: intocable). Inyectarlos en las **3 sesiones abiertas de hoy** metería plata de hace meses en el conteo de esta tarde, y la `difference` es señal antifraude (RN-95). El remedio sería peor que la enfermedad.
3. **Precedente firmado.** Los 175 gastos históricos se dejaron sin imputar por decisión explícita del PO (D7 de `gastos-forma-pago`), con un volumen 16 veces mayor.

**Qué ve el usuario.** Las compras y cobros viejos siguen exactamente como están; sólo los nuevos alimentan la caja. Es la misma discontinuidad que ya aceptó con los gastos.

### D12 — El `Idempotency-Key` cubre el movimiento de caja

**Decisión.** El movimiento de caja del cobro y del pago se postea **dentro** del bloque que la clave de idempotencia protege, después de la resolución de la cuenta corriente y antes del commit. Un replay devuelve el resultado original **sin** postear un segundo movimiento.

**Por qué es explícito.** Los dos modales generan la clave con `Date.now()`, y el retry automático de red del cliente es real. Un cobro duplicado en el arqueo es exactamente el tipo de ruido que RN-95 quiere evitar. La RPC ya tiene el mecanismo (DEC-06, `operation_kind='payment_received'`); lo único que hay que garantizar es que la escritura nueva quede **adentro** y no antes.

## Risks / Trade-offs

**[La reescritura de una RPC de 19.438 caracteres pierde algo en el camino]** → La regla de la casa existe por esto: toda reescritura parte del `pg_get_functiondef` **vivo** hasheado, no del archivo de migración (que ya divergió una vez). El hash de los cuatro cuerpos está en la tabla de arriba; la task 1.x lo vuelve a tomar **en el momento del apply** y compara. Si difiere de lo registrado acá, el apply se detiene y se investiga antes de escribir SQL.

**[Dejar dos overloads vivos de las RPCs de alta]** → `DROP FUNCTION` explícito de la firma anterior + verificación en el gate: `SELECT count(*) FROM pg_proc WHERE proname = ...` debe dar exactamente 1 por función. Es el gotcha `42725` ya registrado.

**[El arqueo de las 3 sesiones abiertas cambia de valor el día del deploy]** → No: el change **no escribe nada retroactivo** (D11). Las sesiones abiertas siguen con el mismo `expected_balance` hasta que alguien registre una compra o un cobro nuevo con el opt-in tildado.

**[El opt-in pre-marcado hace que un usuario postee en caja sin querer]** → Las tres condiciones lo acotan mucho (efectivo + caja abierta en esa sucursal + fecha de hoy), el checkbox es visible y destildable, y el error es **reversible**: borrar la compra compensa la caja (D7). El riesgo simétrico —el arqueo que sigue sin ver la plata porque nadie tildó— es el estado de hoy y es el que el PO pidió arreglar.

**[Ampliar el `CHECK` invalida filas históricas]** → Un `CHECK` que **agrega** valores permitidos no puede invalidar nada preexistente. La ampliación se escribe idempotente (`DROP CONSTRAINT IF EXISTS` + `ADD`) y la verificación cuenta las 71 filas antes y después.

**[El relabel de `purchase_payment` rompe una pantalla]** → Es un cambio de texto en `CASH_MOVEMENT_META`, con **0 filas** que lo muestren hoy. El riesgo real sería el inverso: dejar dos tipos rotulados "Pago a proveedor".

**[La compra empieza a aparecer en `rpc_branch_report`, que hoy no la ve]** → Es el efecto deseado de RN-93 y ya pasó con gastos. Se declara y se verifica: el reporte por sucursal muestra compras a partir de este change, y las 507 históricas siguen sin sucursal (`NULL`), no atribuidas a una equivocada.

**[`P0426` bloquea un borrado que el usuario cree que debería andar]** → Mismo comportamiento que ya tienen venta y gasto, con el mensaje ya redactado en `delete-compensation.ts` ("Abrí la caja para poder borrarlo") y ahora expuesto **en el listado**, antes de intentar (D9), no como un 409 sorpresa.

## Migration Plan

1. **Migración `20261018000001_caja_compras_cobranzas.sql`** — número verificado contra `origin/main` (última: `20261017000001_seguros_perfil_asesor.sql`) y contra `supabase_migrations.schema_migrations` en prod (`max(version)=20261017000001`, 266 filas). **Re-verificar al momento del apply**: la numeración se corrió tres veces en `cuenta-corriente-party-guard` por changes concurrentes.
2. Orden dentro de la migración: (a) ampliación del `CHECK`; (b) `DROP`+`CREATE` de las tres RPCs de alta con sus `REVOKE`/`GRANT`; (c) `CREATE OR REPLACE` de `rpc_delete_purchase_operation`; (d) `CREATE OR REPLACE` de `rpc_atomic_update_purchase_operation` con el predicado de lock ampliado.
3. **Idempotente de punta a punta**: Supabase auto-aplica desde GitHub y una reaplicación no debe fallar.
4. **Deploy**: merge → CI aplica migración + build. Sin feature flag: el comportamiento nuevo sólo se activa cuando el cliente manda `cash_session_id`, y el frontend viaja en el mismo deploy.
5. **Rollback**: revertir el frontend basta para desactivar el camino (sin `cash_session_id` las RPCs son NO-OP en caja). El `CHECK` ampliado y las firmas nuevas son compatibles hacia atrás y **no** se revierten — revertirlas sí rompería las filas que se hubieran creado.
6. **Verificación en prod post-merge** (obligatoria, patrón de los últimos seis changes): `max(version)`; una sola firma viva por función; ACLs de las cuatro funciones; cuerpo vivo conteniendo `c28_register_cash_movement`; y humo real con el PO — una compra en efectivo, un cobro en efectivo y el borrado de esa compra, viendo los tres movimientos en `/caja`.

## Open Questions

**OQ-1 — ¿`payments_received` y `payments_made` deberían persistir el método de pago?**
Hoy no lo hacen: el método llega por parámetro, rutea el movimiento bancario y se descarta. Es la razón #1 por la que el backfill es imposible (D11), y sin él el detalle de la cuenta corriente no puede decir cómo se cobró.
**Recomendación: SÍ.** Dos columnas aditivas y nullable (`payment_method text NULL`), sin backfill, escritas por las mismas RPCs que este change ya reescribe — costo marginal cero. **Si el PO no responde, se hace**: es aditivo, no rompe nada y evita tener que volver a abrir las dos RPCs.
**✅ Firmada 2026-09-01**: SÍ, por recomendación ("aplicalo con todas las recomendaciones").

**OQ-2 — ¿El opt-in del cobro debería arrancar pre-marcado o destildado?**
D4 decide **pre-marcado** para los tres caminos, alineado con el gasto. El caso más discutible es el pago a proveedor: se puede argumentar que a menudo se paga con plata que no salió del cajón del local.
**Recomendación: pre-marcado en los tres**, y revisarlo con datos reales después de un mes. Destildar es un clic; acordarse de tildar es lo que no pasó nunca en 175 gastos.
**✅ Firmada 2026-09-01**: pre-marcado en los tres caminos, por recomendación.

**OQ-3 — ¿El renombre de `purchase_payment` a "Compra en efectivo" necesita sign-off?**
Toca una etiqueta que ningún usuario vio nunca (0 filas).
**Recomendación: aplicarlo sin sign-off.** Se documenta en el change; si el PO prefiere otra redacción, es una línea.
**✅ Firmada 2026-09-01**: aplicado sin sign-off adicional, por recomendación.

**OQ-4 — ¿Se agrega ya el reverso de un cobro/pago de cuenta corriente?**
Hoy no existe el flujo (Non-Goal 1). Un cobro mal cargado no se puede deshacer por ningún camino, lo cual **ya es un problema hoy** — este change no lo empeora, pero le agrega una consecuencia más (el movimiento de caja también quedaría).
**Recomendación: NO en este change**, y darlo de alta como candidato propio (`cobranzas-reverso`), porque implica decidir la semántica de anulación de un cobro (contra-movimiento vs. nota) y eso es un change de dominio, no un agregado.
**✅ Firmada 2026-09-01**: FUERA de este change, por recomendación. Candidato `cobranzas-reverso` dado de alta en `CHANGES.md` (task 16.3).

**OQ-5 — ¿Backfill de los 11 históricos?**
D11 decide que no, con tres razones independientes y precedente firmado.
**Recomendación: confirmar el "no".** Si el PO quisiera reflejarlos, el camino correcto no es un backfill sino un **ajuste manual de caja** (`adjustment`, que exige motivo) hecho por él en la sesión que corresponda — que es justo para lo que ese tipo existe.
**✅ Firmada 2026-09-01**: confirmado el "no", por recomendación.

**Sign-off general del PO (2026-09-01):** *"aplicalo con todas las recomendaciones"* — autoriza el apply completo sin responder OQ-1..OQ-5 una por una; las cinco salen por su opción recomendada, como manda el precedente del proyecto (mismo patrón que `gastos-forma-pago` 2026-08-29).
