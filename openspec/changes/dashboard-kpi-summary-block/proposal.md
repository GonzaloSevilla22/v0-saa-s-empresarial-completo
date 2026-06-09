## Why

El emprendedor abre el Tablero y no puede responder rápido "¿cómo está mi negocio este mes?". Hoy el Tablero muestra solo KPIs de **hoy** (ventas/gastos/ganancia del día) y no hay una vista mensual con comparación contra el mes anterior. La Especificación Técnica "Bloque Resumen KPI" (ALIADATA, v1.1) pide un bloque de 5 indicadores mensuales en el tope del Tablero que responda esa pregunta en menos de 3 segundos.

## What Changes

- **Nuevo bloque "Resumen KPI"** en el tope del Tablero (arriba de "Consejos IA" / `AiSummaryCard`), con 5 tarjetas: Ganancia Neta, Margen por Canal, Stock sin Rotación, Costo por Venta, Ticket Promedio. No se elimina ni mueve nada existente — solo se inserta encima.
- **Selector de período** en el Tablero (mes en curso por defecto) que afecta el bloque. Hoy el Tablero solo tiene filtro de sucursal (`BranchFilter`); no existe selector de período.
- **Badge de variación** por tarjeta comparando contra el mes anterior, con lógica de color invertida según el KPI (subir = verde para Ganancia/Margen/Ticket; subir = rojo para Costo por Venta y Stock sin Rotación).
- **Nuevos RPCs de lectura** (Supabase, `SECURITY DEFINER`, scope `account_id`) para calcular los 5 KPIs del período + su valor del mes anterior en una sola llamada.
- **BREAKING (modelo de datos)**: se agrega la columna `canal` a `sales` y se captura en el formulario de venta, para habilitar el KPI "Margen por Canal" (hoy no existe el concepto de canal de venta). Governance **HIGH** — la migración requiere aprobación humana explícita antes de escribirse/aplicarse.
- Si no hay datos para el período, las tarjetas muestran `—` en lugar del valor.

## Capabilities

### New Capabilities
- `dashboard-kpi-summary`: bloque de 5 tarjetas KPI mensuales en el Tablero, selector de período, badges de variación mes-a-mes, RPCs de agregación y comportamiento responsive (2/3/5 columnas).
- `sales-channel`: campo `canal` en ventas (captura en el form de venta) y agregación de margen neto por canal — base de datos del KPI "Margen por Canal".

### Modified Capabilities
<!-- Sin specs de "ventas"/"tablero" preexistentes en openspec/specs/. No cambian requisitos de capabilities ya documentadas. -->

## Impact

- **Frontend**: `frontend/app/(dashboard)/dashboard/page.tsx` (insertar bloque + estado de período), nuevo `frontend/components/dashboard/KpiSummaryBlock.tsx` + tarjeta del nuevo diseño, nuevo selector de período, nuevo hook de datos (TanStack Query) sobre los RPCs, captura de `canal` en el form de venta. Reusa `frontend/lib/date-range.ts` (`utcMonthRange` / `utcPrevMonthRange`).
- **DB (Supabase, prod `gxdhpxvdjjkmxhdkkwyb`)**: migración con columna `sales.canal` (+ índice), RPC(s) de KPIs mensuales y de margen por canal, y ajuste de `rpc_create_sale_operation` para persistir `canal`. Todas las lecturas con scope `account_id IN (SELECT current_account_ids())` y `SUM(COALESCE(total, amount))`.
- **Tests**: vitest para el hook, el componente del bloque (grilla responsive + lógica de color del badge) y el selector; tests SQL/manuales para los RPCs.
- **Governance**: la migración de `canal` (modelo de datos financiero) es HIGH → gate de aprobación. El resto (RPCs de solo lectura, UI) es MEDIUM.
