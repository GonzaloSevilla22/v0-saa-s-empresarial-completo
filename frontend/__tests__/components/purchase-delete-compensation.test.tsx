/**
 * qa-integral-modulos G10 (H12) — el diálogo de borrado de compra debe
 * enumerar la compensación completa: la reversión del cargo en la cuenta
 * corriente del proveedor Y la reversión del stock que la compra ingresó
 * (el borrado efectivamente revierte ambos — verificado por el QA: saldo
 * $8.900 → $0 y stock repuesto — pero el diálogo no decía nada del stock).
 * El spec operation-delete-compensation ya exige "el detalle de qué se va a
 * compensar en cada libro afectado"; el stock es un libro (branch_stock).
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
    id: "pu1",
    date: "2026-08-30",
    productId: "p1",
    productName: "Harina 000",
    quantity: 10,
    unitCost: 890,
    total: 8900,
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

describe("getDeleteCompensation — la compra enumera la reversión de stock (G10/H12)", () => {
  it("compra con cargo posteado: enumera cargo Y stock", () => {
    const info = getDeleteCompensation(
      { hasAccountCharge: true, reversesStock: true },
      "proveedor",
    )
    expect(info.deletable).toBe(true)
    expect(info.compensations.some((c) => /cuenta corriente del proveedor/i.test(c))).toBe(true)
    expect(info.compensations.some((c) => /stock/i.test(c))).toBe(true)
  })

  it("compra sin dinero posteado: igual enumera la reversión de stock", () => {
    const info = getDeleteCompensation({ reversesStock: false, hasAccountCharge: false }, "proveedor")
    expect(info.compensations).toEqual([])
    const withStock = getDeleteCompensation({ reversesStock: true }, "proveedor")
    expect(withStock.compensations.some((c) => /stock/i.test(c))).toBe(true)
  })

  it("la venta (sin el flag) no cambia: sin dinero posteado no enumera nada", () => {
    const info = getDeleteCompensation({}, "cliente")
    expect(info.deletable).toBe(true)
    expect(info.compensations).toEqual([])
  })
})

describe("PurchaseOperationsList — el diálogo de borrado enumera la compensación (G10/H12)", () => {
  it("compra a cuenta corriente: el diálogo nombra la reversión del cargo y la del stock", () => {
    render(
      <PurchaseOperationsList
        {...baseProps([makePurchase({ hasAccountCharge: true, isPaymentLocked: true })])}
      />,
    )

    const triggers = screen.getAllByTestId("delete-operation-trigger")
    fireEvent.click(triggers[triggers.length - 1])

    expect(screen.getByText(/Se va a compensar/i)).toBeInTheDocument()
    expect(
      screen.getByText(/Se revertirá el cargo registrado en la cuenta corriente del proveedor/i),
    ).toBeInTheDocument()
    expect(screen.getByText(/stock/i)).toBeInTheDocument()
  })

  it("compra al contado (sin cargo): el diálogo igual avisa que el stock se revierte", () => {
    render(<PurchaseOperationsList {...baseProps([makePurchase()])} />)

    const triggers = screen.getAllByTestId("delete-operation-trigger")
    fireEvent.click(triggers[triggers.length - 1])

    expect(screen.getByText(/Se va a compensar/i)).toBeInTheDocument()
    expect(screen.getByText(/stock/i)).toBeInTheDocument()
    expect(screen.queryByText(/cuenta corriente/i)).not.toBeInTheDocument()
  })
})
