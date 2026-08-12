/**
 * TDD tests for `supabase/functions/_shared/reporting-canon.ts` — el gemelo
 * Deno de `frontend/lib/reporting/revenue-canon.ts` (kpi-ia-canonical-revenue,
 * D3). Importado por RUTA RELATIVA (mismo patrón que `__tests__/ai-quota.test.ts`
 * y otros 3 archivos): el módulo no referencia `Deno.*` a nivel de módulo, así
 * que vitest puede resolverlo sin runner de Deno.
 *
 * Repite la batería de 1.4/1.5/1.6 (legacy sin total, total=0, numerics
 * string, revenue 0, ventana no invertida) contra la implementación Deno, más
 * los casos de `fetchKpiSummary` con un doble del cliente inyectado.
 */

import { describe, it, expect, vi } from "vitest"
import {
  lineRevenue,
  sumLineRevenue,
  netMarginPct,
  previousWindow,
  fetchKpiSummary,
  type SaleRevenueRow,
} from "../../../supabase/functions/_shared/reporting-canon"

describe("lineRevenue (Deno)", () => {
  it("caso testigo: multi-unidad aporta el total de línea", () => {
    const row: SaleRevenueRow = { amount: 1000, quantity: 3, total: 3000 }
    expect(lineRevenue(row)).toBe(3000)
  })

  it("fila legacy sin total usa amount", () => {
    expect(lineRevenue({ amount: 500, total: null })).toBe(500)
  })

  it("total = 0 legítimo aporta 0, no cae al fallback", () => {
    expect(lineRevenue({ amount: 900, total: 0 })).toBe(0)
  })

  it("numerics como string sin pérdida de decimales", () => {
    expect(lineRevenue({ amount: "1000", total: "1500.50" })).toBe(1500.5)
  })

  it("amount y total ambos NULL → 0", () => {
    expect(lineRevenue({ amount: null, total: null })).toBe(0)
  })
})

describe("sumLineRevenue (Deno)", () => {
  it("suma varias filas", () => {
    expect(
      sumLineRevenue([
        { amount: 1000, total: 3000 },
        { amount: 500, total: null },
      ]),
    ).toBe(3500)
  })

  it("lista vacía → 0", () => {
    expect(sumLineRevenue([])).toBe(0)
  })
})

describe("netMarginPct (Deno)", () => {
  it("porcentaje redondeado", () => {
    expect(netMarginPct(4000, 9000)).toBe(44)
  })

  it("revenue 0 → null", () => {
    expect(netMarginPct(4000, 0)).toBeNull()
  })

  it("ganancia negativa se informa", () => {
    expect(netMarginPct(-1000, 5000)).toBe(-20)
  })
})

describe("previousWindow (Deno)", () => {
  it("rango nunca invertido y sin solapar la ventana original", () => {
    const from = "2026-07-01T00:00:00.000Z"
    const to = "2026-07-31T23:59:59.999Z"
    const result = previousWindow(from, to)
    expect(Date.parse(result.from)).toBeLessThanOrEqual(Date.parse(result.to))
    expect(Date.parse(result.to)).toBeLessThan(Date.parse(from))
  })
})

describe("fetchKpiSummary (Deno, cliente inyectado)", () => {
  const window = {
    from: "2026-06-01T00:00:00.000Z",
    to: "2026-06-30T23:59:59.999Z",
    prevFrom: "2026-05-01T00:00:00.000Z",
    prevTo: "2026-05-31T23:59:59.999Z",
  }
  const mockRow = {
    net_profit: "4000",
    prev_net_profit: "3000",
    invoiced_revenue: "9000",
    prev_invoiced_revenue: "8000",
  }

  it("respuesta con fila → objeto con los campos canónicos", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [mockRow], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    const result = await fetchKpiSummary(client, window)
    expect(result?.netProfit).toBe(4000)
    expect(result?.invoicedRevenue).toBe(9000)
    expect(result?.prevInvoicedRevenue).toBe(8000)
  })

  it("respuesta vacía → null", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    expect(await fetchKpiSummary(client, window)).toBeNull()
  })

  it("error presente → propaga el error", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: { message: "boom" } })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    await expect(fetchKpiSummary(client, window)).rejects.toEqual({ message: "boom" })
  })

  it("branchId ausente → no envía p_branch_id", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [mockRow], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchKpiSummary>[0]

    await fetchKpiSummary(client, window)
    expect(rpcMock).toHaveBeenCalledWith("rpc_dashboard_kpi_summary", {
      p_from: window.from,
      p_to: window.to,
      p_prev_from: window.prevFrom,
      p_prev_to: window.prevTo,
    })
  })
})
