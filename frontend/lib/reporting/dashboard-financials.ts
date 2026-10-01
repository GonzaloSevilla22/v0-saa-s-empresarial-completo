/**
 * Capa canónica de acceso a `get_dashboard_financials` — el read-model de
 * ingresos / gastos / compras / ganancia neta de una ventana arbitraria.
 *
 * tablero-kpis-mes-vigente (D1): el mapeo de la fila del RPC vivía embebido en
 * `app/(dashboard)/dashboard/page.tsx` (con una interfaz local snake_case).
 * Nace acá, en la capa canónica, para que el Tablero lo consuma desde un único
 * hook (`hooks/data/use-dashboard-financials.ts`) tanto para las tarjetas del
 * mes vigente como para el "hoy" del Resumen IA — nunca dos copias.
 *
 * La regla de notas de crédito NO se reimplementa acá: `get_dashboard_financials`
 * resta las NC con el mismo helper de base de datos que
 * `rpc_dashboard_kpi_summary` (spec `reporting-invariants`), así que la
 * `netProfit` de una ventana mensual coincide con la "Ganancia Neta" del
 * Bloque Resumen sobre la misma cuenta y sucursal.
 */

import type { SupabaseClient } from "@supabase/supabase-js"

// ─── Types ────────────────────────────────────────────────────────────────────

/** Fila de get_dashboard_financials mapeada a camelCase. */
export interface DashboardFinancials {
  totalIncome: number
  totalExpenses: number
  totalPurchases: number
  netProfit: number
}

interface RpcDashboardFinancialsRow {
  total_income: string | number | null
  total_expenses: string | number | null
  total_purchases: string | number | null
  net_profit: string | number | null
}

export interface DashboardFinancialsWindow {
  /** Límite inferior inclusivo, ISO 8601 (UTC). */
  from: string
  /** Límite superior inclusivo, ISO 8601 (UTC). */
  to: string
  /** `null`/ausente ⇒ agregado de todas las sucursales (no se manda el param). */
  branchId?: string | null
}

const ZEROS: DashboardFinancials = {
  totalIncome: 0,
  totalExpenses: 0,
  totalPurchases: 0,
  netProfit: 0,
}

// ─── Access ───────────────────────────────────────────────────────────────────

/**
 * Llama `get_dashboard_financials` con la ventana dada y devuelve la fila
 * mapeada. Una respuesta vacía (período sin datos) son ceros, no `null`.
 * Propaga cualquier error del RPC — la decisión de degradar es del consumidor.
 */
export async function fetchDashboardFinancials(
  supabase: SupabaseClient,
  window: DashboardFinancialsWindow,
): Promise<DashboardFinancials> {
  const params: Record<string, string> = {
    p_date_from: window.from,
    p_date_to: window.to,
  }
  if (window.branchId) params.p_branch_id = window.branchId

  const { data, error } = await supabase.rpc("get_dashboard_financials", params)
  if (error) throw error

  const rows = data as RpcDashboardFinancialsRow[] | null
  const row = rows && rows.length > 0 ? rows[0] : null
  if (!row) return { ...ZEROS }

  return {
    totalIncome: Number(row.total_income ?? 0),
    totalExpenses: Number(row.total_expenses ?? 0),
    totalPurchases: Number(row.total_purchases ?? 0),
    netProfit: Number(row.net_profit ?? 0),
  }
}
