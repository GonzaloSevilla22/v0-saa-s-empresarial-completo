## ADDED Requirements

### Requirement: Una operación con dinero registrado es editable
El sistema SHALL permitir editar una venta (del formulario, del POS o nacida de un presupuesto), una compra o un gasto aunque tenga un cargo en cuenta corriente, un movimiento de caja o un movimiento bancario registrado, y SHALL NOT rechazar la edición por el solo hecho de tener dinero registrado.

Los únicos bloqueos de la edición SHALL ser:

- el bloqueo fiscal de la venta (capability `afip-fiscal-document`: comprobante autorizado, enviado sin respuesta o congelado);
- los bloqueos que no son de dinero: la venta o la compra nacida de un remito, y la venta con conceptos de servicio de un presupuesto;
- las condiciones de negocio que el plan de la edición no puede cumplir (sesión de caja cerrada, saldo final negativo, período bancario conciliado, permiso), cada una con su propio código.

#### Scenario: Editar una venta a cuenta corriente
- **GIVEN** una venta a crédito con su cargo registrado en la cuenta corriente del cliente y sin comprobante fiscal
- **WHEN** se edita su cantidad
- **THEN** la edición se aplica, sin `P0423` por el cargo registrado

#### Scenario: Editar una compra con movimiento bancario
- **GIVEN** una compra por transferencia con su movimiento bancario registrado
- **WHEN** se edita su importe
- **THEN** la edición se aplica, sin `P0423` por el movimiento bancario

#### Scenario: Editar un gasto con movimiento de caja
- **GIVEN** un gasto en efectivo que descontó de la caja
- **WHEN** se edita su descripción
- **THEN** la edición se aplica, sin `P0423` por el movimiento de caja

#### Scenario: La venta con CAE sigue siendo inmutable
- **GIVEN** una venta con comprobante autorizado por ARCA
- **WHEN** se intenta editarla
- **THEN** la edición se rechaza con `P0423`, igual que hoy, y ningún libro cambia

### Requirement: La edición compara la huella vigente con el efecto deseado, libro por libro
El sistema SHALL calcular, para cada libro de dinero de la operación (cuenta corriente de la parte, caja y banco), la **huella vigente** y el **efecto deseado** por el estado editado, y SHALL NOT escribir en un libro donde los dos coincidan.

- La **huella vigente** es lo que la operación tiene neto en ese libro.
- El **efecto deseado** es lo que el estado editado tendría que tener, según las reglas del alta, la regla de herencia y las intenciones de la edición.
- Coinciden cuando la cuenta del libro y el importe neto son iguales. En cuenta corriente, además, la parte y el vencimiento. En banco, además, la fecha de la operación no cambió.

Cuando no coinciden, el sistema SHALL compensar la huella y registrar el efecto deseado en la **misma transacción** que la edición de las líneas y del stock, de modo que ningún fallo deje la operación editada con los libros a medio ajustar, ni los libros ajustados sobre una operación sin editar.

#### Scenario: Corregir la descripción de una venta en efectivo de la semana pasada
- **GIVEN** una venta en efectivo de hace siete días cuyo movimiento de caja está en una sesión ya cerrada, y ninguna sesión abierta en esa caja
- **WHEN** se edita sólo su cliente o su descripción
- **THEN** la edición se aplica sin escribir ningún movimiento de caja y sin exigir una sesión abierta

#### Scenario: Cambiar el importe mueve sólo los libros afectados
- **GIVEN** una venta por transferencia con movimiento bancario y sin cargo ni caja
- **WHEN** se edita su total de 1000 a 1200
- **THEN** el banco recibe el espejo de 1000 y un movimiento nuevo de 1200, y ni la caja ni la cuenta corriente reciben movimientos

#### Scenario: Todo o nada
- **WHEN** falla cualquier paso de la edición después de compensar un libro (por ejemplo, stock insuficiente al aplicar las líneas nuevas)
- **THEN** la transacción completa se revierte: la operación, el stock y todos los libros quedan como antes de la edición

