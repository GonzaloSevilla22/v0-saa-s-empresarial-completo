## Context

Ver `proposal.md` para la motivación. Este documento resuelve **cómo**.

### Estado medido (2026-08-28, prod `gxdhpxvdjjkmxhdkkwyb`, sólo `SELECT`)

| Hecho | Valor | Consecuencia de diseño |
|---|---|---|
| Columnas de `public.expenses` | `id, user_id, category, amount, date, created_at, description, company_id, account_id, branch_id, cost_center_id` | Falta `payment_method_id`. `branch_id` existe pero nadie la escribe. |
| Gastos en prod | 175 · 9 cuentas · 2026-03-07 → 2026-08-29 · $8.723.710,63 | Volumen real, opt-out histórico obligatorio (D7). |
| Gastos con `branch_id` | **0 / 175** | `rpc_branch_report` nunca vio un gasto. |
| Gastos con `cost_center_id` | **0 / 175** | El bug de edición que los borra es parte de la explicación. |
| `cash_movements` con `movement_type='expense'` | **0** (de 67: 65 `sale`, 2 `sale_reversal`) | El tipo existe en el `CHECK` y jamás se emitió. |
| `payment_methods` con `bank_account_id` | **0 / 37 cuentas** | Bloqueante de producto (D5). |
| Cuentas con alguna `bank_accounts` activa | **4 / 37** (9 cuentas cargan gastos) | La exigencia bancaria tiene que ser condicional (D5). |
| `MAX(version)` de migraciones | `20261014000001` (263) | Próximo libre `20261015000001`, re-verificable en el apply. |
| Tests del módulo Gastos | **0** (ni componente, ni hook, ni a11y) | El TDD arranca del andamio (D14). |
| `expenses.date` | `timestamp with time zone` (default `now()`) | Hay que castear antes de comparar con el día local (D1). |
| Soft delete en `expenses` | No existe (`deleted_at` ausente) | El borrado sigue físico + compensado. |

### Restricciones duras

- **DEC-24**: la unidad de trabajo es la RPC `SECURITY DEFINER`. Dos libros en una transacción no se hacen desde `asyncpg` con `INSERT` sueltos.
- **Reutilización antes que repetición** (regla PO 2026-08-02): todo predicado de este change existe ya en ventas o compras. Proponer uno nuevo exige justificar por qué no sirve el existente. Este design **no propone ningún helper SQL nuevo**.
- **`P0001` prohibido** para gates nuevos. De hecho el change **no necesita ningún ERRCODE nuevo**.
- **Gate de integridad de función**: toda reescritura de RPC parte del `pg_get_functiondef` **vivo**, hasheado antes de escribir SQL (regla instaurada tras el G3 reescrito in-place de `compras-proveedor-cuenta-corriente`).
- **Superficie frontend obligatoria**, desktop + mobile, claro + oscuro, con el design system (tokens semánticos, componentes vía cva).

## Goals / Non-Goals

**Goals:**

1. Un gasto puede imputar una forma de pago del catálogo `payment_methods` de su cuenta.
2. Un gasto en efectivo puede descontar de la sesión de caja abierta, atómicamente con el alta.
3. Un gasto por método bancario escribe un `bank_movement` que **efectivamente llega** a la pantalla de conciliación bancaria — no un `NULL` silencioso.
4. Alta, edición y borrado de gastos son atómicos y no pueden dejar un libro apuntando a un gasto inexistente ni un gasto sin sus libros.
5. Toda la funcionalidad es **operable desde `/gastos`** por un usuario, y el estado de bloqueo es visible antes de intentar la acción.
6. Cero lógica financiera nueva: se reusan los helpers y predicados de venta y compra.

**Non-Goals:**

1. Asiento contable del gasto (diferido a V2.6 — ver D10).
2. Emisión de eventos de gasto al outbox.
3. Cuenta corriente de gastos / `kind = 'credit'` (D3).
4. Backfill de los 175 gastos históricos (D7).
5. Soft delete de gastos.
6. Sembrar `bank_account_id` por defecto en los catálogos de las 37 cuentas (OQ-2).
7. Imputación de forma de pago desde el importador CSV (D9).

## Decisions

---

### D1 — El impacto en caja es **opt-in explícito, pre-marcado cuando corresponde**, con las tres condiciones verificadas en el servidor

**Decisión.** La RPC de alta acepta un `p_cash_session_id` opcional. Si viene `NULL` → **no-op** (el gasto se guarda sin tocar caja). Si viene informado, se validan en el servidor **las tres condiciones que ya usa el formulario de venta**, copiadas literalmente de `rpc_create_sale_operation_v2`:

1. el `kind` derivado del catálogo es `cash`, si no → `P0422 cash_optin_requires_cash_kind`;
2. la sesión existe, está `open` y su `cashboxes.branch_id` coincide con la sucursal efectiva del gasto (`COALESCE(p_branch_id, c26_default_branch(cuenta))`), si no → `P0422 cash_optin_requires_open_session`;
3. la fecha del gasto es el **día local de hoy** (`reporting_local_today()`), si no → `P0422 cash_optin_requires_today`.

