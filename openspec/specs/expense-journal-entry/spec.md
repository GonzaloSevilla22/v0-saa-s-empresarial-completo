# expense-journal-entry Specification

## Purpose
El asiento de partida doble que produce cada gasto, posteado por el Consumer 3 del outbox a partir de los eventos `ExpenseCreated`, `ExpenseAdjusted` y `ExpenseDeleted`. El alta debita `5300 Gastos` (con el centro de costo del gasto cuando lo tiene) y acredita `1100 Caja` o `1110 Banco` según la clase de la forma de pago, resuelta por una función de mapeo dedicada que es el espejo de la que gobierna el débito de la venta. La edición de un gasto asentado produce un contra-asiento más un asiento nuevo, y el borrado produce sólo un contra-asiento; ninguno de los dos vuelve inmutable al gasto, que sigue determinado únicamente por sus movimientos de dinero. Entregado en `asiento-contable-gastos` (2026-09-10) para cerrar D10 de `gastos-forma-pago`: el gasto era el último documento operativo que movía dinero real sin dejar rastro en el libro diario.
## Requirements
### Requirement: Todo gasto produce su asiento de partida doble por el outbox

El sistema SHALL postear un asiento de partida doble por cada gasto registrado, por el mismo mecanismo asincrónico que ya sirve a la venta, la compra, el cobro de cuenta corriente y el pago a proveedor: un evento emitido al outbox en la misma transacción que la mutación, y una rama del consumidor contable que lo postea.

El asiento SHALL producirse con independencia del camino de alta: el alta manual del formulario de gastos y el alta por lote del importador SHALL producir el mismo asiento para el mismo gasto, porque el productor vive en la operación atómica de alta y el importador la invoca en lugar de reimplementarla.

El sistema SHALL NOT insertar filas de asiento directamente desde el camino de alta: la escritura contable SHALL ocurrir únicamente en el consumidor, para que exista una sola definición de cómo se postea un gasto.

#### Scenario: Un gasto de alta manual queda asentado

- **WHEN** se registra un gasto desde el formulario y el relay procesa su evento
- **THEN** existe un asiento con el gasto como documento de origen, con sus líneas de débito y crédito, y el asiento balancea

#### Scenario: Un gasto importado queda asentado por el mismo camino

- **WHEN** se importa un lote de gastos y el relay procesa sus eventos
- **THEN** cada gasto del lote tiene su asiento, posteado por la misma rama que sirve al alta manual, sin ninguna lógica contable propia del importador

#### Scenario: El alta no escribe el asiento

- **WHEN** una operación de alta de gasto commitea
- **THEN** el evento existe en el outbox y todavía no hay asiento, que sólo aparece cuando el relay procesa ese evento

### Requirement: El evento del gasto se emite en la transacción de la mutación y sin manejador de excepciones

El sistema SHALL emitir el evento contable del gasto con una inserción plana al outbox, **dentro de la misma transacción** que registra el gasto y sus efectos en los libros de dinero, y SHALL NOT envolver esa inserción en un manejador de excepciones.

Tragarse un evento fallido mientras la mutación commitea dejaría el dinero movido en caja o banco y el libro diario sin el asiento correspondiente, en silencio y sin forma de recuperarlo — que es exactamente el modo de falla que la emisión transaccional existe para impedir.

El evento SHALL identificar el gasto como agregado y SHALL llevar en su carga todo lo que el consumidor necesita para postear sin volver a consultar el documento: la cuenta, el identificador del gasto, el importe, la fecha de negocio del gasto, el centro de costo cuando se imputó y la clase de forma de pago derivada del catálogo en el servidor.

#### Scenario: El evento acompaña al gasto

- **WHEN** un alta de gasto commitea
- **THEN** existe un evento de alta de gasto escrito en la misma transacción que la fila del gasto y que sus movimientos de caja o banco

#### Scenario: El evento se revierte con la mutación fallida

- **WHEN** un alta de gasto falla y revierte
- **THEN** no queda ningún evento de gasto, porque la inserción del evento comparte la transacción de la mutación

#### Scenario: La carga reporta la forma de pago real, incluida su ausencia

- **WHEN** se registra un gasto sin forma de pago imputada
- **THEN** la carga del evento reporta la ausencia de forma de pago en lugar de un valor por defecto, y es la rama del consumidor la que decide la cuenta resultante

