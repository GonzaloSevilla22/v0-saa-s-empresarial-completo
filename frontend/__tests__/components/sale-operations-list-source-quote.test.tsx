/**
 * presupuestos-modulo (tanda B, 6.10, D6/OQ-P16) — `/ventas`:
 *  - la operación nacida de un presupuesto muestra el badge "Desde presupuesto
 *    P-00000012" con enlace al presupuesto;
 *  - "Editar" se deshabilita, con su motivo, en una operación con líneas de
 *    servicio (conceptos sin producto): el editor de /ventas no las rehidrata.
 *    Un bloqueo fiscal o de pago (duro, del servidor) gana al de servicio.
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

/** Los lápices habilitados (la fila entera es un div role=button que los contiene: se filtra por BUTTON). */
function pencilButtons(): HTMLElement[] {
  return screen
    .getAllByRole("button")
    .filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))
}

const SERVICE_REASON = /conceptos sin producto de un presupuesto/i

describe("SaleOperationsList — badge 'Desde presupuesto'", () => {
  it("una venta nacida de un presupuesto muestra 'Desde presupuesto P-00000012' con enlace a él", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ sourceQuoteId: "q-9", sourceQuoteNumber: 12 })])} />)

    const links = screen.getAllByRole("link", { name: /desde presupuesto p-00000012/i })
    expect(links.length).toBeGreaterThan(0)
    for (const link of links) expect(link).toHaveAttribute("href", "/presupuestos/q-9")
  })

  it("una venta suelta no muestra ningún badge de origen", () => {
    render(<SaleOperationsList {...baseProps([makeSale()])} />)
    expect(screen.queryByText(/desde presupuesto/i)).not.toBeInTheDocument()
  })

  it("un presupuesto anterior al módulo (sin número) igual enlaza, sin inventar un número", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ sourceQuoteId: "q-old", sourceQuoteNumber: null })])} />)

    const links = screen.getAllByRole("link", { name: /^desde presupuesto$/i })
    expect(links.length).toBeGreaterThan(0)
    expect(links[0]).toHaveAttribute("href", "/presupuestos/q-old")
  })

  it("en escritorio el badge va en su propia línea, fuera de la celda que trunca el nombre del producto (si no, se corta antes del número)", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ sourceQuoteId: "q-9", sourceQuoteNumber: 12 })])} />)

    const desktop = document.querySelector('[class*="sm:grid"][class*="items-center"]') as HTMLElement
    expect(desktop).not.toBeNull()
    const badge = within(desktop).getByRole("link", { name: /desde presupuesto p-00000012/i })
    const productName = within(desktop).getByText(/Remera/)
    const nameCell = productName.closest(".truncate") as HTMLElement
    expect(nameCell).not.toBeNull()
    expect(nameCell.contains(badge)).toBe(false)
    // La fila del nombre (producto + forma de pago) y el badge son hermanos, no la misma fila.
    expect(nameCell.parentElement).not.toBe(badge.parentElement)
  })

  it("el enlace del badge no expande ni colapsa la fila", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ sourceQuoteId: "q-9", sourceQuoteNumber: 12 })])} />)
    const row = screen.getAllByRole("button").find((b) => b.tagName === "DIV" && b.hasAttribute("aria-expanded"))!
    expect(row).toHaveAttribute("aria-expanded", "false")

    const link = screen.getAllByRole("link", { name: /desde presupuesto/i })[0]
    link.click()
    expect(row).toHaveAttribute("aria-expanded", "false")
  })
})

describe("SaleOperationsList — 'Editar' con líneas de servicio (OQ-P16)", () => {
  it("SIN líneas de servicio: 'Editar' está habilitado", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ hasServiceLines: false })])} />)
    const editable = pencilButtons()
    expect(editable.length).toBeGreaterThan(0)
    for (const b of editable) expect(b).not.toBeDisabled()
  })

  it("CON líneas de servicio: 'Editar' queda deshabilitado con el motivo y la salida", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ hasServiceLines: true })])} />)

    const locked = screen.getAllByTitle(SERVICE_REASON)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) {
      expect(b).toBeDisabled()
      expect(b.getAttribute("title")).toMatch(/eliminala y volvé a venderla desde el presupuesto duplicado/i)
    }
    expect(pencilButtons()).toHaveLength(0)
  })

  it("el motivo también es el nombre accesible del botón deshabilitado", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ hasServiceLines: true })])} />)
    expect(screen.getAllByRole("button", { name: SERVICE_REASON }).length).toBeGreaterThan(0)
  })

  it("PRIORIDAD: un bloqueo duro (de pago) gana al de servicio", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ hasServiceLines: true, isPaymentLocked: true })])} />)

    expect(screen.getAllByTitle(/cargo de cuenta corriente/i).length).toBeGreaterThan(0)
    expect(screen.queryAllByTitle(SERVICE_REASON)).toHaveLength(0)
  })

  it("el borrado sigue disponible: una venta con líneas de servicio se puede eliminar", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ hasServiceLines: true })])} />)
    expect(screen.getAllByTestId("delete-operation-trigger").length).toBeGreaterThan(0)
  })
})

describe("SaleOperationsList — detalle expandido en pantallas angostas", () => {
  it("la columna del producto tiene un ancho mínimo y el contenedor desplaza en horizontal, en vez de colapsar el nombre a 0 px (375 px: la descripción del concepto quedaba invisible)", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ productName: "Flete a domicilio" })])} />)
    const row = screen.getAllByRole("button").find((b) => b.tagName === "DIV" && b.hasAttribute("aria-expanded"))!
    fireEvent.click(row)

    const header = screen.getByText("Subtotal").parentElement as HTMLElement
    const track = /grid-cols-\[minmax\((\d+)px,1fr\)_72px_110px_110px\]/.exec(header.className)
    expect(track).not.toBeNull()
    const minName = Number(track![1])
    expect(minName).toBeGreaterThanOrEqual(120)

    // El mínimo del contenedor alcanza para las 4 columnas + 3 huecos de 8 px + el padding de 24 px.
    const minWidth = /min-w-\[(\d+)px\]/.exec(header.className)
    expect(minWidth).not.toBeNull()
    expect(Number(minWidth![1])).toBeGreaterThanOrEqual(minName + 72 + 110 + 110 + 3 * 8 + 24)

    // Las filas de líneas usan el mismo trazado que el encabezado (si no, las columnas se desalinean).
    const rows = Array.from(document.querySelectorAll<HTMLElement>('[class*="72px_110px_110px"]'))
    expect(rows.length).toBeGreaterThanOrEqual(2) // encabezado + al menos una línea
    for (const r of rows) expect(r.className).toContain(track![0])
  })
})
