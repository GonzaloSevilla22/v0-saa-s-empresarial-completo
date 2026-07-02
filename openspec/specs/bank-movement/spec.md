# bank-movement Specification

## Purpose
Ledger append-only de movimientos bancarios (`BankMovement`): helper intra-tx reutilizable, RPC de carga manual, taxonomía de tipos, RLS por `account_id` denormalizado. Entregado en `bank-account-ledger` (V2.5 C1, BankReconciliation, 2026-06-27). Extendido en `bank-payment-routing` (V2.5 C2, 2026-07-02): los pagos por método bancario escriben `bank_movement` automáticamente y el journal contable postea la contrapartida en `1110 Banco` de forma asíncrona.
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
El sistema SHALL fijar mediante CHECK el conjunto completo de `movement_type` desde ya: `{'transfer_in', 'transfer_out', 'card_settlement', 'fee', 'tax_debit', 'interest', 'manual_adjustment'}`. El `value_date` SHALL representar la fecha valor bancaria, distinta de `created_at`. Los tipos `card_settlement`, `fee`, `tax_debit` (impuesto al cheque, Ley 25.413) e `interest` SHALL quedar RESERVADOS para changes posteriores (C2/C3) y NO ser emitibles por la carga manual de este change.

#### Scenario: El CHECK acepta el enum completo
- **WHEN** se inspecciona el `CHECK` de `bank_movements.movement_type`
- **THEN** incluye los 7 tipos `transfer_in`, `transfer_out`, `card_settlement`, `fee`, `tax_debit`, `interest`, `manual_adjustment`

#### Scenario: Un movement_type fuera del enum es rechazado por el CHECK
- **WHEN** se intenta insertar un `bank_movement` con `movement_type = 'foo'`
- **THEN** la inserción falla por violación del CHECK del enum

### Requirement: RPC de carga manual de movimiento bancario
El sistema SHALL exponer `rpc_register_bank_movement` (SECURITY DEFINER, GRANT a `authenticated`) para registrar movimientos bancarios **manualmente**. Esta RPC SHALL aceptar ÚNICAMENTE el subconjunto manual/transferencia de `movement_type`: `{'transfer_in', 'transfer_out', 'manual_adjustment'}`, rechazando cualquier tipo reservado (p.ej. `card_settlement`) con `P0410`. La RPC SHALL estar guardada por `is_account_writer` (`P0401` si no), SHALL rechazar movimientos sobre una cuenta inexistente o inactiva (`P0412`), y SHALL ser idempotente vía `idempotency_key` (slot en `operation_idempotency`, replay devuelve el resultado original sin re-insertar).

#### Scenario: Registrar una transferencia manual
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `amount = +5000`, `movement_type = 'transfer_in'` y una `idempotency_key` nueva sobre una cuenta activa
- **THEN** se registra el movimiento (vía el helper) con su `balance_after` y la RPC devuelve `replayed = false`

#### Scenario: La RPC manual rechaza un tipo reservado
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `movement_type = 'card_settlement'`
- **THEN** la RPC retorna `P0410` y no inserta ninguna fila (el tipo está reservado a C2/C3)

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
