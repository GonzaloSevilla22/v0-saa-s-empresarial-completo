# party-account-charge Specification

## Purpose
Helper transaccional único (`_pay_register_party_charge`) que concentra el cargo de una operación a crédito en la cuenta corriente de un tercero —cliente o proveedor— y su contraparte de reversión, para que ningún camino de alta o de borrado reimplemente la secuencia de resolver/crear la cuenta, registrar el movimiento y emitir el evento de dominio. Nace de `pagos-cableados-restantes` (2026-08-20) para que el formulario de venta a crédito y el mostrador produjeran el mismo cargo; extendido por `compras-proveedor-cuenta-corriente` para la compra a crédito. Es una función estrictamente interna: recibe la cuenta como parámetro (contrato deliberado, sus llamadores ya la resolvieron) y por eso no es ejecutable desde los roles de aplicación.
## Requirements
### Requirement: Autoría única del cargo en cuenta corriente

El sistema SHALL concentrar en un **único helper transaccional** la operación de cargar el importe de una operación a la cuenta corriente de una parte, y todo camino que registre una venta o una compra a crédito SHALL invocar ese helper en lugar de reimplementar la secuencia. El helper SHALL recibir la cuenta (tenant), el tipo de parte (`customer` o `supplier`), el identificador de la parte, el importe, la referencia de la operación, el identificador de operación **y, opcionalmente, un vencimiento explícito**; SHALL resolver o crear la cuenta corriente de la parte y registrar el movimiento reutilizando los helpers C-30 existentes; y SHALL emitir el evento de dominio correspondiente en el mismo commit. Ningún camino de alta SHALL duplicar esa secuencia inline.

El helper SHALL ser además el **único lugar donde se resuelve el vencimiento del cargo**: cuando no recibe vencimiento explícito, SHALL derivarlo de la cascada de plazos de pago de la parte y de la cuenta, y cuando lo recibe, SHALL usarlo tal cual. Los caminos de alta SHALL limitarse a transportar el vencimiento explícito que venga del payload, y NO SHALL resolver la cascada por su cuenta: replicarla en los tres caminos es exactamente la duplicación que este helper existe para impedir, y una divergencia entre ellos haría que la misma venta venciera distinto según se cargue desde el mostrador o desde el formulario.

El parámetro de vencimiento SHALL ser el **último y opcional** de la firma, de modo que su incorporación no desplace ningún argumento existente y un camino que aún no lo informe siga posteando un cargo válido, sin vencimiento, en lugar de fallar.

El par `(cuenta, parte)` que recibe el helper SHALL ser **coherente**: la parte SHALL pertenecer a la cuenta informada. El helper NO SHALL confiar en que su llamador lo haya verificado —los caminos de alta de venta y de compra reciben el identificador de la parte del payload del cliente y no lo validan—, y por lo tanto la verificación SHALL ocurrir en la resolución de la cuenta corriente, que es el paso por el que el helper pasa siempre. Una combinación incoherente SHALL abortar la transacción entera con el código de error de "parte no encontrada", sin dejar movimiento, evento ni operación de origen.

#### Scenario: La venta del mostrador y la del formulario producen el mismo cargo

- **GIVEN** un cliente sin cuenta corriente previa
- **WHEN** se registra una venta de 5000 a una forma de pago de `kind = 'credit'` desde el POS
- **AND** se registra otra venta de 5000 a `kind = 'credit'` desde el formulario de venta para el mismo cliente
- **THEN** ambos caminos producen un movimiento en `customer_account_movements` con el mismo signo, el mismo `type` y la misma semántica de `balance_after`, y el saldo del cliente queda en 10000

#### Scenario: El helper crea la cuenta corriente cuando no existe

- **GIVEN** un cliente sin fila en `customer_accounts`
- **WHEN** se postea un cargo por una venta a crédito de 3000
- **THEN** se crea la `customer_accounts` del cliente en el mismo commit y el movimiento queda asociado a ella con `balance_after = 3000`

#### Scenario: Un tipo de parte desconocido es rechazado

- **WHEN** se invoca el helper con un tipo de parte distinto de `customer` o `supplier`
- **THEN** la transacción falla con `invalid_party_kind` y no se registra ningún movimiento ni evento

#### Scenario: Una parte que no pertenece a la cuenta es rechazada

