## MODIFIED Requirements

### Requirement: RPC de comparación de métricas entre dos períodos

El sistema SHALL proveer el RPC `rpc_period_comparison(p_a_start DATE, p_a_end DATE, p_b_start DATE, p_b_end DATE)` que calcula para la cuenta activa, en cada período: `period_a_revenue`, `period_a_expenses`, `period_a_purchases`, `period_a_operations`, y los equivalentes `period_b_*`, más los deltas porcentuales `revenue_delta_pct`, `expenses_delta_pct`, `purchases_delta_pct`, `operations_delta_pct`. El RPC deriva el `account_id` internamente desde `current_account_ids()` — no acepta parámetros de identidad. Reglas de cálculo (RN-D):

- `*_revenue` = Σ `COALESCE(total, amount)` de ventas del período (total de línea, nunca `amount` solo) **menos** Σ notas de crédito del período (`customer_account_movements.movement_type = 'credit_note'`, por `created_at`) (RN-D1).
- `*_purchases` = Σ `COALESCE(total, amount)` de compras del período.
- `*_operations` = operaciones de venta y compra contadas con `COUNT(DISTINCT COALESCE(operation_id, id))` + gastos contados por fila (unificado con el dashboard).
- Bordes de período: cada rango incluye el día final **completo** — comparación `date < p_end + 1 día`, no `<= p_end` casteado a medianoche UTC (RN-D5).

La firma de entrada y las columnas de salida NO cambian.

#### Scenario: RPC calcula totales correctos para dos períodos sin solapamiento

- **GIVEN** una cuenta con ventas por un total de línea de $1000 en enero y $1500 en febrero
- **WHEN** se llama a `rpc_period_comparison('2026-01-01','2026-01-31','2026-02-01','2026-02-28')`
- **THEN** retorna `period_a_revenue = 1000`, `period_b_revenue = 1500`, `revenue_delta_pct = 50.0`

#### Scenario: El revenue suma totales de línea, no precios unitarios

- **GIVEN** un período con una única venta de 2 unidades a precio unitario $1.000 (`amount = 1000`, `total = 2000`)
- **WHEN** se llama al RPC con un rango que la contiene
- **THEN** el revenue de ese período es $2.000 (no $1.000)

#### Scenario: Una venta multi-línea cuenta como una sola operación

- **GIVEN** un período cuya única actividad es una venta de 3 productos (3 filas de `sales` con el mismo `operation_id`)
- **WHEN** se llama al RPC
- **THEN** `period_*_operations = 1` para ese período (no 3)

#### Scenario: Una venta con hora real en el último día del rango queda incluida

- **GIVEN** una venta registrada el 2026-01-31 a las 15:00 UTC
- **WHEN** se llama al RPC con período A = `('2026-01-01','2026-01-31')`
- **THEN** la venta suma en `period_a_revenue`

#### Scenario: Una nota de crédito resta del revenue del período de su emisión

- **GIVEN** un período con $10.000 de ventas y una NC de $1.000 emitida dentro del período
- **WHEN** se llama al RPC
- **THEN** el revenue de ese período es $9.000

#### Scenario: RPC retorna delta NULL cuando el período A tiene valor cero

- **GIVEN** una cuenta sin ventas en el período A y ventas en el período B
- **WHEN** se llama al RPC con esos rangos
- **THEN** `revenue_delta_pct` es NULL (no se divide por cero)

#### Scenario: Usuario sin cuenta activa no puede llamar al RPC

- **GIVEN** un usuario autenticado sin membership activa
- **WHEN** llama a `rpc_period_comparison(...)`
- **THEN** el RPC lanza excepción con ERRCODE = 'P0403'

#### Scenario: Períodos solapados devuelven datos matemáticamente correctos

- **GIVEN** períodos A y B que comparten días
- **WHEN** se llama al RPC
- **THEN** cada período suma independientemente sus propias filas — no hay deduplicación ni error
