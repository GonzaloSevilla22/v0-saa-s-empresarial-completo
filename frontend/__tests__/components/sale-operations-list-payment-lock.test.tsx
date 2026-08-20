import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import type { Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

// pagos-cableados-restantes (D6, task 12.4): "Editar" se deshabilita con
// motivo visible cuando la operación tiene un cargo de cuenta corriente o
// movimiento de caja posteado (isPaymentLocked) — el guard real vive en el
// backend (P0423), esto sólo evita que el usuario llegue hasta ese error.

vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 20, total: 1, pages: 1, hasNext: false, hasPrev: false }

function makeSale(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "s1",
    date: "2026-08-20",
    productId: "p1",
    productName: "Producto Test",
    clientId: "c1",
    clientName: "Cliente Test",
    quantity: 1,
    unitPrice: 100,
    total: 100,
    currency: "ARS",
    operationId: "op1",
    ...overrides,
  }
}

function baseProps(sales: Sale[]) {
  return {
    sales, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(),
    dateTo: "", setDateTo: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(),
    clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    clients: [], onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
  }
}

describe("SaleOperationsList — D6 disable 'Editar' con cargo/movimiento posteado", () => {
  it("operación SIN cargo/movimiento: el botón Editar está habilitado", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isPaymentLocked: false })])} />)
    const editButtons = screen.getAllByRole("button", { name: "" }).filter(
      (b) => b.querySelector("svg.lucide-pencil"),
    )
    expect(editButtons.length).toBeGreaterThan(0)
    for (const b of editButtons) expect(b).not.toBeDisabled()
  })

  it("operación CON cargo/movimiento posteado: 'Editar' se deshabilita con motivo visible", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isPaymentLocked: true })])} />)
    const lockButtons = screen.getAllByTitle(/No editable.*cargo de cuenta corriente/i)
    expect(lockButtons.length).toBeGreaterThan(0)
    for (const b of lockButtons) expect(b).toBeDisabled()
  })
})
