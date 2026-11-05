## ADDED Requirements

### Requirement: Contra-movimiento y movimiento nuevo de caja por edición de una operación
El sistema SHALL ajustar la caja al editar una venta, una compra o un gasto cuyo efecto de caja cambia —otra caja, otro importe o salida de la caja—, en la misma transacción que la edición:

1. compensar la huella neta de caja con un contra-movimiento del tipo de reversión del documento (`sale_reversal`, `purchase_payment_reversal` o `expense_reversal`), por el importe exactamente opuesto al neto y con la misma referencia;
2. registrar el efecto nuevo con el tipo del documento (`sale`, `purchase_payment` o `expense`) y la referencia de la operación.

SHALL NOT registrar ningún movimiento cuando el efecto no cambia: misma caja y mismo importe.

El contra-movimiento SHALL ir a la **sesión abierta actual de la misma caja** de la huella y SHALL NOT modificar ni insertar en una sesión cerrada. Si esa caja no tiene sesión abierta, la edición entera SHALL rechazarse con `P0426`, nombrando la caja.

El movimiento nuevo SHALL ir a la sesión que resuelve la intención de caja de la edición (capability `operation-money-edit`). Las descripciones SHALL identificar la edición.

Los tipos de movimiento SHALL ser los ya existentes: la reversión por edición es la misma reversión económica que la del borrado, y SHALL NOT agregarse tipos nuevos al vocabulario de caja.

#### Scenario: Corregir el importe de una venta en efectivo del día
- **GIVEN** una venta en efectivo de hoy de 1000 registrada en la sesión abierta
- **WHEN** se edita a 1200
- **THEN** la misma sesión recibe un `sale_reversal` de −1000 y un `sale` de +1200, y el esperado del arqueo sube 200

#### Scenario: La sesión original ya cerró
- **GIVEN** una venta en efectivo de ayer de 1000 cuya sesión ya cerró, y una sesión abierta hoy en la misma caja
- **WHEN** se edita a 1200
- **THEN** la sesión de hoy recibe el `sale_reversal` de −1000 y el `sale` de +1200
- **AND** la sesión cerrada y su arqueo quedan sin modificaciones

#### Scenario: Sin sesión abierta la edición se rechaza
- **GIVEN** un gasto en efectivo cuyo importe cambia y ninguna sesión abierta en su caja
- **WHEN** se intenta editar
- **THEN** la edición falla con `P0426` y ni el gasto ni ningún libro cambian

#### Scenario: Una edición que no cambia la caja no la toca
- **GIVEN** una compra en efectivo con movimiento de caja en una sesión cerrada y ninguna sesión abierta
- **WHEN** se edita sólo su descripción
- **THEN** la edición se aplica sin registrar movimientos de caja y sin exigir sesión abierta
