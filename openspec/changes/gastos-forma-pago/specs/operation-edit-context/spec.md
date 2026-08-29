## ADDED Requirements

### Requirement: El gasto con cargo posteado en caja o banco es inmutable

El sistema SHALL rechazar con el código de error `P0423` la edición de un gasto que tenga un movimiento de caja o un movimiento bancario asociado, evaluando los guards **antes** de cualquier escritura y con los mismos predicados de localización que usa el borrado.

El mensaje de error SHALL distinguir cuál de los dos libros produjo el bloqueo, con el mismo criterio con que ya se distinguen las causas en ventas y compras.

El camino de corrección SHALL ser borrar y volver a cargar. La alternativa de reescribir los libros con contra-movimientos automáticos SHALL NOT aplicarse a caja ni a banco: la caja es un conteo físico con arqueo firmado y el banco puede estar conciliado contra un extracto real, de modo que la corrección automática de esos libros agrega ruido al arqueo y a la conciliación en lugar de resolverlo. El criterio de contra-asiento automático permanece limitado al libro contable, que es derivado y de propiedad exclusiva del sistema.

Un gasto sin movimientos asociados SHALL seguir siendo plenamente editable.

#### Scenario: Editar un gasto con movimiento de caja es rechazado

- **GIVEN** un gasto en efectivo que descontó de una sesión de caja
- **WHEN** un usuario intenta editarlo
- **THEN** la operación es rechazada con `P0423`
- **AND** el mensaje indica que la causa es el movimiento de caja
- **AND** ni el gasto ni el movimiento se modifican

#### Scenario: Editar un gasto con movimiento bancario es rechazado

- **GIVEN** un gasto por transferencia que registró un egreso bancario
- **WHEN** un usuario intenta editarlo
- **THEN** la operación es rechazada con `P0423`
- **AND** el mensaje indica que la causa es el movimiento bancario

#### Scenario: Un gasto sin movimientos sigue siendo editable

- **GIVEN** un gasto sin forma de pago imputada
- **WHEN** un usuario edita su importe, su categoría, su descripción o su centro de costo
- **THEN** la edición procede normalmente

#### Scenario: La superficie anticipa el bloqueo

- **WHEN** un usuario ve en el listado un gasto con dinero posteado
- **THEN** el control de edición aparece deshabilitado
- **AND** la razón del bloqueo es visible, con el mismo patrón de lock que ya usan los listados de ventas y compras

#### Scenario: Borrar y recrear como camino de corrección

- **GIVEN** un gasto bloqueado por tener movimiento de caja, y la caja abierta
- **WHEN** el usuario lo borra y carga uno nuevo con el importe corregido
- **THEN** los libros quedan compensados por el borrado y vueltos a impactar por el alta nueva

### Requirement: La edición de un gasto preserva el contexto de su header

El sistema SHALL conservar, al editar un gasto, todos los campos de contexto que la edición no toca explícitamente: la sucursal, el centro de costo y la forma de pago. La omisión de una clave en la petición SHALL preservar el valor vigente y SHALL NOT interpretarse como una desimputación.

El alta SHALL persistir la sucursal que la superficie envía, en lugar de descartarla en el camino entre el formulario y la base.

Este requisito cierra dos pérdidas silenciosas preexistentes del módulo de gastos: la sucursal se descartaba en el alta y el centro de costo se borraba en cada edición, en los dos casos sin ningún error visible. Es el mismo defecto que ya se corrigió para ventas y compras.

#### Scenario: editar el importe conserva sucursal, centro de costo y forma de pago

- **GIVEN** un gasto sin movimientos, con sucursal, centro de costo y forma de pago imputados
- **WHEN** se edita únicamente su importe
- **THEN** la sucursal, el centro de costo y la forma de pago siguen siendo los mismos

#### Scenario: el alta conserva la sucursal elegida

- **WHEN** un usuario crea un gasto eligiendo una sucursal en el formulario
- **THEN** el gasto queda persistido con esa sucursal
- **AND** la sucursal no queda en nulo

#### Scenario: la edición no borra el centro de costo

- **GIVEN** un gasto con centro de costo imputado
- **WHEN** se edita cualquier otro campo sin mencionar el centro de costo
- **THEN** el centro de costo se conserva

#### Scenario: el formulario de edición muestra el contexto vigente

- **WHEN** un usuario abre la edición de un gasto con sucursal, centro de costo y forma de pago imputados
- **THEN** los tres selectores aparecen con el valor vigente preseleccionado

### Requirement: Sucursal, centro de costo y forma de pago del gasto son reimputables mediante contrato tri-estado

El sistema SHALL aceptar en la edición de un gasto el contrato tri-estado ya vigente en ventas y compras: la **ausencia** de la clave conserva el valor, un **nulo explícito** desimputa, y un **identificador** reimputa. El contrato SHALL implementarse distinguiendo los campos efectivamente presentes en la petición, y SHALL NOT apoyarse en filtrar los valores nulos, porque esa técnica vuelve indistinguibles la ausencia y la desimputación.

El valor reimputado SHALL pertenecer a la misma cuenta y estar activo, con el mismo criterio de rechazo que el alta.

#### Scenario: desimputar la forma de pago explícitamente

- **GIVEN** un gasto sin movimientos, con forma de pago imputada
- **WHEN** se lo edita enviando la forma de pago en nulo de manera explícita
- **THEN** el gasto queda sin forma de pago imputada

#### Scenario: omitir la forma de pago preserva la vigente

- **GIVEN** un gasto sin movimientos, con forma de pago imputada
- **WHEN** se lo edita sin incluir la clave de forma de pago en la petición
- **THEN** la forma de pago vigente se conserva

#### Scenario: reimputar la sucursal de un gasto

- **WHEN** se edita un gasto informando otra sucursal activa de la propia cuenta
- **THEN** el gasto queda imputado a la sucursal nueva

#### Scenario: reimputar a un valor ajeno o inactivo es rechazado

- **WHEN** se edita un gasto reimputándolo a una forma de pago, una sucursal o un centro de costo de otra cuenta, inactivo o dado de baja
- **THEN** la operación es rechazada
- **AND** el gasto conserva sus valores anteriores

### Requirement: El borrado de un gasto consulta los mismos locks que su edición

El sistema SHALL evaluar en el borrado de un gasto los mismos predicados de localización de movimientos que evalúa su edición, de modo que la superficie pueda derivar un único estado de bloqueo por gasto y no dos criterios que puedan divergir.

A diferencia de la edición, el borrado SHALL ser el camino permitido para un gasto con dinero posteado, aplicando su compensación; el único bloqueo propio del borrado SHALL ser la ausencia de una sesión de caja abierta cuando hay que revertir un egreso de efectivo.

#### Scenario: Gasto con dinero posteado

- **GIVEN** un gasto con movimiento de caja y la caja abierta
- **WHEN** un usuario intenta editarlo y luego borrarlo
- **THEN** la edición es rechazada y el borrado procede con su compensación

#### Scenario: Exposición del estado de bloqueo en el listado

- **WHEN** se lista un conjunto de gastos con y sin dinero posteado
- **THEN** cada fila expone si está bloqueada para edición y si es borrable
- **AND** los dos estados se derivan de los mismos predicados que evalúa el servidor
