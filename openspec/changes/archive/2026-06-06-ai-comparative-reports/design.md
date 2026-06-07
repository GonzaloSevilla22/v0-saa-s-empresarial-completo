## Context

C-12 agrega reportes comparativos entre dos períodos definidos por el usuario. Depende de C-04 (contadores IA atómicos) y C-05 (account scoping). El patrón de implementación replica el de C-11 (`ai-rentabilidad`): RPC SECURITY DEFINER + Edge Function con quota check + página React con plan gating.

Las tablas de datos son `sales`, `purchases` y `expenses`. Los campos relevantes:
- `sales`: `amount` (total de la venta), `date`
- `purchases`: `amount` (total de la compra), `date`  
- `expenses`: `amount`, `date`

## Goals / Non-Goals

**Goals:**
- Comparar ventas, gastos, compras y operaciones entre dos períodos libres
- Calcular delta % entre períodos para cada métrica
- Análisis narrativo IA accionable enviado a `ai_insights` (type=`'comparativo'`)
- Gating por plan con respeto de `historyDays`

**Non-Goals:**
- Comparación de productos específicos (eso es C-11)
- Granularidad diaria/semanal en el desglose (solo totales por período)
- Exportación del reporte (eso es C-14)
- Reportes por sucursal (eso es C-08)

## Decisions

### D1: RPC sin `p_user_id` — usa `current_account_ids()`

Igual que todos los RPCs post-C-05: el RPC deriva el `account_id` internamente desde `current_account_ids()`. No acepta parámetro de identidad. Lanza excepción P403 si no hay cuenta activa.

**Alternativa descartada**: aceptar `p_user_id` como C-11 original proponía. Descartada porque C-05 estableció `current_account_ids()` como el patrón estándar.

### D2: RPC devuelve una sola fila con columnas `period_a_*` / `period_b_*`

Firma:
```sql
rpc_period_comparison(
  p_a_start DATE, p_a_end DATE,
  p_b_start DATE, p_b_end DATE
) RETURNS TABLE (
  period_a_revenue      NUMERIC,
  period_a_expenses     NUMERIC,
  period_a_purchases    NUMERIC,
  period_a_operations   BIGINT,
  period_b_revenue      NUMERIC,
  period_b_expenses     NUMERIC,
  period_b_purchases    NUMERIC,
  period_b_operations   BIGINT,
  revenue_delta_pct     NUMERIC,
  expenses_delta_pct    NUMERIC,
  purchases_delta_pct   NUMERIC,
  operations_delta_pct  NUMERIC
)
```

`operations` = COUNT total de (sales + purchases + expenses) en el período.  
`delta_pct = ROUND((b - a) / NULLIF(a, 0) * 100, 2)` — positivo es crecimiento, negativo es caída.

**Alternativa descartada**: devolver dos filas (una por período). Requeriría más lógica frontend para calcular deltas. La opción de una fila con deltas pre-calculados es más simple para el cliente.

### D3: CTEs separados por período para evitar Cartesian product

Mismo patrón que C-11: cada origen de datos (sales, purchases, expenses) se agrega por separado dentro de su período via CTE, luego se hace `CROSS JOIN` entre los totales de período A y período B.

```sql
WITH
  sales_a   AS (SELECT COALESCE(SUM(s.amount), 0) AS rev, COUNT(*) AS ops FROM sales s WHERE s.date BETWEEN p_a_start AND p_a_end AND s.account_id = ANY(v_accounts)),
  expenses_a AS (SELECT COALESCE(SUM(e.amount), 0) AS exp, COUNT(*) AS ops FROM expenses e WHERE e.date BETWEEN p_a_start AND p_a_end AND e.account_id = ANY(v_accounts)),
  ...
SELECT period_a_revenue, ..., revenue_delta_pct FROM sales_a CROSS JOIN expenses_a CROSS JOIN sales_b CROSS JOIN expenses_b ...
```

### D4: Historial por plan — enforcement en frontend

El frontend limita el date picker al rango permitido por `usePlanLimits().historyDays`. No se valida en el RPC (no tiene contexto de plan). Esto sigue el mismo patrón que C-11 donde `periodDays` viene del frontend.

### D5: UI — dos columnas de KPI cards + grouped BarChart

- Cards de KPI: una fila con 4 métricas (ventas, gastos, compras, operaciones); cada card muestra valor período A, valor período B y badge de delta % (verde si positivo, rojo si negativo para gastos, verde para ventas).
- BarChart agrupado (Recharts `BarChart` con dos `Bar`): eje X = métrica, dos barras por métrica (período A / período B).
- Defaults: período A = mes actual (inicio del mes hasta hoy), período B = mes anterior completo.

### D6: Fallback de timeout — igual que ai-rentabilidad

Si OpenAI no responde en 25 segundos, la Edge Function devuelve `{ ok: true, fallback: true }` sin incrementar cuota ni insertar en `ai_insights`.

## Risks / Trade-offs

- **Períodos solapados**: El usuario puede elegir períodos que se superponen. Los datos serán correctos matemáticamente pero el análisis IA puede ser confuso. Mitigación: mostrar advertencia en UI si los rangos se superponen.
- **Delta con período A = 0**: División por cero → `NULLIF(a, 0)` en SQL devuelve NULL; el frontend muestra "N/A" en lugar del %.
- **Costo de RPC con períodos largos**: Un rango de 12 meses sobre tablas grandes puede ser lento. Mitigación: índices `idx_*_date` ya existen; límite de historial por plan acota el caso de abuso.
