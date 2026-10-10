## MODIFIED Requirements

### Requirement: El gasto persiste su sucursal

El sistema SHALL persistir `branch_id` en todo gasto nuevo **y en todo gasto editado**, resolviéndolo como la sucursal informada o, en su ausencia, la sucursal por defecto de la cuenta (`c26_default_branch`), el mismo criterio de resolución que ya usan el alta de venta y el alta de compra. La columna SHALL permanecer nullable para no invalidar los gastos históricos, que fueron creados por un camino que nunca la escribió.

Este requisito cumple RN-93 para el documento de gasto.

Los gastos históricos sin sucursal NO SHALL rellenarse en masa: toman sucursal sólo cuando un usuario los edita, por la regla del requirement «La edición de un gasto preserva su contexto mediante contrato tri-estado».

La resolución del gasto, en el alta y en la edición, NO SHALL rechazar el registro cuando la cuenta no tiene ninguna sucursal operativa: persiste lo que resuelva `c26_default_branch`, como el alta desde `gastos-forma-pago`. La venta y la compra, en cambio, sí rechazan ese estado con `no_branch_found`.

#### Scenario: Alta de gasto sin sucursal informada

- **WHEN** se crea un gasto sin informar sucursal
- **THEN** el gasto queda persistido con la sucursal por defecto de la cuenta

#### Scenario: Alta de gasto con sucursal informada

- **WHEN** se crea un gasto informando una sucursal activa de la propia cuenta
- **THEN** el gasto queda persistido con esa sucursal

#### Scenario: El gasto queda dentro del predicado de agregación por sucursal

- **GIVEN** un gasto nuevo imputado a una sucursal
- **WHEN** se agregan los gastos del período por sucursal
- **THEN** el gasto queda atribuido a esa sucursal

> El defecto del read-model del reporte por sucursal que este requirement señalaba al nacer (una referencia ambigua a la columna de sucursal) lo corrigió `qa-integral-modulos` (G4): el reporte ya muestra los gastos por sucursal.

#### Scenario: Los gastos históricos siguen siendo válidos sin sucursal

- **GIVEN** gastos anteriores a `gastos-forma-pago`, sin sucursal
- **WHEN** se listan y se leen
- **THEN** siguen siendo legibles y editables, con la sucursal en nulo mientras nadie los edite

#### Scenario: Editar un gasto histórico le asigna la principal

- **GIVEN** un gasto histórico sin sucursal ni dinero posteado, en una cuenta cuya sucursal principal es A
- **WHEN** se lo edita, cambiando sólo su importe
- **THEN** el gasto queda con la sucursal A y con el importe nuevo

### Requirement: La edición de un gasto preserva su contexto mediante contrato tri-estado

El sistema SHALL aplicar a la edición de un gasto el contrato tri-estado de edición de operaciones (capability `operation-edit-context`): la **ausencia** de una clave en la petición conserva el valor vigente, un **nulo explícito** desimputa, y un identificador **reimputa**. El contrato SHALL aplicarse a la forma de pago, la sucursal y el centro de costo.

**Excepción para la sucursal** (`compras-gastos-sucursal-por-defecto`): un gasto no puede quedar sin sucursal por una edición. La sucursal **presente con nulo** y la sucursal **ausente** cuyo valor vigente sea nulo SHALL resolverse a la sucursal por defecto de la cuenta, con la misma regla que el alta del gasto. La forma de pago y el centro de costo conservan las tres intenciones. La venta y la compra tienen la misma excepción para su sucursal (capability `operation-edit-context`).

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

#### Scenario: Informar la sucursal en nulo la registra en la principal

- **GIVEN** un gasto sin dinero posteado, imputado a la sucursal B, en una cuenta cuya sucursal principal es A
- **WHEN** se edita enviando la sucursal en nulo de forma explícita
- **THEN** el gasto queda imputado a A, y su forma de pago y su centro de costo no cambian

#### Scenario: Omitir la sucursal de un gasto sin sucursal le asigna la principal

- **GIVEN** un gasto sin sucursal y sin dinero posteado, en una cuenta cuya sucursal principal es A
- **WHEN** se edita sin incluir la sucursal en la petición
- **THEN** el gasto queda imputado a A

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