### Requirement: La huella vigente es neta y tiene una sola definición
El sistema SHALL calcular la huella vigente de una operación como la **suma neta** de sus movimientos en cada libro, agrupada por cuenta del libro y por referencia, sobre todas las referencias de la operación, y SHALL usar **una única definición** de ese cálculo en la edición, en el borrado, en la vista previa y en los indicadores de los listados.

Referencias de la operación:

- venta: su `operation_id` y el identificador de su orden de venta, si la tiene;
- compra: su `operation_id`;
- gasto: su propio identificador;
- operación sin `operation_id`: sus identificadores de fila.

Tipos de movimiento que entran en el neto (son sólo los que referencian una operación):

- cuenta corriente: el cargo del documento y su reversión;
- caja: el movimiento del documento y su reversión, agrupados **por caja** y no por sesión;
- banco: todos los movimientos con el tipo de documento de la operación, agrupados por cuenta bancaria.

La compensación SHALL dispararse cuando el neto es distinto de cero, por el importe exactamente opuesto, cualquiera sea su signo. Un neto cero significa que la huella ya está compensada y SHALL NOT generar movimientos.

#### Scenario: Una venta editada dos veces y después borrada
- **GIVEN** una venta del POS de 1000 en efectivo, editada a 1200 y después a 900, con su caja ajustada en cada edición
- **WHEN** se borra
- **THEN** la caja recibe una única reversión neta de 900, y no la suma de los importes de tipo venta (3100)

#### Scenario: La caja de una operación repartida en dos sesiones
- **GIVEN** una venta cuyo movimiento original está en una sesión cerrada y cuya compensación por edición está en la sesión abierta de la misma caja
- **WHEN** se calcula su huella
- **THEN** la huella de caja es una sola fila por esa caja, con el neto de las dos sesiones

#### Scenario: Neto cero no genera movimientos
- **GIVEN** una operación cuya huella bancaria fue totalmente compensada por una edición anterior
- **WHEN** se la vuelve a editar o se la borra
- **THEN** no se registra ningún movimiento bancario por esa huella

### Requirement: La edición conserva el identificador de la operación
El sistema SHALL conservar el `operation_id` de una venta o de una compra al editarla, aunque sus filas se reemplacen.

- La única excepción es la operación sin `operation_id`, que SHALL recibir uno al editarse.
- El gasto ya conservaba su identificador y lo sigue haciendo.
- Toda búsqueda del asiento contable vigente de un documento SHALL excluir los contra-asientos, porque con un identificador estable el asiento nuevo y el contra-asiento de una edición anterior comparten referencia.

#### Scenario: El identificador sobrevive a la edición
- **GIVEN** una venta con `operation_id` X
- **WHEN** se edita
- **THEN** las filas resultantes tienen `operation_id` X, y una edición o un borrado posterior la encuentran por X

#### Scenario: La operación legacy recibe un identificador
- **GIVEN** una venta histórica sin `operation_id`
- **WHEN** se edita
- **THEN** las filas resultantes quedan con un `operation_id`, y su huella previa se busca por el identificador de fila

### Requirement: La edición no crea un efecto de dinero que la operación nunca tuvo
El sistema SHALL registrar un efecto en un libro donde la operación no tiene huella sólo en dos casos:

- la edición **cambia el contrato de pago**, es decir, la forma de pago final o la parte final (cliente o proveedor) es distinta de la vigente, comparada por valor y no por la presencia del campo en la solicitud;
- la solicitud trae una **intención explícita** para ese libro.

La exigencia de cliente o de proveedor para una forma de pago de cuenta corriente (`P0400`) SHALL evaluarse cuando el efecto deseado en cuenta corriente existe.

