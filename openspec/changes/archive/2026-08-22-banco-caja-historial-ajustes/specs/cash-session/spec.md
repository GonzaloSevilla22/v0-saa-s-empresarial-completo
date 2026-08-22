## MODIFIED Requirements

### Requirement: Cierre de sesión con arqueo
El sistema SHALL cerrar una `CashSession` vía `rpc_close_cash_session(p_session_id, p_counted_balance)`, calculando `expected_balance = opening_balance + Σ(cash_movements.amount)` de la sesión, registrando `counted_balance`, `difference = counted_balance - expected_balance`, `closing_balance = counted_balance`, `status = 'closed'`, `closed_by` y `closed_at = now()`. La diferencia SHALL persistirse aunque sea distinta de cero (señal antifraude, RN-95). El cierre SHALL además materializar `adjustments_total = Σ(cash_movements.amount) FILTER (movement_type = 'adjustment')` de la sesión y SHALL devolver `difference_before_adjustments = difference + adjustments_total`, sin alterar la definición de `expected_balance` ni la de `difference`, de modo que los ajustes manuales queden separables del arqueo en lugar de disolverse en él.

#### Scenario: Cierre con arqueo exacto
- **GIVEN** una sesión con `opening_balance = 5000` y movimientos que suman `+3000`
- **WHEN** el usuario cierra declarando `counted_balance = 8000`
- **THEN** `expected_balance = 8000`, `difference = 0`, `adjustments_total = 0`, `status = 'closed'`, `closed_at = now()`

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

## REMOVED Requirements

### Requirement: UI de caja por sucursal
**Reason**: La caja deja de ser una subpantalla del detalle de sucursal y pasa a ser un módulo de primer nivel. La superficie queda especificada por la capability `cash-book-module` (ruta `/caja`, entrada de sidebar propia, selección de sucursal y caja dentro de la pantalla, historial completo de la caja y registro de ajuste), que además cubre lo que esta requirement pedía (apertura con saldo inicial, movimientos, cierre con arqueo y diferencia visible, historial de sesiones).

**Migration**: `/sucursales/:id/caja` se conserva como acceso contextual y redirige del lado del servidor a `/caja` con la sucursal preseleccionada — no hay enlaces rotos. Ninguna funcionalidad se pierde: el historial de movimientos deja de estar limitado a la sesión activa y el historial de sesiones sigue mostrando la diferencia de arqueo, ahora acompañada del total de ajustes manuales.

## ADDED Requirements

### Requirement: La sesión de caja persiste el total de sus ajustes manuales
El sistema SHALL persistir en `cash_sessions` la columna aditiva `adjustments_total NUMERIC NULL`, materializada al cerrar la sesión como la suma firmada de los movimientos de tipo `adjustment` de esa sesión, y SHALL calcular esa misma cifra al vuelo para las sesiones que aún están abiertas, de modo que la señal esté disponible sin depender de que alguien cierre la sesión.

#### Scenario: Sesión cerrada con ajustes
- **WHEN** se cierra una sesión que contiene ajustes por `+100` y `-30`
- **THEN** la fila queda con `adjustments_total = +70`

#### Scenario: Sesión abierta con ajustes
- **GIVEN** una sesión `open` con un ajuste de `+100`
- **WHEN** se consulta el estado de la sesión
- **THEN** la lectura informa un total de ajustes de `+100` aunque `adjustments_total` todavía no esté materializado

#### Scenario: Sesiones históricas sin ajustes
- **GIVEN** sesiones cerradas antes de este cambio
- **WHEN** se consultan
- **THEN** su `adjustments_total` es nulo y se interpreta como cero, sin reescritura de datos históricos
