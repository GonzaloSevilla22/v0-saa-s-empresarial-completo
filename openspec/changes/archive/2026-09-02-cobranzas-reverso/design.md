## Context

### Lo que está medido contra producción (2026-09-02)

Todo lo que sigue se verificó contra el `pg_get_functiondef` **vivo** de producción (`gxdhpxvdjjkmxhdkkwyb`) vía `mcp__supabase__execute_sql` (SELECT, read-only), no contra los archivos de migración del repo. Es la regla de la casa desde `metodos-pago-operaciones`: el cuerpo vivo y el último archivo de migración **divergieron al menos una vez**, y el checkpoint que lo atrapó fue justamente el hash.

**Funciones que este change reescribe o usa como molde:**

| Función | Rol en este change | md5 del functiondef | chars |
|---|---|---|---|
| `_journal_post_from_event` | **se reescribe** (2 ramas nuevas + filtro) | `ef2d9459f125c200a28b757d266eb738` | 32.940 |
| `rpc_process_outbox_dispatch` | **se reescribe** (filtro del Consumer 3) | `28ef69cefc0fd0a5d112b656e7795ac6` | 5.933 |
| `rpc_delete_expense` | **molde** de compensación multi-libro | `4d78ee3b241bea2f4df34ceb0afb7cce` | 6.498 |
| `rpc_delete_purchase_operation` | molde secundario (4 libros) | `4da7dfce6087d288662ef47dc7a3598b` | 6.210 |
| `rpc_register_payment_received` | contraparte a revertir (no se toca) | `4d5de67480d67d064c1fba1198c9c6e3` | 7.656 |
| `rpc_register_payment_made` | contraparte a revertir (no se toca) | `07acdadbbcab5eb3086e31e0f055067f` | 6.751 |
| `_pay_reverse_party_charge` | **NO se usa** — ver D4 | `06e002447087a40bea59682ae82f06d2` | 2.514 |
| `c30_register_customer_account_movement` | helper reusado tal cual | `b8dcff26fbc713e70cb579fc6d6945c6` | 1.502 |
| `c28_register_cash_movement` | helper reusado tal cual | `1b0692ad5ba614f267389b335e4d366a` | 4.413 |
| `_register_bank_movement` | helper reusado tal cual | `6005feacb6c1a62bb1918f8f4d47949e` | 1.943 |

**Ausencias verificadas** (`pg_proc` + los dos routers): no existe `rpc_delete_payment_received`, `rpc_reverse_payment_*`, ni ningún endpoint `DELETE` en `backend/routers/customer_accounts.py` / `supplier_accounts.py`. `CustomerAccountHistory.tsx` y `SupplierAccountHistory.tsx` no tienen ninguna acción de fila.

### Estado de los datos

| Medición | Valor |
|---|---|
| Filas en `payments_received` | **6** |
| Filas en `payments_made` | **1** |
| ...de ellas con `payment_method` persistido | **0 de 7** (la columna nació ayer, sin backfill — D11 de `caja-compras-cobranzas`) |
| ...con asiento contable `posted` vigente | **6/6 y 1/1 — el 100%** |
| `bank_movements` con `source_doc_type IN ('payment_received','payment_made')` | **6** |
| `cash_movements` de tipo `payment_received`/`payment_made` | **0** (el camino se abrió el 2026-09-01) |
| Sesiones de caja abiertas ahora mismo | 4 |
| Última migración en prod | `20261018000001` (267 filas en `schema_migrations`) |

**Las dos mediciones que gobiernan el diseño:**

1. **`payment_method` es NULL en el 100% de los pagos.** Un reverso que decidiera qué libro compensar leyendo `payments_received.payment_method` **no compensaría nada para ningún pago histórico**, y fallaría en silencio. Por eso el disparo es **por existencia del movimiento**, no por la etiqueta del pago ni por su signo (D3). La asimetría entre pagos viejos y nuevos se resuelve sola.
2. **El 100% de los pagos tiene asiento contable vigente.** El frente contable no es hipotético ni diferible: es el libro con **más** cobertura histórica de los cuatro (6/6, contra 0 de caja). Diferirlo dejaría al libro diario afirmando que un cobro anulado entró (D5).

### Constraints vivos que el diseño tiene que respetar

