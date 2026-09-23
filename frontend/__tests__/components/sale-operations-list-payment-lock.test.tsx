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

// venta-editable-sin-cae: este literal NO compilaba (pageSize 20 no es un
// PageSizeOption, y `total`/`pages`/`hasNext`/`hasPrev` no existen en
// PaginationMeta — errores de tsc PREEXISTENTES de este archivo, que el
// primero tapaba). Corregido al tocarlo, con los nombres reales del tipo.
const meta: PaginationMeta = {
  page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1,
}

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

/** Los lápices (habilitados) de la fila — móvil y desktop renderizan uno cada uno.
 *
 * `tagName === "BUTTON"` NO es decorativo: la fila entera es un
 * `<div role="button">` (el toggle de expandir) que CONTIENE los lápices, así
 * que un filtro por `querySelector("svg.lucide-pencil")` a secas también la
 * matchea y devuelve 3 elementos en vez de 2 — con el wrapper primero y sin
 * `title`, que es exactamente el falso negativo que este comentario evita. */
function pencilButtons(): HTMLElement[] {
  return screen
    .getAllByRole("button")
    .filter((b) => b.tagName === "BUTTON" && b.querySelector("svg.lucide-pencil"))
}

describe("SaleOperationsList — D6 disable 'Editar' con cargo/movimiento posteado", () => {
  it("operación SIN cargo/movimiento: el botón Editar está habilitado", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isPaymentLocked: false })])} />)
    const editButtons = pencilButtons()
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

// ── venta-editable-sin-cae ────────────────────────────────────────────────────
//
// HALLAZGO que este change cierra: el lápiz del listado NO consultaba el estado
// fiscal en absoluto — se deshabilitaba SÓLO por isPaymentLocked. Lo único que
// frenaba editar una venta facturada era el banner del formulario, UNA VEZ
// ABIERTO (el borrado sí estaba bien gateado). Esa asimetría se cierra acá.

const AUTHORIZED = {
  documentId: "fd-a", status: "authorized" as const, label: "0003-00000004",
  submittedToArca: true, frozen: false, voidable: false,
}
const SENT_PENDING = {
  documentId: "fd-s", status: "pending_cae" as const, label: "0003-00000006",
  submittedToArca: true, frozen: false, voidable: false,
}
const FROZEN = {
  documentId: "fd-f", status: "pending_cae" as const, label: "0003-00000007",
  submittedToArca: true, frozen: true, voidable: false,
}
const VOIDABLE = {
  documentId: "fd-v", status: "pending_cae" as const, label: "0003-00000005",
  submittedToArca: false, frozen: false, voidable: true,
}
const VOIDED = {
  documentId: "fd-x", status: "voided" as const, label: "0003-00000005",
  submittedToArca: false, frozen: false, voidable: false,
}

describe("SaleOperationsList — el lápiz nombra la CAUSA FISCAL real", () => {
  it("comprobante AUTORIZADO: deshabilitado, y el motivo manda a la nota de crédito", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isFiscallyLocked: true, fiscal: AUTHORIZED })])} />)
    const locked = screen.getAllByTitle(/autorizado por ARCA/i)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) expect(b).toBeDisabled()
    expect(locked[0].getAttribute("title")).toContain("0003-00000004")
    expect(locked[0].getAttribute("title")).toMatch(/nota de crédito/i)
    expect(pencilButtons()).toHaveLength(0)
  })

  it("comprobante ENVIADO y sin respuesta: deshabilitado, y el motivo dice esperar", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isFiscallyLocked: true, fiscal: SENT_PENDING })])} />)
    const locked = screen.getAllByTitle(/ya se envió a ARCA y estamos esperando la respuesta/i)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) expect(b).toBeDisabled()
    expect(locked[0].getAttribute("title")).toContain("0003-00000006")
  })

  it("comprobante CONGELADO: deshabilitado, y el motivo pide revisión manual", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isFiscallyLocked: true, fiscal: FROZEN })])} />)
    const locked = screen.getAllByTitle(/no se confirmó y necesita revisión manual/i)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) expect(b).toBeDisabled()
  })

  it("comprobante PENDIENTE no enviado: HABILITADO, con aviso de que se va a anular", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isFiscallyLocked: false, fiscal: VOIDABLE })])} />)
    const editable = pencilButtons()
    expect(editable.length).toBeGreaterThan(0)
    for (const b of editable) {
      expect(b).not.toBeDisabled()
      expect(b.getAttribute("title")).toMatch(/se va a anular el comprobante pendiente/i)
      expect(b.getAttribute("title")).toContain("0003-00000005")
    }
  })

  it("comprobante ya ANULADO: habilitado y SIN aviso de anulación (no hay nada que anular)", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isFiscallyLocked: false, fiscal: VOIDED })])} />)
    const editable = pencilButtons()
    expect(editable.length).toBeGreaterThan(0)
    for (const b of editable) {
      expect(b).not.toBeDisabled()
      expect(b.getAttribute("title")).toBeNull()
    }
  })

  it("PRIORIDAD: con bloqueo fiscal Y de pago a la vez, gana el motivo FISCAL", () => {
    render(
      <SaleOperationsList
        {...baseProps([makeSale({ isFiscallyLocked: true, fiscal: AUTHORIZED, isPaymentLocked: true })])}
      />,
    )
    expect(screen.getAllByTitle(/autorizado por ARCA/i).length).toBeGreaterThan(0)
    expect(screen.queryAllByTitle(/cargo de cuenta corriente/i)).toHaveLength(0)
  })

  it("fail-closed: isFiscallyLocked sin estado fiscal reconocible igual bloquea", () => {
    render(<SaleOperationsList {...baseProps([makeSale({ isFiscallyLocked: true, fiscal: null })])} />)
    const locked = screen.getAllByTitle(/ya se envió a ARCA/i)
    expect(locked.length).toBeGreaterThan(0)
    for (const b of locked) expect(b).toBeDisabled()
    expect(pencilButtons()).toHaveLength(0)
  })
})
