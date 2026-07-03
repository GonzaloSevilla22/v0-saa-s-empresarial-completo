## ADDED Requirements

### Requirement: El presupuesto registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'quote'`) tanto la creación del presupuesto (`from_status = NULL`, `to_status = 'draft'`) como su transición a `accepted` durante `rpc_accept_quote`, en la misma transacción que la operación de negocio.

#### Scenario: Crear un presupuesto registra su estado inicial
- **WHEN** se crea un presupuesto en estado `draft`
- **THEN** el sistema inserta una fila de historial con `document_type = 'quote'`, `from_status = NULL`, `to_status = 'draft'` y `performed_by` = el usuario que lo creó

#### Scenario: Aceptar un presupuesto registra la transición
- **WHEN** `rpc_accept_quote` transiciona el presupuesto a `accepted`
- **THEN** el sistema inserta una fila de historial con `from_status` = estado previo (`draft` o `sent`) y `to_status = 'accepted'` en la misma transacción, y la aceptación no se confirma si el registro falla
