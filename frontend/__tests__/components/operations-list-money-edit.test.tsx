/**
 * Listados de /ventas y /compras — superficie de la edición con dinero (edicion-operaciones-con-dinero, tanda C, 14.1/15.1).
 *
 *  · "Editar" ya no se deshabilita por dinero: el lápiz de una operación con dinero registrado avisa en su `title` que se va a
 *    ver qué se ajusta antes de guardar;
 *  · corregir dinero ya registrado es del dueño o un administrador (OQ-4): para otro rol, "Editar" queda deshabilitado con el
 *    motivo visible — pero sólo si hay dinero que corregir;
 *  · el detalle expandido tiene el «Historial de cambios» (carga diferida), con el `operation_id` de la operación.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import type { Purchase, Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

const historyMock = vi.fn()
vi.mock("@/hooks/data/use-operation-edit", () => ({
  useOperationEditHistory: (...a: unknown[]) => historyMock(...a),
}))
vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

const MONEY_HINT = /tiene dinero registrado/i
const ADMIN_REASON = /due[ñn]o o un administrador/i

function sale(over: Partial<Sale> = {}): Sale {
  return {
    id: "s1", date: "2026-08-20", productId: "p1", productName: "Producto Test", clientId: "c1", clientName: "Cliente Test",
    quantity: 1, unitPrice: 100, total: 100, currency: "ARS", operationId: "op-sale-1", ...over,
  }
}
function purchase(over: Partial<Purchase> = {}): Purchase {
  return {
    id: "pu1", date: "2026-08-20", productId: "p1", productName: "Insumo Test", quantity: 1, unitCost: 50, total: 50,
    operationId: "op-purchase-1", ...over,
  }
}

function saleProps(sales: Sale[], extra: Record<string, unknown> = {}) {
  return {
    sales, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    paymentMethodId: null, setPaymentMethodId: vi.fn(), clearFilters: vi.fn(),
    onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    clients: [], onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
    ...extra,
  }
}
function purchaseProps(purchases: Purchase[], extra: Record<string, unknown> = {}) {
  return {
    purchases, meta, loading: false, error: null,
    dateFrom: "", setDateFrom: vi.fn(), dateTo: "", setDateTo: vi.fn(),
    costCenterId: null, setCostCenterId: vi.fn(), paymentMethodId: null, setPaymentMethodId: vi.fn(),
    clearFilters: vi.fn(), onPageChange: vi.fn(), onPageSizeChange: vi.fn(),
    onDeleteOperation: vi.fn(), onEditOperation: vi.fn(), onRefetch: vi.fn(),
    ...extra,
  }
}

/** Los botones de editar o su versión bloqueada: los distingue su icono (lápiz o candado) y que no son la fila. */
function editControls(): HTMLElement[] {
  return screen
    .getAllByRole("button")
    .filter((b) => b.tagName === "BUTTON" && (b.querySelector("svg.lucide-pencil") || b.querySelector("svg.lucide-lock")))
}

beforeEach(() => {
  historyMock.mockReset()
  historyMock.mockReturnValue({ data: undefined, isLoading: false, isError: false, refetch: vi.fn() })
})

describe.each([
  ["ventas", "venta", (over: Partial<Sale & Purchase>, extra?: Record<string, unknown>) => <SaleOperationsList {...saleProps([sale(over as Partial<Sale>)], extra)} />],
  ["compras", "compra", (over: Partial<Sale & Purchase>, extra?: Record<string, unknown>) => <PurchaseOperationsList {...purchaseProps([purchase(over as Partial<Purchase>)], extra)} />],
])("%s — el lápiz con dinero registrado", (_name, _doc, renderList) => {
  it.each([
    ["cuenta corriente", { hasAccountCharge: true }],
    ["caja", { hasCashMovement: true }],
    ["banco", { hasBankMovement: true }],
  ])("con dinero en %s: el título avisa que se va a ver qué se ajusta, y queda habilitado", (_libro, over) => {
    render(renderList(over))
    const controls = editControls()
    expect(controls.length).toBeGreaterThan(0)
    for (const c of controls) {
      expect(c).not.toBeDisabled()
      expect(c.getAttribute("title")).toMatch(MONEY_HINT)
      expect(c.getAttribute("title")).toMatch(/antes de guardar/i)
    }
  })

  it("sin dinero registrado: sin aviso", () => {
    render(renderList({}))
    for (const c of editControls()) expect(c.getAttribute("title") ?? "").not.toMatch(MONEY_HINT)
  })

  it("sin la capacidad de corregir dinero (OQ-4) y con dinero registrado: 'Editar' queda deshabilitado con el motivo visible", () => {
    render(renderList({ hasCashMovement: true }, { canCorrectMoney: false }))
    const controls = editControls()
    expect(controls.length).toBeGreaterThan(0)
    for (const c of controls) {
      expect(c).toBeDisabled()
      expect(c.getAttribute("title")).toMatch(ADMIN_REASON)
      expect(c.getAttribute("aria-label")).toMatch(ADMIN_REASON)
    }
  })

  it("sin la capacidad pero SIN dinero registrado: sigue editable (la edición no escribe en ningún libro)", () => {
    render(renderList({}, { canCorrectMoney: false }))
    for (const c of editControls()) expect(c).not.toBeDisabled()
  })

  it("con la capacidad (o sin que el listado la reciba), el dinero registrado no deshabilita", () => {
    render(renderList({ hasAccountCharge: true }, { canCorrectMoney: true }))
    for (const c of editControls()) expect(c).not.toBeDisabled()
  })
})

describe("detalle expandido — Historial de cambios", () => {
  it("ventas: el detalle expandido ofrece el historial de la operación (por operation_id)", () => {
    render(<SaleOperationsList {...saleProps([sale()])} />)
    // Cerrada la fila, no hay historial a la vista.
    expect(screen.queryByRole("button", { name: /historial de cambios/i })).toBeNull()
    fireEvent.click(screen.getAllByText("Producto Test")[0])
    const toggle = screen.getByRole("button", { name: /historial de cambios/i })
    fireEvent.click(toggle)
    expect(historyMock).toHaveBeenLastCalledWith("sale", "op-sale-1", true)
  })

  it("compras: ídem, con el operation_id de la compra", () => {
    render(<PurchaseOperationsList {...purchaseProps([purchase()])} />)
    fireEvent.click(screen.getAllByText("Insumo Test")[0])
    fireEvent.click(screen.getByRole("button", { name: /historial de cambios/i }))
    expect(historyMock).toHaveBeenLastCalledWith("purchase", "op-purchase-1", true)
  })

  it("una venta sin operation_id (fila histórica) no ofrece historial: no hay a qué atarlo", () => {
    render(<SaleOperationsList {...saleProps([sale({ operationId: undefined })])} />)
    fireEvent.click(screen.getAllByText("Producto Test")[0])
    expect(screen.queryByRole("button", { name: /historial de cambios/i })).toBeNull()
  })
})
