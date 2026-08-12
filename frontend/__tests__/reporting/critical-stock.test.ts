/**
 * TDD tests for the canonical critical-stock access layer
 * (kpi-critical-stock-dashboard, grupo 5 / D5). Llama a
 * `get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL)` y mapea el
 * escalar a `number`, patrón de `lib/reporting/kpi-summary.ts`.
 */

import { describe, it, expect, vi } from "vitest"
import { fetchCriticalStockCount } from "@/lib/reporting/critical-stock"

describe("fetchCriticalStockCount (5.2/5.4)", () => {
  it("branchId = null -> llama la RPC con p_branch_id: null (agregado)", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: 4, error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockCount>[0]

    const result = await fetchCriticalStockCount(client, null)

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_critical_stock", { p_branch_id: null })
    expect(result).toBe(4)
  })

  it("branchId presente -> se envía p_branch_id explícito", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: 1, error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockCount>[0]

    const result = await fetchCriticalStockCount(client, "branch-9")

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_critical_stock", { p_branch_id: "branch-9" })
    expect(result).toBe(1)
  })

  it("mapea el escalar (string numérico o number) a number", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: "7", error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockCount>[0]

    const result = await fetchCriticalStockCount(client, null)
    expect(result).toBe(7)
  })

  it("data null -> devuelve 0", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockCount>[0]

    const result = await fetchCriticalStockCount(client, null)
    expect(result).toBe(0)
  })

  it("error presente -> propaga el error (degradar es decisión del consumidor)", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: { message: "boom" } })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockCount>[0]

    await expect(fetchCriticalStockCount(client, null)).rejects.toEqual({ message: "boom" })
  })
})
