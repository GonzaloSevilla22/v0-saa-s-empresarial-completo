/**
 * TDD tests for the canonical KPI-summary access layer (kpi-ia-canonical-revenue,
 * grupo 2 / D7). `mapKpiSummaryRow` y `fetchKpiSummary` se extraen de
 * `hooks/data/use-dashboard-kpi-summary.ts` (hook de cliente, no reusable desde
 * una ruta de servidor) a esta capa canónica, sin cambio de comportamiento —
 * protegido por `__tests__/hooks/use-dashboard-kpi-summary.test.ts`.
 */

import { describe, it, expect, vi } from "vitest"
import {
  mapKpiSummaryRow,
  fetchKpiSummary,
  type RpcKpiSummaryRow,
} from "@/lib/reporting/kpi-summary"

// Fila snake_case tal como la devuelve rpc_dashboard_kpi_summary (numerics como string).
const mockRpcRow: RpcKpiSummaryRow = {
  net_profit: "184200",
  prev_net_profit: "164464.29",
  avg_ticket: "6820.00",
  prev_avg_ticket: "6500.00",
  cost_per_sale: "1240.00",
  prev_cost_per_sale: "1148.15",
  stagnant_stock_value: "41600",
  stagnant_stock_count: 23,
  prev_stagnant_stock_value: "39000",
  prev_stagnant_stock_count: 20,
  sales_count: 27,
  prev_sales_count: 31,
  invoiced_revenue: "184200",
  prev_invoiced_revenue: "164464.29",
  collected_revenue: "184200",
  prev_collected_revenue: "164464.29",
}

describe("mapKpiSummaryRow (2.2)", () => {
  it("mapea las 16 columnas snake_case a camelCase, numerics-como-string a number", () => {
    expect(mapKpiSummaryRow(mockRpcRow)).toEqual({
      netProfit: 184200,
      prevNetProfit: 164464.29,
      avgTicket: 6820,
      prevAvgTicket: 6500,
      costPerSale: 1240,
      prevCostPerSale: 1148.15,
      stagnantStockValue: 41600,
      stagnantStockCount: 23,
      prevStagnantStockValue: 39000,
      prevStagnantStockCount: 20,
      salesCount: 27,
      prevSalesCount: 31,
      invoicedRevenue: 184200,
      prevInvoicedRevenue: 164464.29,
      collectedRevenue: 184200,
      prevCollectedRevenue: 164464.29,
    })
  })

  it("preserva null (no lo convierte a 0)", () => {
    const row = { ...mockRpcRow, avg_ticket: null, cost_per_sale: null, sales_count: 0 }
    const mapped = mapKpiSummaryRow(row)
    expect(mapped.avgTicket).toBeNull()
    expect(mapped.costPerSale).toBeNull()
    expect(mapped.salesCount).toBe(0)
  })

  it("columnas RN-D3 ausentes (invoiced_revenue?) no rompen el mapeo", () => {
    const { invoiced_revenue, prev_invoiced_revenue, collected_revenue, prev_collected_revenue, ...rest } = mockRpcRow
    const mapped = mapKpiSummaryRow(rest as RpcKpiSummaryRow)
    expect(mapped.invoicedRevenue).toBeNull()
    expect(mapped.prevInvoicedRevenue).toBeNull()
    expect(mapped.collectedRevenue).toBeNull()
    expect(mapped.prevCollectedRevenue).toBeNull()
  })
})

describe("fetchKpiSummary (2.5)", () => {
  const window = {
    from: "2026-06-01T00:00:00.000Z",
    to: "2026-06-30T23:59:59.999Z",
    prevFrom: "2026-05-01T00:00:00.000Z",
    prevTo: "2026-05-31T23:59:59.999Z",
  }

  it("respuesta con fila → objeto mapeado", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [mockRpcRow], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    const result = await fetchKpiSummary(client, window)
    expect(result?.invoicedRevenue).toBe(184200)
  })

  it("respuesta vacía (data: []) → null", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    const result = await fetchKpiSummary(client, window)
    expect(result).toBeNull()
  })

  it("error presente → propaga el error (la decisión de degradar es del consumidor, D4)", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: { message: "boom" } })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    await expect(fetchKpiSummary(client, window)).rejects.toEqual({ message: "boom" })
  })

  it("branchId = null → el param p_branch_id no se envía", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [mockRpcRow], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    await fetchKpiSummary(client, { ...window, branchId: null })

    expect(rpcMock).toHaveBeenCalledWith("rpc_dashboard_kpi_summary", {
      p_from: window.from,
      p_to: window.to,
      p_prev_from: window.prevFrom,
      p_prev_to: window.prevTo,
    })
  })

  it("branchId presente → se envía p_branch_id", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [mockRpcRow], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    await fetchKpiSummary(client, { ...window, branchId: "branch-9" })

    expect(rpcMock.mock.calls[0][1]).toMatchObject({ p_branch_id: "branch-9" })
  })
})
