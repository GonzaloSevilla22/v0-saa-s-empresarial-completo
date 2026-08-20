import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import type { Purchase } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

// pagos-cableados-restantes (D6, task 9.3/12.4): espejo de
// sale-operations-list-payment-lock.test.tsx — "Editar" se deshabilita con
// motivo visible cuando la compra tiene un cargo de cuenta corriente
// posteado (isPaymentLocked).

vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 20, total: 1, pages: 1, hasNext: false, hasPrev: false }

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "pu1",
    date: "2026-08-20",
    productId: "p1",
    productName: "Insumo Test",
    quantity: 1,
    unitCost: 50,
    total: 50,
    operationId: "op1",
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

describe("PurchaseOperationsList — D6 disable 'Editar' con cargo posteado", () => {
  it("compra SIN cargo posteado: el botón Editar está habilitado", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase({ isPaymentLocked: false })])} />)
    const editButtons = screen.getAllByRole("button", { name: "" }).filter(
      (b) => b.querySelector("svg.lucide-pencil"),
    )
    expect(editButtons.length).toBeGreaterThan(0)
    for (const b of editButtons) expect(b).not.toBeDisabled()
  })

  it("compra CON cargo de cuenta corriente posteado: 'Editar' se deshabilita con motivo visible", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase({ isPaymentLocked: true })])} />)
    const lockButtons = screen.getAllByTitle(/No editable.*cargo de cuenta corriente/i)
    expect(lockButtons.length).toBeGreaterThan(0)
    for (const b of lockButtons) expect(b).toBeDisabled()
  })
})
