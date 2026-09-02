## MODIFIED Requirements

### Requirement: Vocabulario cerrado de `kind` compatible con las taxonomías existentes

El sistema SHALL restringir `payment_methods.kind` por CHECK al conjunto `{cash, transfer, card, check, wallet, credit, other}`, y ese CHECK SHALL ser el **único** lugar donde vive el vocabulario de formas de pago del sistema. El `name` SHALL ser la etiqueta que ve y edita el usuario; el `kind` SHALL ser lo único que consuman los subsistemas para razonar sobre la forma de pago. `sales_orders` NO SHALL tener una columna de texto con su propia copia del vocabulario: la forma de pago de una orden SHALL leerse siempre por `payment_method_id → payment_methods.kind`.

Ninguna función de registro de documentos SHALL conservar una taxonomía de formas de pago propia. En particular, las RPCs de cobro de cuenta corriente y de pago a proveedor —que hasta este cambio validaban un parámetro de texto contra el subconjunto propio `{cash, transfer, card, check}` escrito en su cuerpo— SHALL recibir un identificador del catálogo y derivar el `kind` de él. Con esa retirada, **ningún** subconjunto propio del vocabulario sobrevive en el sistema.

#### Scenario: `kind` fuera del vocabulario es rechazado

- **WHEN** se intenta persistir una forma de pago con `kind = 'crypto'`
- **THEN** la escritura es rechazada por el CHECK

#### Scenario: Renombrar no cambia la semántica

- **GIVEN** la forma de pago sembrada "Transferencia bancaria" con `kind = 'transfer'`
- **WHEN** el usuario la renombra a "Banco Nación"
- **THEN** el `kind` sigue siendo `transfer` y todo consumidor que agrupa por `kind` la sigue tratando como transferencia

#### Scenario: El vocabulario tiene una sola definición

- **WHEN** se inspecciona el schema en busca de CHECKs que enumeren formas de pago
- **THEN** existe únicamente `payment_methods_kind_check` con los 7 valores, y no existe ningún `sales_orders_payment_method_check`

#### Scenario: Las RPCs de cobro y pago no conservan su propia lista

- **WHEN** se inspecciona el cuerpo vivo de las funciones de registro de cobro de cuenta corriente y de pago a proveedor
- **THEN** ninguna contiene una enumeración literal de formas de pago
- **AND** ambas resuelven el `kind` consultando el catálogo por el identificador recibido

### Requirement: Superficies de la forma de pago

Toda superficie que ofrezca elegir o filtrar una forma de pago SHALL consumir el catálogo de la cuenta a través del **mismo componente selector**, y NO SHALL declarar una lista propia de opciones. El selector SHALL aceptar un **contexto** que determine qué formas de pago ofrece y qué texto de apoyo muestra, de modo que la variación por documento sea una extensión aditiva del componente único y nunca un selector paralelo.

Los contextos SHALL ser: venta, compra, gasto y **cobranza** —este último compartido por el cobro de una cuenta corriente de cliente y el pago a un proveedor, porque ambos ofrecen exactamente el mismo conjunto de formas de pago y difieren únicamente en la dirección del dinero—. En los contextos de gasto y de cobranza el selector NO SHALL ofrecer las formas de pago de `kind = 'credit'`.

El texto de apoyo SHALL describir el efecto real de la elección en el documento que se está registrando, incluyendo si el impacto en caja se ofrece marcado o desmarcado por defecto; una superficie NO SHALL afirmar que una forma de pago es una mera etiqueta cuando en ese camino produce un movimiento en algún libro.

#### Scenario: Alta de venta con el selector

- **WHEN** el usuario abre el formulario de alta de venta
- **THEN** ve el selector de forma de pago con las opciones activas de su cuenta, ordenadas por `sort_order`

#### Scenario: Alta de gasto con el selector

- **WHEN** el usuario abre el formulario de alta de gasto
- **THEN** ve el selector con las formas de pago activas de su cuenta, sin las de `kind = 'credit'`

#### Scenario: Cobro de cuenta corriente con el selector

- **WHEN** el usuario abre el modal de registro de un cobro de cuenta corriente
- **THEN** ve el selector con las formas de pago activas de su cuenta, con los nombres que él configuró, sin las de `kind = 'credit'`
- **AND** no ve ninguna lista fija de opciones ajena a su catálogo

#### Scenario: Pago a proveedor con el selector

- **WHEN** el usuario abre el modal de registro de un pago a proveedor
- **THEN** ve el mismo conjunto de opciones que en el modal de cobro, resuelto por el mismo componente y el mismo contexto

#### Scenario: Renombrar una forma de pago se refleja en la cobranza

- **GIVEN** un usuario que renombró "Transferencia bancaria" a "Banco Nación" en el gestor del catálogo
- **WHEN** abre el modal de cobro
- **THEN** la opción aparece como "Banco Nación"

