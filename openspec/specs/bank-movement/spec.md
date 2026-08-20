# bank-movement Specification

## Purpose
Ledger append-only de movimientos bancarios (`BankMovement`): helper intra-tx reutilizable, RPC de carga manual, taxonomía de tipos, RLS por `account_id` denormalizado. Entregado en `bank-account-ledger` (V2.5 C1, BankReconciliation, 2026-06-27). Extendido en `bank-payment-routing` (V2.5 C2, 2026-07-02): los pagos por método bancario escriben `bank_movement` automáticamente y el journal contable postea la contrapartida en `1110 Banco` de forma asíncrona. Extendido en `bank-reconciliation` (V2.5 C3, 2026-07-02): la carga manual acepta además `fee`/`tax_debit`/`interest` ("solo anotar" V1) y los movimientos exponen estado de conciliación (`reconciliation_status`/`reconciled_at`) mantenido por las RPCs de match.
## Requirements
### Requirement: Ledger append-only de movimientos bancarios
El sistema SHALL registrar cada movimiento bancario como una fila append-only en `bank_movements` (`id`, `bank_account_id` FK `bank_accounts`, `account_id` denormalizado FK `accounts`, `amount NUMERIC(14,2)` con signo, `balance_after NUMERIC(14,2)`, `movement_type`, `value_date DATE`, `branch_id UUID NULL`, `source_doc_type`, `source_doc_ref UUID`, `description`, `created_at`), sin UPDATE ni DELETE sobre filas existentes. Cada fila SHALL llevar `balance_after = saldo previo de la cuenta + amount` (patrón ledger, igual que `cash_movements` de C-28). El `amount` SHALL ser signado: positivo = ingreso, negativo = egreso. El aislamiento por cuenta (RLS) SHALL resolverse por `account_id` **denormalizado** (`account_id IN (SELECT current_account_ids())`), sin subquery por fila a `bank_accounts`, para sostener el volumen del ledger.

#### Scenario: Registrar un movimiento calcula balance_after
- **WHEN** sobre una cuenta bancaria con `opening_balance = 10000` y sin movimientos se registra `amount = +5000`, `movement_type = 'transfer_in'`
- **THEN** se inserta una fila con `balance_after = 15000` y `account_id` copiado de la cuenta

#### Scenario: Signo del amount controla el sentido
- **WHEN** sobre esa cuenta (`balance_after = 15000`) se registra `amount = -2000`, `movement_type = 'transfer_out'`
- **THEN** se inserta una fila con `balance_after = 13000`

#### Scenario: Movimientos son append-only
- **WHEN** se intenta modificar o borrar un `bank_movement` ya insertado vía la API
- **THEN** la operación no está permitida (sin endpoint ni policy de UPDATE/DELETE; escritura solo vía helper SECURITY DEFINER)

#### Scenario: Un usuario de otra organización no ve los movimientos
- **WHEN** un miembro de la organización B consulta `bank_movements` y existen movimientos de la organización A
- **THEN** la RLS por `account_id` denormalizado no devuelve las filas de A

### Requirement: Taxonomía de tipos de movimiento bancario
El sistema SHALL fijar mediante CHECK el conjunto completo de `movement_type` desde ya: `{'transfer_in', 'transfer_out', 'card_settlement', 'fee', 'tax_debit', 'interest', 'manual_adjustment'}`. El `value_date` SHALL representar la fecha valor bancaria, distinta de `created_at`. A partir de este change (C3 `bank-reconciliation`), los tipos `fee`, `tax_debit` (impuesto al cheque, Ley 25.413) e `interest` SHALL ser emitibles por la carga manual (habilitan el "solo anotar" de la conciliación V1). El tipo `card_settlement` SHALL permanecer RESERVADO a los escritores automáticos (RPCs de pago de C2) y NO ser emitible manualmente.

#### Scenario: El CHECK acepta el enum completo
- **WHEN** se inspecciona el `CHECK` de `bank_movements.movement_type`
- **THEN** incluye los 7 tipos `transfer_in`, `transfer_out`, `card_settlement`, `fee`, `tax_debit`, `interest`, `manual_adjustment`

#### Scenario: Un movement_type fuera del enum es rechazado por el CHECK
- **WHEN** se intenta insertar un `bank_movement` con `movement_type = 'foo'`
- **THEN** la inserción falla por violación del CHECK del enum

