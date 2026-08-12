## Why

Al filtrar por sucursal, el Tablero mezcla dos universos: `rpc_dashboard_kpi_summary` aplica `p_branch_id` a ventas, gastos y compras, pero **no** a notas de crédito, cargos/cobros de cuenta corriente ni a stock sin rotación — así la tarjeta de una sucursal resta NC de toda la cuenta y valoriza stock que vive en otra sucursal (F3a del plan de remediación, verificado 2026-08-11 contra la definición vigente `20260814000001`). En paralelo, el read-model diario `get_dashboard_financials` calcula `net_profit = ingresos − (gastos + compras)` **sin restar NC**, así que diario y mensual disienten sobre la misma ventana (F3b). Nada en CI detecta esa divergencia: es exactamente la re-divergencia que RN-D1 y el requirement de enforcement de consumo buscaban impedir.

## What Changes

- **Parte A — mensual (`rpc_dashboard_kpi_summary`)**: `p_branch_id` deja de aplicarse a medias.
  - **Stock sin rotación** (`stagnant_curr`/`stagnant_prev`) pasa a calcularse sobre `branch_stock` (fila por sucursal) en vez del agregado `v_products_with_stock`, y excluye productos soft-deleted. **No depende de OQ-1.**
  - **Notas de crédito, cargos y cobros** (`nc_agg`, `charges_agg`, `payments_agg`): la regla de atribución por sucursal queda **bloqueada por OQ-1** (decisión del PO — ver design.md §Open Questions). Recomendación fundada: atribuir la NC a la sucursal de su documento origen (`customer_account_movements.reference_id → sales_orders.branch_id`, NOT NULL) y dejar el par de caja cargos/cobros a nivel cuenta, devolviendo `collected_revenue = NULL` cuando hay filtro de sucursal en vez de un número mezclado.
- **Parte B — diario (`get_dashboard_financials`)**: `total_income` y `net_profit` pasan a ser netos de notas de crédito del período, con la **misma** regla de NC que el mensual — compartida en un helper SQL único (`reporting_credit_notes_in_window`) consumido por ambos RPCs, para que la rama que elija OQ-1 se implemente en un solo lugar y el diario no pueda volver a divergir.
- **Gate CI nuevo** en `validate-kpis`: sobre una ventana y un seed determinístico, `get_dashboard_financials` y `rpc_dashboard_kpi_summary` SHALL coincidir (`total_income ≡ invoiced_revenue`, `net_profit ≡ net_profit`), con y sin filtro de sucursal. Previene la re-divergencia por construcción.
- **Sin cambios de firma** en ninguno de los dos RPCs y sin columnas nuevas → `CREATE OR REPLACE` puro (no aplica el gotcha 42725 de `20260913000001`).
- **Sin superficie frontend nueva** (regla PO 2026-08-02): no se agrega pantalla, ruta ni entrada de menú. Cambian números de tarjetas ya existentes del Tablero — "Ingresos"/"Ganancia Neta" del día (ahora netos de NC), "Stock sin Rotación" (ahora por sucursal) y la línea secundaria "Cobrado", que se oculta al filtrar sucursal porque `KpiSummaryBlock` ya trata `collectedRevenue == null` como "no mostrar". Cero archivos de frontend tocados.

## Capabilities

### New Capabilities

Ninguna. El cambio endurece invariantes ya especificados.

### Modified Capabilities

- `reporting-invariants`: RN-D1 gana la regla de atribución de sucursal de las notas de crédito; RN-D3 documenta el par cargos/cobros como métrica de nivel cuenta y su resultado bajo filtro de sucursal; se agregan dos invariantes transversales — el filtro de sucursal SHALL aplicarse uniformemente a **todos** los términos de un read-model, y los read-models diario y mensual SHALL coincidir sobre la misma ventana.
- `dashboard-kpi-summary`: el cálculo mensual gana scope de sucursal explícito en NC y en stock sin rotación (hoy la spec solo habla de scope por cuenta); las métricas devengado/percibido documentan su comportamiento bajo filtro de sucursal.

## Impact

- **DB** — migración idempotente `supabase/migrations/20260914000001_kpi_branch_consistency.sql` (timestamp posterior a `20260913000001`): helper nuevo `reporting_credit_notes_in_window` + `CREATE OR REPLACE` de `rpc_dashboard_kpi_summary` y `get_dashboard_financials`, con REVOKE/GRANT re-aplicados en el mismo archivo (regla del backlog de advisors 0028).
- **CI** — `supabase/tests/test_kpis_edge_cases.sql` suma el gate de comportamiento diario≡mensual (patrón de fixture con `set_config('request.jwt.claims', …)` ya usado por `kpi-critical-stock-dashboard`). El workflow `KPI_Validation.yml` no cambia: el archivo ya está en la lista.
- **Consumidores** — `frontend/app/(dashboard)/dashboard/page.tsx:78` (único caller de `get_dashboard_financials`) y `frontend/lib/reporting/kpi-summary.ts` (capa canónica del mensual). Ninguno requiere edición: los contratos de columnas no cambian.
- **Datos de producción (medidos 2026-08-11, solo lectura)** — el ledger de cuenta corriente está **vacío**: `customer_account_movements = 0`, `payments_received = 0`, `customer_accounts = 0`. El impacto monetario de la Parte A hoy es cero y todo el efecto visible viene del stock sin rotación; el valor del change es preventivo (la regla se fija antes de que existan datos que migrar). Además, 436 de 581 filas de `sales` (75,0%) tienen `branch_id NULL` (legacy) y una sola cuenta tiene más de una sucursal — dos hechos que condicionan las decisiones de fail-open/fail-closed del design.
- **Governance** — MEDIUM (lógica de negocio de reporting). **El apply de la Parte A queda bloqueado hasta el sign-off explícito de OQ-1**; el resto (Parte B, stock por sucursal, gate CI) es independiente y se puede implementar y mergear antes.
