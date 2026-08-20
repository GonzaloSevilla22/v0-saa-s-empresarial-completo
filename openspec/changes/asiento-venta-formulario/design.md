## PO override (2026-08-20) — reemplaza D7 e invalida OQ-1

El diseño original recomendaba inmutabilidad (extender `P0423` a la venta con evento contable emitido). **El PO lo rechazó explícitamente** y ordenó la alternativa "editable; la edición ajusta el asiento": la venta del formulario sigue siendo editable siempre — sin excepción nueva — y una edición sobre una operación que ya tiene rastro contable **ajusta ese rastro** en vez de bloquear la edición. Los tres guards vigentes (cargo de cuenta corriente, movimiento de caja, movimiento bancario) **no cambian**: siguen bloqueando exactamente lo que bloqueaban antes de este change. Este override reemplaza D7 íntegramente (ver más abajo) y resuelve OQ-1 por rechazo — la sección de Open Questions lo deja registrado como decidido, no abierto. No hay superficie frontend: no hay indicador nuevo que mostrar porque no hay bloqueo nuevo que anticipar.

## Context

### Lo que hay vivo hoy (verificado en prod `gxdhpxvdjjkmxhdkkwyb` por `pg_get_functiondef`, 2026-08-20)

El libro diario se postea de forma **asíncrona** desde el outbox transaccional:

```
mutación (tx) ──INSERT INTO events──┐
                                    │  pg_cron 'relay-process-outbox', * * * * *, batch 100
                                    ▼
                        rpc_process_outbox_dispatch(100)
                          ├─ Consumer 1  AuditLog            (siempre, primero)
                          ├─ Consumer 2  EmailNotification   (3 tipos)
                          ├─ Consumer 3  JournalEntry        (5 tipos) → _journal_post_from_event
                          └─ Consumer 4  Notification        (5 tipos)
                        processed_at = now() sólo si TODOS los consumers activos tuvieron éxito
```

Propiedades del outbox que el evento nuevo debe heredar tal cual:

- **Emisión en la misma transacción de la mutación** (DEC-20 / spec `transactional-outbox` §"Outbox producers"): el evento hace rollback con la venta.
- **Idempotencia del consumidor** por slot `(event_id, consumer_type)` en `operation_idempotency`, reclamado *dentro* de `_journal_post_from_event`; un segundo pase es no-op.
- **Aislamiento por evento**: `BEGIN/EXCEPTION/END` por iteración en el dispatcher. Un fallo de rama emite `RAISE WARNING`, deja `processed_at IS NULL` y **reintenta al minuto siguiente**. No hay DLQ ni contador de intentos: el retry es infinito.
- **ASSERT de balance** Σdébito = Σcrédito con `ERRCODE = 'P0450'` al final del helper, común a todas las ramas.
- **Sin triggers** sobre `events`, `journal_entries` ni `journal_lines` (verificado en `pg_trigger`).

### El molde: la rama `PurchaseCreated`

Es la única rama **operation-level** en producción, y por eso es el molde exacto de lo que hace falta:

| Aspecto | Cómo lo resuelve `PurchaseCreated` |
|---|---|
| Referencia del documento | `source_doc_type='Purchase'`, `source_doc_ref = payload.operation_id` — no hay documento intermedio |
| Neto / IVA | El productor emite `'neto', NULL, 'iva_amount', NULL` **siempre**. El consumidor cae en el `ELSE`: **una sola línea por el TOTAL, sin discriminar IVA** |
| Forma de pago | `COALESCE(payload->>'payment_method','credit')` — el `kind` real derivado en el servidor desde `payment_method_id`, con default histórico |
| Contrapartida | `cash` → `1100 Caja`; todo el resto (incl. `wallet`, `credit`, sin imputar) → `2100 Proveedores` |
| Centro de costo | Del payload, con lookup de respaldo a `purchases.cost_center_id`; la línea de IVA siempre `NULL` |

**La convención de la casa para una operación sin comprobante fiscal es: asentar el TOTAL en una línea, sin IVA.** No hay que inventar tratamiento fiscal nuevo; hay que reusar el que ya está.

### El estado real de los datos (prod, 2026-08-20)

