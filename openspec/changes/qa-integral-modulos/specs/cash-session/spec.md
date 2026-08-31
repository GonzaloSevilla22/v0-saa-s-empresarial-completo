# cash-session — Delta

## MODIFIED Requirements

### Requirement: Cierre de sesión con arqueo

El sistema SHALL cerrar una `CashSession` vía `rpc_close_cash_session(p_session_id, p_counted_balance)`, calculando `expected_balance = opening_balance + Σ(cash_movements.amount)` de la sesión, registrando `counted_balance`, `difference = counted_balance - expected_balance`, `closing_balance = counted_balance`, `status = 'closed'`, `closed_by` y `closed_at = now()`. La diferencia SHALL persistirse aunque sea distinta de cero (señal antifraude, RN-95). El cierre SHALL además materializar `adjustments_total = Σ(cash_movements.amount) FILTER (movement_type = 'adjustment')` de la sesión y SHALL devolver `difference_before_adjustments = difference + adjustments_total`, sin alterar la definición de `expected_balance` ni la de `difference`, de modo que los ajustes manuales queden separables del arqueo en lugar de disolverse en él.

La interfaz de cierre SHALL mostrar el resultado del arqueo (esperado, contado y diferencia) inmediatamente después de confirmar el cierre, y ese panel SHALL persistir en pantalla hasta que el usuario lo cierre explícitamente: ningún refetch, invalidación de query ni cambio de estado de la sesión SHALL desmontarlo antes de esa acción del usuario.

#### Scenario: El panel de arqueo sobrevive al refetch de la sesión

- **GIVEN** una sesión abierta y un cierre confirmado con `counted_balance` distinto del esperado
- **WHEN** la mutación resuelve y la query de sesión vigente se invalida y pasa a "sin sesión abierta"
- **THEN** el panel de resultado sigue visible con el faltante o sobrante, y solo se cierra cuando el usuario lo descarta

#### Scenario: Cierre con arqueo exacto

- **GIVEN** una sesión con `opening_balance = 5000` y movimientos que suman `+3000`
- **WHEN** el usuario cierra declarando `counted_balance = 8000`
- **THEN** `expected_balance = 8000`, `difference = 0`, `adjustments_total = 0`, `status = 'closed'`, `closed_at = now()`
- **AND** el panel de resultado del arqueo queda visible hasta que el usuario lo cierre

#### Scenario: Cierre con faltante (diferencia negativa)

- **GIVEN** una sesión con `expected_balance = 8000`
- **WHEN** el usuario cierra declarando `counted_balance = 7500`
- **THEN** `difference = -500` se persiste, `status = 'closed'`, y la diferencia queda visible en el historial

#### Scenario: No se puede cerrar una sesión ya cerrada

- **GIVEN** una sesión con `status = 'closed'`
- **WHEN** un usuario llama a `rpc_close_cash_session` sobre ella
- **THEN** la RPC retorna `P0409 session_not_open` y no modifica la fila

#### Scenario: Cierre de una sesión con ajustes manuales

- **GIVEN** una sesión cuyo `opening_balance + Σ(movimientos no ajuste) = 900` y que tiene un ajuste de `+100`
- **WHEN** el usuario cierra declarando `counted_balance = 1000`
- **THEN** `expected_balance = 1000`, `difference = 0`, `adjustments_total = +100` y `difference_before_adjustments = +100`

#### Scenario: El total de ajustes queda en el registro de la transición de cierre

- **GIVEN** una sesión con al menos un movimiento de ajuste
- **WHEN** se cierra la sesión
- **THEN** el motivo de la transición `open → closed` menciona los ajustes aplicados, y el evento de cierre emitido lleva `adjustments_total` en su payload