```
customer_account_movements: CHECK (movement_type IN ('sale','payment_received','credit_note','adjustment'))
                            CHECK (balance_after >= 0)
supplier_account_movements: CHECK (movement_type IN ('purchase','payment_made','debit_note','adjustment'))
                            CHECK (balance_after >= 0)
cash_movements:             CHECK (movement_type IN (11 tipos, incl. 'payment_received','payment_made'))
bank_movements:             CHECK (movement_type IN ('transfer_in','transfer_out','card_settlement','fee',
                                                     'tax_debit','interest','manual_adjustment'))
journal_entries:            CHECK (status IN ('posted','reversed'))
```

Las claves foráneas apuntan **desde** `payments_received.movement_id` **hacia** `customer_account_movements.id`, y ninguna FK apunta hacia `payments_received`/`payments_made`. El `DELETE` del documento (D2) no está bloqueado por ninguna referencia.

## Goals / Non-Goals

**Goals:**

1. Que un cobro de cuenta corriente y un pago a proveedor mal cargados se puedan **anular desde la aplicación**, sin intervención manual en la base.
2. Que la anulación compense **los cuatro libros** —cuenta corriente, caja, banco y libro diario— o se rechace entera, en una sola transacción para los tres primeros y por outbox para el contable.
3. Que el KPI "Cobrado" del dashboard deje de contar un cobro anulado, **sin tocar la RPC de KPIs**.
4. Que el usuario vea, **antes** de confirmar, qué libros se van a mover y por qué no puede anular cuando no puede.
5. Que ningún camino de anulación pueda dejar el ledger de cuenta corriente en un estado que sus propios `CHECK` prohíben.

**Non-Goals:**

1. **Reverso parcial.** Un cobro es atómico; el parcial se resuelve anulando y recargando.
2. **Anular un cargo** (`sale`/`purchase`) por fuera del borrado de su operación — ya cubierto por `_pay_reverse_party_charge`.
3. **Reverso de un `adjustment`** de cuenta corriente: el ajuste manual se corrige con otro ajuste manual.
4. **RBAC diferenciado** anular vs. cobrar — materia de `v3-rbac-multirole` (CRÍTICO, bloqueado a sign-off).
5. **Backfill.** No hay nada que backfillear: el change agrega un camino, no cambia los existentes.
6. **Migrar los modales de cobro/pago al catálogo `payment_methods`** — sigue siendo Non-Goal 3 de `caja-compras-cobranzas`, con su propio change pendiente.

## Decisions

### D1 — La semántica es **contra-movimiento con tipo propio**, no nota de crédito ni `adjustment`

**Decisión.** El reverso de un cobro postea en `customer_account_movements` un movimiento de tipo **`payment_received_reversal`** con importe **positivo** (repone la deuda), referencia al pago anulado y `created_by` del que anula. Espejo exacto para el proveedor con **`payment_made_reversal`**. Los dos `CHECK` pasan de 4 a 5 valores.

**Por qué no una nota de crédito / débito como documento aparte.** Una nota de crédito es un documento **comercial** que reconoce una deuda menor del cliente: se emite, se numera, eventualmente se factura. Anular un cobro no reconoce nada —dice *"esta plata nunca entró"*— y **aumenta** la deuda en vez de reducirla. Emitir una NC por un cobro mal cargado inventaría un documento comercial que el cliente nunca vio, y encima con el signo invertido respecto de lo que una NC significa. Además, `RN-99` y la spec `soft-delete-policy` fijan la política de la casa para ledgers en una línea: *"nunca se borran ni se modifican, se corrigen con un contra-asiento"*.

**Por qué no reutilizar `credit_note` / `debit_note`.** Están tomados, y con el **signo opuesto**: `_pay_reverse_party_charge` los postea **negativos** para revertir un **cargo**. Un `credit_note` positivo en el ledger invertiría el significado del tipo para cualquier lector que asuma su signo — y hay al menos uno vivo, `charges_agg` en `rpc_dashboard_kpi_summary`, que filtra por `movement_type` y por signo a la vez.

**Por qué no `adjustment`.** La spec `cash-movement` ya lo fija como normativo: *"Cada contra-movimiento automático SHALL tener su tipo propio en lugar de reutilizar `adjustment`, que está reservado para la corrección manual y exige motivo"*. Reutilizarlo haría indistinguible en el historial de cuenta corriente *"anulé un cobro"* de *"corregí el saldo a mano"*.

**Alternativa considerada y descartada:** un solo tipo `party_payment_reversal` compartido por cliente y proveedor. Rechazada por la misma razón que `caja-compras-cobranzas` rechazó `party_payment`: son dos ledgers distintos con `CHECK` distintos, y el tipo compartido no ahorra una línea de código mientras vuelve ambiguo el filtro de cada historial.

