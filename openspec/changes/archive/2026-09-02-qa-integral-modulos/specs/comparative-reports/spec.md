# comparative-reports — Delta

## MODIFIED Requirements

### Requirement: Página `/reportes/comparativo` con KPIs, chart y análisis IA

El sistema SHALL proveer la página `/reportes/comparativo` con:
- Selectores de fecha para dos períodos (Período A y Período B); por defecto: **Período A = mes anterior (la base de comparación), Período B = mes en curso**, respetando el contrato de `rpc_period_comparison` que calcula los deltas como `(B − A) / A` con A como base; el rango máximo seleccionable respeta `historyDays` del plan.
- Cuatro cards de KPI (ventas, gastos, compras, operaciones): valor en Período A, valor en Período B, delta % con badge verde/rojo. El badge SHALL estar rotulado con qué mide (la evolución del Período A al Período B), de modo que el usuario sepa la dirección temporal del porcentaje.
- BarChart agrupado (Recharts) con dos barras por métrica (una por período).
- Panel con el último insight IA (type=`'comparativo'`) y botón "Analizar con IA".
- Gating: solo accesible para `'avanzado'` y `'pro'`; para planes inferiores muestra `PlanGateFallback`.

El signo y el color del delta SHALL describir la evolución real del negocio del período más viejo al más nuevo: métricas que suben entre A y B muestran signo positivo (verde para ventas; rojo para gastos y compras, que invierten el semáforo).

#### Scenario: Usuario avanzado ve el reporte comparativo completo

- **GIVEN** un usuario con plan efectivo `'avanzado'`
- **WHEN** navega a `/reportes/comparativo`
- **THEN** ve los KPI cards con deltas, el BarChart agrupado y el panel de análisis IA

#### Scenario: Usuario gratis ve el componente de upgrade

- **GIVEN** un usuario con plan efectivo `'gratis'`
- **WHEN** navega a `/reportes/comparativo`
- **THEN** ve `PlanGateFallback` con CTA al plan Avanzado y no accede al contenido del reporte

#### Scenario: Con los defaults, gastos que subieron se muestran en rojo con signo positivo

- **GIVEN** un tenant cuyos gastos del mes en curso superan a los del mes anterior
- **WHEN** carga la página sin tocar los selectores
- **THEN** el badge de gastos muestra un porcentaje positivo en rojo (subieron), nunca un porcentaje negativo en verde

#### Scenario: Delta positivo en ventas se muestra en verde, negativo en rojo

- **GIVEN** un usuario avanzado con el período nuevo (B) con más ventas que el período base (A)
- **WHEN** carga la página
- **THEN** el badge de delta de ventas es verde con el valor `+X%`; si el período nuevo tiene menos ventas, el badge es rojo con `-X%`

#### Scenario: Delta NULL se muestra como "N/A"

- **GIVEN** el período A no tiene ventas (división por cero en el RPC)
- **WHEN** carga la página
- **THEN** el badge de delta de ventas muestra "N/A" en lugar de un porcentaje

#### Scenario: Selector de fechas respeta el historial máximo del plan

- **GIVEN** un usuario `'avanzado'` con `historyDays = 180`
- **WHEN** intenta seleccionar una fecha anterior a 180 días
- **THEN** el date picker deshabilita esas fechas y no permite seleccionarlas

#### Scenario: Advertencia cuando los períodos se solapan

- **GIVEN** el usuario selecciona períodos que comparten días
- **WHEN** carga los datos
- **THEN** se muestra un banner de advertencia indicando que los períodos se superponen
