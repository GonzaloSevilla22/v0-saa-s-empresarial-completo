## ADDED Requirements

### Requirement: Fecha de negocio e instante son columnas distintas y se tratan distinto

Los read-models SHALL distinguir dos clases de columna temporal y aplicarles reglas opuestas:

- **Fecha de negocio declarada** — la fecha que el usuario elige al registrar el documento (`sales.date`, `purchases.date`, `expenses.date`). Aunque su tipo sea `timestamptz`, su contenido es un **día calendario**, persistido a medianoche UTC. Al derivar de ella un día, una semana, un mes o un día de la semana, SHALL usarse un casteo directo a fecha, y NOT SHALL aplicársele una conversión de zona horaria: la conversión desplaza cada fila un día hacia atrás y con ello todo bucket derivado.
- **Instante real** — el momento en que el hecho ocurrió en el sistema (`created_at` y equivalentes). Al derivar de él una hora o un día locales, SHALL convertirse a la zona local del tenant, conforme a RN-D5.

Ningún read-model SHALL derivar una **hora del día** de una fecha de negocio: esa columna no contiene hora, y hacerlo produce una distribución horaria degenerada en la que todas las operaciones caen en un mismo tramo.

Este requirement nace de un defecto real: aplicar la conversión de zona a una fecha de negocio hizo que el 100% de los productos de un read-model en producción informara su última venta un día antes del real. RN-D5 era correcto sobre instantes y silencioso sobre fechas de negocio, y esa omisión se leyó como permiso.

#### Scenario: El día de una fecha de negocio no se corre

- **GIVEN** una venta cuya fecha de negocio declarada es el 3 de septiembre
- **WHEN** un read-model deriva de ella el día, la semana, el mes o el día de la semana
- **THEN** el resultado corresponde al 3 de septiembre

#### Scenario: La hora local deriva del instante, no de la fecha de negocio

- **GIVEN** una operación con fecha de negocio de un día y registrada a las 14:00 hora local de otro
- **WHEN** un read-model informa la hora de la operación
- **THEN** informa las 14, derivadas del instante de registro

#### Scenario: La última fecha de actividad no se adelanta

- **GIVEN** un read-model que informa la fecha de la última venta de un producto
- **WHEN** se compara con la fecha de negocio de esa venta
- **THEN** coinciden exactamente, sin desplazamiento de un día

#### Scenario: Una distribución horaria degenerada delata la fuente equivocada

- **GIVEN** un read-model que informa operaciones por hora del día
- **WHEN** todas las operaciones de un período caen en una única hora
- **THEN** la métrica está derivada de una fecha de negocio y no cumple este requirement

## MODIFIED Requirements

### Requirement: Enforcement de consumo — los invariantes obligan también a los consumidores
Ningún consumidor de negocio que exponga ingresos o ganancia neta a un usuario final SHALL recalcular esas cifras por fuera del read-model canónico que ya las resuelve (`rpc_dashboard_kpi_summary` para el dashboard y los caminos de IA, `rpc_period_comparison` para comparativos, `rpc_product_profitability` para rentabilidad por producto, `rpc_branch_report` para el reporte por sucursal, `rpc_cost_center_report` para costos por centro, y los read-models del módulo de estadísticas de ventas —evolución temporal, desgloses por dimensión, top de clientes y ranking de productos— para las cifras que ese módulo expone). Cuando un consumidor necesite un desglose que ningún read-model expone y deba agregar líneas localmente, SHALL sumar el revenue de línea con `COALESCE(total, amount)` a través de un helper canónico compartido de su runtime, nunca con una expresión escrita en el punto de uso. Toda excepción a esta regla SHALL quedar documentada en la spec de la capability que la introduce, con su motivo — como ya lo están el margen por canal sin NC, el margen de catálogo con costo actual, y los desgloses por dimensión del módulo de estadísticas que no restan notas de crédito porque una nota de crédito no tiene producto, canal ni horario atribuible.

Los read-models que agregan **la misma** población de líneas de venta SHALL derivarla de un único helper canónico compartido en la base de datos, en lugar de repetir la expresión de filtrado y de revenue en cada uno: la duplicación de esa población es el mecanismo por el que dos pantallas del mismo sistema informan cifras distintas del mismo período.

Este requirement existe porque los invariantes RN-D describían lo que los read-models cumplen, y por lo tanto un consumidor podía violarlos sin violar la spec: fue exactamente lo que pasó con los cinco caminos de IA, que sumaban `amount` (precio unitario) y definían la ganancia como `ventas − gastos`, ignorando compras y notas de crédito.

#### Scenario: Un consumidor nuevo no reimplementa la ganancia neta
- **GIVEN** una pantalla o servicio nuevo que necesita mostrar la ganancia neta de un período
- **WHEN** se implementa
- **THEN** consume el read-model canónico que ya la calcula, en lugar de agregar ventas, gastos y compras por su cuenta

#### Scenario: Un desglose no cubierto por ningún read-model usa el helper canónico
- **GIVEN** un consumidor que necesita revenue por producto sobre una ventana que ningún RPC expone
- **WHEN** agrega las líneas localmente
- **THEN** suma `COALESCE(total, amount)` a través del helper canónico compartido de su runtime

#### Scenario: Consumidor y read-model no pueden disentir sobre el mismo período
- **GIVEN** dos superficies distintas que muestran los ingresos de la misma cuenta y el mismo período
- **WHEN** un usuario compara ambas
- **THEN** informan el mismo número, porque ambas derivan de la misma fila del mismo read-model

#### Scenario: Una excepción sin documentar es una violación
- **GIVEN** un consumidor que calcula una métrica financiera con una fórmula propia
- **WHEN** esa desviación no está documentada como excepción en la spec de su capability
- **THEN** incumple este requirement

#### Scenario: Dos read-models sobre la misma población comparten su definición
- **GIVEN** dos read-models que agregan la misma población de líneas de venta de un período
- **WHEN** se implementan
- **THEN** ambos derivan esa población del mismo helper canónico compartido, y no de dos expresiones equivalentes escritas por separado