### Requirement: El asiento del gasto debita la cuenta de gastos y arrastra su centro de costo

El asiento de alta de un gasto SHALL debitar una única línea a la cuenta de gastos del plan de cuentas del sistema, por el importe total del gasto.

Esa línea de débito SHALL llevar el centro de costo del gasto cuando el gasto lo tiene imputado, con el mismo trato que la línea de compras le da al centro de costo, para que la dimensión analítica del gasto llegue al libro diario sin una segunda definición.

El sistema SHALL NOT derivar la cuenta contable de la categoría del gasto. La categoría es texto libre en el almacenamiento —su lista cerrada existe únicamente en la interfaz— y un mapa de cuentas indexado por texto libre caería en su valor por defecto sin error visible ante cualquier categoría que llegue por otra vía. La dimensión analítica del gasto SHALL ser el centro de costo, que ya es un catálogo por cuenta y ya viaja en la línea del asiento.

#### Scenario: Gasto con centro de costo imputado

- **WHEN** se postea el asiento de un gasto que tiene centro de costo
- **THEN** la línea de débito a la cuenta de gastos lleva ese centro de costo

#### Scenario: Gasto sin centro de costo

- **WHEN** se postea el asiento de un gasto sin centro de costo imputado
- **THEN** la línea de débito a la cuenta de gastos se postea igual, sin centro de costo, y el asiento balancea

#### Scenario: Dos gastos de categorías distintas debitan la misma cuenta

- **GIVEN** dos gastos del mismo importe con categorías distintas
- **WHEN** se postean sus asientos
- **THEN** ambos debitan la misma cuenta de gastos, y lo que los distingue en el libro es su centro de costo, no su categoría

### Requirement: La contrapartida del gasto se deriva de la clase de forma de pago mediante una función de mapeo compartida

El crédito del asiento de alta SHALL determinarse a partir de la clase (`kind`) de la forma de pago imputada, resuelta en el servidor desde el catálogo de la cuenta, mediante una **función de mapeo dedicada** y no mediante una condición embebida repetida en cada rama.

El mapeo SHALL acreditar la cuenta de banco para las clases liquidadas por vía bancaria —transferencia, tarjeta, cheque y billetera— y la cuenta de caja para el resto, incluidas la clase efectivo, la clase otros y la ausencia de forma de pago imputada.

Este mapeo SHALL ser el espejo del que gobierna el débito de la venta para la misma clase: la venta debita donde el dinero entra y el gasto acredita donde el dinero sale, y para una misma clase de forma de pago ambos SHALL nombrar la misma cuenta.

La cuenta acreditada para las clases bancarias SHALL corresponder al libro que el gasto efectivamente mueve: el alta de un gasto de clase bancaria registra un movimiento en el ledger bancario, de modo que la cuenta acreditada nombra un hecho registrado y no una presunción.

La clase cuenta corriente SHALL NOT tener mapeo, porque el gasto la rechaza en el momento del alta: un gasto no tiene contraparte con cuenta corriente.

#### Scenario: Gasto por transferencia

- **WHEN** se postea el asiento de un gasto imputado a una forma de pago de clase transferencia
- **THEN** el crédito es a la cuenta de banco por el total, y el gasto tiene además su movimiento en el ledger bancario

#### Scenario: Gasto por billetera virtual

- **WHEN** se postea el asiento de un gasto imputado a una forma de pago de clase billetera
- **THEN** el crédito es a la cuenta de banco, igual que transferencia, tarjeta y cheque

#### Scenario: Gasto en efectivo

- **WHEN** se postea el asiento de un gasto imputado a una forma de pago de clase efectivo
- **THEN** el crédito es a la cuenta de caja por el total

#### Scenario: Gasto en efectivo sin registro en una sesión de caja

- **GIVEN** un gasto en efectivo registrado sin adhesión al registro en caja, o fuera de una sesión abierta
- **WHEN** se postea su asiento
- **THEN** el crédito es igualmente a la cuenta de caja, porque la adhesión gobierna el arqueo y no el hecho de que el efectivo salió

#### Scenario: Gasto sin forma de pago imputada

