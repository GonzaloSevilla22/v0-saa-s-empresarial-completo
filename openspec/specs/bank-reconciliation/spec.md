# bank-reconciliation Specification

## Purpose
Conciliación bancaria (`ReconciliationSession`): import de extracto como datos crudos inmutables, sesiones por cuenta + período con FSM explícita, matching 1:1/1:N/N:1 entre líneas de extracto y movimientos del ledger operativo, y cierre con diferencia explicada. Entregado en `bank-reconciliation` (V2.5 C3, BankReconciliation 3/3, 2026-07-02). Opera EXCLUSIVAMENTE sobre `bank_movements` vs `bank_statement_lines` — nunca sobre el journal contable (dos ledgers: C1/C2). Aplica modelo V3: RN-A (FSM + motivo obligatorio en acciones destructivas) y RN-D5 (fechas con semántica local sobre `value_date`).
## Requirements
### Requirement: Import de extracto bancario
El sistema SHALL permitir importar un extracto bancario contra una `bank_account` activa de la organización, registrando el archivo en `bank_statement_imports` (`id`, `bank_account_id`, `account_id` denormalizado, `file_name`, `file_hash`, `period_from DATE`, `period_to DATE`, `line_count`, `imported_by`, `created_at`) y cada línea en `bank_statement_lines` (`id`, `import_id`, `bank_account_id`, `account_id` denormalizado, `line_no`, `value_date DATE`, `description TEXT`, `amount NUMERIC(14,2)` con signo, `balance NUMERIC(14,2) NULL`). Las líneas del extracto son **datos crudos inmutables del banco**: sin UPDATE ni DELETE (append-only, RN-A3). El formato de entrada V1 SHALL ser filas normalizadas (`value_date`, `description`, `amount`, `balance?`) — el backend acepta CSV nativo y la UI normaliza Excel a filas antes de enviar. El import SHALL ser idempotente: mismo `file_hash` sobre la misma cuenta → replay sin duplicar líneas (`P0430` o replay explícito, sin re-insertar).

#### Scenario: Import exitoso registra archivo y líneas
- **WHEN** un usuario con permiso de escritura importa un extracto de 10 líneas válidas sobre una cuenta activa
- **THEN** existe 1 fila en `bank_statement_imports` con `line_count = 10` y 10 filas en `bank_statement_lines` con su `import_id`, todas con `account_id` denormalizado

#### Scenario: Re-importar el mismo archivo no duplica
- **WHEN** se importa dos veces un archivo con el mismo `file_hash` sobre la misma cuenta
- **THEN** la segunda llamada no inserta líneas nuevas (replay idempotente) y el total de `bank_statement_lines` no cambia

#### Scenario: Las líneas del extracto son inmutables
- **WHEN** se intenta UPDATE o DELETE sobre una fila de `bank_statement_lines` vía la API
- **THEN** la operación no está permitida (sin endpoint ni policy de UPDATE/DELETE; escritura solo vía RPC SECURITY DEFINER)

#### Scenario: Import sobre cuenta inactiva es rechazado
- **WHEN** se intenta importar un extracto sobre una cuenta con `is_active = false`
- **THEN** la RPC retorna `P0412` y no inserta ninguna fila

#### Scenario: Un usuario de otra organización no ve el extracto
- **WHEN** un miembro de la organización B consulta imports o líneas de extracto de la organización A
- **THEN** la RLS por `account_id` denormalizado no devuelve las filas de A

### Requirement: Sesión de conciliación con FSM explícita
El sistema SHALL modelar la conciliación como `reconciliation_sessions` (`id`, `bank_account_id`, `account_id` denormalizado, `status`, `period_from DATE`, `period_to DATE`, `statement_closing_balance NUMERIC(14,2)`, `ledger_closing_balance NUMERIC(14,2) NULL`, `difference NUMERIC(14,2) NULL`, `close_reason TEXT NULL`, `opened_by`, `closed_by NULL`, `opened_at`, `closed_at NULL`) con FSM `OPEN → CLOSED` donde `CLOSED` es terminal (modelo V3 RN-A: transiciones válidas explícitas, sin reapertura). SHALL existir a lo sumo una sesión `OPEN` por cuenta bancaria (índice UNIQUE parcial, análogo al anti doble-apertura de `cash_sessions`). Al cerrar, el sistema SHALL calcular `ledger_closing_balance` (saldo de `bank_movements` de la cuenta con `value_date <= period_to`) y `difference = statement_closing_balance − ledger_closing_balance`; si `difference ≠ 0`, el cierre SHALL exigir `close_reason` no vacío (RN-A5) y rechazar con `P0431` si falta.

