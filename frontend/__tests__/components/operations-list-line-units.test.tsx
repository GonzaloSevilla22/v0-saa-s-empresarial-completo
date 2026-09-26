/**
 * Listados de ventas y compras: la cantidad lleva SU unidad y el precio
 * unitario su precisión (ventas-unidades-conversion, cuarta revisión del
 * PR #584, D-F′).
 *
 * Con D-F el precio es por unidad DE LA LÍNEA, así que la misma venta podía
 * leerse "450 | $1,8" o "0,45 | $1.800" sin que se supiera cuál es g y cuál
 * kg, y el CSV mezclaba gramos con kilos en la columna "Cantidad". El detalle
 * expandido muestra "450 g" / "$ 1,8" y "100 g" / "$ 4,575"; el CSV suma la
 * columna "Unidad". Las unidades llegan por prop (`unitsById`) desde la
 * página: el listado no hace fetch propio.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import type { Sale, Purchase, UnitOfMeasure } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

const exportToCSVMock = vi.hoisted(() => vi.fn())

vi.mock("@/lib/excel", () => ({ exportToCSV: exportToCSVMock }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 }

const GRAM: UnitOfMeasure = {
  id: "u-g", name: "Gramo", symbol: "g", type: "weight", factor: 0.001, baseUnitId: "u-kg", isSystem: true,
} as UnitOfMeasure
const unitsById = new Map<string, UnitOfMeasure>([[GRAM.id, GRAM]])

function sale(overrides: Partial<Sale>): Sale {
  return {
    id: "s1", date: "2026-09-25", productId: "p1", productName: "Queso",
    clientId: null, clientName: "Consumidor Final",
    quantity: 1, unitPrice: 1, total: 1, currency: "ARS", operationId: "op-1",
    ...overrides,
  } as Sale
}

function purchase(overrides: Partial<Purchase>): Purchase {
  return {
    id: "c1", date: "2026-09-25", productId: "p1", productName: "Queso",
    quantity: 1, unitCost: 1, total: 1, operationId: "op-c1",
    ...overrides,
  } as Purchase
}

const plain = (s: string | null | undefined) => (s ?? "").replace(/\u00a0/g, " ")

function expandFirstRow() {
  // La fila entera es un <div role="button"> (toggle de expandir).
  const toggles = screen.getAllByRole("button").filter((b) => b.tagName === "DIV")
  fireEvent.click(toggles[0])
}

function saleProps(sales: Sale[]) {
  return {
    sales, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    clients: [], onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
  }
}

function purchaseProps(purchases: Purchase[]) {
  return {
    purchases, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
  }
}

beforeEach(() => exportToCSVMock.mockReset())

describe("SaleOperationsList — unidad de la línea y precio unitario con su precisión", () => {
  const lines = [
    sale({ id: "s1", quantity: 450, unitId: "u-g", unitPrice: 1.8, total: 810 }),
    sale({ id: "s2", productName: "Jamón", quantity: 100, unitId: "u-g", unitPrice: 4.575, total: 457.5 }),
  ]

  it("el detalle muestra '450 g' con '$ 1,8' y '100 g' con '$ 4,575'", () => {
    render(<SaleOperationsList {...saleProps(lines)} unitsById={unitsById} />)
    expandFirstRow()
    const text = plain(document.body.textContent)
    expect(text).toContain("450 g")
    expect(text).toContain("100 g")
    expect(text).toContain("$ 4,575")
    expect(text).not.toContain("$ 4,58")
  })

  it("el CSV suma la columna Unidad con el símbolo de cada línea", () => {
    render(<SaleOperationsList {...saleProps(lines)} unitsById={unitsById} />)
    fireEvent.click(screen.getAllByRole("button", { name: /exportar/i })[0])
    expect(exportToCSVMock).toHaveBeenCalledTimes(1)
    const [rows, columns] = exportToCSVMock.mock.calls[0] as [Array<Record<string, unknown>>, Array<{ key: string; header: string }>]
    expect(columns.map((c) => c.header)).toContain("Unidad")
    const qIdx = columns.findIndex((c) => c.header === "Cantidad")
    expect(columns[qIdx + 1]?.header).toBe("Unidad")
    expect(rows.map((r) => r.unit)).toEqual(["g", "g"])
  })

  it("sin unidades resueltas (o línea sin unidad) no inventa ninguna", () => {
    render(<SaleOperationsList {...saleProps([sale({ quantity: 3, unitPrice: 100, total: 300 })])} />)
    fireEvent.click(screen.getAllByRole("button", { name: /exportar/i })[0])
    const [rows] = exportToCSVMock.mock.calls[0] as [Array<Record<string, unknown>>]
    expect(rows[0].unit).toBe("")
  })
})

describe("PurchaseOperationsList — unidad de la línea y costo unitario con su precisión", () => {
  const lines = [
    purchase({ id: "c1", quantity: 333, unitId: "u-g", unitCost: 0.999, total: 332.667 }),
  ]

  it("el detalle muestra '333 g' con '$ 0,999'", () => {
    render(<PurchaseOperationsList {...purchaseProps(lines)} unitsById={unitsById} />)
    expandFirstRow()
    const text = plain(document.body.textContent)
    expect(text).toContain("333 g")
    expect(text).toContain("$ 0,999")
  })

  it("el CSV suma la columna Unidad", () => {
    render(<PurchaseOperationsList {...purchaseProps(lines)} unitsById={unitsById} />)
    fireEvent.click(screen.getAllByRole("button", { name: /exportar/i })[0])
    const [rows, columns] = exportToCSVMock.mock.calls[0] as [Array<Record<string, unknown>>, Array<{ key: string; header: string }>]
    const qIdx = columns.findIndex((c) => c.header === "Cantidad")
    expect(columns[qIdx + 1]?.header).toBe("Unidad")
    expect(rows[0].unit).toBe("g")
  })
})