### D2 — El **documento se borra**, los **libros se compensan**

**Decisión.** La fila de `payments_received`/`payments_made` se **`DELETE`a**, después de las cuatro compensaciones. Los cuatro ledgers conservan **ambos** movimientos (el original y su reversa), append-only.

Esta es la división que ya rige en todo el proyecto y no se inventa acá:

| Documento | Ledgers | RPC |
|---|---|---|
| `expenses` → **DELETE** | caja + banco → contra-movimiento | `rpc_delete_expense` |
| `purchases` → **DELETE** | cta cte + caja + banco + stock → contra-movimiento | `rpc_delete_purchase_operation` |
| `sales` → **DELETE** | cta cte + caja + banco + stock + asiento → contra-movimiento | `rpc_delete_sale_operation` |
| **`payments_received`** → **DELETE** | **cta cte + caja + banco + asiento → contra-movimiento** | **este change** |

**Qué se gana.** El KPI `collected_revenue` de `rpc_dashboard_kpi_summary` suma `payments_received.amount` del período **sin ningún filtro de estado** (verificado en el cuerpo vivo, CTE `payments_agg`). Borrar la fila lo corrige **por construcción**: cero cambios en la RPC de KPIs, que está bajo el gate `KPI_Validation` y fue objeto de un programa de remediación entero de 17 PRs.

**Qué se pierde, y por qué se puede perder.** Se pierde la fila del documento con su `created_by` y su `created_at`. **No se pierde el rastro**, que sobrevive en cuatro lugares:
- el movimiento original en el ledger de cuenta corriente, append-only, con su autor y su importe;
- el movimiento de reversa, con su propio autor —*quién anuló*— y su `reference_id` apuntando al pago;
- el evento `PaymentReceivedReversed` en `events`, con payload completo;
- el contra-asiento en `journal_entries` con `reversal_of` apuntando al original.

Y sobre todo: **la pantalla que el usuario mira es el historial de cuenta corriente**, que muestra los dos movimientos. La fila borrada no era visible ahí.

**Alternativa considerada — anulación por estado (`voided_at` / `voided_by` / `void_reason`).** Es lo que la spec `soft-delete-policy` prescribe para *"documentos confirmados"*, y tiene una ventaja real: conserva el motivo textual de la anulación en la fila del documento. Se descarta por tres costos concretos:
1. Obliga a modificar `rpc_dashboard_kpi_summary` (gate `KPI_Validation`) y **todo** lector futuro de `payments_received` que se olvide del filtro — exactamente el modo de falla que `soft-delete-policy` §RN-B1 pide evitar centralizando el filtro, centralización que hoy **no existe** para estas dos tablas.
2. Duplica la fuente de verdad: el estado del documento y la existencia de la reversa en el ledger podrían divergir.
3. Se aparta de los tres precedentes vivos y recientes de la casa sin una razón de dominio que lo justifique.
El motivo textual **no se pierde**: se persiste como `description` del contra-movimiento de caja (el helper ya la acepta) y en el payload del evento. Queda como **OQ-1** por si el PO prefiere el rastro documental.

### D3 — Disparo **por existencia** del movimiento, jamás por signo ni por `payment_method`

**Decisión.** Cada pata de compensación se dispara si existe el movimiento correspondiente:

```sql
-- Caja: agregado por sesión, filtrado por el tipo del ALTA (no por el de la reversa)
SELECT cs.cashbox_id, v_sum.total INTO v_cashbox_id, v_cash_amount
FROM (SELECT session_id, SUM(amount) AS total
      FROM public.cash_movements
      WHERE reference_id = p_payment_id AND movement_type = 'payment_received'
      GROUP BY session_id) v_sum
JOIN public.cash_sessions cs ON cs.id = v_sum.session_id;

IF v_cashbox_id IS NOT NULL AND v_cash_amount <> 0 THEN ...
```

**Por qué `<> 0` y no `> 0` ni `< 0`.** Es la lección literal que `gastos-forma-pago` dejó comentada en el cuerpo de `rpc_delete_expense`, en mayúsculas: un guard de signo copiado del molde equivocado *"se saltearía el bloque entero, no se registraría el contra-movimiento, NUNCA se lanzaría `P0426` y el `DELETE` procedería igual — sin levantar un solo error"*. El cobro es **positivo** (entra plata) y el pago a proveedor **negativo**: un mismo guard de signo no puede servir a los dos, y elegir mal en uno de ellos es un borrado inseguro silencioso. `<> 0` sirve a los dos y no depende de un invariante que vive en otra función.

