# cash-movement Specification

## Purpose
TBD - created by archiving change v21-cash-session. Update Purpose after archive.
## Requirements
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

### Requirement: Movimiento exige sesión abierta
El sistema SHALL rechazar el registro de un `CashMovement` cuya `cash_session` no esté `status = 'open'`, con error `P0409 no_open_session`. Todo movimiento de efectivo requiere una sesión abierta (RN-95).

#### Scenario: Registrar movimiento sin sesión abierta falla
- **GIVEN** una sesión con `status = 'closed'` (o un `session_id` inexistente)
- **WHEN** se llama a `rpc_register_cash_movement` sobre ella
- **THEN** la RPC retorna `P0409 no_open_session` y no inserta ninguna fila

### Requirement: Helper transaccional reutilizable para el hot path de venta
El sistema SHALL exponer un helper SQL `c28_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id)` invocable desde **dentro de otra transacción** (p. ej. la RPC de confirmación de venta de C-29), que inserta el `cash_movement` con `balance_after` calculado y aplica las invariantes (sesión abierta, sucursal operativa) sin abrir una transacción propia. La RPC pública `rpc_register_cash_movement` SHALL ser un wrapper fino sobre este helper. Esto garantiza que una venta en efectivo pueda generar su movimiento de caja en la MISMA transacción que el descuento de stock (DEC-20), atómicamente.

#### Scenario: Venta en efectivo genera el movimiento en la misma transacción (contrato listo para C-29)
- **GIVEN** una sesión de caja `open` y una transacción de venta en curso que invoca `c28_register_cash_movement(session, total, 'sale', sale_id)`
- **WHEN** la transacción de venta hace COMMIT
- **THEN** `cash_movements` contiene exactamente una fila con `movement_type = 'sale'`, `reference_id = sale_id` y `amount = total`, persistida atómicamente con el resto de la venta

#### Scenario: Si la venta falla, el movimiento de caja se revierte (atomicidad)
- **GIVEN** una transacción de venta que registró un `cash_movement` vía el helper y luego falla (p. ej. stock insuficiente)
- **WHEN** la transacción hace ROLLBACK
- **THEN** no queda ninguna fila en `cash_movements` para esa venta (el helper no abre su propia transacción)

### Requirement: Suma de movimientos alimenta el arqueo
El sistema SHALL exponer `Σ(cash_movements.amount)` de una sesión como base del `expected_balance` al cerrar (`expected = opening_balance + Σ amount`), consultable también para mostrar el saldo corriente de la sesión activa en la UI.

#### Scenario: El esperado al cierre refleja todos los movimientos
- **GIVEN** una sesión con `opening_balance = 5000` y movimientos `+1200` (sale), `-300` (expense), `+800` (sale)
- **WHEN** se calcula el esperado
- **THEN** `expected_balance = 6700` (5000 + 1200 − 300 + 800)

### Requirement: Contra-movimiento de caja por borrado de operación
El sistema SHALL registrar un movimiento de caja espejo de tipo `sale_reversal`, por el importe opuesto al movimiento original, cuando se borra una operación que tenía un movimiento de caja posteado.

#### Scenario: Venta con movimiento de caja
- **WHEN** se borra una venta que registró un ingreso de caja
- **THEN** se registra un movimiento `sale_reversal` por el importe opuesto
- **AND** el movimiento referencia la operación borrada
- **AND** el saldo de la caja vuelve exactamente al valor previo a la venta

#### Scenario: Operación sin movimiento de caja
- **WHEN** se borra una operación que nunca registró caja
- **THEN** no se registra ningún movimiento de caja

### Requirement: Destino del contra-movimiento respecto de sesiones cerradas
El sistema SHALL registrar el contra-movimiento en la sesión de caja abierta en ese momento para la misma caja, y SHALL NOT insertar, modificar ni anular movimientos dentro de una sesión ya cerrada, preservando la integridad del arqueo firmado.

#### Scenario: La sesión original ya cerró
- **WHEN** se borra una operación cuyo movimiento de caja pertenece a una sesión cerrada
- **AND** existe una sesión abierta en la misma caja
- **THEN** el contra-movimiento se registra en la sesión abierta
- **AND** la sesión cerrada y su arqueo quedan sin modificaciones

#### Scenario: No hay sesión abierta
- **WHEN** se borra una operación que requiere compensar caja
- **AND** no existe ninguna sesión abierta en esa caja
- **THEN** el sistema rechaza el borrado con el código de error `P0426`
- **AND** el mensaje indica que debe abrirse la caja para poder anular la operación

#### Scenario: La sesión original sigue abierta
- **WHEN** se borra una operación cuyo movimiento de caja pertenece a una sesión todavía abierta
- **THEN** el contra-movimiento se registra en esa misma sesión

### Requirement: Vocabulario de tipos de movimiento de caja
El catálogo de tipos de movimiento de caja SHALL admitir `sale_reversal` como tipo propio, distinguible de los retiros y de los egresos operativos en los reportes de caja.

#### Scenario: Reporte de caja con una reversión
- **WHEN** se lista el detalle de una sesión que contiene un `sale_reversal`
- **THEN** el movimiento aparece identificado como reversión de venta
- **AND** no se contabiliza como retiro ni como gasto

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