#### Scenario: Corregir la cantidad de una venta a crédito histórica sin cargo
- **GIVEN** una venta del formulario imputada a crédito y registrada antes de que el formulario posteara el cargo, sin movimiento en la cuenta corriente
- **WHEN** se edita su cantidad, reenviando la misma forma de pago y el mismo cliente
- **THEN** la edición se aplica y no se registra ningún cargo en la cuenta corriente del cliente

#### Scenario: Pasar una venta de efectivo a crédito postea el cargo
- **GIVEN** una venta en efectivo sin movimiento de caja, con cliente
- **WHEN** se edita a una forma de pago de cuenta corriente
- **THEN** se registra el cargo del total en la cuenta corriente del cliente

#### Scenario: Pasar a crédito sin parte es rechazado
- **WHEN** se edita una compra a una forma de pago de cuenta corriente sin proveedor
- **THEN** la edición se rechaza con `P0400 credit_requires_supplier` y la compra queda intacta

### Requirement: La cuenta corriente se ajusta registrando primero el cargo nuevo y su saldo final nunca es negativo
El sistema SHALL ajustar la cuenta corriente de una edición registrando primero el cargo nuevo y después la reversión de la huella, y SHALL rechazar la edición con `P0425` sólo cuando el saldo **final** de alguna cuenta corriente involucrada quedaría por debajo de cero.

- El mensaje SHALL indicar que primero hay que anular el cobro o el pago.
- Cuando la edición cambia de parte, las cuentas corrientes involucradas SHALL bloquearse en orden ascendente de identificador antes de cualquier escritura.
- El vencimiento SHALL seguir un contrato tri-estado:
  - ausente: conserva el del cargo vigente cuando la parte no cambia y no es anterior a la fecha de la operación; si no, se resuelve por la cascada de plazos;
  - presente con fecha: esa fecha, rechazada con `P0400` si es anterior a la fecha de la operación;
  - presente con nulo: cargo sin vencimiento.

#### Scenario: Subir el importe de una venta ya cobrada
- **GIVEN** una venta a crédito de 1000 totalmente cobrada (saldo del cliente 0)
- **WHEN** se edita a 1200
- **THEN** la edición se aplica y el saldo del cliente queda en 200, sin `P0425`

#### Scenario: Bajar el importe por debajo de lo cobrado
- **GIVEN** una venta a crédito de 1000 de la que el cliente ya pagó 800 (saldo 200)
- **WHEN** se edita a 500
- **THEN** la edición se rechaza con `P0425`, nombrando que hay que anular el cobro primero, y ni la venta ni la cuenta corriente cambian

#### Scenario: El vencimiento pactado se conserva
- **GIVEN** una venta a crédito con vencimiento el día 30
- **WHEN** se edita su cantidad sin informar vencimiento
- **THEN** el cargo nuevo vence el día 30

#### Scenario: Cambiar de cliente mueve el cargo
- **GIVEN** una venta a crédito cargada al cliente A, con saldo suficiente
- **WHEN** se edita al cliente B
- **THEN** la cuenta corriente de A recibe la reversión y la de B el cargo nuevo, en la misma transacción

### Requirement: La edición de efectivo expresa su intención en tres estados
El sistema SHALL aceptar la intención de caja de una edición en tres estados, distinguidos por la presencia del campo y no por su valor:

- **Ausente**: si la operación tiene huella de caja y su forma de pago final es efectivo, el efecto deseado es el total nuevo en la sesión abierta de la misma caja. Si la sucursal efectiva cambió, SHALL rechazarse con `P0422 cash_intent_required`, porque una sucursal puede tener varias cajas. En cualquier otro caso no hay efecto de caja.
- **Presente con una sesión**: registrar en esa sesión. SHALL validarse que la forma de pago final sea efectivo, que la sesión esté abierta, sea de la cuenta y sea de la sucursal efectiva. La fecha de hoy SHALL exigirse sólo si la operación no tenía huella de caja.
- **Presente con nulo**: sin efecto de caja. Si había huella, SHALL compensarse.