**Por qué no leer `payments_received.payment_method`.** Es NULL en el 100% de los pagos históricos (medido). Un despacho por etiqueta no compensaría nada para ellos y **no levantaría error**: exactamente el modo de falla que el proyecto ya sufrió con el helper bancario que hace `RETURN NULL` cuando el `kind` no le corresponde. La existencia del movimiento es la única fuente de verdad que no depende de una columna que puede faltar.

**El filtro por `movement_type` del alta** (`'payment_received'`, no la reversa) impide que una reversa se auto-compense si alguien anulara dos veces — y la segunda anulación no encontraría documento (`P0404`) antes de llegar ahí.

### D4 — El reverso **no** usa `_pay_reverse_party_charge`

**Decisión.** Las dos RPCs nuevas llaman directamente a `c30_register_customer/supplier_account_movement`, no al helper compartido de reversión.

**Por qué**, aunque la regla de reutilización de la casa empuje en la dirección contraria: `_pay_reverse_party_charge` revierte un **cargo**, y eso es un hecho económico distinto en tres dimensiones a la vez.

| | `_pay_reverse_party_charge` | reverso de pago (este change) |
|---|---|---|
| Qué revierte | un **cargo** (venta/compra a crédito) | un **cobro/pago** |
| Signo que postea | **negativo** (reduce la deuda) | **positivo** (repone la deuda) |
| Tipo de movimiento | `credit_note` / `debit_note` | `payment_received_reversal` / `payment_made_reversal` |
| Evento que emite | `CustomerAccountChargeReversed` | `PaymentReceivedReversed` |
| ¿Puede violar `balance_after >= 0`? | **SÍ** → traduce `P0409` a `P0425` | **NO, nunca** — ver D6 |

Reutilizarlo exigiría cuatro parámetros nuevos para invertir todo lo que hace, lo cual **no es reutilizar sino reescribir con una capa de indirección de más**. La reutilización real de este change está en el nivel de abajo, que sí es idéntico: los tres helpers de escritura (`c30_register_*_account_movement`, `c28_register_cash_movement`, `_register_bank_movement`) se usan **tal cual, sin un solo parámetro nuevo**.

### D5 — El contra-asiento contable nace con el reverso; **no se difiere a V2.6**

**Decisión.** `_journal_post_from_event` suma dos ramas, `PaymentReceivedReversed` y `PaymentMadeReversed`, calcadas de `PurchaseDeleted`.

**Por qué esto no es una excepción a los deferrals anteriores.** `gastos-forma-pago` (D10) y `caja-compras-cobranzas` (Non-Goal 2) difirieron el asiento porque **no existía rama contable para su documento**: `_journal_post_from_event` no tiene rama de gasto y `public.events` no tiene ningún `event_type` de gasto. Acá es al revés: **las ramas `PaymentReceived` y `PaymentMade` existen y están vivas**, y el 100% de los pagos históricos tiene su asiento `posted`. Diferir el contra-asiento no sería *"no agregar contabilidad todavía"* sino *"romper la contabilidad que ya funciona"*: el libro diario seguiría afirmando `1100 Caja → 1300 Deudores` por un cobro que la aplicación acaba de declarar inexistente.

**El molde, byte a byte de `PurchaseDeleted`:**

```
1. v_payment_id := (v_payload->>'payment_id')::uuid;
2. SELECT id INTO v_orig_entry_id FROM journal_entries
     WHERE source_doc_type = 'CustomerAccount'   -- 'SupplierAccount' en el espejo
       AND source_doc_ref  = v_payment_id
       AND status = 'posted' AND account_id = v_account_id
     LIMIT 1;
3. IF v_orig_entry_id IS NULL → RAISE P0451 (el evento queda pending para retry)
4. INSERT contra-entry copiando source_doc_type/ref, con reversal_of = v_orig_entry_id
5. INSERT líneas invirtiendo side (debit↔credit), copiando amount, line_no y cost_center_id
6. UPDATE journal_entries SET status='reversed' WHERE id = v_orig_entry_id
```

