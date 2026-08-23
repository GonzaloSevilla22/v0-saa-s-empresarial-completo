## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Autoría única del cargo en cuenta corriente

El sistema SHALL concentrar en un **único helper transaccional** la operación de cargar el importe de una operación a la cuenta corriente de una parte, y todo camino que registre una venta o una compra a crédito SHALL invocar ese helper en lugar de reimplementar la secuencia. El helper SHALL recibir la cuenta (tenant), el tipo de parte (`customer` o `supplier`), el identificador de la parte, el importe, la referencia de la operación y el identificador de operación; SHALL resolver o crear la cuenta corriente de la parte y registrar el movimiento reutilizando los helpers C-30 existentes; y SHALL emitir el evento de dominio correspondiente en el mismo commit. Ningún camino de alta SHALL duplicar esa secuencia inline.

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
