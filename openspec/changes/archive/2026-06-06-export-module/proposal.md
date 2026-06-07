## Why

Los usuarios de EmprendeSmart no tienen forma de llevarse sus datos fuera de la plataforma. El módulo de exportaciones es el último entregable del roadmap MVP y un diferenciador por plan: gratis no exporta, inicial/avanzado/pro tienen cuotas mensuales crecientes (3/15/50), lo que incentiva el upgrade y cumple con el principio de portabilidad de datos.

## What Changes

- Nueva tabla `export_logs` para registrar cada exportación generada (audit trail + control de cuota)
- Campo `exports_used INTEGER DEFAULT 0` en `profiles` para rastrear el uso mensual
- Edge Function `generate-export`: genera CSV (ventas, compras, gastos, stock) o XLSX (reporte completo), guarda en Supabase Storage bucket `exports` (privado), retorna URL firmada de 1 hora
- Botones "Exportar CSV" en las páginas de ventas, compras, gastos e inventario
- Nueva page `/exportaciones`: historial de exportaciones del mes, links de descarga, contador de cuota usada
- pg_cron job mensual `reset-export-counters`: resetea `exports_used = 0` el primer día de cada mes
- Gating: plan `gratis` bloqueado con CTA de upgrade; resto limitado por cuota mensual

## Capabilities

### New Capabilities
- `data-export`: Generación y descarga de archivos CSV/XLSX de datos propios del usuario, con cuotas por plan, historial en `/exportaciones` y almacenamiento seguro en Storage

### Modified Capabilities
- `plan-gating`: Se agrega el límite `max_exports_per_month` a la tabla `plan_limits` y al hook `usePlanLimits()`

## Impact

- **DB**: nueva tabla `export_logs`, columna `profiles.exports_used`, seed en `plan_limits` con `max_exports_per_month`
- **Edge Functions**: nueva función `generate-export` (Deno); bucket privado `exports` en Supabase Storage
- **Frontend**: botones en 4 páginas existentes + nueva page `/exportaciones`
- **Gating**: `usePlanLimits()` expone `canExport()` y `exportsRemaining`
- **pg_cron**: nuevo job `reset-export-counters` (primer día de cada mes)