En la UI el checkbox aparece **pre-marcado** cuando las tres condiciones se cumplen del lado cliente, y cuando no se cumplen **no se oculta**: se muestra deshabilitado con el motivo concreto ("no hay caja abierta en esta sucursal", "el gasto no es de hoy", "la forma de pago no es efectivo").

**Por qué opt-in y no obligatorio.** Bloquear el alta de un gasto porque no hay caja abierta convierte un problema de arqueo en un problema de registro: el microemprendedor que carga los gastos del día a la noche, con la caja ya cerrada, **no podría registrarlos**. Es fricción real y desproporcionada. Además rompería el importador CSV y toda carga retroactiva.

**Por qué pre-marcado, apartándose del formulario de venta.** El opt-in de venta nace **desmarcado** (D4 de `pagos-cableados-restantes`) para no convertir en diferencia de arqueo las 223 operaciones históricas y el hábito ya instalado de cargar ventas retroactivas. **El gasto no tiene esa deuda**: 0 de 175 gastos tocaron caja jamás, y el pedido del PO es literalmente que los movimientos concilien caja. Pre-marcar es el default correcto para un comportamiento nuevo; el checkbox se mantiene para el caso legítimo del gasto que ya se pagó de otro bolsillo. La asimetría es deliberada y queda documentada en el texto de apoyo.

**Por qué se conserva la condición "sólo hoy".** Es tentador relajarla porque los gastos se cargan retroactivamente más que las ventas. No se relaja: si la plata salió ayer y la sesión de ayer ya cerró con su arqueo, postear el egreso en la sesión de hoy **inventa una diferencia** en el arqueo de hoy. El invariante de `cash_movements` como ledger append-only por sesión no admite el retroactivo. Se reusa el predicado tal cual.

**Detalle de implementación obligatorio.** `expenses.date` es `timestamptz`, no `date` como `sales.date`. La comparación se hace **casteando** (`p_date::date <> reporting_local_today()`); sin el cast, un gasto legítimo de hoy cargado a las 15:00 es rechazado.

**Alternativas descartadas.**
- *Obligatorio (el gasto en efectivo exige sesión abierta o se rechaza)*: bloquea el registro por una razón ajena al gasto; rompe carga retroactiva e importador.
- *Automático por `kind`, sin checkbox (como el POS)*: el POS puede hacerlo porque el mostrador es siempre "ahora y acá". El gasto no. Automático sin condiciones convertiría cada gasto retroactivo en una diferencia de arqueo — exactamente lo que D4 de `pagos-cableados-restantes` descartó.

---

### D2 — La pata bancaria se despacha con **una llamada incondicional** al helper existente

**Decisión.** La RPC de gasto invoca `_pay_register_operation_bank_movement(cuenta, kind, payment_method_id, bank_account_id, importe, 'out', 'expense', id_del_gasto, fecha::date, sucursal, NULL)` **sin ningún `IF` previo**, exactamente como lo hacen `rpc_create_sale_operation_v2` (con `'in'`, `'sale'`) y `rpc_create_purchase_operation` (con `'out'`, `'purchase'`). El helper decide.

**Qué aporta gratis, y por eso no se reimplementa nada:** el predicado `kind IN ('transfer','card','check','wallet')`; la resolución override → default → `NULL`; la validación de la cuenta bancaria (ajena, inactiva o borrada → `P0412`); el rechazo de cuenta bancaria informada sobre un `kind` no bancario → `P0400`; el mapa `kind`→`movement_type` (`card`→`card_settlement`, resto `out`→`transfer_out`); el signo; y el **guard de período conciliado** `P0424`, que revierte la operación entera si la fecha cae dentro de una `reconciliation_sessions` cerrada.

**La fecha valor va sí o sí.** Se pasa la fecha del gasto casteada a `date`. Si fuera `NULL`, el movimiento cae en `created_at` y la sugerencia automática de conciliación (monto exacto, ventana ±3 días) se desalinea del extracto — el objetivo del PO se cumpliría a medias.

**Alternativas descartadas.**
- *`_register_bank_movement` directo*: es el escritor crudo, sin validación de cuenta ni guard de período conciliado. Se reserva **exclusivamente** para la reversa por borrado (D8), imitando el loop de `rpc_delete_sale_operation`.
- *`rpc_register_bank_movement`*: es el alta **manual** — consume su propia idempotencia y su whitelist de `movement_type` excluye `card_settlement`. Llamarla desde la RPC de gasto duplicaría idempotencia y guards.

---

### D3 — `kind = 'credit'` **no aplica** a un gasto: se oculta en la UI y se rechaza en el servidor

**Decisión.** Doble puerta:
- **UI**: `PaymentMethodSelect` en contexto de gasto **no ofrece** las formas de pago de `kind = 'credit'`.
- **Servidor**: la RPC rechaza `kind = 'credit'` con `P0400 credit_not_supported_for_expense`, para que la API no sea un bypass de la UI.

