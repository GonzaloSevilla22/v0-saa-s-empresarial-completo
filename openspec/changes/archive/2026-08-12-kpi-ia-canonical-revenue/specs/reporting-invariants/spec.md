## ADDED Requirements

### Requirement: Enforcement de consumo — los invariantes obligan también a los consumidores
Ningún consumidor de negocio que exponga ingresos o ganancia neta a un usuario final SHALL recalcular esas cifras por fuera del read-model canónico que ya las resuelve (`rpc_dashboard_kpi_summary` para el dashboard y los caminos de IA, `rpc_period_comparison` para comparativos, `rpc_product_profitability` para rentabilidad por producto, `rpc_branch_report` para el reporte por sucursal, `rpc_cost_center_report` para costos por centro). Cuando un consumidor necesite un desglose que ningún read-model expone y deba agregar líneas localmente, SHALL sumar el revenue de línea con `COALESCE(total, amount)` a través de un helper canónico compartido de su runtime, nunca con una expresión escrita en el punto de uso. Toda excepción a esta regla SHALL quedar documentada en la spec de la capability que la introduce, con su motivo — como ya lo están el margen por canal sin NC y el margen de catálogo con costo actual.

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