### Requirement: RPC de carga manual de movimiento bancario
El sistema SHALL exponer `rpc_register_bank_movement` (SECURITY DEFINER, GRANT a `authenticated`) para registrar movimientos bancarios **manualmente**. Esta RPC SHALL aceptar el subconjunto manual de `movement_type`: `{'transfer_in', 'transfer_out', 'manual_adjustment', 'fee', 'tax_debit', 'interest'}` — los tres últimos habilitados por C3 `bank-reconciliation` para anotar cargos del extracto sin contraparte en el sistema — rechazando el tipo reservado a escritores automáticos (`card_settlement`) con `P0410`. La RPC SHALL estar guardada por `is_account_writer` (`P0401` si no), SHALL rechazar movimientos sobre una cuenta inexistente o inactiva (`P0412`), y SHALL ser idempotente vía `idempotency_key` (slot en `operation_idempotency`, replay devuelve el resultado original sin re-insertar).

#### Scenario: Registrar una transferencia manual
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `amount = +5000`, `movement_type = 'transfer_in'` y una `idempotency_key` nueva sobre una cuenta activa
- **THEN** se registra el movimiento (vía el helper) con su `balance_after` y la RPC devuelve `replayed = false`

#### Scenario: Anotar una comisión bancaria manualmente
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `amount = -350`, `movement_type = 'fee'` y una `idempotency_key` nueva sobre una cuenta activa
- **THEN** se registra el movimiento con `balance_after` calculado (el tipo dejó de estar reservado)

#### Scenario: La RPC manual rechaza card_settlement
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `movement_type = 'card_settlement'`
- **THEN** la RPC retorna `P0410` y no inserta ninguna fila (el tipo queda reservado a los escritores automáticos de C2)

#### Scenario: Un usuario sin permiso de escritura no puede registrar
- **WHEN** un usuario de solo lectura llama a `rpc_register_bank_movement`
- **THEN** la RPC retorna `P0401` y no inserta ninguna fila