El texto de apoyo dice el camino correcto: *"para un gasto que vas a pagar después, cargalo como compra a proveedor: la cuenta corriente vive ahí"*.

**Por qué.** `expenses` **no tiene contraparte**: ni `supplier_id` ni `client_id`. No hay cuenta corriente que cargar. `_pay_register_party_charge` exige un `party` real. Un gasto a crédito sin tercero es una deuda con nadie.

**Alternativas descartadas.**
- *Permitirlo como etiqueta sin efecto (como `other`)*: ofrecería "Cuenta corriente" en el selector de gastos para no hacer absolutamente nada. Es la clase exacta de no-op silencioso que este proyecto viene pagando caro (el bloque `credit` borrado de C-30, los defaults bancarios en `NULL`). Un usuario que elige "Cuenta corriente" en un gasto está diciendo algo que el sistema no puede cumplir; se lo decimos.
- *Agregar `supplier_id` a `expenses`*: convertiría al gasto en una compra sin líneas. La compra a proveedor ya existe, ya tiene cuenta corriente y ya está probada (`compras-proveedor-cuenta-corriente`). Duplicar el dominio es peor que redirigir.

---

### D4 — El CRUD entero migra a RPC en **una sola etapa**: alta, edición y borrado

**Decisión.** Tres RPCs `SECURITY DEFINER` con `search_path` fijado: `rpc_create_expense`, `rpc_update_expense`, `rpc_delete_expense`. El repositorio Python pasa a **una llamada por operación** y deja de componer SQL.

**Por qué no hay etapa 1 "sólo alta".** Un alta que postea dinero conviviendo con el `DELETE` crudo actual (`expense_repository.py` L52) es **exactamente** el estado que produjo un cargo fantasma real en producción: borrar la operación sin compensar el libro. Etapar el change dejaría el sistema **peor** que hoy durante la ventana entre etapas, no a medias. La instrucción del PO ("la etapa 1 tiene que dejar el sistema consistente") sólo se cumple entregando las tres.

**Autorización dentro del `DEFINER`.** Un `SECURITY DEFINER` deja la RLS fuera de juego, así que la autorización se re-establece explícitamente y **el tenant se resuelve desde la sesión, nunca por parámetro**: se deriva de `current_account_ids()` y se exige `is_account_writer` sobre la cuenta resuelta. Es la lección directa del hotfix #454 (`_pay_register_party_charge` recibía el `account_id` por parámetro con `GRANT` a `authenticated` = escritura cross-tenant real). En la edición y el borrado, el gasto se localiza con `WHERE id = $1 AND account_id = <cuenta de la sesión>` → si no aparece, `P0404`, sin distinguir "no existe" de "es de otro".

**ACLs.** `REVOKE ALL FROM PUBLIC, anon` + `GRANT EXECUTE TO authenticated` sobre las tres, patrón uniforme. **No se crea ningún helper interno** con prefijo `_`/`c2x_`/`c3x_`, así que el chequeo (4) del gate de ACLs no se ve afectado y no hace falta tocar su allowlist. Tampoco se lee ni escribe `public.events`, así que el chequeo (5) queda fuera.

**Alternativas descartadas.**
- *Mantener el `INSERT` plano y postear los libros con llamadas separadas desde Python*: viola DEC-24 y no es atómico — un fallo entre el `INSERT` y el movimiento de caja deja el gasto sin su egreso, o peor, al revés.
- *Una sola RPC "upsert" para alta y edición*: mezcla dos conjuntos de guards muy distintos (la edición tiene inmutabilidad, el alta no) en un cuerpo que nadie va a poder auditar.

---

### D5 — La cuenta bancaria se exige **en el caller de gasto**, condicionada a que la organización tenga bancos

**El problema.** `_pay_resolve_bank_account` resuelve override → default del método → `NULL`, y con `NULL` el helper **retorna sin error**. Con **0 de 37** catálogos con `bank_account_id` configurado, el pedido literal del PO ("que estos movimientos concilien banco") fallaría en silencio para el 100% de los tenants.

**Decisión.** Un guard **en `rpc_create_expense`**, antes de llamar al helper:

```
si kind ∈ ('transfer','card','check','wallet')
   y la cuenta bancaria no resuelve (ni override ni default)
   y la organización tiene ≥ 1 bank_account activa
→ P0412 bank_account_required_for_expense
```

Si la organización **no tiene ninguna** cuenta bancaria activa (33 de 37 hoy), el gasto se guarda como etiqueta sin efecto bancario y la UI lo dice ("no tenés cuentas bancarias cargadas: este gasto no va a aparecer en la conciliación"). Del lado UI, `BankAccountDestinationSelect` se monta con la misma condición que en venta y compra (`isBankPaymentKind` + hay cuentas activas) pero en gastos es **obligatorio**, no opcional.

