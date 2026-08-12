/**
 * Capa canónica de acceso a `get_dashboard_critical_stock(p_branch_id)` — el
 * KPI de stock crítico consciente de sucursal que alimenta la tarjeta
 * "Productos en alerta" del Tablero.
 *
 * kpi-critical-stock-dashboard, D5: patrón de `lib/reporting/kpi-summary.ts`
 * (llamada + mapeo separados del hook de React Query, que es cliente-only).
 */

import type { SupabaseClient } from "@supabase/supabase-js"

/**
 * Llama `get_dashboard_critical_stock` con el filtro de sucursal dado
 * (`null` → agregado consciente de sucursal, D2) y devuelve el conteo
 * mapeado a `number`. Propaga cualquier error del RPC — la decisión de
 * degradar (a 0 + `console.error`) es del consumidor (el hook), no de esta
 * capa de acceso.
 */
export async function fetchCriticalStockCount(
  supabase: SupabaseClient,
  branchId: string | null,
): Promise<number> {
  const { data, error } = await supabase.rpc("get_dashboard_critical_stock", {
    p_branch_id: branchId,
  })
  if (error) throw error

  return data == null ? 0 : Number(data)
}