- **WHEN** se invoca el helper con una cuenta y una parte de tenants distintos
- **THEN** la transacción falla con el código de "parte no encontrada" y no se crea cuenta corriente, movimiento ni evento en ninguno de los dos tenants

#### Scenario: El helper resuelve la cascada cuando no recibe vencimiento

- **GIVEN** una cuenta con plazo por defecto de 30 días y un cliente sin plazo propio
- **WHEN** se invoca el helper sin vencimiento explícito para un cargo del día D
- **THEN** el movimiento queda con vencimiento en D+30

#### Scenario: El vencimiento explícito atraviesa el helper sin alterarse

- **WHEN** se invoca el helper con un vencimiento explícito
- **THEN** el movimiento queda con ese vencimiento, sin importar el plazo configurado para la parte o la cuenta

#### Scenario: Los dos caminos de venta vencen igual

- **GIVEN** un cliente con plazo efectivo de 15 días
- **WHEN** se registra una venta a crédito desde el mostrador y otra desde el formulario, ambas el mismo día y sin vencimiento explícito
- **THEN** los dos cargos quedan con el mismo vencimiento

#### Scenario: Sin plazo configurado el cargo se postea sin vencimiento

- **GIVEN** una cuenta sin plazo por defecto y una parte sin plazo propio
- **WHEN** se postea un cargo sin vencimiento explícito
- **THEN** el movimiento se registra correctamente con vencimiento nulo, y la operación no falla

### Requirement: El cargo y la operación comparten transacción

El sistema SHALL registrar el cargo en cuenta corriente en la **misma transacción** que la operación que lo origina, de modo que no exista un estado observable en el que la venta o la compra esté registrada y su cargo no, ni a la inversa. El evento de dominio del cargo SHALL insertarse en el outbox dentro de esa misma transacción.

#### Scenario: Un fallo posterior al cargo revierte el cargo

- **GIVEN** una venta a crédito en curso cuyo cargo ya fue posteado
- **WHEN** un paso posterior de la misma RPC falla
- **THEN** ni la venta, ni el movimiento en `customer_account_movements`, ni el evento quedan persistidos

#### Scenario: El evento del cargo viaja con la operación

- **WHEN** se registra una venta a crédito por cualquier camino
- **THEN** se inserta en `events` un evento del tipo correspondiente a la parte cargada, con el importe, el identificador de la cuenta corriente afectada y la referencia a la operación

### Requirement: El despacho por tipo de parte cubre cliente y proveedor

El sistema SHALL soportar en el mismo helper las dos partes del circuito —cliente (venta a crédito) y proveedor (compra a crédito)— resolviendo para cada una su par de helpers C-30, su origen de plazo de pago y su tipo de evento, sin que el llamador tenga que conocer qué tabla se toca. La incorporación de un camino de compra a crédito NO SHALL requerir un helper nuevo.

La resolución del plazo SHALL leerse de la parte que corresponda —el cliente para el cargo de venta, el proveedor para el de compra— con la misma cascada y el mismo significado de la ausencia de valor en ambos casos.

#### Scenario: El cargo a proveedor usa el mismo helper

- **GIVEN** un proveedor registrado en la cuenta
- **WHEN** se postea un cargo de 8000 con tipo de parte `supplier`
- **THEN** el movimiento se registra en `supplier_account_movements` sobre la `supplier_accounts` del proveedor y se emite el evento de cargo a proveedor

#### Scenario: La parte cliente no escribe en tablas de proveedor

- **WHEN** se postea un cargo con tipo de parte `customer`
- **THEN** no se inserta ninguna fila en `supplier_accounts` ni en `supplier_account_movements`

#### Scenario: El alta de compra a crédito despacha por el helper compartido

- **WHEN** se registra una compra imputada a una forma de pago de `kind = 'credit'` con proveedor
- **THEN** el cargo se resuelve invocando el helper compartido con tipo de parte `supplier`, y la RPC de alta de compra no contiene lógica propia de cuenta corriente

#### Scenario: Las dos partes producen la misma forma de movimiento

- **WHEN** se comparan el cargo producido por una venta a crédito y el producido por una compra a crédito del mismo importe
- **THEN** ambos son movimientos con signo positivo sobre la cuenta corriente de su parte, con `balance_after` calculado por el helper C-30 correspondiente y `reference_id` apuntando a la operación de origen

#### Scenario: Cada parte usa su propio plazo