**Por qué el guard va en el caller y no en el helper.** La spec `bank-movement` vigente tiene un escenario explícito — *"Sin cuenta resuelta la venta sigue funcionando igual que antes"* — y el helper es punto de paso de venta, compra y POS. Endurecerlo ahí cambiaría el comportamiento de tres caminos probados para resolver un problema de uno. El endurecimiento asimétrico es deliberado y está justificado: el gasto **nace** con este contrato, las ventas no.

**Por qué condicionado a que existan bancos.** Un guard incondicional dejaría a 33 de 37 tenants sin poder registrar un gasto por transferencia hasta que carguen una cuenta bancaria — un bloqueo de registro por un problema de configuración, el mismo error que D1 evita en caja.

**Alternativas descartadas.**
- *Sembrar `bank_account_id` por defecto en las 37 cuentas*: no se puede adivinar qué cuenta corresponde a qué método, y 33 cuentas no tienen ninguna. Queda como OQ-2 (tarea de configuración del PO, no de código).
- *Cambiar el `RETURN NULL` del helper a error*: rompe las ventas y compras existentes.
- *Dejarlo como no-op silencioso*: es literalmente no cumplir el pedido.

---

### D6 — El gasto persiste `branch_id`

**Decisión.** El alta escribe `branch_id`, resuelto como `COALESCE(p_branch_id, c26_default_branch(cuenta))` — el mismo `COALESCE` que usa la venta. La edición lo reimputa por contrato tri-estado. La columna queda **nullable** (los 175 históricos no se backfillean, D7).

**Por qué es inevitable.** El guard de sucursal del opt-in de caja compara la sucursal de la sesión contra la **sucursal efectiva de la operación**. Sin `branch_id` persistido, ese guard queda hueco o se apoya en un default fantasma que nadie ve. Además lo exige **RN-93** ("Toda venta, compra, gasto y movimiento de caja lleva `branch_id`"), que para gastos estaba incumplida al 100%.

**Beneficio colateral, no objetivo:** `rpc_branch_report` empieza a ver gastos.

---

### D7 — Los 175 gastos históricos quedan **sin imputar** (opt-out, sin backfill)

**Decisión.** `payment_method_id` nullable; los 175 gastos existentes quedan en `NULL` y se muestran como "Sin imputar" (constante `UNASSIGNED_PAYMENT_METHOD_LABEL`, que ya existe). Lo mismo con `branch_id`.

**Por qué no hay backfill honesto.** Para imputar retroactivamente a caja haría falta una sesión abierta (`c28_register_cash_movement` la exige) y las sesiones de esos días están cerradas y arqueadas. Para imputar a banco haría falta saber de qué cuenta salió cada peso, dato que no existe en ninguna parte. Backfillear la **etiqueta** sin el libro (por ejemplo, marcar todo como "Efectivo") sería **inventar un dato** que después nadie puede distinguir de uno real, y contaminaría el reporte por forma de pago con una certeza falsa.

**Qué hay que decirle al PO antes de empezar, no después:** la mitad de sus gastos de 2026 va a quedar fuera del reporte por forma de pago y fuera de la conciliación, para siempre. Es el precio de no inventar datos. Es el mismo trato que recibieron `cost_center_id` y `payment_method_id` en ventas cuando se introdujeron.

---

### D8 — El borrado compensa las dos patas, copiando el patrón de `rpc_delete_sale_operation`

**Decisión.** `rpc_delete_expense` ejecuta, en la misma transacción y antes del `DELETE`:

1. **Caja**: agrupa `cash_movements` con `reference_id = <id del gasto> AND movement_type = 'expense'`; resuelve la **sesión abierta actual** del mismo `cashbox` (`ORDER BY opened_at DESC LIMIT 1`); si no hay ninguna → `P0426 no_open_session_for_reversal` con el mensaje "abrí la caja para poder borrar este gasto"; si hay → `c28_register_cash_movement(sesión_abierta, +importe, 'expense_reversal', <id del gasto>)`. **Nunca toca la sesión original** (append-only).
2. **Banco**: loop sobre `bank_movements` con `source_doc_type = 'expense' AND source_doc_ref = <id del gasto>`, espejo invertido (`transfer_out`→`transfer_in`, `card_settlement` con signo opuesto) vía `_register_bank_movement(..., -amount, ..., CURRENT_DATE, sucursal, 'Reversión por borrado de gasto')`.
3. `DELETE FROM expenses`.

No hay pata de cuenta corriente (no hay tercero, D3) ni de stock (un gasto no mueve stock) ni de evento (D10).

**El `P0426` es una restricción nueva y visible que el PO tiene que aceptar**: no se puede borrar un gasto en efectivo con la caja cerrada. Es el comportamiento correcto —la plata volvió al cajón, y el cajón está cerrado— y es **idéntico** al que ya rige para borrar una venta en efectivo. Uniformidad, no invención.

**Alternativa descartada.** *Borrar sin compensar (estado actual)*: es el bug que motivó `delete-guard-ledgers`, con 204 operaciones delete-inseguras corregidas por backfill.

---