#### Scenario: El texto de apoyo del efectivo en cobranza declara el valor inicial marcado

- **WHEN** el usuario elige en el modal de cobro o de pago una forma de pago de `kind = 'cash'`
- **THEN** el texto de apoyo dice que el movimiento se registra en la caja abierta salvo que se desmarque la afirmación
- **AND** no reutiliza la redacción del formulario de venta, cuya afirmación nace desmarcada

#### Scenario: El desplegable es operable dentro del modal

- **WHEN** el selector se despliega dentro del modal de cobro o de pago
- **THEN** la lista de opciones se desplaza dentro del modal y todas las opciones son alcanzables
- **AND** se comporta igual en escritorio y en móvil

#### Scenario: Presentación responsive y por tema en cobranza

- **WHEN** el modal de cobro o de pago se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** el selector usa los tokens semánticos del design system y es legible y operable en las cuatro combinaciones

## ADDED Requirements

### Requirement: Imputación de la forma de pago en cobros y pagos de cuenta corriente

El sistema SHALL imputar la forma de pago de un cobro de cuenta corriente y de un pago a proveedor mediante `payment_method_id`, con FK al catálogo de la cuenta, y SHALL derivar el `kind` en el servidor a partir de ese identificador. El `kind` NO SHALL aceptarse como dato del cliente por ningún camino.

La resolución del `kind` SHALL filtrar explícitamente por la cuenta del usuario: una forma de pago que no pertenezca al tenant SHALL rechazarse con el error de recurso no encontrado, con un mensaje que no revele si el identificador existe en otra cuenta.

Los `kind` admitidos SHALL ser seis de los siete del vocabulario: `cash` (impacto en caja bajo opt-in), `transfer`, `card`, `check` y `wallet` (movimiento bancario), y `other` (etiqueta sin efecto en ningún libro). El `kind = 'credit'` SHALL rechazarse con error de solicitud inválida, porque cancelar una cuenta corriente con cuenta corriente es circular: el cobro reduce la deuda de la parte y `credit` significa aumentarla. Ese rechazo SHALL sostenerse en el servidor **además** de no ofrecerse en la interfaz, de modo que la API no sea un bypass de la superficie.

La imputación SHALL ser opcional: un cobro sin forma de pago imputada SHALL registrarse normalmente, sin efecto sobre ningún libro de dinero, y los cobros anteriores a este cambio SHALL permanecer sin imputar, sin backfill.

#### Scenario: Cobro imputado a una forma de pago del catálogo

- **WHEN** se registra un cobro informando el identificador de una forma de pago activa de la cuenta
- **THEN** el cobro queda imputado a esa forma de pago y sus efectos se resuelven por el `kind` derivado del catálogo

#### Scenario: El kind no se acepta del cliente

- **WHEN** una solicitud de cobro informa un identificador de forma de pago junto con un texto que declara otro `kind`
- **THEN** el servidor ignora el texto y resuelve el `kind` del catálogo, o rechaza la solicitud
- **AND** los efectos aplicados son los del `kind` real de la forma de pago identificada

#### Scenario: Forma de pago de otro tenant es rechazada

- **GIVEN** el identificador de una forma de pago perteneciente a otra cuenta
- **WHEN** se registra un cobro informándolo
- **THEN** la operación falla con el error de recurso no encontrado
- **AND** no se inserta el cobro, ni el movimiento de cuenta corriente, ni ningún movimiento de dinero

#### Scenario: Cobro por billetera virtual

- **GIVEN** una forma de pago activa de `kind = 'wallet'` y una cuenta bancaria activa
- **WHEN** se registra un cobro imputado a ella
- **THEN** el cobro se registra y se crea un movimiento bancario de ingreso contra la cuenta indicada, en el mismo commit

#### Scenario: Cobro imputado a `other` no toca ningún libro

- **WHEN** se registra un cobro imputado a una forma de pago de `kind = 'other'`
- **THEN** el saldo de la parte se reduce, el cobro queda imputado a esa forma de pago
- **AND** no se crea ningún movimiento de caja ni bancario

#### Scenario: Cobro imputado a cuenta corriente es rechazado

- **WHEN** se registra un cobro imputado a una forma de pago de `kind = 'credit'`
- **THEN** la operación falla con error de solicitud inválida
- **AND** no se inserta el cobro ni ningún movimiento

#### Scenario: Cobro sin forma de pago imputada

- **WHEN** se registra un cobro sin informar forma de pago
- **THEN** el cobro se registra con la imputación vacía y sin efecto sobre ningún libro de dinero

#### Scenario: Los cobros entran al reporte de formas de pago

- **GIVEN** cobros imputados a distintas formas de pago del catálogo
- **WHEN** se consulta el reporte de distribución por forma de pago
- **THEN** los cobros se agrupan por su forma de pago imputada, igual que las ventas, las compras y los gastos