#### Scenario: Movimiento sobre cuenta inactiva es rechazado
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` sobre una cuenta con `is_active = false`
- **THEN** la RPC retorna `P0412` y no inserta ninguna fila

#### Scenario: Doble submit con la misma idempotency_key no duplica
- **WHEN** se llama dos veces a `rpc_register_bank_movement` con la misma `idempotency_key` y los mismos datos
- **THEN** la segunda llamada devuelve el resultado original con `replayed = true` y existe una sola fila en `bank_movements`

### Requirement: Helper transaccional reutilizable (contrato C1→C2)
El sistema SHALL exponer un helper SQL `_register_bank_movement(p_bank_account_id, p_amount, p_type, ...)` invocable desde **dentro de otra transacción** (p.ej. las futuras RPCs de pago de C2), que inserta el `bank_movement` con `balance_after` calculado (bajo `FOR UPDATE` sobre la cabecera `bank_accounts`) y `account_id` denormalizado, sin abrir transacción propia. El helper SHALL ser SECURITY DEFINER con `SET search_path`, y su EXECUTE SHALL estar REVOCADO de `PUBLIC`/`anon`/`authenticated` (callable solo desde RPCs SECURITY DEFINER de este módulo o de C2). Este es el análogo exacto de `c28_register_cash_movement` que C-29 reutilizó en el hot path de venta.

#### Scenario: El helper calcula balance_after a lo largo de una secuencia de movimientos
- **WHEN** sobre una cuenta con `opening_balance = 1000` el helper registra en orden `+500`, `-200`, `+300`
- **THEN** los `balance_after` resultantes son `1500`, `1300`, `1600` respectivamente

#### Scenario: El helper no es callable por authenticated directamente
- **WHEN** el rol `authenticated` intenta `SELECT _register_bank_movement(...)` directamente
- **THEN** la llamada es rechazada por falta de privilegio (EXECUTE revocado)

#### Scenario: Atomicidad — si la transacción del llamador falla, el movimiento se revierte
- **WHEN** una transacción registra un `bank_movement` vía el helper y luego falla y hace ROLLBACK
- **THEN** no queda ninguna fila en `bank_movements` para esa operación (el helper no abre su propia transacción)

### Requirement: C1 no postea al journal contable
El sistema, a partir de este change (C2 `bank-payment-routing`), SHALL postear al journal de partida doble la contrapartida bancaria de los eventos de pago/venta cuyo método sea bancario, usando la cuenta contable `1110 Banco` (antes reservada y vacía) — reemplazando el invariante original de C1 según el cual `1110` permanecía reservada y vacía. El posteo a `1110` SHALL realizarse **asincrónicamente** vía el Consumer 3 del outbox (`_journal_post_from_event`), leyendo el `payment_method` del payload del evento, y NUNCA de forma intra-tx desde la RPC de pago. Se mantiene la separación de dos ledgers: `bank_movements` es el ledger OPERACIONAL (fuente de verdad del saldo bancario y base de la conciliación C3) escrito intra-tx por la RPC; `1110 Banco` es el espejo CONTABLE escrito async por el consumer. La conciliación futura (C3) SHALL seguir operando sobre `bank_movements`, NUNCA sobre el journal.

#### Scenario: Registrar un movimiento bancario manual no crea asiento contable
- **WHEN** se registra un `bank_movement` vía `rpc_register_bank_movement` (carga manual, no ligada a un pago)
- **THEN** no se inserta ninguna fila en `journal_entries`/`journal_lines` con `account_code = '1110'` (la carga manual no emite evento de outbox)

#### Scenario: Un pago por transferencia postea a 1110 Banco vía el consumer async
- **WHEN** se procesa (Consumer 3 del outbox) un evento `PaymentReceived`/`PaymentMade`/`SaleConfirmed` con `payment_method` bancario
- **THEN** el asiento resultante usa `1110 Banco` en la pata bancaria, y ese posteo lo hace `_journal_post_from_event` (no la RPC de pago)

#### Scenario: El movimiento operacional y el posteo contable quedan sincronizados por el outbox
- **WHEN** una RPC de pago por método bancario inserta el `bank_movement` (intra-tx) y emite el evento con `payment_method` en el payload
- **THEN** el `bank_movement` existe en el commit del pago y el asiento en `1110` aparece luego de forma idempotente al procesar el evento — sin que la conciliación (C3) dependa del journal

### Requirement: Los pagos por método bancario registran un bank_movement automático
El sistema SHALL, dentro de la transacción de la RPC de pago correspondiente, registrar un `bank_movement` vía el helper `_register_bank_movement` cuando el método de pago sea bancario (transfer/card/check). Un cobro (`rpc_register_payment_received`) por método bancario SHALL generar un `bank_movement` con `amount` positivo (ingreso), `movement_type = 'transfer_in'` (o `'card_settlement'` para tarjeta), `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro. Un pago (`rpc_register_payment_made`) por método bancario SHALL generar un `bank_movement` con `amount` negativo (egreso), `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` y `source_doc_ref` = id del pago. El movimiento SHALL escribirse en la cuenta bancaria indicada por la RPC (`p_bank_account_id`), sobre la que aplican las validaciones de C1 (existe, pertenece a la organización, `is_active`). Estos son los **primeros escritores automáticos (no manuales)** del ledger `bank_movements`, y SHALL usar el mismo helper `_register_bank_movement` que C1 dejó como contrato C1→C2 (análogo a cómo la venta usa `c28_register_cash_movement`).

#### Scenario: Un cobro por transferencia acredita el ledger bancario
- **WHEN** se ejecuta `rpc_register_payment_received` con `payment_method = 'transfer'`, monto 400 y una cuenta bancaria activa
- **THEN** existe un `bank_movement` con `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` y `balance_after` calculado por el helper, en el mismo commit que el cobro

#### Scenario: Un pago por transferencia debita el ledger bancario
- **WHEN** se ejecuta `rpc_register_payment_made` con `payment_method = 'transfer'`, monto 400 y una cuenta bancaria activa
- **THEN** existe un `bank_movement` con `amount = −400`, `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'`, en el mismo commit que el pago

#### Scenario: Un pago en efectivo no genera bank_movement
- **WHEN** se ejecuta una RPC de pago con `payment_method = 'cash'`
- **THEN** no se inserta ninguna fila en `bank_movements` (el efectivo va por el ledger de caja)