### D9 — `expense_reversal` entra al vocabulario de caja; no se recicla `adjustment` ni se invierte el signo de `expense`

**Decisión.** Se amplía el `CHECK` de `cash_movements.movement_type` con `expense_reversal`, se suma al enum `MovementType` de `backend/schemas/cash.py` y a los **tipos de ingreso** (la reversión de un egreso entra plata), y se agrega su entrada en `CASH_MOVEMENT_META` del frontend (familia "Ingresos").

**Por qué un tipo propio.** `sale_reversal` ya existe con exactamente esta semántica y este nombre: **es el patrón a copiar, no una invención**. El vocabulario de caja distingue el contra-movimiento automático del ajuste manual, y esa distinción es lo que hace legibles los reportes de caja.

**Alternativas descartadas.**
- *Usar `adjustment`*: el `CHECK cash_movements_adjustment_needs_reason` exige `description` no vacío, así que habría que fabricar un motivo; y mezclaría compensaciones automáticas con correcciones manuales en el mismo cubo de reporting.
- *Postear un `expense` con signo positivo*: contradice el validador de signo de `backend/schemas/cash.py` (que exige `expense` negativo). Como el validador sólo cubre el camino API y no la RPC, el resultado sería una **inconsistencia silenciosa entre las dos puertas** — precisamente el bug que el fix #442 cerró.

---

### D10 — El asiento contable queda **fuera de alcance**, declarado

**Decisión.** El change **no** emite eventos ni postea asientos. `_journal_post_from_event` filtra con una whitelist literal de 9 `event_type` y hace `RETURN` (no-op) para todo lo demás; ninguno es de gasto, y `public.events` no tiene ningún tipo de gasto entre sus 13 tipos con datos.

**Por qué.** (i) `CHANGES.md` ya lo tiene diferido a V2.6; (ii) incluirlo obligaría a agregar un `event_type`, una rama al consumer y un mapeo de cuentas contables de gasto por categoría — un change entero; (iii) insertar en `public.events` desde la RPC de gasto activaría el chequeo (5) del gate de ACLs (lista curada de funciones que leen o actualizan el outbox), agregando superficie de seguridad a un change que no la necesita.

**Lo que este change sí deja listo para V2.6:** la forma de pago imputada, que es el dato que le falta al asiento para elegir la contrapartida. La rama futura sería el espejo de `SaleConfirmed` (crédito a `1100 Caja` o `1110 Banco` según el `kind`, débito a la cuenta de gasto).

**Lo que sigue funcionando gratis:** el trigger `trg_analytics_operation_created` vive **en la tabla**, no en el camino de código, así que la RPC nueva lo sigue disparando sin hacer nada.

---

### D11 — La edición de un gasto con dinero posteado se **bloquea** (`P0423`), no se compensa

**Decisión.** `rpc_update_expense` corre dos `EXISTS` antes de cualquier cosa, con los mismos predicados y el mismo ERRCODE que la venta y la compra:

- `cash_movements` con `reference_id = <id del gasto>` → `P0423 expense_has_cash_movement_immutable`
- `bank_movements` con `source_doc_type = 'expense' AND source_doc_ref = <id del gasto>` → `P0423 expense_has_bank_movement_immutable`

Con su **espejo de lectura obligatorio**: `ExpenseOut.is_payment_locked`, derivado en el repositorio con el mismo predicado, para que el listado deshabilite "Editar" con el motivo visible **antes** de llegar al 409. `P0423` ya está mapeado a HTTP 409 en `backend/core/errors.py`: no hay plomería nueva.

**Por qué bloquear y no compensar, teniendo el proyecto los dos precedentes.** El patrón de contra-asiento de `asiento-venta-formulario` aplica al **journal**, que es un libro derivado, asíncrono y de nuestra propiedad exclusiva: reescribirlo no tiene consecuencia externa. Caja y banco son distintos: la caja es un **conteo físico** con arqueo firmado, y el banco tiene un movimiento que puede estar ya **conciliado contra un extracto real** (y cuya reversa toparía con el `P0424` de período cerrado). Compensar automáticamente esos dos libros por un cambio de monto convierte cada corrección en dos movimientos más de ruido en el arqueo y en la conciliación.

**Por qué la fricción es acotada.** El bloqueo alcanza **solamente** a los gastos que movieron plata. Un gasto sin forma de pago, o con una forma de pago `other`/sin cuenta bancaria resuelta, **sigue plenamente editable** — o sea, los 175 históricos y la mayoría de los nuevos. Y el camino de corrección (borrar y recargar) queda seguro justamente por D8.

**Alternativa descartada.** *Edición con contra-movimiento automático*: además de lo anterior, obligaría a resolver "¿a qué sesión de caja va el contra-movimiento si la original cerró?" en el camino de edición, que es precisamente la complejidad que `delete-guard-ledgers` concentró —y acotó— en el borrado.

---

### D12 — La edición **preserva** el contexto, con contrato tri-estado, y de paso cierra dos bugs pre-existentes

