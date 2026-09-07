/**
 * TDD tests for the canonical critical-stock access layer
 * (kpi-critical-stock-dashboard, grupo 5 / D5). Llama a
 * `get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL)` y mapea el
 * escalar a `number`, patrón de `lib/reporting/kpi-summary.ts`.
 */

import { readFileSync } from "node:fs"
import { join } from "node:path"
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

describe("consumidores del KPI canónico de stock crítico", () => {
  it("el resumen secundario del Tablero usa el hook canónico con la sucursal activa", () => {
    const source = readFileSync(
      join(process.cwd(), "components/dashboard/ai-summary-card.tsx"),
      "utf8",
    )

    expect(source).toContain("useCriticalStock(branchId)")
    expect(source).not.toContain("useProducts")
    expect(source).not.toContain("isBelowThreshold")
    expect(source).not.toContain("@/lib/product-stock")
  })

  it("Copilot e ai-insights no reconstruyen criticidad desde v_products_with_stock", () => {
    const copilotSource = readFileSync(
      join(process.cwd(), "lib/ai/buildBusinessSnapshot.ts"),
      "utf8",
    )
    const insightsSource = readFileSync(
      join(process.cwd(), "../supabase/functions/ai-insights/index.ts"),
      "utf8",
    )

    for (const source of [copilotSource, insightsSource]) {
      expect(source).toContain("fetchCriticalStockCount")
      expect(source).not.toMatch(/Number\(p\.stock\)\s*<=\s*Number\(p\.min_stock/)
    }
  })
})
