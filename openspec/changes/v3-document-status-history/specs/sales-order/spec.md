## ADDED Requirements

### Requirement: La orden de venta registra sus transiciones de estado en el historial

El sistema SHALL registrar en `document_status_history` (con `document_type = 'sales_order'`) tanto la creación de la orden (`from_status = NULL`, `to_status = 'draft'`) como su transición a `confirmed` durante `_c29_confirm_order_core`, en la misma transacción atómica de la confirmación (junto con stock, caja, fiscal y outbox).

#### Scenario: Crear una orden de venta registra su estado inicial
- **WHEN** se crea una orden de venta en estado `draft` (incluyendo la creación implícita de `quickSale`)
- **THEN** el sistema inserta una fila de historial con `document_type = 'sales_order'`, `from_status = NULL`, `to_status = 'draft'`

#### Scenario: Confirmar una orden registra la transición atómicamente
- **WHEN** `_c29_confirm_order_core` transiciona la orden de `draft` a `confirmed`
- **THEN** el sistema inserta una fila de historial con `from_status = 'draft'`, `to_status = 'confirmed'` en la misma transacción, y si el registro falla toda la confirmación (stock, caja, fiscal, outbox) se revierte

#### Scenario: La idempotencia de la confirmación no duplica el historial
- **WHEN** una confirmación se reejecuta con la misma `idempotency_key` y devuelve la operación original sin re-ejecutar
- **THEN** no se inserta una nueva fila de historial para la transición ya registrada