**Decisión.** `ExpenseUpdate` adopta el contrato tri-estado ya vigente en ventas y compras: **clave ausente** conserva el valor, **`null` explícito** desimputa, **uuid** reimputa. Se implementa con `model_fields_set` (Pydantic v2) y la RPC lo recibe con el mismo par de parámetros (`p_<campo>`, `p_set_<campo>`) que ya usa `rpc_atomic_update_purchase_operation`.

Aplica a `payment_method_id`, `branch_id` y `cost_center_id`.

**Los dos bugs que se cierran en el camino** (`use-expenses-query.ts`):
- el alta manda `branchId` al `mutateAsync` pero el `mutationFn` **no lo pone en el payload** → 0 de 175 gastos con sucursal;
- la edición manda `costCenterId` pero el `mutationFn` del `PUT` **tampoco lo incluye** → el centro de costo se borra en cada edición, en silencio.

Además `mapExpense()` no mapea `branch_id`, así que el selector de sucursal arranca vacío al editar.

**Por qué se arreglan acá y no en un change aparte.** El campo nuevo caería en la misma trampa si se copia el molde. Y un `payment_method_id` que se borra solo al editar un gasto **que ya posteó en caja** no es cosmético: deja el movimiento de caja sin la etiqueta que lo explica. Es el mismo patrón que `edicion-preserva-contexto` (#423/#424) ya corrigió para ventas y compras; acá seguía vivo.

---

### D13 — El importador CSV **no** imputa forma de pago

**Decisión.** El template sigue teniendo 4 columnas (`Descripción;Categoría;Monto;Fecha`). Las filas importadas entran con `payment_method_id = NULL` → sin efecto en libros. El texto de ayuda del paso 1 lo dice explícitamente ("los gastos importados quedan sin forma de pago; imputalos después desde el listado si querés que impacten caja o banco").

**Por qué.** El importador llama `addExpense` **una vez por fila**, sin ninguna transacción que abarque el loop. Con impacto en libros, importar 200 filas generaría 200 movimientos y, ante un fallo a mitad de camino, dejaría N gastos con movimiento y M sin — un descuadre imposible de reconstruir. Es el mismo criterio con que el importador hoy no imputa centro de costo.

**Alternativa descartada.** *Columna nueva en el template*: exigiría además resolver la sesión de caja y la cuenta bancaria por fila, y convertiría un importador en un motor de asientos.

---

### D14 — Los gastos entran al reporte `/reportes/formas-pago`

**Decisión.** `rpc_payment_method_report` suma una columna de gastos (junto a las de ventas y compras) y la pantalla suma su columna. La reescritura de la RPC parte del `pg_get_functiondef` **vivo**, hasheado antes de escribir SQL.

**Por qué está en alcance y no es scope creep.** El reporte se llama "formas de pago" y hoy cubre ventas y compras; si los gastos imputan forma de pago y no aparecen, el reporte **miente por omisión** sobre un tercio del dinero. Dejarlo sin decidir reproduciría exactamente la clase de superficie a medias que originó la regla PO de superficie frontend obligatoria (el `CostCenterManager` construido y nunca montado). Es una columna en un read-model, un campo en el tipo y una columna en una tabla.

Si aparece presión de alcance, **ésta es la pieza recortable** del change (OQ-5) — es la única cuya ausencia no deja el sistema inconsistente, sólo incompleto.

---

### D15 — Cobertura de tests: el módulo arranca del andamio

**Decisión.** El módulo Gastos **no tiene hoy ni un test** (ni componente, ni hook, ni a11y; lo único cubierto es `parseAndValidate` del importador, y desde un test de timezone). No hay "dónde agregar un caso": hay que construir la base.

Los moldes existen y se copian, no se inventan: `__tests__/components/PaymentMethodSelect.test.tsx`, `__tests__/components/sale-form-payment-effects.test.tsx`, `__tests__/hooks/use-sales-cash-session.test.ts`, `__tests__/hooks/use-sales-payment-method.test.ts`, `__tests__/c2-bank-payment-routing.test.ts`, y `__tests__/a11y/proveedores.a11y.test.tsx`.

---

### D16 — Canonización: `PaymentMethodBadge` y `useCashOptin`

**Decisión.** Dos extracciones, ambas con la Regla de Tres **ya cumplida**, no anticipada:

1. **`PaymentMethodBadge`** — el badge está duplicado literal en 4 lugares (`sale-operations-list.tsx` ×2, `purchase-operations-list.tsx` ×2). Con gastos serían 6. Se canoniza el componente en `components/payment-methods/` y se sube `KIND_LABELS` (las 7 etiquetas en castellano) desde el interior privado de `PaymentMethodManager` a `lib/payment-method-meta.ts`, espejo de `lib/ledger/cash-movement-meta.ts` y `lib/bank-account-kind.ts`. El literal "Sin especificar" sale de la constante que ya existe en `lib/payment-method-report.ts`.
2. **`useCashOptin({ kind, branchId, date })`** — el bloque de opt-in de caja (unas 20 líneas: `useBranches` + `useCashboxes` + `useCurrentSession` + comparación con el día local) está hoy inline en `sale-form.tsx`. El gasto es el segundo consumidor del bloque **exacto**. Se extrae a un hook en vez de copiarlo.

**Por qué esto no es abstraer prematuramente.** No se crea una abstracción para un uso hipotético: se retira duplicación ya existente y medida. Es la regla PO de reutilización aplicada en su forma correcta ("lo nuevo reusable nace en la capa canónica").

**Riesgo asumido y acotado:** extraer `useCashOptin` toca el formulario de venta, que está en producción. Va con su propio RED sobre el comportamiento vigente del form de venta antes de mover una línea, y con checkpoint 🛑.

---

### D17 — Estética y accesibilidad: tokens semánticos, nunca `categoryColors`

**Decisión.** El badge de forma de pago y todo elemento nuevo usan **tonos semánticos** (`success`/`destructive`/`warning`/`muted`/`primary`) y variantes de `Badge` vía cva. Está explícitamente **prohibido** copiar el estilo de `categoryColors` de `gastos/page.tsx`, que usa literales de Tailwind (`bg-blue-500/20 text-blue-400 …`, `text-red-400`) — el patrón que `tokens-contraste-aa` (#406-#408) desterró y que el gate `token-contrast-aa.test.ts` rechaza en CI.

`categoryColors` **no se refactoriza** en este change (es deuda ajena y tocarla ampliaría la superficie sin relación con el pedido); queda anotada como candidato.

Verificación obligatoria antes del merge: **desktop y mobile** × **tema claro y oscuro**, más un test a11y del formulario con el molde de `proveedores.a11y.test.tsx`.

---

## Risks / Trade-offs

| Riesgo | Mitigación |
|---|---|
| **La cuenta bancaria no resuelve y el gasto por transferencia no llega nunca a la conciliación** (0/37 catálogos con default). Es el riesgo que hace fallar el pedido literal del PO. | D5: selector obligatorio en el form + `P0412` en la RPC cuando la organización tiene bancos. Escenario de spec explícito para el caso "organización sin bancos". |
| **La renumeración de la migración muerde otra vez** (ya pasó tres veces: `cuenta-corriente-party-guard` se renumeró 3×; el número previsto por `tenancy-guard-caja-outbox` se lo llevó un hotfix). | Task explícita de re-verificar `MAX(version)` vivo **inmediatamente antes** de escribir el archivo, no al principio del apply. |
| **Reescribir `rpc_payment_method_report` sobre una definición desactualizada del repo.** El `pg_get_functiondef` vivo ya divergió una vez de su archivo de migración (G3 de `20261003000001`, reescrito in-place). | Checkpoint 🛑 de gate de integridad: hashear el cuerpo vivo y guardarlo en `baseline/` antes de escribir una línea de SQL. |
| **Extraer `useCashOptin` rompe el formulario de venta**, que está en producción y mueve caja. | RED sobre el comportamiento vigente del form de venta **antes** de mover código; checkpoint 🛑; la extracción es la última task del grupo de frontend, no la primera. |
| **`expenses.date` es `timestamptz`**: la comparación con el día local sin castear rechaza gastos legítimos de hoy cargados a cualquier hora ≠ 00:00. | Cast explícito en la RPC + test dedicado con un gasto de hoy a las 15:00 (RED que falla sin el cast). |
| **El `P0426` al borrar un gasto en efectivo con la caja cerrada** es una restricción nueva y visible. | Es idéntica a la que ya rige para borrar una venta en efectivo (uniformidad). El diálogo de borrado la anticipa: el control aparece deshabilitado con el motivo antes de intentarlo. OQ-8 para el sign-off del PO. |
| **Los 175 gastos históricos quedan fuera del reporte y de la conciliación para siempre.** | Es la única salida sin inventar datos (D7). Hay que decírselo al PO **antes** de empezar. El listado y el reporte los muestran explícitamente como "Sin imputar", no los esconden. |
| **La UI queda stale**: el listado de gastos es query Supabase directa (no invalida por query key) y los paneles de /caja y /banco no usan TanStack Query por diseño. | Las mutaciones invalidan `expenses`, `cashSessions`, `cashMovements`, `bankAccounts`, `bankReconciliation` y el reporte, llaman `pq.refetch()` en /gastos y **bumpean el `refreshToken`** de `LedgerMovementsPanel`. Test dedicado del hook que asserta el set completo de invalidaciones (el precedente de `customerAccounts` en ventas ya se pagó una vez). |
| **El importador masivo genera cientos de movimientos** o falla a mitad sin transacción envolvente. | D13: el importador no imputa forma de pago. |
| **La columna nueva no llega al listado**: `/gastos` lee por PostgREST directo, sin joins ni backend. | `payment_method_id` debe estar en la tabla y visible por la policy de `SELECT` (lo está: la policy es por `account_id`); el **nombre** se resuelve en cliente con un `Map` desde `usePaymentMethods(true)` — `includeInactive` para que un método dado de baja siga mostrando su nombre histórico. |
| **Regresión de contraste en CI** si el badge copia `categoryColors`. | D17 + el gate `token-contrast-aa.test.ts` ya en CI. |
| **Dominio: dinero en dos libros.** | Governance MEDIUM con checkpoints 🛑 en los tramos de caja y banco; gate SQL propio; auditoría de que ningún gasto histórico quedó con movimientos huérfanos. |

## Migration Plan

1. **Baseline y gates** — medir suite backend y frontend; hashear el `pg_get_functiondef` vivo de `rpc_payment_method_report`, `c28_register_cash_movement` y `_pay_register_operation_bank_movement` a `baseline/`; re-verificar `MAX(version)`.
2. **Migración `20261015000001_gastos_forma_pago.sql`** — idempotente, sin BOM, ERRCODEs de 5 chars, sin `P0001`. Orden: columna + índice → `CHECK` de `cash_movements` → las tres RPCs + ACLs → `rpc_payment_method_report`.
3. **Backend** — schemas, repositorio, service, tests.
4. **Frontend** — canonización, hook, formulario, listado, reporte, importador, tests, a11y, responsive y temas.
5. **Gate SQL propio** + wiring en `KPI_Validation.yml`.
6. **Verificación** — suites completas, `tsc` sin errores nuevos, los 30 gates verdes.
7. **Merge → CI/CD aplica la migración automáticamente.** Verificación post-merge en prod (sólo `SELECT`): `MAX(version)`, ACLs de las tres RPCs nuevas, `CHECK` vivo de `cash_movements`, y auditoría de que no hay movimientos con `source_doc_type='expense'` o `movement_type='expense'` huérfanos.

**Rollback.** El change es aditivo en el esquema (columna nullable + un valor más en un `CHECK`): no hay pérdida de datos al revertir el código. Si hubiera que desactivar el comportamiento sin revertir la migración, alcanza con que el frontend deje de enviar `payment_method_id`/`cash_session_id`/`bank_account_id` — la RPC vuelve al camino no-op. Las RPCs nuevas conviven con el esquema viejo porque todas las columnas que agregan son nullables.

## Open Questions

> Precedente del proyecto: si el PO no responde, el apply avanza por la **opción recomendada** de cada OQ y lo deja registrado. Ninguna es bloqueante.

**OQ-1 — ¿El opt-in de caja arranca pre-marcado?**
Recomendación: **sí, pre-marcado cuando las tres condiciones se cumplen** (D1). Se aparta a propósito del formulario de venta, que arranca desmarcado por compatibilidad con 223 operaciones históricas; el gasto no tiene esa deuda (0/175) y el pedido del PO es que concilien. Alternativa: desmarcado, estricta simetría con ventas.

**OQ-2 — ¿Cómo se resuelve la cuenta bancaria: selector obligatorio en el gasto, o configurar antes los defaults del catálogo?**
Recomendación: **selector obligatorio en el formulario + `P0412` en la RPC** (D5), porque no depende de una tarea de configuración previa. En paralelo, sugerir al PO que configure el `bank_account_id` default de cada forma de pago bancaria en Configuración → Formas de pago: es una pantalla que **ya existe** y que volvería el selector innecesario en el caso normal.

**OQ-3 — ¿`kind = 'credit'` se bloquea o se acepta como etiqueta muda?**
Recomendación: **bloqueado en las dos puntas**, con el texto que redirige a la compra a proveedor (D3).

**OQ-4 — ¿El gasto con dinero posteado es inmutable, o se edita con contra-movimiento?**
Recomendación: **inmutable (`P0423`)**, criterio uniforme del proyecto (D11). El PO debe saber que corregir el monto de un gasto ya imputado a caja pasa a ser "borrar y recargar", y que borrar en efectivo exige caja abierta.

**OQ-5 — ¿Los gastos entran al reporte `/reportes/formas-pago`?**
Recomendación: **sí** (D14). Es la única pieza recortable del change si aparece presión de alcance.

**OQ-6 — ¿Los 175 gastos históricos se dejan sin imputar?**
Recomendación: **sí, sin backfill** (D7). Backfillear la etiqueta sin el libro sería inventar un dato indistinguible de uno real.

**OQ-7 — ¿El importador CSV acepta forma de pago?**
Recomendación: **no** (D13), con la aclaración en la ayuda del paso 1.

**OQ-8 — ¿Se acepta que borrar un gasto en efectivo exija una sesión de caja abierta (`P0426`)?**
Recomendación: **sí**, por uniformidad con el borrado de una venta en efectivo (D8). Es la consecuencia directa de que el ledger de caja sea append-only por sesión.

**OQ-9 — ¿Alguna categoría de gasto debería sugerir una forma de pago por defecto** (por ejemplo, "Alquiler" → Transferencia)?
Recomendación: **no en este change**. Es una comodidad de UI que sólo tiene sentido con datos de uso, y hoy hay cero. Candidato posterior.
