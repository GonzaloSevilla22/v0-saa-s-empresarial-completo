/**
 * caja-compras-cobranzas (task 12.1/12.3/12.4 RED->GREEN->TRIANGULATE): el
 * listado de compras pasa hasCashMovement/isDeleteBlocked a
 * getDeleteCompensation (documento "compra") y deshabilita "Editar" con
 * motivo cuando is_payment_locked es true por caja.
 *
 * Espejo de purchase-delete-compensation.test.tsx (G10/H12), que ya fijó el
 * molde para stock/cuenta corriente.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { PurchaseOperationsList } from "@/components/compras/purchase-operations-list"
import { getDeleteCompensation } from "@/lib/delete-compensation"
import type { Purchase } from "@/lib/types"
import type { PaginationMeta } from "@/lib/pagination-utils"

vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({ PaymentMethodSelect: () => null }))

const meta: PaginationMeta = { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 }

function makePurchase(overrides: Partial<Purchase> = {}): Purchase {
  return {
    id: "pu1", date: "2026-09-01", productId: "p1", productName: "Harina 000",
    quantity: 10, unitCost: 890, total: 8900, operationId: "op1",
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

describe("getDeleteCompensation — documento 'compra' con movimiento de caja (12.2)", () => {
  it("compra con caja y sesión abierta: borrable, enumera la caja como ingreso (reversa)", () => {
    const info = getDeleteCompensation({ hasCashMovement: true, isDeleteBlocked: false }, "proveedor", "compra")
    expect(info.deletable).toBe(true)
    expect(info.compensations.some((c) => /ingreso.*caja abierta actual/i.test(c))).toBe(true)
  })

  it("compra con caja y SIN sesión abierta: bloqueada, motivo nombra 'la compra' (no 'el gasto')", () => {
    const info = getDeleteCompensation({ hasCashMovement: true, isDeleteBlocked: true }, "proveedor", "compra")
    expect(info.deletable).toBe(false)
    expect(info.blockedReason).toMatch(/la compra descontó de una caja/i)
    expect(info.blockedReason).not.toMatch(/el gasto/i)
  })

  it("compra sin caja: comportamiento idéntico al de antes de este change", () => {
    const info = getDeleteCompensation({ hasCashMovement: false, isDeleteBlocked: false }, "proveedor", "compra")
    expect(info.deletable).toBe(true)
    expect(info.compensations.some((c) => /caja/i.test(c))).toBe(false)
  })
})

describe("PurchaseOperationsList — el diálogo de borrado enumera la caja (12.1)", () => {
  it("compra con caja y sesión abierta: el diálogo nombra la reversión de caja, es borrable", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ hasCashMovement: true, isDeleteBlocked: false })])}
      />,
    )

    const triggers = screen.getAllByTestId("delete-operation-trigger")
    fireEvent.click(triggers[triggers.length - 1])

    expect(screen.getByText(/Se va a compensar/i)).toBeInTheDocument()
    expect(screen.getByText(/ingreso.*caja abierta actual/i)).toBeInTheDocument()
  })

  it("compra con caja y SIN sesión abierta: el control de borrado queda deshabilitado con motivo", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ hasCashMovement: true, isDeleteBlocked: true })])}
      />,
    )

    // Cuando info.deletable=false, DeleteOperationDialog renderiza el botón
    // bloqueado con su propio testid — no el trigger del diálogo.
    const blocked = screen.getAllByTestId("delete-operation-blocked")[0]
    expect(blocked).toBeDisabled()
    expect(blocked).toHaveAttribute("title", expect.stringMatching(/la compra descontó de una caja/i))
    expect(screen.queryByTestId("delete-operation-trigger")).not.toBeInTheDocument()
  })
})

describe("PurchaseOperationsList — 'Editar' deshabilitado cuando is_payment_locked es por caja (12.4)", () => {
  it("compra con caja posteada (is_payment_locked=true): el lápiz aparece deshabilitado con motivo visible", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ isPaymentLocked: true, hasCashMovement: true })])}
      />,
    )

    const lockedButtons = screen.getAllByTitle(/movimiento de caja registrado/i)
    expect(lockedButtons.length).toBeGreaterThan(0)
  })

  it("compra sin dinero posteado: 'Editar' sigue habilitado", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase({ isPaymentLocked: false })])} />)

    expect(screen.queryByTitle(/movimiento de caja registrado/i)).not.toBeInTheDocument()
  })
})