La validación SHALL vivir en una única función, compartida con el alta de venta, de compra y de gasto, con los mismos tokens de error que el alta.

#### Scenario: Pasar de efectivo a transferencia saca la venta de la caja
- **GIVEN** una venta en efectivo con movimiento de caja y una sesión abierta en esa caja
- **WHEN** se edita a una forma de pago de transferencia sin intención de caja
- **THEN** la caja recibe la reversión del importe, y no se registra ningún movimiento de caja nuevo

#### Scenario: Corregir el importe de una venta en efectivo de ayer
- **GIVEN** una venta en efectivo de ayer cuyo movimiento está en una sesión cerrada, y una sesión abierta hoy en la misma caja
- **WHEN** se edita su total de 1000 a 1200 sin intención de caja
- **THEN** la sesión de hoy recibe la reversión de 1000 y un movimiento de venta de 1200, sin rechazo por la fecha

#### Scenario: Agregar a la caja una venta retroactiva que nunca estuvo
- **GIVEN** una venta en efectivo de ayer sin movimiento de caja
- **WHEN** se edita informando la sesión abierta de hoy
- **THEN** la edición se rechaza con `P0422 cash_optin_requires_today`, igual que el alta

#### Scenario: Cambiar la sucursal de una venta en efectivo sin decir la caja
- **GIVEN** una venta en efectivo con movimiento de caja en la sucursal A
- **WHEN** se edita a la sucursal B sin intención de caja
- **THEN** la edición se rechaza con `P0422 cash_intent_required` y nada cambia

### Requirement: La edición bancaria expresa su intención en tres estados
El sistema SHALL resolver la cuenta bancaria del efecto deseado de una edición según si la solicitud la informa:

- **Ausente**:
  - si hay huella bancaria y la forma de pago final es bancaria, la misma cuenta bancaria de la huella;
  - si no hay huella y la edición cambió el contrato de pago, la resolución del alta (destino por defecto de la forma de pago);
  - en cualquier otro caso, sin efecto.
- **Presente**: esa cuenta, con las validaciones del alta. `P0412` si es ajena, inactiva o borrada; `P0400` si la forma de pago final no es bancaria.

#### Scenario: Corregir el importe conserva la cuenta bancaria
- **GIVEN** una compra por transferencia con movimiento en la cuenta Galicia
- **WHEN** se edita su importe sin informar cuenta bancaria
- **THEN** el espejo y el movimiento nuevo van a la cuenta Galicia

#### Scenario: Una cuenta bancaria con forma de pago no bancaria es rechazada
- **WHEN** se edita una venta a efectivo informando una cuenta bancaria
- **THEN** la edición se rechaza con `P0400` y nada cambia

### Requirement: El servidor calcula el plan de la edición antes de escribir y lo puede devolver sin aplicarlo
El sistema SHALL calcular, antes de cualquier escritura y con una única función, el **plan** de la edición. Para cada libro, el plan contiene:

- la huella y el efecto deseado;
- la acción: sin cambios, compensar, registrar, o compensar y registrar;
- importes, cuentas del libro, vencimiento y sesión de caja destino;
- los bloqueos de negocio: `P0426` sin sesión abierta, `P0425` saldo final negativo con el saldo proyectado, `P0424` período conciliado y `P0403` permiso.

Las tres ediciones SHALL aceptar un modo de vista previa:

- **En vista previa**: corren las mismas validaciones y devuelven el plan, con los bloqueos como datos, sin escribir nada.
- **Al aplicar**: vuelven a evaluar todo dentro de la transacción y levantan el código de cada bloqueo. Si el estado cambió entre la vista previa y la aplicación, SHALL prevalecer el resultado de la aplicación.

#### Scenario: Vista previa sin efectos
- **WHEN** se pide la vista previa de una edición que cambia el total de una venta a crédito
- **THEN** la respuesta enumera la reversión del cargo viejo y el cargo nuevo con el saldo proyectado, y no existe ningún movimiento ni fila de auditoría nuevos

