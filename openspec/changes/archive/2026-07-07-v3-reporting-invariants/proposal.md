# Proposal: v3-reporting-invariants

## Why

El modelo V3 (§8) eleva cinco reglas de reporting (RN-D1..D5) a invariantes de todas las proyecciones/read-models. La auditoría read-only ejecutada durante este propose (migraciones + definiciones vivas en prod vía `pg_get_functiondef`, 2026-07-06) muestra que los RPCs de reporting cumplen RN-D2 (snapshots, resuelto por `v3-snapshot-pattern`) y RN-D4 (NUMERIC), pero tienen desvíos reales y medibles en el resto:

- **Revenue inconsistente** (defecto transversal encontrado por la auditoría): `rpc_product_profitability`, `rpc_period_comparison` y `rpc_branch_report` suman `sales.amount` (precio **unitario**) en vez de `COALESCE(total, amount)` (total de línea). En prod (2026-07-06) el revenue queda **subvaluado en 17,53 %** ($7.905.976 con `amount` vs $9.291.711 con `total`; 45 filas con `total ≠ amount`) — y en `/rentabilidad` el margen compara revenue unitario contra costo × cantidad: para líneas con `quantity > 1` el margen reportado es falso (puede dar negativo en ventas ganadoras).
- **RN-D1**: las notas de crédito (`rpc_issue_credit_note`) impactan cuenta corriente y journal pero **ningún** RPC de reporting las resta del revenue. Violación latente (0 NC en prod hoy → corregirla no mueve ningún número actual).
- **RN-D3**: el dashboard muestra solo lo **facturado** (devengado); no existe la métrica de ingresos **percibidos** (cobrados). La maquinaria C-30 (`customer_account_movements`, `payments_received`) ya existe para derivarla.
- **RN-D5**: `rpc_period_comparison` y `rpc_branch_report` reciben `DATE` y el borde superior castea a medianoche UTC — en prod hay **43 ventas y 27 compras con hora ≠ 00:00** que quedan **excluidas** cuando caen en el último día del rango. `rpc_product_profitability` usa `CURRENT_DATE` (UTC): entre las 21:00 y las 00:00 hora Argentina la ventana de "últimos N días" corre un día antes.

## What Changes

- **Fix transversal de revenue**: los tres RPCs que suman `amount` pasan a `COALESCE(total, amount)` (convención ya vigente en `rpc_dashboard_kpi_summary`). Sube el revenue reportado en `/rentabilidad`, `/reportes/comparativo` y `/reportes/sucursal` (~+17,5 % agregado; por producto varía). **Cambio de números visibles — ver design.md D1.**
- **RN-D1**: `rpc_dashboard_kpi_summary` y `rpc_period_comparison` restan las notas de crédito del período (vía `customer_account_movements.movement_type='credit_note'`). Documentos CANCELED ya no pueden sumar por construcción (ventas se borran físicamente con reposición de stock; `sales_orders.canceled` no tiene RPC que lo alcance y las canceladas nunca escriben `sales`) — se formaliza como invariante de spec.
- **RN-D3**: `rpc_dashboard_kpi_summary` devuelve dos métricas nuevas: `invoiced_revenue` (devengado = Σ ventas del período) y `collected_revenue` (percibido = devengado − cargos a cta cte del período + cobros `payments_received` del período). UI mínima: línea secundaria en la tarjeta Ganancia Neta, visible solo cuando difieren. La rama `mp_status` de RN-D3 se documenta N/A (no existe pasarela MP de cobro a clientes finales; MP es solo billing de la plataforma).
- **RN-D5**: bordes de período con semántica de fecha local del tenant en los tres RPCs con desvío: fin de rango inclusivo hasta `23:59:59.999` del día (no medianoche), y ventana relativa de profitability anclada a la fecha local Argentina, no a `CURRENT_DATE` UTC. La convención del fix del dashboard 2026-06-08 (`frontend/lib/date-range.ts`) se generaliza como regla escrita.
- **Conteo de operaciones consistente**: `rpc_period_comparison` y `rpc_branch_report` adoptan la definición del dashboard (`COUNT(DISTINCT COALESCE(operation_id, id))`) — hoy comparativo cuenta filas (una venta multi-línea cuenta N veces) y sucursal ignora 18 ventas legacy sin `operation_id`.
- **Sin cambios**: RPCs admin (`rpc_admin_*` — métricas de plataforma sobre `analytics_events`/`profiles`, sin documentos financieros: RN-D1..D3 N/A); `rpc_dashboard_channel_margin` (ya cumple D2 y usa `COALESCE(total, amount)`); COGS/costos (ya en snapshots).

## Capabilities

### New Capabilities

- `reporting-invariants`: invariantes transversales RN-D1..D5 para todo read-model financiero (exclusión de cancelados, resta de NC, revenue = total de línea, percibido vs devengado, bordes de período en fecha local del tenant, dinero NUMERIC), incluyendo los requisitos del RPC `rpc_branch_report` (hoy sin spec propia).

### Modified Capabilities

- `dashboard-kpi-summary`: la Ganancia Neta resta notas de crédito del período (RN-D1); el RPC expone `invoiced_revenue`/`collected_revenue` (+ prev) (RN-D3) y la tarjeta Ganancia Neta muestra el desglose cobrado/facturado cuando difieren.
- `product-profitability`: `total_revenue` pasa a Σ total de línea (`COALESCE(total, amount)` — corrige margen para `quantity > 1`); la ventana de `p_period_days` se ancla a la fecha local del tenant (RN-D5).
- `comparative-reports`: revenue por período = Σ total de línea; borde superior inclusivo hasta fin de día local (RN-D5); `*_operations` cuenta operaciones (`DISTINCT COALESCE(operation_id, id)`) y no filas; el revenue del período resta NC (RN-D1).

## Impact

- **DB (migración `20260814000001`)**: `CREATE OR REPLACE` de `rpc_product_profitability`, `rpc_period_comparison`, `rpc_branch_report` (firmas de entrada/salida sin cambios) y `DROP+CREATE` de `rpc_dashboard_kpi_summary` (misma firma de entrada; `RETURNS TABLE` extendido con 4 columnas — requiere DROP porque `CREATE OR REPLACE` no puede cambiar columnas OUT). Idempotente/both-worlds-safe; gates con anchor auto-limpiante (cleanup hijo→padre incluye branch+cashbox sembrados por `handle_new_user`).
- **Frontend**: `use-dashboard-kpi-summary.ts` mapea 4 campos nuevos; `KpiSummaryBlock`/tarjeta Ganancia Neta agrega línea secundaria condicional. Sin cambios de layout ni rutas. `use-period-comparison.ts`, `use-profitability.ts` y `/reportes/sucursal` no cambian (contratos estables).
- **Backend Python**: sin cambios (ningún endpoint FastAPI llama a estos RPCs).
- **Edge Functions**: `ai-rentabilidad`/`ai-comparativo` consumen los mismos contratos — sin cambios de código; los análisis IA verán los números corregidos.
- **Números visibles en prod**: suben revenue/márgenes de `/rentabilidad`, revenue de `/reportes/comparativo` y `/reportes/sucursal`; baja el conteo de operaciones del comparativo. El dashboard principal NO cambia hoy (0 NC, 0 movimientos cta cte). Cada desvío se justifica en design.md §Decisions y requiere visto del PO antes del apply.
- **Dependencias**: `v3-snapshot-pattern` ✅ (satisfecha). No toca write paths (governance BAJO-MEDIO).