**Convención única, no doble.** La venta necesita probar `(SaleOperation, operation_id)` y después `(SalesOrder, sales_order_id)` porque tiene dos caminos de alta. El cobro tiene **uno solo**, así que la localización es un `SELECT` directo — la rama es más simple que su molde, no más compleja.

**El `P0451` no es un bug, es el diseño.** Si el evento `PaymentReceivedReversed` llegara al consumidor antes que su `PaymentReceived` (outbox con backlog), el asiento original no existiría todavía y el reverso levantaría `P0451` → el evento queda `pending` → se reprocesa en el próximo tick, cuando el original ya está posteado. Es la **misma carrera y la misma mitigación** que `SaleOperationDeleted`/`PurchaseDeleted` ya tienen en producción desde `delete-guard-ledgers`. No se inventa un mecanismo nuevo.

### D6 — El reverso de un pago **nunca** puede violar el invariante de saldo, y eso se declara

**Decisión.** Las dos RPCs **no** traducen `P0409` a `P0425`, a diferencia de `_pay_reverse_party_charge`. La razón es aritmética y está verificada contra los constraints vivos:

- `customer_accounts.balance` es la **deuda** del cliente. `CHECK (balance_after >= 0)` en el ledger, más el guard explícito `P0409` en el helper (*"overpayment: el pago excede el saldo deudor"*), garantizan que **el saldo nunca es negativo**.
- Un cobro postea `−X` y sólo se acepta si `balance − X >= 0`.
- El reverso postea `+X` ⇒ `balance_after = balance + X >= balance >= 0`. **Es imposible que quede negativo.**

**Esto responde la pregunta abierta del chip** *"¿qué pasa con el saldo si el cliente ya usó el crédito?"*: **no puede pasar**. Un cobro nunca genera saldo a favor —`P0409` lo impide en el momento del cobro—, así que no hay crédito que el cliente pueda haber usado. El caso es estructuralmente inalcanzable, no improbable. Se **declara en la spec** en vez de dejarlo como folklore, y el gate lo ejercita con un control positivo: cobro que agota el saldo a 0, reverso, saldo vuelve al original.

El espejo del proveedor es idéntico con el mismo razonamiento sobre `supplier_accounts.balance`.

### D7 — La compensación de caja va a la **sesión abierta actual**, jamás a la original

**Decisión.** Copia literal del molde de `rpc_delete_expense`: el contra-movimiento se postea contra la **sesión `open` más reciente de la misma caja** (`ORDER BY opened_at DESC LIMIT 1`); si no hay ninguna → **`P0426`** y el reverso entero se rechaza.

**Esto responde la tercera pregunta del chip, sobre el alcance temporal, sin necesidad de una ventana de tiempo.** El chip preguntaba si limitar el reverso al día o a la sesión. **No hace falta ninguna limitación temporal explícita**, porque el molde ya la produce donde importa:

- El ledger de caja es **append-only por sesión** y un arqueo cerrado y firmado es intocable. La sesión original **nunca** se modifica, tenga un día o un mes.
- El efecto económico es el correcto: la plata sale del cajón **hoy**, que es cuando realmente sale.
- Si la caja de aquella sesión está cerrada hoy, `P0426` obliga a abrirla — y el mensaje lo dice: *"abrí la caja para poder anular este cobro"*.
- Para los pagos **sin** movimiento de caja (los 7 históricos, y todo cobro bancario o sin opt-in), la pata no se dispara y **no hay ninguna restricción temporal**: se pueden anular con cualquier antigüedad.

**Alternativa considerada y descartada:** limitar el reverso a los cobros del día o de la sesión abierta. Rechazada porque el caso de uso del PO —*"un cobro mal cargado"*— se descubre típicamente al conciliar, días después, y porque para el cobro bancario o sin caja la restricción no tendría ninguna justificación mecánica: sería una regla arbitraria que sólo impediría corregir el error.

**Consecuencia contable declarada:** el contra-asiento se postea con `posted_at = now()`, no con la fecha del asiento original. Es el mismo comportamiento que ya tienen los contra-asientos de venta y compra borradas.

### D8 — Guard de tenencia en las dos RPCs, con `P0404`

**Decisión.** Antes de tocar nada, cada RPC resuelve el pago con `WHERE id = p_payment_id AND account_id = v_account_id`; si no lo encuentra → `P0404`, con un mensaje que **no revela** si el identificador existe en otro tenant.