- **WHEN** se postea el asiento de un gasto sin forma de pago
- **THEN** el crédito es a la cuenta de caja, y no a la cuenta de proveedores: un gasto no tiene contraparte a la que deberle

#### Scenario: El mapeo es una función y no una condición repetida

- **WHEN** se inspecciona la definición vigente del consumidor contable
- **THEN** la resolución de la cuenta de contrapartida del gasto ocurre a través de la función de mapeo dedicada, invocable y verificable de forma aislada

### Requirement: El asiento del gasto se fecha por la fecha de negocio del gasto

El asiento de alta de un gasto SHALL fecharse con la **fecha de negocio del gasto**, no con el instante en que el relay lo procesa, para que el gasto pese en el período al que pertenece aunque su asiento se postee minutos u horas más tarde.

La fecha de negocio SHALL viajar en la carga del evento como fecha pura, sin componente horario ni zona, y SHALL convertirse a instante en la zona horaria del negocio y no en la de la sesión que corre el relay. Una conversión resuelta en la zona de la sesión corre el asiento un día en las franjas horarias de borde, que es un error silencioso y sistemático.

Cuando la carga del evento no informa fecha de negocio, el asiento SHALL fecharse en el instante del posteo.

#### Scenario: El asiento pertenece al período del gasto

- **GIVEN** un gasto fechado el último día de un mes cuyo evento se procesa al día siguiente
- **WHEN** se postea su asiento
- **THEN** el asiento queda fechado en el día del gasto y no en el día del posteo

#### Scenario: Un gasto cargado en la franja de borde no corre de día

- **GIVEN** un gasto fechado hoy y registrado en la franja nocturna en que la hora local y la hora universal caen en días distintos
- **WHEN** se postea su asiento
- **THEN** el asiento queda fechado en el mismo día del gasto

### Requirement: La edición de un gasto ajusta su asiento en lugar de invalidarlo

Editar un gasto que ya tiene asiento SHALL producir un **par contra-asiento más asiento nuevo**: el asiento vigente se revierte con una entrada de lados invertidos y queda marcado como revertido, y se postea uno nuevo con los valores resultantes de la edición.

El asiento posteado SHALL NOT volver inmutable al gasto. Un gasto sin movimientos de dinero asociados SHALL seguir siendo plenamente editable, con la misma regla que ya rige para la operación de venta: la inmutabilidad la determinan los movimientos de dinero, no la existencia de un asiento.

El contra-asiento SHALL fecharse en el momento de la corrección y no en la fecha del gasto original: la corrección data la corrección.

Si al procesar el evento de edición no se encuentra el asiento vigente del gasto, el consumidor SHALL fallar de forma recuperable, dejando el evento pendiente para reintento, y SHALL NOT postear un asiento nuevo huérfano.

#### Scenario: Editar el importe de un gasto asentado

- **GIVEN** un gasto sin movimientos de dinero, con su asiento posteado
- **WHEN** se edita su importe y el relay procesa el evento
- **THEN** el asiento original queda marcado como revertido, existe un contra-asiento que lo referencia, y existe un asiento nuevo por el importe editado
- **AND** los tres asientos balancean

#### Scenario: Editar un gasto no lo bloquea por tener asiento

- **GIVEN** un gasto sin movimiento de caja ni bancario, con asiento posteado
- **WHEN** se edita su categoría
- **THEN** la edición procede normalmente

#### Scenario: El contra-asiento de edición se fecha en la corrección

- **WHEN** se postea el par de una edición
- **THEN** el contra-asiento queda fechado en el momento de la corrección, mientras el asiento nuevo conserva la fecha de negocio del gasto

#### Scenario: Edición procesada antes que el alta

- **GIVEN** un evento de edición cuyo evento de alta todavía no se procesó
- **WHEN** el relay intenta procesar la edición
- **THEN** falla de forma recuperable, el evento queda pendiente, el lote continúa, y en la corrida siguiente —ya posteada el alta— el par se postea correctamente

### Requirement: El borrado de un gasto produce su contra-asiento

Borrar un gasto que tiene asiento SHALL postear un **contra-asiento**: una entrada única con los lados invertidos del asiento vigente, que lo referencia, y el asiento original SHALL quedar marcado como revertido.

El borrado SHALL NOT eliminar filas del libro diario. El libro es de sólo agregado y se corrige por contra-asiento, igual que los ledgers de stock, caja, banco y cuentas corrientes.

