/**
 * ProductBranchBreakdown — desglose por sucursal para la fila expandible del
 * listado de /stock (sucursal-guard-vaciado-auditoria OQ-5).
 *
 * Lee de useProductBranchBreakdown (mockeado) — mismo hook canónico que ya
 * usa TransferStockAction — y reutiliza StockSemaphore para el estado, con el
 * mismo predicado de umbral 0 = "sin mínimo" (nunca "Crítico").
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { ProductBranchBreakdown } from "@/components/stock/ProductBranchBreakdown"

const useProductBranchBreakdownMock = vi.fn()
vi.mock("@/hooks/data/use-branch-stock", () => ({
  useProductBranchBreakdown: (...args: unknown[]) => useProductBranchBreakdownMock(...args),
}))

describe("ProductBranchBreakdown", () => {
  it("muestra un skeleton mientras carga", () => {
    useProductBranchBreakdownMock.mockReturnValue({ breakdown: [], isLoading: true })
    const { container } = render(<ProductBranchBreakdown productId="p1" />)
    expect(container.querySelector(".animate-pulse")).toBeTruthy()
    expect(screen.queryByText(/sin existencias/i)).not.toBeInTheDocument()
  })

  it("muestra el mensaje vacío cuando no hay filas en ninguna sucursal", () => {
    useProductBranchBreakdownMock.mockReturnValue({ breakdown: [], isLoading: false })
    render(<ProductBranchBreakdown productId="p1" />)
    expect(screen.getByText(/sin existencias en ninguna sucursal/i)).toBeInTheDocument()
  })

  it("lista cada sucursal con su cantidad, mínimo y estado (crítico)", () => {
    useProductBranchBreakdownMock.mockReturnValue({
      breakdown: [
        { branchId: "b1", branchName: "Showroom", quantity: 2, minStock: 5 },
        { branchId: "b2", branchName: "Depósito", quantity: 40, minStock: 5 },
      ],
      isLoading: false,
    })
    render(<ProductBranchBreakdown productId="p1" />)

    expect(screen.getByText("Showroom")).toBeInTheDocument()
    expect(screen.getByText("Depósito")).toBeInTheDocument()
    expect(screen.getByText("2")).toBeInTheDocument()
    expect(screen.getByText("40")).toBeInTheDocument()
    expect(screen.getByText("Crítico")).toBeInTheDocument()
    expect(screen.getByText("OK")).toBeInTheDocument()
  })

  it("una fila con min_stock = 0 se muestra 'Sin mínimo', nunca 'Crítico' (predicado canónico)", () => {
    useProductBranchBreakdownMock.mockReturnValue({
      breakdown: [{ branchId: "b1", branchName: "Showroom", quantity: 0, minStock: 0 }],
      isLoading: false,
    })
    render(<ProductBranchBreakdown productId="p1" />)

    expect(screen.getByText("Sin mínimo")).toBeInTheDocument()
    expect(screen.queryByText("Crítico")).not.toBeInTheDocument()
  })
})
