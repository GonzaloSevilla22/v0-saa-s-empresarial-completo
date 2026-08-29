## ADDED Requirements

### Requirement: Los gastos por método bancario registran un bank_movement automático

El sistema SHALL registrar un movimiento bancario de egreso, atómico con el alta del gasto, cuando la forma de pago imputada al gasto sea de un `kind` bancario (`transfer`, `card`, `check`, `wallet`), usando `expense` como tipo de documento de origen y el identificador del gasto como referencia.

El registro SHALL delegarse en el **mismo helper transaccional de movimiento bancario de operaciones** que ya usan el alta de venta y el alta de compra, invocado de forma incondicional con sentido de egreso: el helper SHALL seguir siendo el único lugar donde viven el predicado de qué `kind` es bancario, la resolución de la cuenta destino, el mapeo a tipo de movimiento, el signo y el guard de período conciliado. SHALL NOT escribirse lógica bancaria nueva para el gasto.

El comportamiento del helper para venta y compra SHALL permanecer idéntico: el helper SHALL NOT modificarse.

La fecha valor del movimiento SHALL ser la fecha del gasto, y SHALL NOT quedar en nulo, para que el emparejamiento automático con el extracto opere sobre la fecha real del egreso.

#### Scenario: Gasto por transferencia debita el ledger bancario

- **GIVEN** una forma de pago de tipo transferencia con una cuenta bancaria destino resoluble
- **WHEN** se registra un gasto por ese medio
- **THEN** el ledger bancario de esa cuenta registra un egreso por el importe del gasto
- **AND** el movimiento queda con tipo de documento de origen `expense` y referencia al gasto
- **AND** el saldo posterior de la cuenta disminuye en ese importe

#### Scenario: Gasto con tarjeta se asienta bruto

- **WHEN** se registra un gasto con una forma de pago de tipo tarjeta y cuenta destino resoluble
- **THEN** el movimiento se registra con el tipo propio de liquidación de tarjeta, por el importe bruto del gasto

#### Scenario: Gasto en efectivo o sin forma de pago no toca el banco

- **WHEN** se registra un gasto en efectivo, o sin forma de pago imputada
- **THEN** no se registra ningún movimiento bancario

#### Scenario: El movimiento es atómico con el gasto

- **WHEN** la transacción del alta del gasto falla después de registrar el movimiento bancario
- **THEN** el movimiento bancario se revierte junto con el gasto
- **AND** ninguno de los dos queda persistido

#### Scenario: El movimiento del gasto no genera asiento contable por sí mismo

- **WHEN** un gasto registra su movimiento bancario
- **THEN** no se crea ningún asiento contable
- **AND** no se emite ningún evento al outbox

#### Scenario: Gasto retroactivo dentro de un período conciliado y cerrado

- **GIVEN** un período de conciliación cerrado para la cuenta bancaria destino
- **WHEN** se intenta registrar un gasto por transferencia con fecha dentro de ese período
- **THEN** la operación completa es rechazada
- **AND** ni el gasto ni el movimiento quedan persistidos

### Requirement: La cuenta bancaria del gasto no degrada en silencio cuando la organización tiene cuentas

El sistema SHALL rechazar con el código de error `P0412` el alta de un gasto cuya forma de pago sea de `kind` bancario y cuya cuenta bancaria destino no resuelva —ni por override explícito ni por el destino por defecto de la forma de pago— **cuando la organización tenga al menos una cuenta bancaria activa**.

Cuando la organización NO tenga ninguna cuenta bancaria activa, el gasto SHALL persistirse como etiqueta sin efecto bancario, y la superficie SHALL informar que ese gasto no va a aparecer en la conciliación.

El guard SHALL vivir en el camino de gasto y SHALL NOT alterar el comportamiento del helper compartido, que para venta y compra conserva el criterio vigente de continuar sin movimiento cuando la cuenta no resuelve.

El motivo SHALL ser que, con los destinos por defecto de las formas de pago sin configurar, la degradación silenciosa deja al gasto por transferencia fuera de la conciliación sin ningún aviso — lo contrario de lo que la funcionalidad promete.

