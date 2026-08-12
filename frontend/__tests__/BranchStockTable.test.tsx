/**
 * TDD tests for BranchStockTable's "is this row below threshold?" predicate
 * (kpi-critical-stock-dashboard, D6): reemplaza el inline
 * `item.minStock > 0 && item.quantity <= item.minStock` por
 * `isBelowThreshold` de `lib/product-stock.ts` — la fuente única del
 * predicado en cliente.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { BranchStockTable } from "@/components/branches/BranchStockTable"
import type { BranchStockWithProduct } from "@/lib/types"
import * as productStock from "@/lib/product-stock"

const useBranchStockMock = vi.fn()
vi.mock("@/hooks/data/use-branch-stock", () => ({
  useBranchStock: (...args: unknown[]) => useBranchStockMock(...args),
}))

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ isWriter: false, role: "member", isLoading: false }),
}))

function row(overrides: Partial<BranchStockWithProduct>): BranchStockWithProduct {
  return {
    id: "row-1",
    accountId: "acc-1",
    productId: "prod-1",
    branchId: "branch-1",
    quantity: 10,
    minStock: 5,
    productName: "Producto de prueba",
    productSku: null,
    ...overrides,
  }
}

describe("BranchStockTable — predicado de criticidad", () => {
  beforeEach(() => {
    useBranchStockMock.mockReset()
  })

  it("usa isBelowThreshold (no un inline propio) para decidir la fila crítica", () => {
    const spy = vi.spyOn(productStock, "isBelowThreshold")
    useBranchStockMock.mockReturnValue({
      branchStock: [row({ id: "r1", quantity: 3, minStock: 5 })],
      isLoading: false,
    })

    render(<BranchStockTable branchId="branch-1" />)

    expect(spy).toHaveBeenCalledWith(3, 5)
    spy.mockRestore()
  })

  it("fila crítica (quantity <= minStock > 0) muestra el badge Stock bajo", () => {
    useBranchStockMock.mockReturnValue({
      branchStock: [row({ id: "r1", quantity: 3, minStock: 5, productName: "Crítico" })],
      isLoading: false,
    })

    render(<BranchStockTable branchId="branch-1" />)

    expect(screen.getByText("Stock bajo")).toBeInTheDocument()
  })

  it("fila sana (quantity > minStock) NO muestra el badge", () => {
    useBranchStockMock.mockReturnValue({
      branchStock: [row({ id: "r1", quantity: 20, minStock: 5, productName: "Sano" })],
      isLoading: false,
    })

    render(<BranchStockTable branchId="branch-1" />)

    expect(screen.queryByText("Stock bajo")).not.toBeInTheDocument()
  })

  it("fila con minStock = 0 (sin umbral) NUNCA es crítica, aunque quantity sea 0", () => {
    useBranchStockMock.mockReturnValue({
      branchStock: [row({ id: "r1", quantity: 0, minStock: 0, productName: "Sin umbral" })],
      isLoading: false,
    })

    render(<BranchStockTable branchId="branch-1" />)

    expect(screen.queryByText("Stock bajo")).not.toBeInTheDocument()
    expect(screen.getByText("—")).toBeInTheDocument() // minStock 0 se muestra como "—"
  })
})
