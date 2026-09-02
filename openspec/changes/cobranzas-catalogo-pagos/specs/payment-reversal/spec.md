## MODIFIED Requirements

### Requirement: Cada pata de compensación se dispara por la existencia del movimiento, nunca por su signo ni por la forma de pago declarada

El sistema SHALL decidir qué libro compensar consultando **si existe** el movimiento correspondiente al pago, y SHALL NOT condicionar la compensación a que ese movimiento tenga un signo determinado ni a la forma de pago registrada en el documento.

Condicionar al signo dejaría pasar sin compensar —y **sin levantar ningún error**— todo movimiento cuyo signo no fuera el esperado, que es precisamente el modo de falla silenciosa que el sistema ya sufrió. Condicionar a la forma de pago declarada no compensaría nada para los pagos registrados antes de que esa columna existiera, que son los únicos que hoy hay en el sistema, también sin error.

El predicado de existencia SHALL filtrar por el tipo de movimiento del **registro original** del pago, no por el de su reversa, de modo que una reversa no pueda auto-compensarse.

Esta independencia SHALL sostenerse **con independencia de cómo el documento persista su forma de pago**. En particular, la migración de la forma de pago desde una etiqueta de texto hacia una referencia al catálogo NO SHALL alterar el comportamiento de la anulación: las funciones de anulación NO SHALL leer la columna de forma de pago del documento por ningún camino, ni para decidir qué libro compensar, ni para calcular importes, ni para localizar el asiento contable a revertir. Un cambio en la persistencia de la forma de pago que exigiera modificar una función de anulación sería, por sí mismo, evidencia de que este requirement dejó de cumplirse.

#### Scenario: Pago sin forma de pago registrada compensa igual

- **GIVEN** un pago anterior a la persistencia de la forma de pago, con movimiento bancario asociado
- **WHEN** se anula
- **THEN** el movimiento bancario se compensa igual, porque el disparo depende de la existencia del movimiento y no de la etiqueta del documento

#### Scenario: Un movimiento de caja con signo inesperado se compensa igual

- **GIVEN** un pago cuyo movimiento de caja quedó registrado con un signo distinto del esperado para su tipo
- **WHEN** se anula
- **THEN** la compensación de caja se ejecuta igual, con el importe exactamente opuesto al registrado
- **AND** la anulación no procede jamás dejando el movimiento sin compensar

#### Scenario: Un pago sin movimiento de caja no exige caja

- **GIVEN** un pago bancario, o un pago en efectivo registrado sin impacto en caja
- **WHEN** se anula
- **THEN** la pata de caja no se dispara y la anulación no exige ninguna sesión de caja

#### Scenario: Un pago imputado a una forma de pago del catálogo se anula igual

- **GIVEN** un cobro en efectivo imputado a una forma de pago del catálogo, con movimiento de caja registrado y asiento contable posteado
- **WHEN** se anula
- **THEN** los cuatro libros se compensan igual que para un pago sin forma de pago imputada: contra-movimiento en la cuenta corriente, contra-movimiento de caja en la sesión abierta, espejo bancario si lo hubiera, y contra-asiento
- **AND** el resultado es idéntico al de anular un cobro sin imputar del mismo importe

#### Scenario: Un pago imputado a una forma de pago bancaria del catálogo compensa el banco

- **GIVEN** un cobro imputado a una forma de pago de `kind = 'wallet'`, con su movimiento bancario de ingreso
- **WHEN** se anula
- **THEN** se registra el movimiento bancario espejo con la dirección invertida sobre la misma cuenta
- **AND** el tipo de movimiento invertido se resuelve por el tipo del movimiento original, no por la forma de pago del documento

#### Scenario: Las funciones de anulación no referencian la forma de pago del documento

- **WHEN** se inspecciona el cuerpo vivo de las funciones de anulación de cobro y de pago
- **THEN** ninguna referencia la columna de forma de pago de `payments_received` ni de `payments_made`
- **AND** las cuatro patas de compensación se resuelven por la existencia de movimientos y por los campos de importe y de parte del documento
