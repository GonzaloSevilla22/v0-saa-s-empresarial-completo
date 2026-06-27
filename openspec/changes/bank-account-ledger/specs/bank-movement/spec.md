## ADDED Requirements

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
El sistema en este change NO SHALL postear movimientos bancarios a la cuenta contable `1110 Banco` del journal de partida doble. `bank_movements` es el ledger OPERACIONAL (fuente de verdad del saldo bancario y base de la conciliación futura). La cuenta `1110 Banco` SHALL permanecer reservada y vacía hasta que C2 (`bank-payment-routing`) cablee el posteo asincrónico vía el Consumer 3 del outbox. La conciliación futura (C3) SHALL operar sobre `bank_movements`, NUNCA sobre el journal.

#### Scenario: Registrar un movimiento bancario no crea asiento contable
- **WHEN** se registra un `bank_movement` vía `rpc_register_bank_movement`
- **THEN** no se inserta ninguna fila en `journal_entries`/`journal_lines` con `account_code = '1110'` (el posteo es responsabilidad de C2)
