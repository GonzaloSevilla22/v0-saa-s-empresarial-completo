## MODIFIED Requirements

### Requirement: La imputación de cobros es una derivación FIFO, no un estado almacenado

El sistema SHALL determinar qué parte de cada cargo permanece abierta **derivándola del ledger** en el momento de la consulta, y NO SHALL almacenar la imputación de cobros a cargos en ninguna tabla ni columna.

La derivación SHALL funcionar por línea de flotación: los cargos se ordenan del más viejo al más nuevo y el crédito disponible los cancela en ese orden, quedando parcialmente abierto aquel donde el crédito se agota y enteramente abiertos los posteriores.

SHALL considerarse **cargo** —y por lo tanto susceptible de estar abierto y vencido— el movimiento de venta (o de compra, del lado proveedor) y el ajuste de importe positivo. Todo otro movimiento SHALL contribuir al crédito disponible **con su propio signo**, de modo que un cobro y una nota de crédito lo aumentan y la anulación de un cobro lo disminuye.

**Emparejamiento de la reversión de un cargo**: el crédito de una reversión de cargo —`credit_note` del lado cliente, `debit_note` del lado proveedor— SHALL cancelar **primero los cargos de su misma referencia y de la misma cuenta corriente**, en el orden de la línea de flotación de esos cargos. Sólo el remanente, si lo hubiera, SHALL ir al crédito disponible general. Sin este emparejamiento, revertir el cargo de una venta editada o borrada cancelaría el cargo más viejo del cliente y no el propio, alterando el saldo abierto por cargo, los tramos de mora, el aviso diario de deuda vencida y el recordatorio al cliente. La regla SHALL aplicarse con la misma definición en todos los lugares que derivan la imputación: el historial de cuenta corriente, los paneles de cobranzas y de pagos, el aviso diario y el cambio de vencimiento de un cargo.

La anulación de un cobro NO SHALL crear un cargo nuevo: SHALL reducir el crédito disponible, con lo que los cargos que ese cobro había cancelado vuelven a abrirse en orden inverso al que se cerraron. Tratar la anulación como un cargo propio produciría un ítem abierto fechado el día de la anulación, rejuveneciendo la deuda.

La derivación SHALL satisfacer el **invariante de cierre**: la suma de los importes abiertos de todos los cargos de una cuenta corriente SHALL ser exactamente igual al saldo materializado de esa cuenta, cualquiera sea la combinación de tipos de movimiento presentes.

#### Scenario: Un cobro cancela el cargo más viejo

- **GIVEN** una cuenta corriente con un cargo de 1000 del día D y otro de 500 del día D+5
- **WHEN** se registra un cobro de 1000
- **THEN** el cargo del día D queda con importe abierto 0 y el del día D+5 queda abierto por 500

#### Scenario: Un cobro parcial deja un cargo parcialmente abierto

- **GIVEN** una cuenta corriente con un único cargo de 1000
- **WHEN** se registra un cobro de 400
- **THEN** ese cargo queda con importe abierto 600

#### Scenario: Anular un cobro reabre los cargos que había cancelado

- **GIVEN** una cuenta con cargos de 1000 y 500, y un cobro de 1200 ya imputado
- **WHEN** se anula ese cobro
- **THEN** el cargo de 1000 vuelve a estar abierto por 1000 y el de 500 por 500

#### Scenario: Una nota de crédito consume como un cobro

- **GIVEN** una cuenta con un cargo de 1000 y otro de 500, ambos abiertos, y una nota de crédito de 1000 que no comparte referencia con ninguno de los dos
- **WHEN** se deriva la imputación
- **THEN** el cargo más viejo queda con importe abierto 0

#### Scenario: La reversión de un cargo editado cancela su propio cargo

- **GIVEN** una cuenta con un cargo A de 500 del día D (otra venta) y un cargo B de 1000 del día D+3, ambos abiertos
- **WHEN** se edita la venta de B a 1200, dejando la reversión de 1000 y un cargo nuevo de 1200 con la referencia de B
- **THEN** A sigue abierto por 500, el cargo original de B queda en 0 y el cargo nuevo de B queda abierto por 1200

#### Scenario: Una cadena de ediciones deja abierto sólo el último cargo

- **GIVEN** una venta a crédito editada dos veces (1000 → 1200 → 900), con sus dos reversiones y sus tres cargos bajo la misma referencia
- **WHEN** se deriva la imputación sin cobros
- **THEN** sólo el cargo de 900 queda abierto, por 900

#### Scenario: El invariante de cierre se sostiene

- **GIVEN** una cuenta corriente con cualquier secuencia de cargos, cobros, notas, anulaciones, reversiones por edición y reversiones por borrado
- **WHEN** se derivan los importes abiertos de todos sus cargos
- **THEN** su suma es exactamente igual al saldo materializado de la cuenta corriente

#### Scenario: Un tipo de movimiento no previsto no descuadra el invariante

- **GIVEN** una cuenta corriente que contiene un movimiento de un tipo que no está clasificado como cargo
- **WHEN** se derivan los importes abiertos
- **THEN** ese movimiento contribuye al crédito disponible con su signo, no genera un ítem abierto propio, y el invariante de cierre se sigue cumpliendo