#### Scenario: El movimiento bancario del pago es atómico con el pago
- **WHEN** una RPC de pago por método bancario falla después de registrar el `bank_movement` (p.ej. por overpayment `P0409`)
- **THEN** ni el pago ni el `bank_movement` quedan persistidos (todo revierte en la misma transacción)

### Requirement: Estado de conciliación del movimiento bancario
El sistema SHALL exponer en `bank_movements` el estado de conciliación mediante columnas aditivas `reconciliation_status TEXT NOT NULL DEFAULT 'unreconciled' CHECK IN ('unreconciled','matched')` y `reconciled_at TIMESTAMPTZ NULL`. Estas columnas SHALL ser mantenidas EXCLUSIVAMENTE por las RPCs de conciliación (match/unmatch de C3) en la misma transacción del match — ningún otro escritor (helper `_register_bank_movement`, RPCs de pago, carga manual) las setea, y sigue sin existir UPDATE directo para `authenticated`. Este UPDATE controlado de columnas de estado NO viola el carácter append-only del ledger: los campos económicos (`amount`, `balance_after`, `movement_type`, `value_date`) permanecen inmutables.

#### Scenario: Un movimiento nuevo nace sin conciliar
- **WHEN** se registra un `bank_movement` (manual o automático)
- **THEN** la fila tiene `reconciliation_status = 'unreconciled'` y `reconciled_at IS NULL`

#### Scenario: Solo las RPCs de conciliación cambian el estado
- **WHEN** la RPC de match de una sesión abierta concilia el movimiento
- **THEN** `reconciliation_status = 'matched'` con `reconciled_at` seteado; y **WHEN** el rol `authenticated` intenta un UPDATE directo de esas columnas, **THEN** la operación es rechazada (sin policy de UPDATE)

#### Scenario: Los campos económicos siguen inmutables
- **WHEN** un movimiento pasa a `matched`
- **THEN** `amount`, `balance_after`, `movement_type` y `value_date` no cambian

### Requirement: Las operaciones de venta y compra por método bancario registran un bank_movement automático

El sistema SHALL registrar, dentro de la misma transacción que la operación, un `bank_movement` vía el helper `_register_bank_movement` cuando el `kind` derivado de la forma de pago imputada sea bancario (`transfer`, `card`, `check`, `wallet`) **y** se haya resuelto una cuenta bancaria destino. Esto SHALL aplicar a los tres caminos de alta de operación: el mostrador (`rpc_quick_sale` / `rpc_confirm_sales_order` → `_c29_confirm_order_core`), el formulario de venta (`rpc_create_sale_operation` / `_v2`) y el formulario de compra (`rpc_create_purchase_operation`), convirtiéndolos en los segundos escritores automáticos del ledger después de las RPCs de pago de C2. Una venta SHALL generar un movimiento de ingreso con `amount = +total`, `source_doc_type = 'sale'`; una compra SHALL generar uno de egreso con `amount = −total`, `source_doc_type = 'purchase'`. El `movement_type` SHALL derivarse del `kind` según el mapa `transfer|check|wallet → transfer_in` (venta) / `transfer_out` (compra) y `card → card_settlement`, extendiendo a `wallet` el criterio bancario que la capability `journal-entry` ya le aplica al rutearlo a `1110 Banco`. Los `kind` `cash`, `credit` y `other` NO SHALL generar movimiento bancario por ningún camino, de modo que una venta a cuenta corriente registre su movimiento bancario recién cuando se cobre (vía `rpc_register_payment_received`) y nunca dos veces. El `kind` SHALL derivarse en el servidor desde `payment_method_id`, nunca aceptarse como dato del cliente. La escritura SHALL concentrarse en un único helper compartido por los tres caminos, y NO SHALL emitir eventos de outbox ni escribir en el journal: el `bank_movement` es el ledger OPERATIVO y su espejo contable en `1110 Banco` lo sigue posteando de forma asíncrona `_journal_post_from_event`.

#### Scenario: Una venta del POS por transferencia acredita el ledger bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se cobra desde el POS una venta de 10.000 con esa forma de pago
- **THEN** existe, en el mismo commit que el descuento de stock, un `bank_movement` con `amount = +10000`, `movement_type = 'transfer_in'`, `source_doc_type = 'sale'` y `balance_after` calculado por el helper

