## MODIFIED Requirements

### Requirement: Ledger append-only de movimientos de efectivo
El sistema SHALL registrar cada movimiento de efectivo como una fila append-only en `cash_movements` (`id`, `session_id` FK `cash_sessions`, `amount NUMERIC`, `movement_type`, `reference_id UUID NULL`, `description TEXT NULL`, `balance_after NUMERIC`, `created_by`, `created_at`), sin UPDATE ni DELETE sobre filas existentes. Cada fila SHALL llevar `balance_after = saldo previo + amount` (patrón ledger contable, RN-98, igual que `stock_movements`). El aislamiento por cuenta (RLS) SHALL resolverse vía `session_id → cash_sessions.cashbox_id → cashboxes.branch_id → branches.account_id`. La columna `description` SHALL contener el motivo del movimiento cuando lo tenga; es opcional para los movimientos originados en operaciones (que ya se explican por su `reference_id`) y obligatoria para los ajustes manuales.

#### Scenario: Registrar un movimiento calcula balance_after
- **GIVEN** una sesión `open` con `opening_balance = 5000` y sin movimientos
- **WHEN** se registra un movimiento `amount = +1200`, `movement_type = 'sale'`
- **THEN** se inserta una fila con `balance_after = 6200` y `created_at = now()`

#### Scenario: Movimientos son append-only
- **GIVEN** un `cash_movement` ya insertado
- **WHEN** se intenta modificarlo o borrarlo vía la API
- **THEN** la operación no está permitida (sin endpoint de UPDATE/DELETE; RLS sin políticas de escritura directa fuera del helper definer)

#### Scenario: Un movimiento de venta no necesita motivo
- **WHEN** el hot path de la venta registra un movimiento `sale` sin `description`
- **THEN** la fila se inserta normalmente con `description IS NULL`

### Requirement: Tipos de movimiento enumerados
El sistema SHALL aceptar únicamente `movement_type` dentro del conjunto `{'sale', 'purchase_payment', 'expense', 'advance', 'withdrawal', 'sale_reversal', 'adjustment'}`, validado por CHECK en la columna. `sale` y `advance` son ingresos (signo positivo esperado); `purchase_payment`, `expense`, `withdrawal` y `sale_reversal` son egresos (signo negativo esperado); `adjustment` admite ambos signos (positivo = sobrante, negativo = faltante). El signo SHALL viajar en `amount` (el llamador lo provee), y el CHECK del enum SHALL validar solo la pertenencia al conjunto. Adicionalmente, un CHECK SHALL exigir que todo movimiento de tipo `adjustment` lleve `description` no vacía, sin imponer esa exigencia a los demás tipos.

#### Scenario: Tipo inválido es rechazado
- **GIVEN** una sesión `open`
- **WHEN** se intenta registrar un movimiento con `movement_type = 'tip'`
- **THEN** la inserción falla por violación del CHECK del enum

#### Scenario: El enum incluye adjustment
- **WHEN** se inspecciona el CHECK de `cash_movements.movement_type`
- **THEN** incluye los 7 tipos `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`, `sale_reversal`, `adjustment`

#### Scenario: Ajuste sin motivo es rechazado por el CHECK
- **GIVEN** una sesión `open`
- **WHEN** se intenta insertar un movimiento `movement_type = 'adjustment'` con `description` nula o en blanco
- **THEN** la inserción falla por violación del CHECK de motivo obligatorio

#### Scenario: Las filas históricas sin motivo siguen siendo válidas
- **GIVEN** movimientos preexistentes de tipos distintos de `adjustment` con `description IS NULL`
- **WHEN** se aplica el CHECK de motivo obligatorio
- **THEN** ninguna fila histórica es invalidada ni reescrita

## ADDED Requirements

### Requirement: El motivo del ajuste viaja por la cadena de escritura de caja
El sistema SHALL propagar el motivo del movimiento desde la RPC de registro hasta la fila del ledger, agregando el parámetro de motivo tanto a `rpc_register_cash_movement` como al helper intra-transaccional que ésta delega, con valor por omisión nulo para que los llamadores existentes del hot path de venta no requieran cambios. La firma nueva SHALL revocar explícitamente `EXECUTE` de `PUBLIC`, `anon` y `authenticated` y volver a otorgarlo de forma selectiva en la misma migración, y SHALL quedar como única firma viva de cada función.

#### Scenario: El hot path de venta no cambia
- **WHEN** el camino de venta llama a la RPC de registro sin el parámetro de motivo
- **THEN** el movimiento se registra igual que antes, con `description IS NULL`

#### Scenario: El ajuste viaja con su motivo
- **WHEN** se llama a la RPC de registro con `movement_type = 'adjustment'` y un motivo
- **THEN** la fila insertada persiste ese motivo en `description`

#### Scenario: No quedan firmas duplicadas
- **WHEN** se inspeccionan las funciones de registro de movimiento de caja tras la migración
- **THEN** existe exactamente una firma viva de cada una, con los permisos re-otorgados explícitamente
