/**
 * qa-integral-modulos G10 (H25) — el contador de las listas de ventas y
 * compras imprimía "21 operaciónes" (la tilde del singular concatenada con
 * el sufijo del plural). Singular: "1 operación"; plural: "N operaciones".
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import type { Sale, Purchase } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, total: 21, pages: 1, hasNext: false, hasPrev: false }

function makeSales(n: number): Sale[] {
  return Array.from({ length: n }, (_, i) => ({
    id: `s${i}`,
    date: "2026-08-20",
    productId: "p1",
    productName: "Producto Test",
    clientId: "c1",
    clientName: "Cliente Test",
    quantity: 1,
    unitPrice: 100,
    total: 100,
    currency: "ARS",
    operationId: `op-s${i}`,
  }))
}

function makePurchases(n: number): Purchase[] {
  return Array.from({ length: n }, (_, i) => ({
    id: `pu${i}`,
    date: "2026-08-20",
    productId: "p1",
    productName: "Insumo Test",
    quantity: 1,
    unitCost: 50,
    total: 50,
    operationId: `op-p${i}`,
  }))
}

function saleProps(sales: Sale[]) {
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

function purchaseProps(purchases: Purchase[]) {
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

describe("contador de operaciones — pluralización (G10/H25)", () => {
  it("ventas: 21 filas → '21 operaciones', jamás 'operaciónes'", () => {
    render(<SaleOperationsList {...saleProps(makeSales(21))} />)
    expect(screen.getByText("21 operaciones")).toBeInTheDocument()
    expect(screen.queryByText(/operaciónes/)).not.toBeInTheDocument()
  })

  it("ventas: 1 fila → '1 operación'", () => {
    render(<SaleOperationsList {...saleProps(makeSales(1))} />)
    expect(screen.getByText("1 operación")).toBeInTheDocument()
  })

  it("compras: 21 filas → '21 operaciones' (el mismo patrón estaba copiado)", () => {
    render(<PurchaseOperationsList {...purchaseProps(makePurchases(21))} />)
    expect(screen.getByText("21 operaciones")).toBeInTheDocument()
    expect(screen.queryByText(/operaciónes/)).not.toBeInTheDocument()
  })

  it("compras: 1 fila → '1 operación'", () => {
    render(<PurchaseOperationsList {...purchaseProps(makePurchases(1))} />)
    expect(screen.getByText("1 operación")).toBeInTheDocument()
  })
})
