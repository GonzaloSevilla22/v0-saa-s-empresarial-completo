## MODIFIED Requirements

### Requirement: No se da de baja una sucursal con contenido operativo adentro

El sistema SHALL rechazar todo intento de dar de baja una sucursal que tenga contenido operativo, sin escribir ningún cambio sobre la sucursal.

"Dar de baja" abarca las dos formas de baja que el sistema admite: la **desactivación** (la sucursal deja de existir a efectos operativos y desaparece de los selectores) y el **cierre operacional** (la sucursal existe pero no puede operar). Ambas sacan a la sucursal de la resolución de la sucursal por defecto de la cuenta, que es el mecanismo que convierte una baja descuidada en un inventario inalcanzable.

"Contenido operativo" SHALL abarcar cuatro cosas, evaluadas en este orden:

1. **Existencias**: alguna posición del inventario por sucursal con cantidad distinta de cero. El predicado SHALL ser *distinta de cero* y no *mayor que cero*: una cantidad negativa producto de una anomalía debe bloquear la baja, nunca autorizarla en silencio.
2. **Una sesión de caja abierta** en alguna caja de la sucursal. Desactivar la sucursal deja esa sesión imposible de cerrar desde la interfaz y sus movimientos huérfanos.
3. **Transferencias de stock sin completar** con la sucursal como origen o como destino.
4. **Remitos pendientes** (`issued`) de la sucursal, de cualquier sentido (venta o compra). Con la sucursal desactivada, el remito queda en una sucursal que desaparece de los selectores y de la resolución de la sucursal por defecto; con la sucursal cerrada, la conversión en venta la rechaza. En los dos casos, anularlo devolvería el stock a una sucursal que ya no opera. El rechazo SHALL nombrar la cantidad de remitos pendientes y la acción que destraba la baja (convertirlos o anularlos), con un motivo propio que la interfaz distingue de los otros tres. Un remito ya convertido o anulado NO SHALL bloquear.

La cuarta condición SHALL tener una única definición (un solo lugar que cuenta los remitos pendientes de una sucursal) y evaluarse en el único punto de decisión de la baja, que ya comparten el disparador y los comandos de desactivación y de cierre; NO SHALL evaluarse por separado en el disparador, y NO SHALL cambiar la firma de las funciones existentes del predicado. La pantalla de desactivación SHALL detectar los remitos pendientes antes de ofrecer la baja y enlazar al listado filtrado.

La verificación SHALL leer el **ledger canónico de stock por sucursal** que el sistema ya mantiene. SHALL NOT recalcularse a partir del stock agregado del catálogo ni escribirse una segunda definición de "cuánto hay en esta sucursal".

#### Scenario: Desactivar una sucursal con mercadería es rechazado

- **GIVEN** una sucursal activa con existencias distintas de cero en su inventario
- **WHEN** el owner de la cuenta la desactiva
- **THEN** la operación es rechazada y la sucursal sigue activa

#### Scenario: Desactivar una sucursal vacía funciona

- **GIVEN** una sucursal activa sin existencias, sin sesión de caja abierta y sin transferencias en vuelo
- **WHEN** el owner de la cuenta la desactiva
- **THEN** la sucursal queda inactiva

#### Scenario: Transferir el stock destraba la baja — el recorrido completo del incidente

- **GIVEN** una sucursal activa con existencias y otra sucursal activa de la misma cuenta
- **WHEN** se transfiere la totalidad de las existencias a la otra sucursal y recién entonces se desactiva la primera
- **THEN** la transferencia se completa y la desactivación es aceptada

#### Scenario: Una sesión de caja abierta bloquea la baja

- **GIVEN** una sucursal sin existencias pero con una sesión de caja abierta en una de sus cajas
- **WHEN** se intenta desactivarla
- **THEN** la operación es rechazada y el motivo informado es la sesión de caja, no las existencias

#### Scenario: Una transferencia sin completar bloquea la baja

- **GIVEN** una sucursal sin existencias con una transferencia de stock aún no completada donde figura como origen
- **WHEN** se intenta desactivarla
- **THEN** la operación es rechazada

#### Scenario: El cierre operacional queda sujeto al mismo predicado

- **GIVEN** una sucursal activa con existencias
- **WHEN** se la cierra operacionalmente
- **THEN** la operación es rechazada por el mismo motivo y con el mismo vocabulario de error que la desactivación

#### Scenario: Un remito pendiente bloquea la baja

- **GIVEN** una sucursal sin existencias, sin sesión de caja abierta ni transferencias en vuelo, con un remito de venta `issued` emitido desde ella
- **WHEN** se intenta desactivarla o cerrarla
- **THEN** la operación es rechazada con el mismo código de baja de sucursal, el mensaje nombra la cantidad de remitos pendientes y la salida disponible para resolverlos (anularlos, sólo un administrador o el dueño; con la conversión en venta, también convertirlos), y la sucursal sigue activa

#### Scenario: Un remito de compra pendiente también bloquea
- **GIVEN** una sucursal vacía con un remito de compra `issued`
- **WHEN** se intenta desactivarla
- **THEN** la operación es rechazada con el mismo motivo de remitos pendientes

#### Scenario: Un remito convertido o anulado no bloquea

- **GIVEN** una sucursal vacía cuyos remitos están todos convertidos o anulados
- **WHEN** se la desactiva
- **THEN** la desactivación es aceptada