#### Scenario: Abrir una sesión de conciliación
- **WHEN** un usuario con permiso abre una sesión sobre una cuenta activa sin sesión abierta, con período y saldo final del extracto
- **THEN** se crea la sesión con `status = 'open'` y `opened_by` = el usuario

#### Scenario: No se puede abrir una segunda sesión sobre la misma cuenta
- **WHEN** existe una sesión `open` sobre la cuenta y se intenta abrir otra
- **THEN** la operación falla (`P0409` o violación del índice UNIQUE parcial) y no se crea la segunda sesión

#### Scenario: Cierre sin diferencia
- **WHEN** se cierra una sesión donde el saldo del extracto coincide con el saldo del ledger al corte
- **THEN** la sesión queda `closed` con `difference = 0`, `closed_by` y `closed_at` registrados, sin exigir motivo

#### Scenario: Cierre con diferencia exige motivo
- **WHEN** se intenta cerrar una sesión con `difference ≠ 0` sin `close_reason`
- **THEN** la RPC retorna `P0431` y la sesión sigue `open`; con `close_reason` no vacío el cierre procede y la diferencia queda registrada

#### Scenario: CLOSED es terminal
- **WHEN** se intenta operar (match, unmatch, cerrar de nuevo) sobre una sesión `closed`
- **THEN** la operación es rechazada (`P0432 session_closed`) — no existe transición saliente de `closed`

### Requirement: Matching entre líneas de extracto y movimientos del ledger
El sistema SHALL permitir vincular, dentro de una sesión `OPEN`, líneas de extracto con movimientos de `bank_movements` de la misma cuenta mediante `reconciliation_matches` (`id`, `session_id`, `account_id` denormalizado, `match_group UUID`, `statement_line_id NULL`, `bank_movement_id NULL`, `status ('active','undone')`, `matched_by`, `matched_at`, `undo_reason NULL`, `undone_by NULL`, `undone_at NULL`), soportando cardinalidades **1:1, 1:N y N:1** vía `match_group` (todas las filas de un grupo comparten el UUID; la suma de montos de las líneas del grupo SHALL igualar la suma de montos de los movimientos del grupo, con rechazo `P0433 amounts_mismatch`). Una línea de extracto o un movimiento con match `active` NO SHALL poder participar de otro match (`P0434 already_matched`). Al confirmar un match, los `bank_movements` involucrados SHALL pasar a `reconciliation_status = 'matched'` con `reconciled_at` en la misma transacción.

#### Scenario: Match 1:1 exitoso
- **WHEN** un usuario matchea una línea de extracto de `+5000` con un `bank_movement` de `+5000` en sesión abierta
- **THEN** se crean las filas del grupo con `status = 'active'` y el movimiento queda `reconciliation_status = 'matched'`

#### Scenario: Match 1:N con montos que suman
- **WHEN** un usuario matchea una línea de `+9000` contra dos movimientos de `+4000` y `+5000`
- **THEN** el grupo se crea (misma `match_group`) y ambos movimientos quedan `matched`

#### Scenario: Match con montos que no suman es rechazado
- **WHEN** un usuario intenta matchear una línea de `+9000` contra un movimiento de `+8000`
- **THEN** la RPC retorna `P0433` y no se crea ningún match

#### Scenario: Doble match del mismo movimiento es rechazado
- **WHEN** un movimiento ya tiene un match `active` y se lo intenta incluir en otro grupo
- **THEN** la RPC retorna `P0434` y el nuevo match no se crea

#### Scenario: Sugerencias automáticas 1:1
- **WHEN** el usuario pide sugerencias para una sesión abierta
- **THEN** el sistema propone pares 1:1 no matcheados con monto exacto igual y `value_date` dentro de ±3 días — como sugerencia a confirmar, nunca auto-confirmada

### Requirement: Deshacer un match exige motivo y preserva historia
El sistema SHALL permitir deshacer un match `active` solo en sesión `OPEN`, exigiendo `undo_reason` no vacío (RN-A5, rechazo `P0431` si falta). Deshacer NO SHALL borrar filas: el grupo pasa a `status = 'undone'` con `undo_reason`, `undone_by` y `undone_at` (append-only en espíritu, RN-A3), y los `bank_movements` del grupo vuelven a `reconciliation_status = 'unreconciled'` (`reconciled_at = NULL`) en la misma transacción, quedando disponibles para un nuevo match.