- **GIVEN** un cliente con plazo de 30 días y un proveedor con plazo de 15, en la misma cuenta
- **WHEN** se postea un cargo de venta a ese cliente y uno de compra a ese proveedor, el mismo día
- **THEN** el primero vence a los 30 días y el segundo a los 15

### Requirement: Contraparte de reversión del cargo de tercero
El helper compartido de cargo en cuenta de tercero SHALL exponer una contraparte de reversión que atienda por igual a clientes y proveedores, de modo que el borrado de una venta y el de una compra reviertan su cargo por el mismo camino, sin lógica duplicada por dominio.

#### Scenario: Reversión de un cargo de cliente
- **WHEN** el borrado de una venta revierte su cargo de cuenta corriente
- **THEN** la reversión se resuelve por el helper compartido
- **AND** registra el movimiento negativo en la cuenta del cliente

#### Scenario: Reversión de un cargo de proveedor
- **WHEN** el borrado de una compra revierte su cargo de cuenta corriente
- **THEN** la reversión se resuelve por el mismo helper compartido
- **AND** registra el movimiento negativo en la cuenta del proveedor

#### Scenario: Tipo de tercero inválido
- **WHEN** se invoca la reversión con un tipo de tercero distinto de cliente o proveedor
- **THEN** el helper falla con el código de error `P0400`

### Requirement: Emisión del evento de reversión de cargo
El helper de reversión SHALL emitir el evento de dominio correspondiente a la reversión del cargo, para que los consumidores posteriores puedan reaccionar por el mismo mecanismo con que reaccionan al cargo original.

#### Scenario: Reversión de cargo de cliente
- **WHEN** se revierte el cargo de cuenta corriente de un cliente
- **THEN** se emite un evento de reversión con la cuenta, el cliente, la operación y el importe revertido

#### Scenario: Atribución del movimiento de reversión
- **WHEN** se registra un movimiento de reversión desde una sesión de usuario
- **THEN** el movimiento queda atribuido al usuario que ejecuta el borrado

### Requirement: El helper compartido de cargo no es alcanzable desde el rol de aplicación

El sistema SHALL mantener el helper compartido de cargo en cuenta de tercero como una función **estrictamente interna**: no SHALL ser ejecutable por los roles de aplicación (`anon`, `authenticated`), y su única forma de invocación SHALL ser desde funciones `SECURITY DEFINER` que ya resolvieron el tenant desde la sesión y verificaron el permiso de escritura.

El motivo es que el helper recibe la cuenta (tenant) **como parámetro** en lugar de resolverla de la sesión —es un contrato deliberado, porque sus llamadores ya la resolvieron—, y por lo tanto no valida ni SHALL validar por sí mismo el permiso del invocante. Mientras esa función sea ejecutable por el rol de aplicación, ese contrato se convierte en una primitiva de escritura entre tenants: cualquier usuario autenticado puede invocarla directamente por la API de datos con la cuenta de otro tenant y escribirle un movimiento, un saldo y un evento de dominio en sus libros reales.

La reafirmación de permisos que acompaña a cada redefinición del helper SHALL revocar explícitamente `anon` **y** `authenticated`, no solo el pseudo-rol público: el proyecto hospedado otorga permisos de ejecución a los roles de aplicación de forma directa, así que una revocación limitada al pseudo-rol público puede dejar la función abierta en producción aunque se vea cerrada en el entorno local. El helper de **reversión** de cargo ya cumple este requisito y es el patrón a replicar.

#### Scenario: El helper no es invocable por un usuario autenticado

- **GIVEN** una sesión de usuario autenticado
- **WHEN** intenta ejecutar directamente el helper compartido de cargo
- **THEN** la ejecución es rechazada por falta de permiso, y no se escribe ningún movimiento ni evento

#### Scenario: Un cargo con la cuenta de otro tenant es imposible de originar

- **GIVEN** un usuario del tenant A
- **WHEN** intenta invocar el helper directamente informando la cuenta del tenant B y un cliente del tenant B
- **THEN** la ejecución es rechazada por falta de permiso
- **AND** los libros del tenant B quedan sin cambios: sin movimiento, sin saldo alterado y sin evento de cargo

#### Scenario: Los caminos legítimos no se ven afectados

- **WHEN** se registra una venta a crédito desde el mostrador o desde el formulario
- **THEN** el cargo se postea normalmente, porque la invocación ocurre dentro de una función con privilegios de definidor y no depende del permiso del rol de sesión

