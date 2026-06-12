/**
 * C-21 v20-inventory-unification — Group 6 TDD tests for importer branch_stock.
 *
 * Tests verify:
 *   6.1 Importing a product with stock calls rpc_bulk_upsert_products with the stock value
 *   6.2 The RPC is responsible for writing to branch_stock (tested here via call args)
 *   6.3 Re-importing same product with updated stock calls RPC (upsert — no duplicate)
 *
 * The actual branch_stock write is server-side (inside rpc_bulk_upsert_products).
 * Frontend responsibility: pass the correct `stock` value in the RPC payload.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"

// ── Supabase mock ─────────────────────────────────────────────────────────────
const mockRpc = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    rpc: mockRpc,
  })),
}))

// ── File parser mock ───────────────────────────────────────────────────────────
vi.mock("@/lib/import/parser", () => ({
  parseImportFile: vi.fn().mockResolvedValue({
    ok: true,
    rows: [
      {
        lineNumber: 2,
        tipo:       "Producto",
        nombre:     "Yerba Mate",
        precio:     "850",
        costo:      "400",
        stock:      "25",
        stock_minimo: "5",
        sku:        "YM-001",
        sku_padre:  "",
        producto_padre: "",
        categoria:  "Alimentos",
        codigo:     "",
        attributes: {},
      },
    ],
  }),
}))

// ── Resolver mock ──────────────────────────────────────────────────────────────
vi.mock("@/lib/import/resolver", () => ({
  resolveHierarchy: vi.fn().mockImplementation(async (rows) => ({
    rows: rows.map((r: any) => ({
      ...r,
      rowType:           r.rowType || "Producto",
      isVariant:         false,
      resolvedParentId:  null,
      resolvedParentName: null,
    })),
  })),
}))

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("importProductsFromFile — C-21 branch_stock dual-write", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("6.1 — calls rpc_bulk_upsert_products with correct stock value (25)", async () => {
    const { importProductsFromFile } = await import("@/lib/import/importer")

    mockRpc.mockResolvedValueOnce({
      data: { inserted: 1, updated: 0, errors: [] },
      error: null,
    })

    const mockFile = new File(["fake-csv"], "products.csv", { type: "text/csv" })
    await importProductsFromFile({ file: mockFile, userId: "user-123" })

    expect(mockRpc).toHaveBeenCalledOnce()
    const rpcCall = mockRpc.mock.calls[0]
    expect(rpcCall[0]).toBe("rpc_bulk_upsert_products")

    const payload = rpcCall[1]
    expect(payload.p_user_id).toBe("user-123")

    const rows = payload.p_rows
    expect(Array.isArray(rows)).toBe(true)
    expect(rows).toHaveLength(1)

    // 6.1: stock value is passed correctly (will be written to branch_stock server-side)
    expect(rows[0].stock).toBe(25)
    expect(rows[0].name).toBe("Yerba Mate")
  })

  it("6.2 — stock=0 is passed for Padre rows (parent products have no direct stock)", async () => {
    const { parseImportFile } = await import("@/lib/import/parser")
    vi.mocked(parseImportFile).mockResolvedValueOnce({
      ok: true,
      rows: [
        {
          lineNumber: 2,
          tipo:       "Padre",
          nombre:     "Yerba Mate Padre",
          precio:     "0",
          costo:      "0",
          stock:      "10",  // ignored for Padre rows
          stock_minimo: "0",
          sku:        "YM-PAD",
          sku_padre:  "",
          producto_padre: "",
          categoria:  "Alimentos",
          codigo:     "",
          attributes: {},
        },
      ],
    })

    mockRpc.mockResolvedValueOnce({
      data: { inserted: 1, updated: 0, errors: [] },
      error: null,
    })

    const { importProductsFromFile } = await import("@/lib/import/importer")
    const mockFile = new File(["fake-csv"], "products.csv", { type: "text/csv" })
    await importProductsFromFile({ file: mockFile, userId: "user-123" })

    const rows = mockRpc.mock.calls[0][1].p_rows
    // Padre rows always send stock=0 (design decision — parent has no direct stock)
    expect(rows[0].stock).toBe(0)
  })

  it("6.3 — re-importing same product updates stock (upsert, no error)", async () => {
    const { importProductsFromFile } = await import("@/lib/import/importer")

    // First import
    mockRpc.mockResolvedValueOnce({
      data: { inserted: 1, updated: 0, errors: [] },
      error: null,
    })
    const mockFile = new File(["fake-csv"], "products.csv", { type: "text/csv" })
    const result1 = await importProductsFromFile({ file: mockFile, userId: "user-123" })
    expect(result1.inserted).toBe(1)
    expect(result1.dbErrors).toHaveLength(0)

    // Second import (same product — RPC does upsert → updated: 1)
    mockRpc.mockResolvedValueOnce({
      data: { inserted: 0, updated: 1, errors: [] },
      error: null,
    })
    const result2 = await importProductsFromFile({ file: mockFile, userId: "user-123" })
    expect(result2.updated).toBe(1)
    expect(result2.dbErrors).toHaveLength(0)
  })
})