| Métrica | Valor |
|---|---|
| Operaciones de venta totales | 345 |
| — nacidas en el POS (con `sales_orders.sale_operation_id`) | 117 |
| — **nacidas en el formulario** | **228** |
| `sales_orders` / eventos `SaleConfirmed` / asientos `SalesOrder` | 120 / 120 / 120 (cobertura 100%) |
| Asientos totales | 159 (120 `SalesOrder` + 39 `Purchase`) |
| Ventas del formulario con asiento | **0** |
| Monto de las 228 sin asiento | **$13.333.157,19** |

Composición de las 228 por `kind` imputado:

| `kind` | ops | total | rango |
|---|---|---|---|
| **(sin imputar)** | **225** | $13.333.157,19 | 2026-04-18 → 2026-08-18 |
| `cash` | 2 | $48.150,00 | 2026-08-19 → 2026-08-20 |
| `credit` | 1 | $700,00 | 2026-08-20 |

El catálogo de formas de pago llegó al formulario recién el 2026-08-19 (`metodos-pago-operaciones`), de modo que **el caso dominante —y el que gobierna el diseño— es `kind` NULL**. 223 de las 225 sin imputar sí tienen cliente asociado.

### El lado compras: no hay agujero vivo

Dimensionado por día de creación, cruzando `purchases.operation_id` contra `events.payload->>'operation_id'`:

| Corte | Operaciones | Con `PurchaseCreated` |
|---|---|---|
| Anteriores al 2026-06-29 (alta del productor) | 39 | **0** |
| Desde el 2026-06-29 | 36 | **35** |

El productor cubre el 100% del tráfico posterior a su alta; la única excepción es 1 operación del 2026-07-31 (2 ops, 1 evento), compatible con una ventana de deploy. **Compras es backfill histórico de 40 operaciones, no un bug vivo** — a diferencia de ventas, donde el productor nunca existió. Quedan además 13 filas de `purchases` con `operation_id IS NULL` (legacy pre-agrupación) que no son backfilleables como operación y quedan fuera de alcance.

## Goals / Non-Goals

**Goals:**

- Que toda venta nacida en el formulario produzca un asiento balanceado, por el mismo camino asíncrono y con las mismas garantías que el POS y las compras.
- Que la contrapartida del asiento **espeje lo que los subledgers realmente hicieron** en esa misma transacción (cuenta corriente, caja, banco), sin crear saldos que ningún subledger respalde.
- Que el histórico quede regularizable por el consumidor real, no por INSERTs directos a `journal_entries`.
- Que una operación ya asentada siga siendo editable (override del PO, 2026-08-20) y que editarla **ajuste** el asiento —reemplazo in-place si el evento seguía pendiente, contra-entry + entry nuevo si ya procesó— en vez de dejarlo apuntando en silencio a un hecho distinto.

**Non-Goals:**

- **No** se toca ninguna de las cinco ramas vigentes del consumidor (`SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`). Regresión cero es un requisito, no un objetivo.
- **No** se resuelve el `DELETE` sin guard sobre operaciones con ledger posteado — ese es el candidato ya documentado `delete-guard-ledgers`. Este diseño no lo empeora (ver Riesgos).
- **No** se introduce tratamiento fiscal nuevo: sin discriminación de IVA para la venta del formulario, porque no hay comprobante del cual leerla.
- **No** se retrofitea `posted_at` en las cuatro ramas existentes (OQ-3).
- **No** se extiende `P0423` al asiento contable (**override del PO, 2026-08-20** — ver sección al inicio del documento): la venta del formulario sigue editable después de tener asiento. El follow-up que el design original preveía como alternativa (`asiento-edicion-reversa`) queda absorbido por este mismo change: construir la reversa/ajuste es ahora parte del alcance, no un follow-up.
- **No** se toca el bloque fiscal de `rpc_atomic_update_sale_operation`, ni los tres guards de pago vigentes (cargo de cuenta corriente / caja / banco) — el override no los reabre.

## Decisions

### D1 — Evento nuevo `SaleOperationCreated`, no reutilizar `SaleConfirmed`

`aggregate_type = 'SaleOperation'`, `aggregate_id = operation_id`, emitido por `rpc_create_sale_operation_v2`.

