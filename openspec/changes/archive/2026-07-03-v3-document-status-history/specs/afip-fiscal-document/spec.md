## ADDED Requirements

### Requirement: El comprobante fiscal registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'fiscal_document'`) tanto la creación del comprobante (`from_status = NULL`, `to_status = 'pending_cae'`) al reservar el número, como la transición `pending_cae → authorized` o `pending_cae → rejected` cuando el relay obtiene o rechaza el CAE. Como el relay del CAE se ejecuta en el backend (no en un único RPC atómico), el sistema SHALL exponer un punto de escritura con privilegios elevados (`SECURITY DEFINER`) para que el backend registre la transición en la misma transacción en que actualiza `fiscal_documents.status`, sin abrir escritura directa sobre `document_status_history`.

#### Scenario: Emitir un pending_cae registra el estado inicial
- **WHEN** `rpc_emit_pending_cae` reserva un número y persiste el comprobante en `pending_cae`
- **THEN** el sistema inserta una fila de historial con `document_type = 'fiscal_document'`, `from_status = NULL`, `to_status = 'pending_cae'`

#### Scenario: Obtener el CAE registra la transición a authorized
- **WHEN** el relay persiste un CAE válido y actualiza el comprobante a `authorized`
- **THEN** el sistema inserta una fila de historial con `from_status = 'pending_cae'`, `to_status = 'authorized'` en la misma transacción que la actualización de estado

#### Scenario: El rechazo del CAE registra la transición a rejected
- **WHEN** el relay marca el comprobante como `rejected` tras agotar los reintentos o recibir un rechazo de ARCA
- **THEN** el sistema inserta una fila de historial con `from_status = 'pending_cae'`, `to_status = 'rejected'`
