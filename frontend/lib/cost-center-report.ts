/**
 * cost-center-surface — lectura del read-model `rpc_cost_center_report`.
 *
 * Capa canónica del reporte: el mapeo y los totales viven acá (no en la
 * pantalla) para que sean testeables y reutilizables desde cualquier vista que
 * quiera cortar costos por centro.
 *
 * Dos cosas que el mapeo tiene que resolver sí o sí:
 *   1. Los importes son NUMERIC en Postgres y supabase-js los entrega como
 *      string para no perder precisión — sin castear, la UI concatena.
 *   2. La fila con `cost_center_id = NULL` son los costos del período que
 *      nunca se imputaron. Es parte del contrato del reporte: excluirla
 *      mostraría un total por debajo del costo real (design.md Decisión 4).
 */

import type { CostCenterReportRow } from "@/lib/types"

export const UNASSIGNED_COST_CENTER_LABEL = "Sin centro de costo"

/** Fila cruda tal como la devuelve el RPC vía supabase-js. */
export interface CostCenterReportRawRow {
  cost_center_id?: string | null
  cost_center_name?: string | null
  cost_center_code?: string | null
  is_active?: boolean | null
  total_expenses?: string | number | null
  total_purchases?: string | number | null
  total_cost?: string | number | null
  operation_count?: string | number | null
}

function toNumber(value: string | number | null | undefined): number {
  if (value === null || value === undefined) return 0
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function mapCostCenterReportRow(raw: CostCenterReportRawRow): CostCenterReportRow {
  return {
    id:             raw.cost_center_id ?? null,
    name:           raw.cost_center_name ?? UNASSIGNED_COST_CENTER_LABEL,
    code:           raw.cost_center_code ?? null,
    isActive:       raw.is_active ?? true,
    totalExpenses:  toNumber(raw.total_expenses),
    totalPurchases: toNumber(raw.total_purchases),
    totalCost:      toNumber(raw.total_cost),
    operationCount: toNumber(raw.operation_count),
  }
}

export interface CostCenterReportTotals {
  totalExpenses:  number
  totalPurchases: number
  totalCost:      number
  operationCount: number
}

/**
 * Totales del período. Suma TODAS las filas, incluida la de no imputados: el
 * pie de la tabla tiene que cerrar contra el costo real del período.
 */
export function sumCostCenterReport(rows: CostCenterReportRow[]): CostCenterReportTotals {
  return rows.reduce<CostCenterReportTotals>(
    (acc, r) => ({
      totalExpenses:  acc.totalExpenses  + r.totalExpenses,
      totalPurchases: acc.totalPurchases + r.totalPurchases,
      totalCost:      acc.totalCost      + r.totalCost,
      operationCount: acc.operationCount + r.operationCount,
    }),
    { totalExpenses: 0, totalPurchases: 0, totalCost: 0, operationCount: 0 },
  )
}
