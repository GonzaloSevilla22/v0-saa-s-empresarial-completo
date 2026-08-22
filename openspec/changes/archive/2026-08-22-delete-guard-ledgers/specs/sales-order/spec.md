## ADDED Requirements

### Requirement: Cancelación de la orden al borrar su venta
El sistema SHALL cancelar la orden de venta en la misma transacción en que se borra la venta que originó, dejándola en estado `canceled` y sin referencia a una operación de venta inexistente.

#### Scenario: Borrado de la venta del POS
- **WHEN** se borra la venta originada por una orden confirmada del POS
- **THEN** la orden queda en estado `canceled`
- **AND** deja de referenciar la operación de venta borrada

#### Scenario: La transición queda registrada
- **WHEN** una orden se cancela por el borrado de su venta
- **THEN** la transición de estado queda registrada en el historial de la orden
- **AND** el motivo registrado identifica el borrado de la venta

#### Scenario: Orden con comprobante fiscal
- **WHEN** se intenta borrar la venta de una orden con comprobante fiscal emitido
- **THEN** el borrado se rechaza
- **AND** la orden conserva su estado confirmado

### Requirement: Ausencia de órdenes confirmadas sin venta viva
El sistema SHALL NOT dejar órdenes en estado `confirmed` cuya operación de venta asociada no exista.

#### Scenario: Verificación de consistencia
- **WHEN** se audita el conjunto de órdenes confirmadas con operación de venta asignada
- **THEN** cada una referencia una operación de venta existente