Es el precedente literal de `cuenta-corriente-party-guard` (`P0404` → 404 RFC 7807) y de `rpc_delete_expense` (*"expense_not_found: el gasto no existe o no pertenece a esta cuenta"*). El `account_id` resuelto se propaga como filtro a **todas** las lecturas posteriores —incluida la del asiento vigente en el consumidor contable, que ya filtra por `account_id`— para no depender sólo de la RLS: regla dura del proyecto desde la fuga de agosto (*"todo repository filtra explícito por account_id; RLS es red, no guard único"*).

### D9 — Idempotencia por **ausencia del documento**, no por clave

**Decisión.** Las RPCs de reverso **no** toman `p_idempotency_key`. El segundo reverso del mismo pago falla con `P0404` porque el documento ya no existe.

**Por qué.** Es el mismo contrato que `rpc_delete_expense` y `rpc_delete_purchase_operation`: un borrado es naturalmente idempotente-por-ausencia y no necesita una clave. Agregarla introduciría una tabla más que tocar y un modo de falla nuevo (clave quemada por un rechazo) sin ganar nada — el `DELETE` bajo el mismo `account_id` es el candado.

La idempotencia **del contra-asiento** sí existe y ya está resuelta: el slot `(event_id, 'JournalEntry')` de `operation_idempotency` que reclama `_journal_post_from_event` en su primera línea.

### D10 — Dos tipos nuevos de caja, familia **Reversas**, signo opuesto entre sí

**Decisión.** `cash_movements.movement_type` pasa de 11 a 13:

| Tipo | Signo (`backend/schemas/cash.py`) | Familia UI (`cash-movement-meta.ts`) | Etiqueta |
|---|---|---|---|
| `payment_received_reversal` | **egreso** (sale plata del cajón) | **Reversas** | "Anulación de cobro" |
| `payment_made_reversal` | **ingreso** (vuelve la plata al cajón) | **Reversas** | "Anulación de pago" |

**Las dos taxonomías siguen separadas** (D9 de `gastos-forma-pago`, normativa desde entonces): el signo vive en el backend y la familia del filtro en el frontend. Los cinco contra-movimientos automáticos comparten familia y **no comparten signo**, porque revertir un ingreso saca plata y revertir un egreso la repone.

Conjuntos finales:
- ingresos: `{sale, advance, expense_reversal, purchase_payment_reversal, payment_received, payment_made_reversal}`
- egresos: `{purchase_payment, expense, withdrawal, sale_reversal, payment_made, payment_received_reversal}`
- signo libre: `{adjustment}`

### D11 — El espejo bancario usa el escritor crudo, siempre `unreconciled`

**Decisión.** Loop calcado de `rpc_delete_expense` sobre `(source_doc_type = 'payment_received'|'payment_made', source_doc_ref = p_payment_id)`, invocando `_register_bank_movement` con `-amount` y el tipo invertido:

```
transfer_in  → transfer_out
transfer_out → transfer_in
ELSE           (mismo tipo, importe negativo)   -- card_settlement no tiene opuesto en el CHECK
```

**Por qué el escritor crudo y no `_pay_register_operation_bank_movement`.** La reversa no tiene que volver a resolver la cuenta bancaria ni volver a evaluar el guard de período conciliado: va **contra la misma cuenta** del movimiento original. Es el único uso autorizado del escritor crudo en este change, con el mismo razonamiento que `gastos-forma-pago` dejó comentado (D2 de aquel change).

**`card_settlement` conserva su tipo** con importe negativo, porque el `CHECK` de `bank_movements` no tiene un opuesto para él (verificado: 7 tipos, sin `card_settlement_reversal`). Es el comportamiento del molde y no se cambia acá — inventar un tipo bancario nuevo excedería el alcance y tocaría la conciliación.

### D12 — La superficie expone el bloqueo **antes** de intentar, con derivados del servidor

**Decisión.** `AccountMovementOut` gana dos derivados calculados en el **backend** con `EXISTS`, nunca columnas denormalizadas (regla D5 de `delete-guard-ledgers`):

- **`is_reversible`**: el movimiento es de tipo `payment_received`/`payment_made` **y** su documento sigue vivo en `payments_received`/`payments_made`. Un movimiento de tipo `sale`, `credit_note`, `adjustment` o una reversa **no** ofrece la acción.
- **`is_reversal_blocked`**: existe movimiento de caja del pago **y** no hay sesión `open` en esa caja. Es el **mismo `EXISTS` que evalúa el servidor** en la RPC, derivado para la UI — no una regla de cliente.