El contra-asiento SHALL poder postearse aunque el documento del gasto ya no exista, porque el borrado del gasto es físico: el consumidor SHALL localizar el asiento vigente por la referencia al documento que el propio asiento conserva, sin consultar la fila borrada.

El contra-asiento SHALL fecharse en el momento del borrado.

#### Scenario: Borrar un gasto asentado

- **GIVEN** un gasto con su asiento posteado
- **WHEN** se borra el gasto y el relay procesa el evento
- **THEN** el asiento original queda marcado como revertido y existe un contra-asiento que lo referencia, con los mismos importes y los lados invertidos
- **AND** el contra-asiento balancea

#### Scenario: El contra-asiento sobrevive a la desaparición del documento

- **GIVEN** un gasto borrado, cuya fila ya no existe
- **WHEN** el relay procesa el evento de borrado
- **THEN** el contra-asiento se postea, localizando el asiento vigente por la referencia al documento y sin consultar la fila borrada

#### Scenario: El libro diario no pierde filas por un borrado

- **WHEN** se borra un gasto asentado
- **THEN** ni el asiento original ni sus líneas se eliminan; el asiento queda marcado como revertido y acompañado de su contra-asiento

### Requirement: Los eventos de edición y borrado se emiten sólo para gastos que tienen evento de alta

El sistema SHALL emitir el evento de edición y el de borrado de un gasto **únicamente cuando existe un evento de alta para ese mismo gasto**. Un gasto anterior a la puesta en marcha del asiento contable no tiene evento de alta, y SHALL editarse y borrarse sin emitir ningún evento contable.

El predicado SHALL evaluarse sobre la **existencia del evento de alta**, y SHALL NOT evaluarse sobre la existencia del asiento. La distinción es sustantiva: un gasto creado y borrado antes de que el relay corra tiene su evento de alta sin procesar y todavía no tiene asiento, y debe emitir igualmente su evento de borrado; el relay procesa los eventos en orden de ocurrencia, de modo que el alta se postea antes que el borrado, y si quedaran en corridas distintas el fallo recuperable del consumidor resuelve el orden por reintento.

Sin este predicado, borrar un gasto histórico emitiría un evento cuyo asiento original no existe ni existirá, que fallaría de forma recuperable en **cada corrida del relay, indefinidamente**, sin ninguna señal visible fuera de los registros internos.

#### Scenario: Borrar un gasto histórico no emite evento

- **GIVEN** un gasto anterior a la puesta en marcha del asiento contable, sin evento de alta
- **WHEN** se lo borra
- **THEN** el borrado procede normalmente y no se emite ningún evento contable de gasto

#### Scenario: Editar un gasto histórico no emite evento

- **GIVEN** un gasto sin evento de alta
- **WHEN** se lo edita
- **THEN** la edición procede normalmente y no se emite ningún evento contable de gasto

#### Scenario: Borrar un gasto recién creado sí emite evento

- **GIVEN** un gasto creado y borrado antes de que el relay procese su evento de alta
- **WHEN** se lo borra
- **THEN** se emite el evento de borrado, porque el evento de alta existe aunque su asiento todavía no
- **AND** al procesarse ambos en orden de ocurrencia, el asiento se postea y su contra-asiento a continuación

### Requirement: El posteo del asiento del gasto es idempotente y su fallo no aborta el lote

El posteo del asiento de un gasto SHALL ser idempotente respecto del evento que lo origina: reprocesar el mismo evento SHALL NOT producir un segundo asiento.

Un fallo de posteo —un asiento que no balancea, o un evento de corrección cuyo asiento original todavía no está— SHALL dejar el evento sin marcar como procesado, para reintento en la corrida siguiente, y SHALL NOT abortar el procesamiento del resto del lote.

Todo asiento de gasto SHALL satisfacer la igualdad entre la suma de débitos y la suma de créditos antes de darse por posteado.

#### Scenario: Reprocesar el evento no duplica el asiento

- **WHEN** el mismo evento de gasto se despacha al consumidor contable dos veces
- **THEN** existe exactamente un asiento para ese evento

#### Scenario: Un asiento que no balancea deja el evento para reintento

