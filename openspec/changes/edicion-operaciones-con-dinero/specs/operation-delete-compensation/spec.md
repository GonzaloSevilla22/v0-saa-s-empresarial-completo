## MODIFIED Requirements

### Requirement: Localización de movimientos bajo las dos convenciones de referencia
El sistema SHALL localizar los movimientos financieros de una operación consultando todas las referencias de la operación —el `operation_id` (camino del formulario) y el `id` de la `sales_order` asociada (camino del POS y de la conversión de un presupuesto)— con la misma definición de huella neta que usan la edición y los indicadores del listado (capability `operation-money-edit`).

#### Scenario: Operación creada por el formulario
- **WHEN** se borra una operación cuyos movimientos referencian su `operation_id`
- **THEN** el sistema los encuentra y los compensa

#### Scenario: Operación creada por el POS
- **WHEN** se borra una venta cuyos movimientos referencian el `id` de su `sales_order`
- **THEN** el sistema los encuentra y los compensa

#### Scenario: Operación editada antes de borrarse
- **WHEN** se borra una operación que fue editada, con movimientos originales, compensaciones y movimientos nuevos referenciando la misma operación
- **THEN** el sistema compensa sólo el neto vigente de cada libro
- **AND** no compensa dos veces lo que la edición ya había compensado

## ADDED Requirements

### Requirement: El borrado compensa la huella neta de cada libro
El sistema SHALL compensar, al borrar una venta, una compra o un gasto, la **huella neta** de la operación en cada libro —cuenta corriente, caja agrupada por caja y banco agrupado por cuenta bancaria—, con una compensación por cada fila de huella cuyo neto sea distinto de cero, por el importe exactamente opuesto y con **la misma referencia** que esa fila. SHALL NOT sumar sólo los movimientos del tipo original del documento, porque después de una edición una misma referencia acumula el movimiento original, su compensación y el movimiento nuevo.

El disparo por existencia y no por signo SHALL mantenerse sobre el neto: una huella neta distinta de cero SHALL compensarse cualquiera sea su signo, y una huella neta cero SHALL considerarse ya compensada.

Para los datos existentes al momento de este cambio, el borrado SHALL compensar los mismos libros y los mismos importes que antes: no existe ninguna referencia con movimientos en más de una sesión ni compensaciones parciales vivas. La única diferencia observable es la referencia de la compensación de una venta del POS, que pasa a ser la de su orden (la del movimiento que compensa) en vez del `operation_id`.

#### Scenario: Borrar una venta del POS editada
- **GIVEN** una venta del POS de 1000 en efectivo editada a 1200, con la reversión de 1000 y el movimiento de 1200 en la caja
- **WHEN** se borra
- **THEN** la caja recibe una reversión de 1200 en la sesión abierta y su huella neta queda en cero

#### Scenario: Borrar un gasto editado
- **GIVEN** un gasto en efectivo de 500 editado a 300
- **WHEN** se borra
- **THEN** la caja recibe una reversión de 300, y no de 800

#### Scenario: La compensación de caja agrupa por caja
- **GIVEN** una venta cuyo movimiento original está en una sesión cerrada y cuya reversión parcial por edición está en la sesión abierta de la misma caja
- **WHEN** se borra
- **THEN** se calcula un único neto para esa caja y se registra una única compensación en la sesión abierta

#### Scenario: Un borrado sobre datos sin ediciones no cambia
- **GIVEN** una operación sin ediciones con dinero
- **WHEN** se borra después de este cambio
- **THEN** los contra-movimientos registrados afectan los mismos libros por los mismos importes que antes de este cambio