`getDeleteCompensation` recibe los documentos nuevos `"cobro"` y `"pago"` y enumera, en el diálogo, sólo las patas que apliquen. La redacción del ítem de caja **respeta el signo del documento**: anular un cobro *saca* plata del cajón, anular un pago la *repone* — decir lo contrario sería mentir sobre el arqueo, que es exactamente el bug que `qa-integral-modulos` corrigió para gasto y compra.

### D13 — El invariante de los dos filtros de `event_type` pasa a tener gate

**Decisión.** Los dos listados —el de `_journal_post_from_event` y el del Consumer 3 de `rpc_process_outbox_dispatch`— pasan de 9 a 11 tipos, y se agrega un **gate SQL** que compara los dos conjuntos extrayéndolos de los cuerpos vivos.

**Por qué.** Hoy el invariante lo sostiene **sólo un comentario** (*"el filtro del dispatcher y el de `_journal_post_from_event` deben listar el mismo conjunto"*), documentado desde `asiento-venta-formulario` y repetido por `delete-guard-ledgers`. Un olvido en cualquiera de los dos lados produce un evento que nunca postea asiento —o peor, que el dispatcher enruta a un helper que hace no-op— **sin levantar un solo error**. Es el mismo patrón de falla silenciosa que este proyecto ya pagó tres veces. Un comentario no es un gate.

## Risks / Trade-offs

**[La fila del documento desaparece y con ella el motivo textual de la anulación]** → El motivo se persiste como `description` del contra-movimiento de caja (el helper `c28_register_cash_movement` ya acepta el parámetro y `banco-caja-historial-ajustes` lo dejó normativo) y en el payload del evento. Para un pago **sin** movimiento de caja, el motivo sobrevive sólo en el evento. **OQ-1** ofrece la alternativa documental si el PO prefiere el rastro en la fila.

**[El contra-asiento se postea con fecha de hoy, no del asiento original]** → Es el comportamiento vigente de todos los contra-asientos del sistema (venta y compra borradas). Cambiarlo acá crearía una inconsistencia dentro del mismo libro. Se declara en la spec para que sea una decisión y no un descubrimiento.

**[Un reverso cuyo evento llega al consumidor antes que el alta deja el asiento sin revertir]** → `P0451` deja el evento `pending` y el relay lo reintenta en el próximo tick. Mecanismo idéntico al que `SaleOperationDeleted`/`PurchaseDeleted` usan en producción desde `delete-guard-ledgers`. El gate ejercita el orden invertido explícitamente.

**[`P0426` bloquea anular un cobro viejo cuya caja está cerrada hoy]** → Es deliberado (D7) y el mensaje dice qué hacer. Afecta **sólo** a pagos con movimiento de caja, que hoy son **0** en producción. Los 7 pagos históricos son anulables sin ninguna restricción.

**[Reescribir `_journal_post_from_event` (32.940 chars) puede perder una rama existente]** → Regla de integridad de función: la reescritura parte del `pg_get_functiondef` **vivo hasheado** (`ef2d9459…`), el hash se verifica en el checkpoint 1.x del apply **antes de escribir una línea de SQL**, y el gate `test_asiento_venta_formulario.sql` + `test_delete_guard_ledgers.sql` ejercitan las 9 ramas preexistentes. La spec `journal-entry` ya tiene un requirement dedicado —*"Preservación de las ramas contables existentes"*— que este change hereda.

**[Dos `CHECK` de ledger ampliados podrían invalidar filas existentes]** → Los tres `CHECK` se amplían **agregando** valores, nunca quitando; ninguna fila existente puede dejar de cumplirlos. La migración es idempotente (`DROP CONSTRAINT IF EXISTS` + `ADD CONSTRAINT`) y se verifica con un conteo antes/después.

**[El usuario anula un cobro y el saldo del cliente sube: puede leerse como un error]** → Es correcto y es lo que tiene que pasar, pero el diálogo lo dice **antes** de confirmar: *"se repondrá la deuda del cliente por $X"*. El historial muestra los dos movimientos, con el saldo después de cada uno.

## Migration Plan