#### Scenario: La vista previa anticipa la caja cerrada
- **GIVEN** una venta en efectivo cuyo importe cambia y ninguna sesión abierta en su caja
- **WHEN** se pide la vista previa
- **THEN** el plan informa el bloqueo de caja cerrada con el nombre de la caja, sin levantar un error

#### Scenario: El servidor dicta el resultado
- **GIVEN** una vista previa sin bloqueos
- **WHEN** antes de aplicar alguien cierra la caja involucrada
- **THEN** la aplicación se rechaza con `P0426` y la interfaz muestra ese rechazo

### Requirement: La edición sigue un orden fijo de pasos y de bloqueos
El sistema SHALL ejecutar la edición en este orden:

1. Tomar las filas de la operación con bloqueo exclusivo, en orden ascendente de identificador, y volver a contarlas (`P0404` si alguna desapareció).
2. Evaluar los guards que no son de dinero.
3. Resolver los valores finales y el plan.
4. Bloquear, en orden ascendente dentro de cada grupo, las cuentas corrientes, las sesiones de caja y las cuentas bancarias que el plan va a escribir.
5. Revertir y aplicar el stock.
6. Escribir el dinero: cuenta corriente, caja, banco.
7. Emitir los eventos.
8. Auditar.

Este orden SHALL respetar el orden global de locks de las operaciones de venta (filas de venta → orden de venta → comprobante fiscal → resto). La edición de compra SHALL ganar el bloqueo de filas que hoy no tiene, y la edición de gasto SHALL bloquear la fila del gasto.

#### Scenario: Doble guardado de una compra
- **GIVEN** dos ediciones concurrentes de la misma compra con dinero registrado
- **WHEN** la primera confirma
- **THEN** la segunda falla con `P0404` antes de escribir en cualquier libro, y el dinero no queda compensado dos veces

#### Scenario: Dos ediciones que cruzan clientes no se bloquean mutuamente
- **GIVEN** una edición que pasa una venta del cliente A al B y otra que pasa otra venta del B al A, al mismo tiempo
- **WHEN** las dos corren
- **THEN** ambas toman las cuentas corrientes en el mismo orden y terminan sin error de deadlock

### Requirement: Toda edición queda auditada con quién, cuándo y qué cambió
El sistema SHALL registrar cada edición de una venta, una compra o un gasto, con o sin dinero, en la tabla de auditoría, en la misma transacción. El registro contiene:

- la acción y la entidad (el identificador estable de la operación o del gasto);
- el usuario;
- el estado anterior y el resultante (cabecera, líneas resumidas, total, forma de pago, parte, fecha y sucursal);
- el plan de dinero ejecutado;
- el comprobante fiscal anulado, si lo hubo;
- el motivo opcional informado por el usuario.

El historial de ediciones de una operación SHALL poder leerse desde la aplicación, filtrado por la cuenta del usuario.

#### Scenario: La edición deja su rastro
- **WHEN** un usuario edita el total de una compra de 1000 a 1200 con el motivo "factura corregida"
- **THEN** existe una entrada de auditoría con ese usuario, el total anterior y el nuevo, los movimientos generados y el motivo

#### Scenario: Una edición rechazada no deja rastro
- **WHEN** una edición se rechaza por `P0425`
- **THEN** no existe ninguna entrada de auditoría nueva para ella

### Requirement: Corregir dinero ya registrado requiere dueño o administrador
El sistema SHALL exigir el rol de dueño o de administrador de la cuenta para aplicar una edición cuyo plan **escribe** en algún libro de dinero, y SHALL rechazarla con `P0403 money_edit_requires_admin` en otro caso. Una edición cuyo plan no escribe en ningún libro SHALL seguir con la autorización vigente.