*Alternativa descartada — emitir `SaleConfirmed`*: su rama hace `SELECT ... FROM sales_orders so LEFT JOIN fiscal_documents fd WHERE so.id = payload.sales_order_id`. Una venta del formulario no tiene `sales_order`: el SELECT no devuelve fila, `v_comp_type/v_neto/v_iva` quedan NULL, el `source_doc_ref` queda colgado apuntando a una `sales_orders.id` inexistente y el asiento se arma con un `v_total` que sí existe — es decir, *balancearía* pero con una referencia falsa e irrastreable. Peor aún, `CreditNoteIssued` localiza el asiento original por `(source_doc_type='SalesOrder', source_doc_ref)`: contaminar ese espacio de claves con refs colgadas rompe la reversa de notas de crédito.

*Alternativa descartada — fabricar `sales_orders` sintéticas*: contamina el agregado del POS (conteos, KPIs, `rpc_payment_method_report`, el estado FSM de `document_status_history`) para resolver un problema contable. Se descartó ya en el propose de `pagos-cableados-restantes`.

### D2 — Rama nueva del consumidor con forma `Purchase`, no con forma `SalesOrder`

`source_doc_type = 'SaleOperation'`, `source_doc_ref = payload.operation_id`. Es el mismo patrón que `Purchase`/`operation_id`, con el que ya conviven 39 asientos en producción. El nombre del tipo se elige distinto de `'SalesOrder'` justamente para que las dos poblaciones sean separables en cualquier lectura futura.

### D3 — Débito ruteado por `kind`; el `kind` sin imputar va a `1100 Caja`

| `kind` del payload | Débito |
|---|---|
| `credit` | `1300 Deudores por Ventas` |
| `transfer`, `card`, `check`, `wallet` | `1110 Banco` |
| `cash`, `other` | `1100 Caja` |
| **NULL (sin imputar)** | **`1100 Caja`** |

Las cuatro primeras filas son el espejo literal de la rama `SaleConfirmed`, incluido el vocabulario bancario extendido con `wallet` por `pagos-cableados-restantes` D7. La quinta es la decisión propia de este change, y **es deliberadamente distinta del default de `PurchaseCreated`** (`COALESCE(...,'credit')` → `2100 Proveedores`):

> El asiento SHALL espejar lo que los subledgers hicieron. Con `kind` NULL, `rpc_create_sale_operation_v2` **no** llama a `_pay_register_party_charge` (no hay cargo en cuenta corriente) y `_pay_register_operation_bank_movement` no escribe nada (NULL no es un `kind` bancario). Debitar `1300` crearía 225 deudores por $13,3M que ningún `customer_account_movements` respalda, y que la pantalla de cuentas corrientes contradiría de inmediato.

La asimetría con compras está justificada: una compra sin forma imputada conserva un acreedor identificable (`purchases.supplier_id`) y la deuda con el proveedor es la presunción correcta; una venta sin forma imputada no tiene contrapartida en el subledger de clientes, y la presunción del micro-comercio es el cobro al contado. Es reversible con una línea si el PO decide otra cosa (OQ-2).

### D4 — Crédito: línea única `4100 Ventas` por el total, sin discriminar IVA

Una venta del formulario no tiene `sales_order` y por lo tanto **no puede** tener `fiscal_document_id`: no hay comprobante del cual leer `neto`/`iva_amount`. Este es exactamente el caso que el consumidor ya cubre hoy dos veces —el `ELSE` de `SaleConfirmed` ("Factura C / sin comprobante / sin desglose") y el `ELSE` de `PurchaseCreated`, que es el camino que toman las 39 compras posteadas—. Se reusa la convención existente; no se inventa nada.

`cost_center_id = NULL` en todas las líneas: la tabla `sales` **no tiene** columna `cost_center_id` (sólo `purchases` la tiene). No hay dato que imputar.

### D5 — `posted_at` = fecha de la venta (día ART), no el instante de proceso

