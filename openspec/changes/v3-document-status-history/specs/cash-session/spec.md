## ADDED Requirements

### Requirement: La sesión de caja registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'cash_session'`) tanto la apertura de la sesión (`from_status = NULL`, `to_status = 'open'`) como su cierre (`open → closed`) durante `rpc_close_cash_session`, en la misma transacción del cierre. Cuando el arqueo registra una diferencia distinta de cero, el sistema SHALL exigir un `reason` no vacío para la transición de cierre (RN-A5).

#### Scenario: Abrir una sesión de caja registra su estado inicial
- **WHEN** se abre una sesión de caja en estado `open`
- **THEN** el sistema inserta una fila de historial con `document_type = 'cash_session'`, `from_status = NULL`, `to_status = 'open'`

#### Scenario: Cerrar una sesión sin diferencia registra la transición
- **WHEN** `rpc_close_cash_session` cierra una sesión cuyo arqueo no arroja diferencia
- **THEN** el sistema inserta una fila de historial con `from_status = 'open'`, `to_status = 'closed'` en la misma transacción

#### Scenario: Cerrar una sesión con diferencia exige motivo
- **WHEN** `rpc_close_cash_session` cierra una sesión cuyo arqueo arroja una diferencia distinta de cero y no se provee `reason`
- **THEN** el registro de la transición aborta la operación con un error de payload inválido y el cierre no se confirma
