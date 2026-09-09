/**
 * TDD tests for the canonical critical-stock access layer
 * (kpi-critical-stock-dashboard, grupo 5 / D5). Llama a
 * `get_dashboard_critical_stock(p_branch_id uuid DEFAULT NULL)` y mapea el
 * escalar a `number`, patrón de `lib/reporting/kpi-summary.ts`.
 */

import { readFileSync } from "node:fs"
import { join } from "node:path"
import { describe, it, expect, vi } from "vitest"
import { fetchCriticalStockCount, fetchCriticalStockItems } from "@/lib/reporting/critical-stock"

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

describe("fetchCriticalStockItems (kpi-canonicalization S5)", () => {
  it("llama get_dashboard_critical_stock_items con p_branch_id y p_limit, y mapea las filas", async () => {
    const rpcMock = vi.fn().mockResolvedValue({
      data: [
        {
          product_id: "p1",
          name: "Remera",
          sku: "REM-01",
          branch_id: "b1",
          branch_name: "Showroom",
          quantity: "2",
          min_stock: "5",
        },
      ],
      error: null,
    })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockItems>[0]

    const result = await fetchCriticalStockItems(client, "b1", 5)

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_critical_stock_items", {
      p_branch_id: "b1",
      p_limit: 5,
    })
    expect(result).toEqual([
      {
        productId: "p1",
        name: "Remera",
        sku: "REM-01",
        branchId: "b1",
        branchName: "Showroom",
        quantity: 2,
        minStock: 5,
      },
    ])
  })

  it("branchId = null, sin limit -> pide p_branch_id: null y el default de la función", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockItems>[0]

    await fetchCriticalStockItems(client, null)

    expect(rpcMock).toHaveBeenCalledWith("get_dashboard_critical_stock_items", {
      p_branch_id: null,
      p_limit: 5,
    })
  })

  it("data null -> devuelve []", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockItems>[0]

    const result = await fetchCriticalStockItems(client, null)
    expect(result).toEqual([])
  })

  it("error presente -> propaga el error (degradar es decisión del consumidor)", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: { message: "boom" } })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchCriticalStockItems>[0]

    await expect(fetchCriticalStockItems(client, null)).rejects.toEqual({ message: "boom" })
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

  it("Copilot e ai-insights consumen el detalle canónico (fetchCriticalStockItems), no lo reconstruyen (kpi-canonicalization S5)", () => {
    const copilotSource = readFileSync(
      join(process.cwd(), "lib/ai/buildBusinessSnapshot.ts"),
      "utf8",
    )
    const insightsSource = readFileSync(
      join(process.cwd(), "../supabase/functions/ai-insights/index.ts"),
      "utf8",
    )

    for (const source of [copilotSource, insightsSource]) {
      expect(source).toContain("fetchCriticalStockItems")
    }
  })

  it("Copilot e ai-insights no reconstruyen top productos desde v_sales_flat/v_products_with_stock (migrar-top-productos-canon)", () => {
    const copilotSource = readFileSync(
      join(process.cwd(), "lib/ai/buildBusinessSnapshot.ts"),
      "utf8",
    )
    const insightsSource = readFileSync(
      join(process.cwd(), "../supabase/functions/ai-insights/index.ts"),
      "utf8",
    )

    for (const source of [copilotSource, insightsSource]) {
      expect(source).toContain("fetchTopProducts")
      // La agregación local vieja armaba un Map keyed por product_id sumando
      // lineRevenue/quantity sobre las filas de sales/v_sales_flat ya en
      // memoria — eso es lo que rpc_product_ranking reemplaza.
      expect(source).not.toMatch(/salesByProduct/)
    }
  })
})