1. **Checkpoint 1.x (antes de escribir SQL)**: re-capturar el `pg_get_functiondef` vivo de las 10 funciones de la tabla del Context y comparar los md5. **Un hash que no coincide detiene el apply** — significa que prod divergió del baseline y el diseño hay que revisarlo, no forzarlo.
2. Re-verificar la correlativa de migración contra `origin/main` **y** contra `supabase_migrations.schema_migrations` en prod. `20261019000001` es la previsión, no una certeza: `caja-compras-cobranzas` ya vivió un renumerado y `cuenta-corriente-party-guard` tres.
3. Migración en un solo archivo, idempotente, en este orden: `CHECK`s → RPCs nuevas → `_journal_post_from_event` → `rpc_process_outbox_dispatch` → `REVOKE`/`GRANT`.
4. Backend y frontend en el mismo PR (el derivado `is_reversible` sin UI no sirve a nadie, y la UI sin el derivado inventaría la regla).
5. **Rollback**: el change es puramente aditivo en DB (tipos nuevos en `CHECK`, funciones nuevas, dos ramas nuevas en un `IF`). Revertir el PR restaura los cuerpos anteriores; las filas de reversa ya posteadas **quedan** y siguen siendo válidas para todos los lectores, porque los `CHECK` ampliados no se revierten (un `CHECK` que rechace filas existentes rompería la tabla). El rollback de los `CHECK` es explícitamente **no deseado** y se documenta como tal.
6. **Verificación post-merge en prod** (misma rutina que los cuatro changes anteriores): `MAX(version)`, ACLs de las 2 RPCs nuevas (`REVOKE` efectivo de `anon` y `authenticated` sobre nada que no deba ser llamable), cuerpos vivos con las ramas nuevas, y un humo real de anulación de un cobro de prueba con verificación de los cuatro libros.

## Open Questions

**OQ-1 — ¿La anulación borra la fila del pago, o la marca como anulada?**
D2 decide **borrarla**, por precedente (los tres borrados de documento vivos hacen exactamente eso) y porque corrige el KPI `collected_revenue` sin tocar `rpc_dashboard_kpi_summary` (gate `KPI_Validation`). La alternativa —`voided_at`/`voided_by`/`void_reason`— conserva el motivo textual en la fila y se alinea con la letra de `soft-delete-policy` para *"documentos confirmados"*, a costa de modificar la RPC de KPIs y de dejar un filtro que todo lector futuro puede olvidar.
**Recomendación: borrar (D2).** El rastro no se pierde —vive en los dos movimientos del ledger, en el evento y en el contra-asiento con `reversal_of`— y la pantalla que el usuario mira ya lo muestra completo. **Si el PO no responde, se hace así.**

**OQ-2 — ¿El motivo de la anulación debería ser obligatorio?**
`p_reason` se diseña **opcional**, como en `rpc_delete_purchase_operation`. El argumento a favor de exigirlo es que anular dinero no es lo mismo que borrar un gasto.
**Recomendación: opcional, pero el campo se muestra en el diálogo** y viaja al `description` del contra-movimiento de caja y al payload del evento. Volverlo obligatorio es un `NOT NULL` de un renglón si el PO lo pide después de ver el uso real; volverlo opcional después de haberlo exigido rompe llamadas. No bloqueante.

**OQ-3 — ¿Quién puede anular?**
Hoy `is_account_writer`, igual que para cobrar.
**Recomendación: `is_account_writer`, por simetría.** Restringir la anulación a owner/admin es defendible, pero fabricaría una regla de roles fuera de `v3-rbac-multirole` (CRÍTICO, bloqueado a sign-off del PO), que es donde vive la matriz de permisos. No bloqueante: elevar el guard después es un `IF` más; relajarlo después es una discusión de seguridad.

**OQ-4 — ¿Se limita el reverso a una ventana temporal?**
D7 decide **no**, y argumenta que el molde `P0426` + compensación en la sesión abierta ya produce el único límite que importa, sin inventar una regla arbitraria para los cobros bancarios.
**Recomendación: sin ventana temporal.** El caso de uso real —descubrir el error al conciliar, días después— quedaría fuera de cualquier ventana corta. **Si el PO no responde, se hace así.**

**OQ-5 — ¿El historial de cuenta corriente debería mostrar el `payment_method` del cobro anulado?**
`AccountMovementOut.payment_method` se resuelve hoy por `LEFT JOIN` a `payments_received`. Borrada la fila (D2), el movimiento original pasa a mostrar `payment_method = NULL` — igual que los 7 históricos, que ya lo muestran NULL.
**Recomendación: aceptarlo.** Es cosmético, afecta sólo a cobros anulados, y el dato relevante —qué libro se movió— sigue visible en `/caja` y en el detalle bancario. Anotarlo, no resolverlo acá. No bloqueante.