#### Scenario: Una compra por transferencia debita el ledger bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se registra una compra de 4.000 imputada a esa forma de pago
- **THEN** existe un `bank_movement` con `amount = −4000`, `movement_type = 'transfer_out'` y `source_doc_type = 'purchase'`, en el mismo commit que la compra

#### Scenario: Una venta con tarjeta se asienta bruta

- **WHEN** se cobra una venta de 10.000 con una forma de pago de `kind = 'card'` con cuenta destino resuelta
- **THEN** el `bank_movement` registra `amount = +10000` (el bruto) con `movement_type = 'card_settlement'`, y la comisión no se descuenta automáticamente

#### Scenario: Una venta en efectivo o a cuenta corriente no toca el banco

- **WHEN** se cobra una venta con una forma de pago de `kind = 'cash'` o de `kind = 'credit'`
- **THEN** no se inserta ninguna fila en `bank_movements`

#### Scenario: La venta a cuenta corriente registra el movimiento recién al cobrarse

- **GIVEN** una venta registrada con `kind = 'credit'` que posteó su cargo en la cuenta corriente del cliente
- **WHEN** más tarde se registra el cobro con `rpc_register_payment_received` por método bancario
- **THEN** existe exactamente un `bank_movement` para ese ciclo, el del cobro, sin duplicación con la venta

#### Scenario: El movimiento es atómico con la operación

- **WHEN** el alta de la venta falla después de resolver la cuenta bancaria (por ejemplo por stock insuficiente)
- **THEN** no queda ninguna fila en `bank_movements` ni en `sales` (todo revierte en la misma transacción)

#### Scenario: El movimiento de la operación no genera asiento por sí mismo

- **WHEN** una venta por método bancario registra su `bank_movement`
- **THEN** la RPC no inserta filas en `journal_entries`/`journal_lines` ni emite eventos nuevos, y la contrapartida en `1110 Banco` sigue llegando de forma asíncrona por el consumer del outbox desde el evento `SaleConfirmed` ya existente

### Requirement: Resolución de la cuenta bancaria destino de una operación

El sistema SHALL resolver la cuenta bancaria destino de una operación en el siguiente orden: (1) el parámetro explícito de la operación (`p_bank_account_id`), si se informó; (2) el destino por defecto configurado en la forma de pago imputada (`payment_methods.bank_account_id`); (3) ninguna. Cuando no se resuelve ninguna cuenta, la operación SHALL completarse normalmente **sin** registrar movimiento bancario — la ausencia de configuración es un camino válido y silencioso, porque el ledger bancario es opcional y la mayoría de las organizaciones no lleva sus cuentas bancarias en el sistema. La cuenta resuelta SHALL validarse siempre: existir, pertenecer a la organización de la operación, estar activa (`is_active`) y no estar borrada (`deleted_at IS NULL`); si falla cualquiera de esas condiciones la operación SHALL rechazarse con `P0412` y no registrarse. Informar una cuenta bancaria explícita junto a un `kind` no bancario SHALL rechazarse con `P0400`, en vez de ignorarse en silencio.

#### Scenario: El default por método se aplica sin intervención

- **GIVEN** la forma de pago "Transferencia bancaria" con la cuenta "Galicia CC" configurada como destino
- **WHEN** se cobra una venta con esa forma de pago sin informar cuenta en la operación
- **THEN** el `bank_movement` se registra contra "Galicia CC"

#### Scenario: El override de la operación gana sobre el default

- **GIVEN** la misma forma de pago con default "Galicia CC"
- **WHEN** se cobra una venta con esa forma de pago informando explícitamente la cuenta "Santander CA"
- **THEN** el `bank_movement` se registra contra "Santander CA" y no contra el default

#### Scenario: Sin cuenta resuelta la venta sigue funcionando igual que antes

- **GIVEN** una forma de pago de `kind = 'transfer'` sin destino configurado y una operación que no informa cuenta
- **WHEN** se cobra la venta
- **THEN** la venta se confirma normalmente y no se inserta ninguna fila en `bank_movements`

#### Scenario: Cuenta bancaria de otra organización es rechazada

- **WHEN** una operación informa una cuenta bancaria que pertenece a otra organización
- **THEN** la RPC retorna `P0412` y no se registra ni la operación ni el movimiento

#### Scenario: Cuenta bancaria inactiva o borrada es rechazada

