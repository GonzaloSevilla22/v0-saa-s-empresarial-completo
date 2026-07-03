## ADDED Requirements

### Requirement: La sesión de conciliación registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'reconciliation_session'`) tanto la apertura de la sesión (`from_status = NULL`, `to_status = 'open'`) como su cierre (`open → closed`) durante `rpc_close_reconciliation_session`, en la misma transacción del cierre.

#### Scenario: Abrir una sesión de conciliación registra su estado inicial
- **WHEN** se abre una sesión de conciliación en estado `open`
- **THEN** el sistema inserta una fila de historial con `document_type = 'reconciliation_session'`, `from_status = NULL`, `to_status = 'open'`

#### Scenario: Cerrar una sesión de conciliación registra la transición
- **WHEN** `rpc_close_reconciliation_session` transiciona la sesión de `open` a `closed`
- **THEN** el sistema inserta una fila de historial con `from_status = 'open'`, `to_status = 'closed'` en la misma transacción, y el cierre no se confirma si el registro falla
