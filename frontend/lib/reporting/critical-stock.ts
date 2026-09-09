/**
 * Capa canónica de acceso a `get_dashboard_critical_stock(p_branch_id)` — el
 * KPI de stock crítico consciente de sucursal que alimenta la tarjeta
 * "Productos en alerta" del Tablero.
 *
 * kpi-critical-stock-dashboard, D5: patrón de `lib/reporting/kpi-summary.ts`
 * (llamada + mapeo separados del hook de React Query, que es cliente-only).
 *
 * kpi-canonicalization (candidato S5): `fetchCriticalStockItems` es la
 * hermana de detalle — misma tenencia y mismo predicado (branch_stock,
 * min_stock > 0, tracked), pero devuelve las filas en vez del conteo, para
 * que los consumidores de IA puedan nombrar los productos críticos. Gemelo
 * Deno: `supabase/functions/_shared/reporting-canon.ts`.
 */

import type { SupabaseClient } from "@supabase/supabase-js"
import { toNumber } from "./coerce"

/** Fila de `get_dashboard_critical_stock_items` mapeada a camelCase — una
 *  fila por (producto, sucursal), sin deduplicar por producto (a diferencia
 *  del conteo de la hermana). */
export interface CriticalStockItem {
  productId: string
  name: string
  sku: string | null
  branchId: string
  branchName: string
  quantity: number
  minStock: number
}

interface RpcCriticalStockItemRow {
  product_id: string
  name: string
  sku: string | null
  branch_id: string
  branch_name: string
  quantity: string | number
  min_stock: string | number
}

/**
 * Llama `get_dashboard_critical_stock` con el filtro de sucursal dado
 * (`null` → agregado consciente de sucursal, D2) y devuelve el conteo
 * mapeado a `number`. Propaga cualquier error del RPC — la decisión de
 * degradar (a 0 + `console.error`) es del consumidor (el hook), no de esta
 * capa de acceso.
 */
export async function fetchCriticalStockCount(
  supabase: SupabaseClient,
  branchId: string | null = null,
): Promise<number> {
  const { data, error } = await supabase.rpc("get_dashboard_critical_stock", {
    p_branch_id: branchId,
  })
  if (error) throw error

  return data == null ? 0 : Number(data)
}

/**
 * Llama `get_dashboard_critical_stock_items` (mismo predicado que la
 * hermana, sin deduplicar por producto) y devuelve las filas mapeadas, top
 * `limit` por criticidad (menor `quantity/minStock` primero). Propaga
 * cualquier error del RPC — la decisión de degradar (omitir el bloque,
 * nunca reconstruir desde `v_products_with_stock`) es del consumidor.
 */
export async function fetchCriticalStockItems(
  supabase: SupabaseClient,
  branchId: string | null = null,
  limit = 5,
): Promise<CriticalStockItem[]> {
  const { data, error } = await supabase.rpc("get_dashboard_critical_stock_items", {
    p_branch_id: branchId,
    p_limit: limit,
  })
  if (error) throw error

  const rows = (data as RpcCriticalStockItemRow[] | null) ?? []
  return rows.map((row) => ({
    productId: row.product_id,
    name: row.name,
    sku: row.sku,
    branchId: row.branch_id,
    branchName: row.branch_name,
    quantity: toNumber(row.quantity),
    minStock: toNumber(row.min_stock),
  }))
}