El permiso SHALL estar declarado como una capacidad con nombre propio, espejada entre la base de datos, el backend y el frontend, y verificada por el test que ya ata esas tres fuentes.

#### Scenario: El cajero corrige la descripción de una venta en efectivo
- **GIVEN** un usuario con rol de cajero
- **WHEN** edita sólo la descripción de una venta en efectivo
- **THEN** la edición se aplica, porque el plan no escribe en ningún libro

#### Scenario: El cajero intenta bajar el importe de una venta en efectivo
- **GIVEN** un usuario con rol de cajero
- **WHEN** edita el total de una venta en efectivo con movimiento de caja
- **THEN** la edición se rechaza con `P0403 money_edit_requires_admin` y nada cambia

### Requirement: El listado expone el motivo de bloqueo de la edición como un token del servidor
El sistema SHALL exponer en los listados de ventas, compras y gastos un motivo de bloqueo de la edición (`edit_locked_reason`), calculado en el servidor con los mismos predicados que los guards, y SHALL retirar el indicador de bloqueo por dinero (`is_payment_locked`) de los tres contratos de lectura y de todos sus consumidores.

- Un token desconocido para la interfaz SHALL deshabilitar la edición igual (cierre por defecto).
- Los indicadores de cuenta corriente, caja y banco que alimentan los diálogos SHALL reflejar la huella neta.
- El listado SHALL exponer los datos vigentes que el formulario de edición necesita precargar: vencimiento y parte del cargo, caja de la huella y su sesión abierta, y cuenta bancaria de la huella.

#### Scenario: Una venta con cargo aparece editable
- **WHEN** el listado incluye una venta a crédito con cargo registrado y sin comprobante
- **THEN** la fila no trae motivo de bloqueo de la edición y "Editar" está habilitado

#### Scenario: Una venta de remito trae su motivo
- **WHEN** el listado incluye una venta nacida de un remito
- **THEN** la fila trae el motivo `delivery_note_sale_locked` y "Editar" está deshabilitado con su explicación

### Requirement: La superficie de edición muestra el plan antes de confirmar
La interfaz SHALL ofrecer en el formulario de edición de venta, de compra y de gasto los mismos bloques de pago que en el alta: cuenta corriente con saldo proyectado y vencimiento, caja con su estado y cuenta bancaria destino, precargados con el estado vigente de la operación. Antes de confirmar una edición que toca dinero, la interfaz SHALL mostrar el plan del servidor libro por libro.

- La redacción SHALL respetar el sentido real del movimiento: qué entra y qué sale de la caja.
- Ante un bloqueo, la interfaz SHALL deshabilitar la confirmación con el motivo visible y la acción que lo resuelve.
- El detalle de la operación SHALL mostrar su historial de ediciones.
- Todo SHALL usar los tokens semánticos del sistema de diseño y verificarse en escritorio y móvil, en tema claro y oscuro.

#### Scenario: Confirmar una edición de una venta a crédito
- **WHEN** el usuario guarda una venta a crédito cuyo total pasó de 1000 a 1200
- **THEN** ve, antes de confirmar, que se revierte el cargo de 1000, se registra uno de 1200 con su vencimiento y el saldo del cliente queda en el valor proyectado

#### Scenario: Edición sin dinero involucrado
- **WHEN** el usuario guarda una edición cuyo plan no cambia ningún libro
- **THEN** la edición se aplica sin el diálogo del plan

#### Scenario: Confirmación bloqueada por caja cerrada
- **WHEN** el plan informa que la caja de la venta no tiene sesión abierta
- **THEN** el diálogo muestra que hay que abrir esa caja y la confirmación queda deshabilitada

#### Scenario: Presentación responsive y por tema
- **WHEN** el formulario de edición, el diálogo del plan y el historial se muestran en escritorio o en móvil, en tema claro u oscuro
- **THEN** usan los tokens semánticos del sistema de diseño y son legibles y operables con teclado en las cuatro combinaciones
