## ADDED Requirements

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