- **WHEN** la cuenta resuelta tiene `is_active = false` o `deleted_at` no nulo
- **THEN** la RPC retorna `P0412` y no se registra ni la operación ni el movimiento

#### Scenario: Cuenta bancaria informada sobre un kind no bancario es rechazada

- **WHEN** una operación con forma de pago de `kind = 'cash'` informa una cuenta bancaria explícita
- **THEN** la RPC retorna `P0400` y no se registra la operación

### Requirement: La fecha valor del movimiento de una operación respeta los períodos ya conciliados

El sistema SHALL usar como `value_date` del movimiento la fecha de la operación —el día local del tenant en el camino del mostrador (canon `business-day-timezone`) y la fecha informada en los formularios— y SHALL rechazar con `P0424` el registro de un movimiento cuya `value_date` caiga dentro del período (`period_from`..`period_to`) de una sesión de conciliación en estado `closed` de esa misma cuenta bancaria. El rechazo SHALL alcanzar a la operación completa, no sólo al movimiento, para no dejar una venta registrada cuyo efecto bancario se perdió en silencio, y el mensaje SHALL indicar que el ajuste corresponde registrarlo como movimiento manual. Esta regla protege la conciliación ya firmada: un movimiento aparecido después del cierre no tendría línea de extracto disponible para matchearse y quedaría huérfano en el ledger para siempre.

#### Scenario: El movimiento del mostrador toma el día local

- **WHEN** se cobra una venta desde el POS por transferencia
- **THEN** el `bank_movement` nace con `value_date` igual al día local del tenant, no a la fecha UTC del servidor

#### Scenario: Una operación retroactiva dentro de un período conciliado es rechazada

- **GIVEN** una sesión de conciliación `closed` sobre la cuenta destino que cubre el período del mes anterior
- **WHEN** se registra desde el formulario una venta por transferencia con fecha dentro de ese período
- **THEN** la operación falla con `P0424`, no se registra la venta ni el movimiento, y el mensaje indica registrar un ajuste manual

#### Scenario: Una operación retroactiva fuera de todo período conciliado procede

- **GIVEN** una sesión de conciliación `closed` que cubre el mes anterior
- **WHEN** se registra una venta por transferencia con fecha posterior al `period_to` de esa sesión
- **THEN** la operación se registra y el `bank_movement` queda `unreconciled`, disponible para la próxima sesión

### Requirement: El movimiento de una operación es conciliable sin piezas nuevas

El sistema SHALL hacer que el movimiento generado por una operación nazca con `reconciliation_status = 'unreconciled'` y `reconciled_at IS NULL`, quedando disponible para el matching de la capability `bank-reconciliation` exactamente igual que un movimiento manual o uno de las RPCs de pago. NO SHALL existir un estado intermedio de "movimiento esperado" distinto de `unreconciled`: el movimiento operativo generado por la venta **es** el esperado, y su confirmación bancaria es el match contra la línea de extracto. La conciliación de una venta con tarjeta, cuyo bruto no coincide con el neto acreditado por el adquirente, SHALL resolverse con el instrumento ya existente: un match N:1 que agrupe el movimiento de la venta con los movimientos manuales `fee`/`tax_debit` de la comisión, cuya suma iguale la línea del extracto.

#### Scenario: El movimiento de la venta nace conciliable

- **WHEN** una venta por transferencia registra su `bank_movement`
- **THEN** la fila tiene `reconciliation_status = 'unreconciled'` y `reconciled_at IS NULL`

#### Scenario: La sugerencia automática engancha el movimiento de una venta

- **GIVEN** un `bank_movement` de `+10000` generado por una venta por transferencia y una línea de extracto importada de `+10000` con `value_date` dentro de ±3 días
- **WHEN** el usuario pide sugerencias en una sesión abierta de esa cuenta
- **THEN** el par aparece como sugerencia 1:1 a confirmar, y al confirmarla el movimiento queda `matched`

#### Scenario: La venta con tarjeta se concilia neteando la comisión con un match N:1

- **GIVEN** un `bank_movement` de `+10000` con `movement_type = 'card_settlement'` y un `bank_movement` manual de `−350` con `movement_type = 'fee'`
- **WHEN** el usuario los matchea contra una línea de extracto de `+9650`
- **THEN** el match se crea (la suma del grupo iguala la línea) y ambos movimientos quedan `matched`

