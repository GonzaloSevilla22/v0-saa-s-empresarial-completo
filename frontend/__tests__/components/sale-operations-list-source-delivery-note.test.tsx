/**
 * remitos-venta (tanda B, 7.6, D9/D13) — `/ventas`:
 *  - la operación nacida de un remito muestra "Desde remito R-00000007" con
 *    enlace al remito, en su propia línea (igual que el de presupuesto);
 *  - "Editar" queda deshabilitado con el motivo y el número del remito (el
 *    servidor responde P0423 `delivery_note_sale_locked`); ese motivo gana a los
 *    demás porque es el PRIMER guard de la RPC de edición;
 *  - el diálogo de borrado suma la línea de D9: el stock no vuelve y el remito
 *    vuelve a pendiente. El borrado sigue disponible.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen, within, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { SaleOperationsList } from "@/components/ventas/sale-operations-list"
import type { Sale } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

vi.mock("@/hooks/data/use-fiscal-profile", () => ({ useFiscalProfile: () => ({ profile: null }) }))
vi.mock("@/hooks/data/use-points-of-sale", () => ({ usePointsOfSale: () => ({ pointsOfSale: [] }) }))
vi.mock("@/hooks/data/use-promote-to-order", () => ({ usePromoteToOrder: () => ({ mutateAsync: vi.fn() }) }))
vi.mock("@/components/fiscal/EmitInvoiceButton", () => ({ EmitInvoiceButton: () => null }))
vi.mock("@/components/fiscal/FiscalDocumentBadge", () => ({ FiscalDocumentBadge: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))
vi.mock("@/components/ventas/sale-receipt-button", () => ({ SaleReceiptButton: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

function makeSale(overrides: Partial<Sale> = {}): Sale {
  return {
    id: "s1",
    date: "2026-10-02",
    productId: "p1",
    productName: "Remera",
    clientId: "c1",
    clientName: "Ana Pérez",
    quantity: 1,
    unitPrice: 100,
    total: 100,
    currency: "ARS",
    operationId: "op1",
    ...overrides,
  }
}

const FROM_REMITO: Partial<Sale> = {
  sourceDeliveryNoteId: "dn-3",
  sourceDeliveryNoteNumber: 7,
  editLockedReason: "delivery_note_sale_locked",
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

function pencilButtons(): HTMLElement[] {
  return screen
    .getAllByRole("button")
    .filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))
}

const LOCK_REASON = /la venta nació del remito R-00000007/i

describe("SaleOperationsList — badge 'Desde remito'", () => {
  it("una venta nacida de un remito muestra 'Desde remito R-00000007' con enlace a él", () => {
    render(<SaleOperationsList {...baseProps([makeSale(FROM_REMITO)])} />)
    const links = screen.getAllByRole("link", { name: "Desde remito R-00000007" })
    expect(links.length).toBeGreaterThan(0)
    for (const link of links) expect(link).toHaveAttribute("href", "/remitos/dn-3")
    expect(screen.queryByText(/desde presupuesto/i)).not.toBeInTheDocument()
  })

  it("una venta suelta no muestra ningún badge de origen", () => {
    render(<SaleOperationsList {...baseProps([makeSale()])} />)
    expect(screen.queryByText(/desde remito/i)).not.toBeInTheDocument()
  })

  it("el origen presupuesto sigue mostrándose igual (el badge generalizado no cambió su texto ni su enlace)", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ sourceQuoteId: "q-9", sourceQuoteNumber: 12 })])} />)
    const links = screen.getAllByRole("link", { name: "Desde presupuesto P-00000012" })
    expect(links[0]).toHaveAttribute("href", "/presupuestos/q-9")
    expect(screen.queryByText(/desde remito/i)).not.toBeInTheDocument()
  })

  it("en escritorio el badge va en su propia línea, fuera de la celda que trunca el nombre del producto", () => {
    render(<SaleOperationsList {...baseProps([makeSale(FROM_REMITO)])} />)
    const desktop = document.querySelector('[class*="sm:grid"][class*="items-center"]') as HTMLElement
    const badge = within(desktop).getByRole("link", { name: /desde remito r-00000007/i })
    const productName = within(desktop).getByText(/Remera/)
    const nameCell = productName.closest(".truncate") as HTMLElement
    expect(nameCell.contains(badge)).toBe(false)
    expect(nameCell.parentElement).not.toBe(badge.parentElement)
  })

  it("el enlace del badge no expande ni colapsa la fila", () => {
    render(<SaleOperationsList {...baseProps([makeSale(FROM_REMITO)])} />)
    const row = screen.getAllByRole("button").find((b) => b.tagName === "DIV" && b.hasAttribute("aria-expanded"))!
    expect(row).toHaveAttribute("aria-expanded", "false")
    screen.getAllByRole("link", { name: /desde remito/i })[0].click()
    expect(row).toHaveAttribute("aria-expanded", "false")
  })
})

describe("SaleOperationsList — 'Editar' en una venta nacida de un remito (D9)", () => {
  it("queda deshabilitado con el motivo, el número del remito y la salida", () => {
    render(<SaleOperationsList {...baseProps([makeSale(FROM_REMITO)])} />)
    const locked = screen.getAllByTitle(LOCK_REASON)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) {
      expect(b).toBeDisabled()
      expect(b.getAttribute("title")).toMatch(/para corregirla, eliminá la venta, editá el remito y volvé a convertirlo/i)
    }
    expect(pencilButtons()).toHaveLength(0)
  })

  it("el motivo también es el nombre accesible del botón deshabilitado", () => {
    render(<SaleOperationsList {...baseProps([makeSale(FROM_REMITO)])} />)
    expect(screen.getAllByRole("button", { name: LOCK_REASON }).length).toBeGreaterThan(0)
  })

  it("PRIORIDAD: gana al bloqueo de pago, porque el servidor lo evalúa primero", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ ...FROM_REMITO, isPaymentLocked: true })])} />)
    expect(screen.getAllByTitle(LOCK_REASON).length).toBeGreaterThan(0)
    expect(screen.queryAllByTitle(/cargo de cuenta corriente/i)).toHaveLength(0)
  })

  it("el motivo viene del servidor: sin `editLockedReason` el lápiz sigue habilitado aunque haya un origen remito", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ sourceDeliveryNoteId: "dn-3", sourceDeliveryNoteNumber: 7 })])} />)
    expect(pencilButtons().length).toBeGreaterThan(0)
  })

  it("un token de motivo desconocido también bloquea (fail-closed), con un texto genérico", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ editLockedReason: "otro_motivo_futuro" })])} />)
    expect(pencilButtons()).toHaveLength(0)
    expect(screen.getAllByRole("button", { name: /no editable/i }).length).toBeGreaterThan(0)
  })

  it("una venta suelta se sigue pudiendo editar", () => {
    render(<SaleOperationsList {...baseProps([makeSale()])} />)
    expect(pencilButtons().length).toBeGreaterThan(0)
  })
})

describe("SaleOperationsList — borrar una venta nacida de un remito (D9)", () => {
  it("el borrado sigue disponible y el diálogo avisa que el stock no vuelve y que el remito queda pendiente", () => {
    render(<SaleOperationsList {...baseProps([makeSale(FROM_REMITO)])} />)
    const triggers = screen.getAllByTestId("delete-operation-trigger")
    expect(triggers.length).toBeGreaterThan(0)
    fireEvent.click(triggers[0])
    expect(
      screen.getByText(/el stock no vuelve: la mercadería quedó entregada con el remito R-00000007, que vuelve a quedar pendiente/i),
    ).toBeInTheDocument()
    expect(screen.getByText(/para devolverla al stock, anulá el remito/i)).toBeInTheDocument()
  })

  it("una venta suelta no muestra esa línea", () => {
    render(<SaleOperationsList {...baseProps([makeSale()])} />)
    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])
    expect(screen.queryByText(/el stock no vuelve/i)).not.toBeInTheDocument()
  })
})