- **WHEN** el posteo del asiento de un gasto no satisface la igualdad de débitos y créditos
- **THEN** el evento queda pendiente, el lote continúa procesando el resto de los eventos, y no queda ningún asiento parcial vigente

### Requirement: El estado contable del gasto es visible en la superficie de gastos

La pantalla de gastos SHALL exponer, por gasto, su estado contable, en **todas** sus renderizaciones —la tabular de escritorio y la de tarjetas en pantallas angostas— y en los temas claro y oscuro.

El estado SHALL distinguir tres situaciones y SHALL NOT confundirlas: el gasto **asentado**, el gasto con evento emitido y **pendiente de posteo**, y el gasto **sin asiento** por ser anterior a la puesta en marcha.

El estado pendiente SHALL comunicarse como una espera normal y SHALL NOT presentarse como un error: el posteo es asincrónico por diseño y un lote de importación se asienta de a tandas. El estado sin asiento SHALL comunicarse como una condición legítima de los gastos históricos y SHALL NOT presentarse como un fallo.

El estado contable SHALL derivarse en el servidor y viajar como dato del gasto, con el mismo tratamiento que los demás derivados de estado del gasto, y SHALL NOT reconstruirse en el cliente con consultas por fila.

Desde el gasto asentado SHALL poder llegarse a su asiento en el libro diario.

#### Scenario: Un gasto asentado se distingue de uno pendiente

- **GIVEN** un gasto ya posteado y otro con su evento sin procesar
- **WHEN** se listan los gastos
- **THEN** cada uno muestra su estado contable y los dos estados se distinguen entre sí

#### Scenario: El estado se ve en pantalla angosta

- **WHEN** se abre la lista de gastos en un ancho de móvil
- **THEN** el estado contable de cada gasto es visible en la tarjeta, sin desbordar horizontalmente

#### Scenario: Un gasto histórico no aparenta un fallo

- **GIVEN** un gasto anterior a la puesta en marcha del asiento contable
- **WHEN** se lo lista
- **THEN** su estado indica que no tiene asiento por ser anterior, con un tono neutro y no de error

#### Scenario: Desde el gasto se llega a su asiento

- **WHEN** se acciona el estado contable de un gasto asentado
- **THEN** se llega al libro diario mostrando el asiento de ese gasto

### Requirement: El libro diario tiene pantalla propia y consultable

El sistema SHALL exponer el libro diario en una pantalla propia, alcanzable desde la navegación principal, que liste los asientos con su fecha, su documento de origen, su estado y sus líneas de débito y crédito.

La pantalla SHALL permitir acotar la consulta por rango de fechas, por tipo de documento de origen y por estado del asiento, y SHALL permitir mostrar los asientos de un documento determinado.

La pantalla SHALL consumir el endpoint de lectura de asientos ya existente, extendido con esos criterios, y SHALL NOT dar lugar a un endpoint paralelo que devuelva los mismos asientos.

La pantalla SHALL estar disponible en todos los planes, con el mismo criterio que las demás lecturas de datos que el propio usuario generó, y SHALL respetar el alcance por cuenta que las políticas de acceso ya imponen sobre los asientos.

#### Scenario: Consultar el libro diario

- **WHEN** un miembro de la cuenta abre el libro diario
- **THEN** ve los asientos de su cuenta ordenados del más reciente al más antiguo, con sus líneas de débito y crédito

#### Scenario: Acotar por período y por tipo de documento

- **WHEN** se acota la consulta a un rango de fechas y a los asientos originados en gastos
- **THEN** la lista muestra sólo los asientos de gasto de ese período

#### Scenario: Ver el asiento de un documento

- **WHEN** se consulta el libro diario por un gasto determinado
- **THEN** se muestran el asiento vigente de ese gasto y, si los hubiera, sus contra-asientos

#### Scenario: Un asiento revertido se distingue de uno vigente

- **GIVEN** un gasto borrado, con su asiento revertido y su contra-asiento
- **WHEN** se consulta el libro diario
- **THEN** el asiento original se muestra como revertido y el contra-asiento como vigente, y la distinción es visible sin abrir cada uno

#### Scenario: La consulta no cruza cuentas

- **WHEN** un miembro de una cuenta consulta el libro diario
- **THEN** no ve ningún asiento de otra cuenta