Las cinco ramas vigentes escriben `posted_at = now()`, es decir la hora en que corrió el relay. En el histórico eso ya produjo un desfase visible: los 120 eventos `SaleConfirmed` del 2026-06-22 quedaron posteados el 2026-07-01, cuando se revivió el dispatcher (#248).

Para la rama nueva eso no es aceptable, por dos razones concretas:

1. **El formulario admite fechas pasadas** (`p_date` es un parámetro, con guards explícitos que sólo aplican a caja: `cash_optin_requires_today`). Una venta de agosto cargada en septiembre quedaría asentada en septiembre.
2. **El backfill** de 228 operaciones que van de abril a agosto quedaría íntegro con la fecha del día en que se corra, inutilizando el estado de resultados por mes que el change viene a arreglar.

El productor emite `sale_date` (= `p_date`) en el payload; la rama nueva calcula `posted_at` anclando esa fecha al **mediodía** de la zona horaria del proyecto, de modo que ningún corrimiento de offset pueda desplazar el día. La zona se toma **del literal que ya usa `public.reporting_local_today()`** (única función de día local viva), no de un segundo hardcode. Fallback `COALESCE(..., now())` si el payload no trae la fecha.

Las cuatro ramas existentes quedan como están: cambiarlas reescribiría la fecha contable de 159 asientos ya emitidos (OQ-3).

### D6 — El productor es un `INSERT` plano, sin degrade-don't-fail

`INSERT INTO public.events (...)` al final de `rpc_create_sale_operation_v2`, **después** de caja / cuenta corriente / banco, exactamente donde `rpc_create_purchase_operation` pone el suyo.

Sin bloque `EXCEPTION`: el patrón degrade-don't-fail está para triggers que no deben tumbar la mutación que los dispara, y aquí **violaría el contrato del outbox**. Si el `INSERT` falla y la venta igual commitea, el resultado es precisamente el bug que este change viene a arreglar —una venta sin asiento— pero ahora silencioso e irrepetible. La spec `transactional-outbox` es explícita: el evento comparte la transacción de la mutación. Además el riesgo alegado no existe: `events` no tiene triggers, la RPC es `SECURITY DEFINER` (RLS no aplica), no hay FK a nada volátil y el payload se arma con valores ya validados.

Payload:

```jsonc
{
  "account_id":     v_account_id,
  "operation_id":   v_new_op_id,
  "total":          v_total_sum,        // COALESCE canónico ya acumulado por línea
  "payment_method": v_kind,             // kind derivado del catálogo; NULL si no hay imputación (NO se coalescea)
  "client_id":      p_client_id,        // trazabilidad; la rama no lo usa para rutear
  "sale_date":      p_date,             // fecha contable (D5)
  "occurred_at":    now()
}
```

`payment_method` va **crudo**, sin `COALESCE(...,'cash')`: el default vive en la rama del consumidor, no en el payload, para que el evento reporte el hecho y no una presunción — la lección literal que dejó `pagos-cableados-restantes` D7 con el `'credit'` cableado de compras (afectó al 100% de las 38 compras históricas).

### D7 — Editable; la edición ajusta el asiento (reemplaza la inmutabilidad — override del PO, 2026-08-20)

`rpc_atomic_update_sale_operation` **no gana ningún guard nuevo**. Sigue rechazando exactamente lo que rechazaba antes de este change (comprobante fiscal, cargo de cuenta corriente, movimiento de caja, movimiento bancario) y nada más. La edición de una venta con rastro contable procede, y ese rastro se ajusta **dentro de la misma transacción de edición o del ciclo async del outbox**, según en qué punto del pipeline estaba el rastro en el momento de editar.

`rpc_atomic_update_sale_operation` regenera `operation_id` en cada edición (`v_new_op_id := gen_random_uuid()`, STEP 1 REVERSE → STEP 2 DELETE → STEP 3 APPLY, ya vigente, sin cambios). El `operation_id` viejo (`v_old_operation_id`) se captura antes del DELETE — ya lo hace el código vigente para re-apuntar `sales_orders`. El nuevo total (`v_total_sum`, agregado en el mismo patrón que `rpc_create_sale_operation_v2`) y el nuevo `kind` (derivado de `v_final_payment_method_id` vía `payment_methods.kind`, mismo lookup que el productor) sólo se conocen al final del loop STEP 3.

Al editar, el rastro contable de la operación vieja está en exactamente uno de tres estados, y cada uno tiene su propio tratamiento:

**Caso A — sin rastro** (operación anterior al productor, o que nunca tuvo evento): no hay `events` ni `journal_entries` para `v_old_operation_id`. No-op contable; la edición procede como si este change no existiera. Es el mismo comportamiento que la spec `operation-edit-context` ya documenta para "una operación anterior al asiento del formulario".

**Caso B — evento pendiente** (`processed_at IS NULL`): el dispatcher (`pg_cron`, cada minuto) todavía no generó el asiento. En vez de dejar que se genere con los valores viejos y compensarlo después, la edición **reemplaza el evento pendiente en el lugar**, en la misma transacción:

- Se localiza el evento con `SELECT * FROM events WHERE processed_at IS NULL AND ((event_type='SaleOperationCreated' AND aggregate_id=v_old_operation_id) OR (event_type='SaleOperationAdjusted' AND (payload->>'new_operation_id')::uuid = v_old_operation_id)) FOR UPDATE`.
- El `FOR UPDATE` (sin `SKIP LOCKED`) es la elección deliberada: el dispatcher lee su lote con `FOR UPDATE SKIP LOCKED` dentro de una única transacción de hasta 100 eventos. Si el dispatcher ya tiene la fila tomada, la edición **espera** (acotado por el tamaño del batch, no indefinido) en vez de fallar o de correr en paralelo sobre la misma fila — exactamente la garantía que pedía el brief: "un lock que no compita con el dispatcher".
- **Re-chequeo obligatorio tras el lock**: si al obtener el lock `processed_at` ya no es NULL (el dispatcher terminó de procesarlo mientras la edición esperaba), la fila ya no es "pendiente" — la edición cae al Caso C, no al B. Sin este re-chequeo habría una ventana de carrera real.
- Si el evento localizado es `SaleOperationCreated`: se actualiza `aggregate_id = v_new_op_id` y el payload completo (`operation_id`, `total`, `payment_method`, `client_id`, `sale_date`, `occurred_at`) a los valores nuevos. El dispatcher, cuando lo procese, genera **un solo asiento**, correcto, con `source_doc_ref = v_new_op_id`. No se emite un segundo evento.
- Si el evento localizado es `SaleOperationAdjusted` (edición encadenada sobre una edición cuyo ajuste todavía no procesó el relay): se actualiza `payload.new_operation_id` y los campos nuevos (`total`, `payment_method`, `sale_date`, `occurred_at`) a los valores de ESTA edición, pero **se preserva `payload.old_operation_id`** (la referencia al asiento original que hay que revertir no cambia — sigue siendo el mismo asiento original, todavía no tocado). Esto colapsa N ediciones-antes-de-procesar en un solo evento de ajuste final, en vez de encadenar eventos fantasma.

**Caso C — evento ya procesado** (existe `journal_entries` con `source_doc_type='SaleOperation'`, `source_doc_ref=v_old_operation_id`, `status='posted'`): el asiento ya es un hecho consumado. La edición **emite un evento nuevo** `SaleOperationAdjusted` (mismo INSERT plano sin `EXCEPTION`, mismo argumento D6: swallowar el fallo reproduciría el bug que este change arregla) con:

```jsonc
{
  "old_operation_id": v_old_operation_id,   // asiento a revertir
  "new_operation_id": v_new_op_id,          // asiento a crear
  "account_id":       v_account_id,
  "total":            v_total_sum,          // total nuevo
  "payment_method":   v_kind_final,         // kind nuevo, crudo (D6)
  "client_id":        p_client_id,
  "sale_date":        p_date,               // fecha nueva
  "occurred_at":      now()
}
```

`aggregate_type='SaleOperation'`, `aggregate_id = v_new_op_id`.

**Rama nueva del consumidor para `SaleOperationAdjusted`** (asíncrona, corre en el próximo tick del relay): localiza el asiento vigente por `source_doc_type='SaleOperation' AND source_doc_ref = old_operation_id AND status='posted'` (si no existe → `RAISE` con `P0451`, mismo código que ya usa `CreditNoteIssued` para "asiento original no encontrado, reintentar" — no hace falta un ERRCODE nuevo) y postea el par:

1. **Contra-entry** (reversión exacta): copia las líneas del asiento vigente con `side` invertido — el mismo patrón que la rama `CreditNoteIssued` ya usa para copiarse a sí misma —, `source_doc_type='SaleOperation'`, `source_doc_ref = old_operation_id`, `reversal_of = <id del asiento vigente>`, `status='posted'`, `source_event_id = NULL` (el índice único parcial `idx_journal_entries_source_event_uq` sólo admite **un** `journal_entries` por `source_event_id`; el evento produce dos filas, así que sólo una de las dos puede llevarlo — ver más abajo). `posted_at = now()` (la reversión no tiene "fecha propia": se postea el instante de la corrección, el mismo criterio que ya usa `CreditNoteIssued`).
2. **Nuevo entry**: líneas calculadas con el mismo ruteo por `kind` y la misma convención de crédito único `4100` que `SaleOperationCreated` (D3/D4) — factorizado en un helper compartido `_journal_sale_debit_account(kind text)` para que las **dos ramas nuevas** (`SaleOperationCreated`, `SaleOperationAdjusted`) lean el mismo mapeo y no puedan divergir entre sí. `SaleConfirmed` **no se toca** para leer del helper: su código queda byte a byte como está (task 2.1 lo exige para las cinco ramas vigentes) — su ruteo ya coincide en comportamiento con el del helper (mismo mapeo `kind`→cuenta), sólo que expresado inline; no hay divergencia de comportamiento, sólo de dónde vive el texto. `source_doc_type='SaleOperation'`, `source_doc_ref = new_operation_id`, `source_event_id = p_event.id`, `status='posted'`, `posted_at` por D5 (fecha de `sale_date` del payload, ancla mediodía ART).
3. El asiento vigente original se marca `status='reversed'` (mismo patrón que `CreditNoteIssued` sobre el asiento que reversa).
4. `ASSERT` de balance corre sobre **cada uno** de los dos asientos por separado (cada uno debe balancear individualmente — `P0450`). La invariante de negocio, verificada por test y no por un ASSERT de runtime adicional, es sobre los **tres** asientos de la cadena juntos (original + contra-entry + nuevo), no sólo sobre el par: Σ(crédito 4100 del original) − Σ(débito 4100 de la contra-entry) + Σ(crédito 4100 del nuevo) = el total nuevo. El primer término menos el segundo es siempre cero por construcción (la contra-entry es la reversión exacta del original — línea por línea, lado invertido), de modo que la invariante se reduce en la práctica a que el asiento nuevo lleve el total nuevo, pero la fórmula completa es la que hay que verificar para no confundir "el par contra+nuevo suma el total nuevo" (falso: ese par solo, sin el original, no balancea al total nuevo salvo que el total viejo fuera cero) con "la cadena completa deja 4100 en el total nuevo" (lo verdadero).

**Cadena de ediciones ya procesadas (gate dedicado)**: si se edita una operación cuyo ajuste anterior ya fue procesado por el relay, `v_old_operation_id` de la nueva edición es el `new_operation_id` que dejó el ajuste anterior, y el asiento "vigente" a revertir es el que ese ajuste creó (`status='posted'`) — no el original de la primera creación, que ya quedó `status='reversed'` por el ajuste previo. El lookup por `source_doc_ref = v_old_operation_id AND status='posted'` resuelve esto correctamente sin lógica adicional, porque cada ajuste deja como "vigente" exactamente un asiento por `operation_id`, y `v_old_operation_id` siempre es el `operation_id` que la operación tenía justo antes de esta edición.

**Trazabilidad**: `old_operation_id → reversal_of → new_operation_id` es reconstruible en una sola query por `journal_entries.source_doc_ref` + `journal_entries.reversal_of`, encadenable transitivamente para N ediciones.

**Consecuencia explícita (reemplaza a la de la versión anterior de este documento)**: ninguna venta del formulario deja de ser editable por tener asiento. El costo que el PO compra a cambio no es UX (no se resigna nada) sino superficie de implementación: dos caminos nuevos (reemplazo in-place + evento de ajuste) y una rama nueva del consumidor, en vez de un guard de una línea. No hay indicador nuevo que exponer en el frontend — no hay bloqueo nuevo que anticipar — así que este change **no tiene superficie frontend** (ver override al inicio del documento y la sección "Superficie frontend" del proposal).

### D8 — Backfill por el consumidor real, gateado, en dos grupos

Se emiten eventos al outbox y **los procesa el consumidor de producción**. No hay INSERT directo a `journal_entries`: una sola definición de "cómo se asienta una venta", y el mismo camino por el que la casa ya hizo su puesta al día en #248.

- **Grupo A — ventas del formulario**: un `SaleOperationCreated` por cada `operation_id` de `sales` sin `sales_orders` asociada y sin evento previo, con `sale_date` = fecha de la operación, `payment_method` = `kind` imputado (NULL para 225 de 228) y `payload.source = 'backfill'`. Conteo esperado hoy: **228**.
- **Grupo B — compras históricas**: un `PurchaseCreated` por cada `operation_id` de `purchases` sin evento previo, con la misma forma de payload que emite el productor vivo. **Cero código nuevo**: la rama del consumidor ya existe y está probada con 39 asientos. Conteo esperado: **40**.

Ambos grupos son idempotentes por construcción (`WHERE NOT EXISTS` sobre `events` por `operation_id` + tipo) y, por si acaso, el consumidor los vuelve a filtrar por su slot `(event_id, 'JournalEntry')`. El dispatcher los drena a 100 por minuto: ~3 minutos para los 268.

`payload.source = 'backfill'` marca el origen sin cambiar el comportamiento del consumidor y permite revertir el lote entero con una consulta.

### D9 — Firmas intactas, ACLs reafirmadas

Ninguna de las tres funciones cambia de firma → `CREATE OR REPLACE` sin `DROP`, de modo que los ACLs sobreviven. Aun así, se reafirma `REVOKE ALL ... FROM anon, PUBLIC` en el mismo archivo de migración, por la regla de la casa (un `DROP+CREATE` posterior resetearía los permisos) y para que `test_function_acl_gate.sql` verifique lo que el archivo declara. Se reusa `P0423` (5 caracteres, ya existente): no se agrega ERRCODE nuevo.

### D10 — Reescritura desde la definición viva

Las tres funciones se reescriben partiendo de `pg_get_functiondef` **de producción**, no de la última migración del repo. Es la regla que dejó el incidente del bloque `credit` de C-30, borrado en silencio durante un día de julio por una reescritura desde una base vieja. Las definiciones vivas se guardan en `baseline/` antes de tocar nada, y el gate de integridad de función las compara.

## Risks / Trade-offs

- **[La edición que reemplaza un evento pendiente compite con el dispatcher por la misma fila]** → Mitigado por diseño (D7): `SELECT ... FOR UPDATE` sin `SKIP LOCKED` espera en vez de fallar, acotado al tamaño del batch del dispatcher (100 eventos, corre en segundos); el re-chequeo de `processed_at` tras obtener el lock cierra la ventana de carrera (si el dispatcher terminó mientras la edición esperaba, la edición cae al camino de evento-ya-procesado en vez de mutar una fila que ya no es pendiente).
- **[Una cadena de ediciones sobre una operación ya ajustada podría referenciar el asiento equivocado si el lookup fuera por `operation_id` original en vez de por el vigente]** → Mitigado por diseño (D7): el lookup del asiento a revertir siempre usa `v_old_operation_id` de la edición ACTUAL (el que la operación tenía justo antes de esta edición), nunca el `operation_id` de la creación original — cada ajuste deja "vigente" exactamente un asiento `posted` por operación. Cubierto por un gate dedicado de edición encadenada (tasks 1.5c/5.6).
- **[La ventana asíncrona: la venta commitea y el asiento aparece hasta un minuto después]** → Es el contrato del outbox desde C-25, común a POS y compras; el guard de D7 se apoya en el evento justamente para que la ventana no sea explotable. Un fallo de rama deja el evento pendiente y reintenta al minuto.
- **[El backfill dispara 268 eventos y hasta 268 asientos en pocos minutos, sobre datos de usuarios reales]** → Gateado a sign-off con conteos declarados de antemano; idempotente y re-corrible; marcado con `source='backfill'` para revertir el lote completo; se corre fuera de horario y se verifica el balance de cada asiento antes de dar por cerrado el grupo.
- **[`kind` NULL → `1100 Caja` puede sobrestimar la caja histórica]** → Es la lectura menos dañina de las dos (la alternativa fabrica deudores que ningún subledger respalda) y es exactamente la presunción de un comercio que no registró forma de pago. Un solo `ELSIF` la cambia; queda como OQ-2 para el PO.
- **[El `DELETE` de una operación sigue sin guard: borrar una venta ya asentada deja el asiento apuntando a un `operation_id` inexistente]** → Preexistente e idéntico a lo que ya ocurre con `SalesOrder` y `Purchase`; este diseño no lo agrava porque no agrega ningún camino de borrado. Es el candidato `delete-guard-ledgers`, fuera de alcance por decisión explícita.
- **[La anomalía de compras del 2026-07-31 (2 operaciones, 1 evento) queda sin explicación]** → El Grupo B la absorbe como backfill. Se deja registrada por si reaparece: si vuelve a haber una operación sin evento posterior al 2026-06-29, hay un camino de alta de compras que no pasa por `rpc_create_purchase_operation` y eso sí sería un bug vivo.
- **[Divergencia futura entre la rama nueva y `SaleConfirmed`]** → Dos ramas de venta que hay que mantener sincronizadas cuando cambie el ruteo bancario. Mitigación mínima: el vocabulario bancario se define **una vez** en el helper y ambas ramas lo leen del mismo lugar.

## Migration Plan

1. Guardar en `baseline/` las definiciones vivas de las tres funciones (`pg_get_functiondef`, prod).
2. Migración única e idempotente, con `version > 20261003000001`, en este orden: rama nueva del consumidor (`SaleOperationCreated` + `SaleOperationAdjusted`) → productor (`rpc_create_sale_operation_v2`) → RPC de edición (`rpc_atomic_update_sale_operation`, reemplazo in-place + emisión de ajuste, D7). El consumidor primero, para que ningún evento quede pendiente esperando una rama que todavía no existe.
3. Merge → el pipeline de CI/CD construye, despliega y aplica la migración automáticamente.
4. Verificación en prod (sólo SELECT): una venta de prueba del formulario produce 1 evento y, al minuto, 1 asiento balanceado con las cuentas correctas; editarla antes de que el relay procese reemplaza el evento en el lugar (1 asiento final, con el `operation_id` nuevo); editarla después de que el relay procesó produce contra-entry + entry nuevo; los 159 asientos previos intactos; `events` sin pendientes acumulados.
5. **Gate del PO** → recién entonces, backfill Grupo A y Grupo B, con conteos verificados antes y después. El override de D7 ya no gatea el backfill a una decisión de inmutabilidad (esa pregunta está resuelta) — el gate que queda es el mismo que cualquier escritura masiva sobre datos reales: conteos declarados de antemano y verificación de balance por asiento.

Rollback: el consumidor vuelve a la definición del baseline (las ramas nuevas pasan a ser no-op y los eventos quedan pendientes, sin pérdida); el productor y la RPC de edición se revierten igual — una edición sobre una operación con evento pendiente ya reemplazado in-place perdería la capacidad de re-emitir con el rollback, pero el evento pendiente reemplazado sigue siendo válido y se procesa igual con el consumidor pre-rollback (no-op) hasta la siguiente migración hacia adelante. Los asientos ya posteados se revierten por `source='backfill'` o por `source_doc_type='SaleOperation'`.

## Open Questions

- **OQ-1 — RESUELTA por override del PO (2026-08-20)**: rechazada. La venta del formulario con evento/asiento emitido **no** se vuelve inmutable. Ver la sección "PO override" al inicio de este documento y D7 (reemplazado): editar ajusta el rastro contable en vez de bloquearlo. No queda abierta.
- **OQ-2** — Venta sin forma de pago imputada: ¿`1100 Caja` (recomendado, D3) o una cuenta puente de "ventas sin imputar" que obligue a regularizar? Afecta a 225 operaciones históricas por $13,3M y a toda venta futura del formulario en la que el usuario no elija forma de pago.
- **OQ-3** — ¿Se retrofitea `posted_at` = fecha del documento en las cuatro ramas existentes? Hoy postean con la hora del relay; los 120 asientos de junio quedaron fechados el 2026-07-01. Es un change aparte (toca 159 asientos ya emitidos) y probablemente conviene resolverlo junto con el cierre contable.
- **OQ-4** — ¿El backfill debe cubrir también las 18 filas de `sales` y 13 de `purchases` con `operation_id IS NULL` (legacy pre-agrupación)? Recomendación: no — sin `operation_id` no hay operación que referenciar y el asiento quedaría sin `source_doc_ref`.
- **OQ-5** — El libro diario no tiene pantalla. Con el backfill pasa de 159 a ~427 asientos y se vuelve la lectura contable principal de la app. ¿Amerita un change de superficie (`/reportes/libro-diario`) con filtro por `source_doc_type` y período?
