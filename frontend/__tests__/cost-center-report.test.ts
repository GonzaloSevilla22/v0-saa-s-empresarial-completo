/**
 * cost-center-surface — mapeo y totales del reporte por centro de costo.
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 *
 * El RPC devuelve NUMERIC, que supabase-js entrega como string para no perder
 * precisión: si el mapeo no castea, la UI suma strings y muestra "50007000".
 * La fila con cost_center_id NULL es contrato (los costos sin imputar), no un
 * caso borde a descartar.
 */

import { describe, it, expect } from "vitest"
import {
  mapCostCenterReportRow,
  sumCostCenterReport,
  UNASSIGNED_COST_CENTER_LABEL,
} from "@/lib/cost-center-report"

describe("mapCostCenterReportRow", () => {
  it("mapea una fila con centro imputado, casteando los NUMERIC a number", () => {
    const row = mapCostCenterReportRow({
      cost_center_id: "cc-1",
      cost_center_name: "Marketing",
      cost_center_code: "MKT",
      is_active: true,
      total_expenses: "5000.00",
      total_purchases: "6000.50",
      total_cost: "11000.50",
      operation_count: "3",
    })

    expect(row).toEqual({
      id: "cc-1",
      name: "Marketing",
      code: "MKT",
      isActive: true,
      totalExpenses: 5000,
      totalPurchases: 6000.5,
      totalCost: 11000.5,
      operationCount: 3,
    })
  })

  it("mapea la fila de costos no imputados (cost_center_id NULL)", () => {
    const row = mapCostCenterReportRow({
      cost_center_id: null,
      cost_center_name: UNASSIGNED_COST_CENTER_LABEL,
      cost_center_code: null,
      is_active: true,
      total_expenses: "700",
      total_purchases: "0",
      total_cost: "700",
      operation_count: "1",
    })

    expect(row.id).toBeNull()
    expect(row.name).toBe("Sin centro de costo")
    expect(row.code).toBeNull()
    expect(row.totalCost).toBe(700)
  })

  it("TRIANGULATE: un centro desactivado conserva nombre y queda marcado", () => {
    const row = mapCostCenterReportRow({
      cost_center_id: "cc-2",
      cost_center_name: "Feria 2025",
      cost_center_code: null,
      is_active: false,
      total_expenses: "800",
      total_purchases: "0",
      total_cost: "800",
      operation_count: "1",
    })

    expect(row.name).toBe("Feria 2025")
    expect(row.isActive).toBe(false)
  })

  it("TRIANGULATE: tolera nulos e indefinidos en los importes", () => {
    const row = mapCostCenterReportRow({
      cost_center_id: "cc-3",
      cost_center_name: "Logística",
      cost_center_code: null,
      is_active: true,
      total_expenses: null,
      total_purchases: undefined,
      total_cost: null,
      operation_count: null,
    })

    expect(row.totalExpenses).toBe(0)
    expect(row.totalPurchases).toBe(0)
    expect(row.totalCost).toBe(0)
    expect(row.operationCount).toBe(0)
  })

  it("TRIANGULATE: sin nombre cae en la etiqueta de no imputado", () => {
    const row = mapCostCenterReportRow({
      cost_center_id: null,
      cost_center_name: null,
      cost_center_code: null,
      is_active: true,
      total_expenses: "10",
      total_purchases: "0",
      total_cost: "10",
      operation_count: "1",
    })

    expect(row.name).toBe(UNASSIGNED_COST_CENTER_LABEL)
  })
})

describe("sumCostCenterReport", () => {
  it("suma gastos, compras, costo total y operaciones de todas las filas", () => {
    const rows = [
      { totalExpenses: 5100, totalPurchases: 6000, totalCost: 11100, operationCount: 3 },
      { totalExpenses: 700, totalPurchases: 0, totalCost: 700, operationCount: 1 },
      { totalExpenses: 800, totalPurchases: 0, totalCost: 800, operationCount: 1 },
    ].map((r) => ({ id: null, name: "x", code: null, isActive: true, ...r }))

    expect(sumCostCenterReport(rows)).toEqual({
      totalExpenses: 6600,
      totalPurchases: 6000,
      totalCost: 12600,
      operationCount: 5,
    })
  })

  it("TRIANGULATE: sin filas los totales son cero, no NaN", () => {
    expect(sumCostCenterReport([])).toEqual({
      totalExpenses: 0,
      totalPurchases: 0,
      totalCost: 0,
      operationCount: 0,
    })
  })

  it("la fila de no imputados cuenta en el total del período", () => {
    const rows = [
      { id: "cc-1", name: "Marketing", code: null, isActive: true, totalExpenses: 0, totalPurchases: 30000, totalCost: 30000, operationCount: 1 },
      { id: null, name: UNASSIGNED_COST_CENTER_LABEL, code: null, isActive: true, totalExpenses: 20000, totalPurchases: 0, totalCost: 20000, operationCount: 2 },
    ]

    expect(sumCostCenterReport(rows).totalCost).toBe(50000)
  })
})
