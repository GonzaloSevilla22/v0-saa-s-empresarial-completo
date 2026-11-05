import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import type { Purchase } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

// compras-proveedor-cuenta-corriente (D9, task 13.1/13.2): la fila de la
// operación identifica al proveedor imputado con un badge (mismo patrón que
// los badges de centro de costo / forma de pago ya existentes), y muestra
// "Sin proveedor" cuando la operación no tiene uno.

// edicion-operaciones-con-dinero (tanda C): el detalle expandido monta el historial de cambios, que consulta por react-query + python-client.
vi.mock("@/hooks/data/use-operation-edit", () => ({
  useOperationEditHistory: () => ({ data: [], isLoading: false, isError: false, refetch: vi.fn() }),
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "pu1", date: "2026-08-20", productId: "p1", productName: "Insumo Test",
    quantity: 1, unitCost: 50, total: 50, operationId: "op1",
    ...overrides,
  }
}

function baseProps(purchases: Purchase[]) {
  return {
    purchases, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(),
    dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(),
    clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
  }
}

describe("PurchaseOperationsList — badge de proveedor", () => {
  it("muestra el nombre del proveedor imputado", () => {
    render(<PurchaseOperationsList {...baseProps([
      makePurchase({ supplierId: "sup-1", supplierName: "Distribuidora Mendoza" }),
    ])} />)
    expect(screen.getAllByText("Distribuidora Mendoza").length).toBeGreaterThan(0)
  })

  it("sin proveedor imputado, muestra 'Sin proveedor'", () => {
    render(<PurchaseOperationsList {...baseProps([
      makePurchase({ supplierId: null, supplierName: null }),
    ])} />)
    expect(screen.getAllByText(/sin proveedor/i).length).toBeGreaterThan(0)
  })
})

describe("PurchaseOperationsList — la compra con cargo del proveedor se edita (edicion-operaciones-con-dinero, tanda B)", () => {
  it("con el cargo de cuenta corriente del proveedor posteado, 'Editar' queda habilitado y sin motivo de bloqueo por dinero", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase({ hasAccountCharge: true })])} />)
    expect(screen.queryAllByTitle(/No editable.*cargo de cuenta corriente/i)).toHaveLength(0)
    const edit = screen.getAllByRole("button").filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))
    expect(edit.length).toBeGreaterThan(0)
    for (const b of edit) expect(b).not.toBeDisabled()
  })
})
