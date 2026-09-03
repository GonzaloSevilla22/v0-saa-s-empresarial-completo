/**
 * cobranzas-reverso (task 13.6-13.7): la acción "Anular" en
 * CustomerAccountHistory / SupplierAccountHistory.
 *
 *   - aparece SÓLO en filas is_reversible (payment-reversal spec, escenario
 *     "La acción aparece sólo en las filas de pago")
 *   - bloqueada con motivo visible cuando is_reversal_blocked, ANTES de
 *     intentar (mismo escenario, "La acción bloqueada muestra el motivo sin
 *     intentar")
 *   - confirmar invoca la mutación con el paymentId (referenceId) y el
 *     motivo opcional
 *   - accesibilidad: nombre accesible en la acción, motivo del bloqueo
 *     llega a lectores de pantalla (no sólo como title) — task 13.7
 */
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { describe, expect, it, vi, beforeEach } from "vitest"

const mutateAsyncCustomer = vi.fn()
vi.mock("@/hooks/data/use-customer-account", () => ({
  useReversePaymentReceived: () => ({ mutateAsync: mutateAsyncCustomer, isPending: false }),
}))

const mutateAsyncSupplier = vi.fn()
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useReversePaymentMade: () => ({ mutateAsync: mutateAsyncSupplier, isPending: false }),
}))

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { CustomerAccountHistory } from "@/components/customer-accounts/CustomerAccountHistory"
import type { CustomerAccountMovement } from "@/hooks/data/use-customer-account"
import { SupplierAccountHistory } from "@/components/supplier-accounts/SupplierAccountHistory"
import type { SupplierAccountMovement } from "@/hooks/data/use-supplier-account"

function customerMovement(overrides: Partial<CustomerAccountMovement>): CustomerAccountMovement {
  return {
    id: "m1",
    customerAccountId: "ca1",
    accountId: "acc1",
    amount: -400,
    balanceAfter: 600,
    movementType: "payment_received",
    referenceId: "pay-1",
    createdBy: "u1",
    createdAt: "2026-09-02T00:00:00Z",
    isReversible: false,
    isReversalBlocked: false,
    hasCashMovement: false,
    hasBankMovement: false,
    paymentMethod: null,
    // cobranzas-vencimientos (D7): derivados de vencimiento — null = no aplica.
    dueDate: null,
    openAmount: null,
    isOverdue: null,
    daysOverdue: null,
    ...overrides,
  }
}

function supplierMovement(overrides: Partial<SupplierAccountMovement>): SupplierAccountMovement {
  return {
    id: "m1",
    supplierAccountId: "sa1",
    accountId: "acc1",
    amount: -300,
    balanceAfter: 700,
    movementType: "payment_made",
    referenceId: "pay-2",
    createdBy: "u1",
    createdAt: "2026-09-02T00:00:00Z",
    isReversible: false,
    isReversalBlocked: false,
    hasCashMovement: false,
    hasBankMovement: false,
    paymentMethod: null,
    // cobranzas-vencimientos (D7): derivados de vencimiento — null = no aplica.
    dueDate: null,
    openAmount: null,
    isOverdue: null,
    daysOverdue: null,
    ...overrides,
  }
}

describe("CustomerAccountHistory — acción Anular", () => {
  beforeEach(() => {
    mutateAsyncCustomer.mockReset()
    mutateAsyncCustomer.mockResolvedValue({ reversed: true })
  })

  it("aparece SÓLO en la fila de un cobro reversible — no en cargo/reversa/ajuste", () => {
    const movements = [
      customerMovement({ id: "sale", movementType: "sale", amount: 1000, isReversible: false }),
      customerMovement({ id: "cobro", movementType: "payment_received", isReversible: true, hasCashMovement: true }),
      customerMovement({ id: "reversa", movementType: "payment_received_reversal", amount: 400, isReversible: false }),
    ]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    // 2 triggers por fila reversible (mobile + desktop layout, ambos en el DOM).
    expect(screen.getAllByTestId("delete-operation-trigger").length).toBe(2)
  })

  it("la acción habilitada tiene nombre accesible propio (task 13.7)", () => {
    const movements = [customerMovement({ isReversible: true })]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    const trigger = screen.getAllByTestId("delete-operation-trigger")[0]
    expect(trigger).toHaveAccessibleName(/anular.*cobro/i)
  })

  it("con is_reversal_blocked: aparece deshabilitada con el motivo, sin abrir el diálogo", () => {
    const movements = [
      customerMovement({ isReversible: true, isReversalBlocked: true, hasCashMovement: true }),
    ]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    const blocked = screen.getAllByTestId("delete-operation-blocked")[0]
    expect(blocked).toBeDisabled()
    expect(blocked).toHaveAttribute("title", expect.stringMatching(/no se puede anular/i))
    // El motivo llega también como aria-label — no sólo como title (task 13.7).
    expect(blocked).toHaveAccessibleName(/no se puede anular/i)
    expect(screen.queryByTestId("delete-operation-trigger")).toBeNull()
  })

  it("confirmar invoca la mutación con el paymentId (referenceId) del movimiento", async () => {
    const movements = [
      customerMovement({ referenceId: "pay-xyz", isReversible: true }),
    ]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])
    fireEvent.click(screen.getByRole("button", { name: /^Anular$/ }))

    await waitFor(() => expect(mutateAsyncCustomer).toHaveBeenCalledWith(
      expect.objectContaining({ paymentId: "pay-xyz" }),
    ))
  })

  it("el diálogo enumera la reposición de deuda para un cobro sin caja ni banco", () => {
    const movements = [customerMovement({ isReversible: true })]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])
    expect(screen.getByText(/repondrá la deuda del cliente/i)).toBeInTheDocument()
    expect(screen.getByText(/asiento contable/i)).toBeInTheDocument()
  })
})

describe("SupplierAccountHistory — acción Anular", () => {
  beforeEach(() => {
    mutateAsyncSupplier.mockReset()
    mutateAsyncSupplier.mockResolvedValue({ reversed: true })
  })

  it("aparece sólo en la fila de un pago reversible", () => {
    const movements = [
      supplierMovement({ id: "cargo", movementType: "purchase", amount: 1000, isReversible: false }),
      supplierMovement({ id: "pago", movementType: "payment_made", isReversible: true }),
    ]
    render(<SupplierAccountHistory movements={movements} supplierId="s1" />)

    expect(screen.getAllByTestId("delete-operation-trigger").length).toBe(2)
  })

  it("el diálogo dice INGRESO en caja para un pago en efectivo (repone, no saca)", () => {
    const movements = [supplierMovement({ isReversible: true, hasCashMovement: true })]
    render(<SupplierAccountHistory movements={movements} supplierId="s1" />)

    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])
    expect(screen.getByText(/ingreso.*caja/i)).toBeInTheDocument()
  })

  it("confirmar invoca la mutación con el paymentId del pago", async () => {
    const movements = [supplierMovement({ referenceId: "pay-abc", isReversible: true })]
    render(<SupplierAccountHistory movements={movements} supplierId="s1" />)

    fireEvent.click(screen.getAllByTestId("delete-operation-trigger")[0])
    fireEvent.click(screen.getByRole("button", { name: /^Anular$/ }))

    await waitFor(() => expect(mutateAsyncSupplier).toHaveBeenCalledWith(
      expect.objectContaining({ paymentId: "pay-abc" }),
    ))
  })
})
