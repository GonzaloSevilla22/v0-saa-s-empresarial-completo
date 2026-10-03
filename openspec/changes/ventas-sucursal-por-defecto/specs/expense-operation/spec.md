## MODIFIED Requirements

### Requirement: La edición de un gasto preserva su contexto mediante contrato tri-estado

El sistema SHALL aplicar a la edición de un gasto el contrato tri-estado de edición de operaciones (capability `operation-edit-context`): la **ausencia** de una clave en la petición conserva el valor vigente, un **nulo explícito** desimputa, y un identificador **reimputa**. El contrato SHALL aplicarse a la forma de pago, la sucursal y el centro de costo.

El gasto conserva las tres intenciones también para la sucursal. La única excepción de ese contrato es la sucursal de una **venta**, que desde `ventas-sucursal-por-defecto` no admite quedar vacía: un nulo, informado o vigente, se registra en la sucursal principal. No alcanza al gasto.

Ningún campo de contexto SHALL perderse por omisión, ni en el alta ni en la edición. Este requisito cierra dos pérdidas silenciosas preexistentes: la sucursal se descartaba al crear y el centro de costo se borraba en cada edición.

El valor reimputado SHALL pertenecer a la misma cuenta y estar activo, con el mismo criterio de rechazo que el alta.

Reenviar el valor que el gasto **ya tiene** SHALL entenderse como preservación y SHALL NOT validarse como una reimputación: la superficie de edición envía siempre la forma de pago vigente y ofrece a propósito las formas dadas de baja para que un gasto histórico siga nombrando la suya, de modo que exigir que esté activa volvería inoperable todo gasto imputado a una forma de pago desactivada después. La pertenencia a la cuenta SHALL verificarse igual en los dos casos.

#### Scenario: Editar el importe conserva la forma de pago y el centro de costo

- **GIVEN** un gasto sin movimientos, con forma de pago y centro de costo imputados
- **WHEN** se edita únicamente su importe
- **THEN** la forma de pago y el centro de costo siguen siendo los mismos

#### Scenario: Desimputar la forma de pago explícitamente

- **WHEN** se edita un gasto enviando la forma de pago en nulo de forma explícita
- **THEN** el gasto queda sin forma de pago imputada

#### Scenario: Reimputar el centro de costo

- **WHEN** se edita un gasto informando otro centro de costo activo de la cuenta
- **THEN** el gasto queda imputado al centro nuevo

#### Scenario: El alta persiste la sucursal que el formulario envía

- **WHEN** un usuario crea un gasto eligiendo una sucursal en el formulario
- **THEN** el gasto queda persistido con esa sucursal
- **AND** el valor no se pierde entre el formulario y la base

#### Scenario: Editar un gasto imputado a una forma de pago desactivada

- **GIVEN** un gasto sin dinero posteado, imputado a una forma de pago que después se desactivó
- **WHEN** se edita cualquier otro campo del gasto reenviando su forma de pago vigente
- **THEN** la edición se aplica
- **AND** el gasto conserva su imputación histórica

#### Scenario: Reimputar a otra forma de pago inactiva sigue rechazándose

- **WHEN** se edita un gasto reimputándolo a una forma de pago distinta de la vigente que está inactiva
- **THEN** la operación es rechazada
- **AND** el gasto conserva su forma de pago anterior

#### Scenario: Reimputar a un valor de otra cuenta es rechazado

- **WHEN** se edita un gasto reimputándolo a una forma de pago, una sucursal o un centro de costo de otra cuenta
- **THEN** la operación es rechazada
- **AND** el gasto conserva sus valores anteriores

#### Scenario: El formulario de edición muestra el contexto vigente

- **WHEN** un usuario abre la edición de un gasto con sucursal, centro de costo y forma de pago imputados
- **THEN** los tres selectores aparecen con el valor vigente preseleccionado
