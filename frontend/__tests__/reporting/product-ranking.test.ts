/**
 * TDD tests for the canonical top-products access layer
 * (migrar-top-productos-canon). Llama `rpc_product_ranking` (orden por
 * importe, variantes agrupadas) — el mismo read-model que
 * `/estadisticas` y su export CSV ya consumen — y resuelve la cuenta
 * activa con el mismo criterio determinístico que
 * `backend/core/deps.py:get_account_id`.
 */

import { describe, it, expect, vi } from "vitest"
import {
  fetchTopProducts,
  resolveActiveAccountId,
} from "@/lib/reporting/product-ranking"

describe("fetchTopProducts", () => {
  it("llama rpc_product_ranking con orden por importe, variantes agrupadas y el límite dado", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    await fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31", limit: 5 })

    expect(rpcMock).toHaveBeenCalledWith("rpc_product_ranking", {
      p_account_id: "acc-1",
      p_start: "2026-08-01",
      p_end: "2026-08-31",
      p_order_by: "revenue",
      p_group_variants: true,
      p_branch_id: null,
      p_canal: null,
      p_limit: 5,
      p_offset: 0,
    })
  })

  it("sin limit -> pide el default de 5", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    await fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31" })

    expect(rpcMock).toHaveBeenCalledWith(
      "rpc_product_ranking",
      expect.objectContaining({ p_limit: 5 }),
    )
  })

  it("mapea filas: B (4u x $2.000 = $8.000) por delante de A (1u x $5.000), tal como las ordena la RPC", async () => {
    const rpcMock = vi.fn().mockResolvedValue({
      data: [
        { product_id: "B", product_name: "B", units: "4", revenue: "8000", gross_margin_pct: "50" },
        { product_id: "A", product_name: "A", units: "1", revenue: "5000", gross_margin_pct: "60" },
      ],
      error: null,
    })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    const result = await fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31" })

    expect(result[0]).toEqual({ productId: "B", name: "B", units: 4, revenue: 8000, marginPct: 50 })
    expect(result[1].productId).toBe("A")
  })

  it("gross_margin_pct null (sin snapshot de costo) -> marginPct null, no 0 inventado", async () => {
    const rpcMock = vi.fn().mockResolvedValue({
      data: [{ product_id: "C", product_name: "C", units: "1", revenue: "100", gross_margin_pct: null }],
      error: null,
    })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    const result = await fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31" })
    expect(result[0].marginPct).toBeNull()
  })

  it("data null -> lista vacía", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    expect(await fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31" })).toEqual([])
  })

  it("error presente -> propaga el error (degradar es decisión del consumidor)", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: null, error: { message: "boom" } })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    await expect(
      fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31" }),
    ).rejects.toEqual({ message: "boom" })
  })

  it("branchId presente -> se envía p_branch_id explícito", async () => {
    const rpcMock = vi.fn().mockResolvedValue({ data: [], error: null })
    const client = { rpc: rpcMock } as unknown as Parameters<typeof fetchTopProducts>[0]

    await fetchTopProducts(client, "acc-1", { start: "2026-08-01", end: "2026-08-31", branchId: "branch-9" })

    expect(rpcMock).toHaveBeenCalledWith(
      "rpc_product_ranking",
      expect.objectContaining({ p_branch_id: "branch-9" }),
    )
  })
})

describe("resolveActiveAccountId", () => {
  function makeChain(result: { data: Array<{ account_id: string }> | null; error: { message: string } | null }) {
    const order2 = vi.fn().mockReturnValue({ limit: vi.fn().mockResolvedValue(result) })
    const order1 = vi.fn().mockReturnValue({ order: order2 })
    const eq = vi.fn().mockReturnValue({ order: order1 })
    const select = vi.fn().mockReturnValue({ eq })
    const from = vi.fn().mockReturnValue({ select })
    return { from, eq, order1, order2, select }
  }

  it("devuelve la membresía más antigua (created_at asc, id asc)", async () => {
    const { from, eq, order1 } = makeChain({ data: [{ account_id: "acc-1" }], error: null })
    const client = { from } as unknown as Parameters<typeof resolveActiveAccountId>[0]

    const result = await resolveActiveAccountId(client, "user-1")

    expect(from).toHaveBeenCalledWith("account_members")
    expect(eq).toHaveBeenCalledWith("user_id", "user-1")
    expect(order1).toHaveBeenCalledWith("created_at", { ascending: true })
    expect(result).toBe("acc-1")
  })

  it("sin membresías -> null", async () => {
    const { from } = makeChain({ data: [], error: null })
    const client = { from } as unknown as Parameters<typeof resolveActiveAccountId>[0]

    expect(await resolveActiveAccountId(client, "user-1")).toBeNull()
  })

  it("error -> null (no lanza; el caller degrada omitiendo el bloque)", async () => {
    const { from } = makeChain({ data: null, error: { message: "boom" } })
    const client = { from } as unknown as Parameters<typeof resolveActiveAccountId>[0]

    expect(await resolveActiveAccountId(client, "user-1")).toBeNull()
  })
})