#### Scenario: Organización con cuentas bancarias y gasto sin destino resuelto

- **GIVEN** una organización con al menos una cuenta bancaria activa y una forma de pago de transferencia sin destino por defecto
- **WHEN** se intenta registrar un gasto por ese medio sin informar cuenta destino
- **THEN** la operación es rechazada con `P0412`
- **AND** el mensaje indica que hay que elegir la cuenta bancaria de la que sale el dinero

#### Scenario: Organización sin ninguna cuenta bancaria

- **GIVEN** una organización sin ninguna cuenta bancaria activa
- **WHEN** se registra un gasto por transferencia
- **THEN** el gasto queda persistido con su forma de pago imputada
- **AND** no se registra ningún movimiento bancario
- **AND** la superficie informa que el gasto no va a aparecer en la conciliación

#### Scenario: El destino por defecto de la forma de pago evita el rechazo

- **GIVEN** una forma de pago de transferencia con destino bancario por defecto configurado
- **WHEN** se registra un gasto por ese medio sin informar cuenta destino
- **THEN** el movimiento se registra contra la cuenta por defecto
- **AND** no hay rechazo

#### Scenario: La venta sigue tolerando la cuenta no resuelta

- **GIVEN** una organización con cuentas bancarias activas y una forma de pago de transferencia sin destino por defecto
- **WHEN** se registra una venta por ese medio sin informar cuenta destino
- **THEN** la venta procede sin movimiento bancario, igual que antes de este cambio

#### Scenario: Cuenta bancaria de otra organización en un gasto

- **WHEN** se intenta registrar un gasto informando una cuenta bancaria que pertenece a otra organización
- **THEN** la operación es rechazada
- **AND** ningún movimiento queda registrado en la cuenta ajena

### Requirement: El movimiento bancario del gasto es conciliable sin piezas nuevas

El sistema SHALL hacer que el movimiento bancario originado por un gasto nazca en estado no conciliado y aparezca en la lista de movimientos pendientes de la conciliación de su cuenta por su sola existencia, sin ninguna tabla, RPC ni paso intermedio nuevo.

El emparejamiento automático SHALL poder engancharlo con la misma regla vigente de importe exacto y ventana de días alrededor de la fecha valor.

#### Scenario: El movimiento del gasto nace conciliable

- **WHEN** un gasto por transferencia registra su movimiento bancario
- **THEN** el movimiento aparece en la lista de pendientes de conciliar de esa cuenta
- **AND** su estado de conciliación es no conciliado

#### Scenario: La sugerencia automática engancha el movimiento del gasto

- **GIVEN** una línea de extracto por el mismo importe y con fecha dentro de la ventana de la fecha del gasto
- **WHEN** se piden las sugerencias de conciliación de la cuenta
- **THEN** la línea del extracto y el movimiento del gasto aparecen emparejados

### Requirement: Movimiento bancario espejo por borrado de un gasto

El sistema SHALL registrar un movimiento espejo de sentido invertido por cada movimiento bancario originado por un gasto que se borra, dentro de la misma transacción del borrado, con una descripción que identifique la reversión, y SHALL NOT modificar ni eliminar el movimiento original.

#### Scenario: Gasto pagado por transferencia

- **GIVEN** un gasto que registró un egreso bancario
- **WHEN** se borra el gasto
- **THEN** la cuenta bancaria registra un movimiento espejo de ingreso por el mismo importe
- **AND** el movimiento original queda intacto
- **AND** el saldo de la cuenta vuelve al valor previo al gasto

#### Scenario: Gasto sin movimiento bancario

- **WHEN** se borra un gasto que nunca registró un movimiento bancario
- **THEN** el borrado procede sin registrar ningún movimiento espejo

#### Scenario: El movimiento espejo queda pendiente de conciliar

- **WHEN** se registra el movimiento espejo del borrado de un gasto
- **THEN** su estado de conciliación es no conciliado