#### Scenario: Deshacer con motivo revierte el estado del movimiento
- **WHEN** un usuario deshace un match `active` con motivo "monto correspondía a otra transferencia"
- **THEN** el grupo queda `undone` (las filas persisten con el motivo) y los movimientos vuelven a `unreconciled`

#### Scenario: Deshacer sin motivo es rechazado
- **WHEN** un usuario intenta deshacer un match sin `undo_reason`
- **THEN** la RPC retorna `P0431` y el match sigue `active`

### Requirement: La conciliación opera solo sobre el ledger operativo
La conciliación SHALL operar exclusivamente sobre `bank_movements` vs. `bank_statement_lines`. Ninguna RPC de este módulo (import, open/close session, match, unmatch) SHALL insertar, modificar ni leer para decisión filas de `journal_entries`/`journal_lines`, ni emitir eventos de outbox que posteen al journal. Los ajustes V1 son "solo anotar": una comisión/impuesto/interés del extracto sin contraparte en el sistema se registra como `bank_movement` manual (tipos `fee`/`tax_debit`/`interest`, ver `bank-movement`) y luego se matchea — la generación automática de asientos de ajuste queda fuera de este change.

#### Scenario: Cerrar una sesión no escribe en el journal
- **WHEN** se cierra una sesión de conciliación (con o sin diferencia)
- **THEN** no se inserta ninguna fila en `journal_entries`/`journal_lines` como efecto del cierre

#### Scenario: Anotar una comisión del extracto
- **WHEN** el extracto trae una comisión de `−350` sin movimiento en el sistema, y el usuario la registra como `bank_movement` manual `movement_type = 'fee'` y la matchea 1:1
- **THEN** la línea queda conciliada y el ledger operativo refleja la comisión; el journal no recibe ningún asiento desde la conciliación

### Requirement: Semántica de fechas locales del tenant
Los filtros de período de la conciliación (import, sesión, matching, saldo al corte) SHALL operar sobre `value_date` con tipo `date` en los bordes y semántica de fecha local del tenant (modelo V3 RN-D5), sin conversiones implícitas de timezone sobre `created_at`.

#### Scenario: El corte de sesión usa value_date
- **WHEN** existe un movimiento con `value_date = period_to` y `created_at` del día siguiente en UTC
- **THEN** el movimiento SÍ entra en el `ledger_closing_balance` del cierre (el corte es por `value_date`, no por `created_at`)

### Requirement: Escritura solo vía RPCs con permisos e idempotencia
Todas las escrituras del módulo (import, apertura/cierre de sesión, match, unmatch) SHALL realizarse vía RPCs `SECURITY DEFINER` con `SET search_path`, guardadas por `is_account_writer` (`P0401` si no), con RLS de las tablas nuevas en SELECT-only por `account_id IN (SELECT current_account_ids())`. Las operaciones de escritura no-idempotentes por naturaleza (import, cierre de sesión) SHALL registrar su slot en `operation_idempotency`, extendiendo el CHECK de `operation_kind` con los kinds nuevos **en la misma migración** (regla C-30).

#### Scenario: Un usuario de solo lectura no puede matchear
- **WHEN** un usuario sin permiso de escritura llama a la RPC de match
- **THEN** la RPC retorna `P0401` y no se crea ningún match

#### Scenario: El CHECK de operation_idempotency acepta los kinds nuevos
- **WHEN** una RPC del módulo registra su slot de idempotencia con un `operation_kind` nuevo (p.ej. `bank_statement_import`)
- **THEN** el INSERT no viola el CHECK (fue extendido en la misma migración del change)

### Requirement: La sesión de conciliación registra sus transiciones de estado en el historial
El sistema SHALL registrar en `document_status_history` (con `document_type = 'reconciliation_session'`) tanto la apertura de la sesión (`from_status = NULL`, `to_status = 'open'`) como su cierre (`open → closed`) durante `rpc_close_reconciliation_session`, en la misma transacción del cierre.

#### Scenario: Abrir una sesión de conciliación registra su estado inicial
- **WHEN** se abre una sesión de conciliación en estado `open`
- **THEN** el sistema inserta una fila de historial con `document_type = 'reconciliation_session'`, `from_status = NULL`, `to_status = 'open'`

#### Scenario: Cerrar una sesión de conciliación registra la transición
- **WHEN** `rpc_close_reconciliation_session` transiciona la sesión de `open` a `closed`
- **THEN** el sistema inserta una fila de historial con `from_status = 'open'`, `to_status = 'closed'` en la misma transacción, y el cierre no se confirma si el registro falla
