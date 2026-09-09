/**
 * cobranzas-vencimientos OQ-1 — acción "Editar vencimiento" en
 * CustomerAccountHistory / SupplierAccountHistory.
 *
 *   - visible SÓLO para owner/admin (useOrgRole.isWriter)
 *   - visible SÓLO en filas de CARGO (sale/purchase o adjustment>0) con
 *     saldo abierto (openAmount > 0) — nunca en cobros/pagos/reversas ni en
 *     un cargo ya saldado
 *   - confirmar invoca la mutación con due_date en ISO (yyyy-mm-dd)
 *   - vaciar la fecha y confirmar invoca la mutación con dueDate: null
 */
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import { describe, expect, it, vi, beforeEach } from "vitest"

const mutateAsyncCustomerReverse = vi.fn()
const mutateAsyncCustomerDueDate = vi.fn()
vi.mock("@/hooks/data/use-customer-account", () => ({
  useReversePaymentReceived: () => ({ mutateAsync: mutateAsyncCustomerReverse, isPending: false }),
  useUpdateCustomerChargeDueDate: () => ({ mutateAsync: mutateAsyncCustomerDueDate, isPending: false }),
}))

const mutateAsyncSupplierReverse = vi.fn()
const mutateAsyncSupplierDueDate = vi.fn()
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useReversePaymentMade: () => ({ mutateAsync: mutateAsyncSupplierReverse, isPending: false }),
  useUpdateSupplierChargeDueDate: () => ({ mutateAsync: mutateAsyncSupplierDueDate, isPending: false }),
}))

const mockUseOrgRole = vi.fn()
vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => mockUseOrgRole(),
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
    amount: 1000,
    balanceAfter: 1000,
    movementType: "sale",
    referenceId: null,
    createdBy: "u1",
    createdAt: "2026-08-06T00:00:00Z",
    isReversible: false,
    isReversalBlocked: false,
    hasCashMovement: false,
    hasBankMovement: false,
    paymentMethod: null,
    dueDate: "2026-08-06",
    openAmount: 1000,
    isOverdue: false,
    daysOverdue: null,
    ...overrides,
  }
}

function supplierMovement(overrides: Partial<SupplierAccountMovement>): SupplierAccountMovement {
  return {
    id: "m1",
    supplierAccountId: "sa1",
    accountId: "acc1",
    amount: 800,
    balanceAfter: 800,
    movementType: "purchase",
    referenceId: null,
    createdBy: "u1",
    createdAt: "2026-08-11T00:00:00Z",
    isReversible: false,
    isReversalBlocked: false,
    hasCashMovement: false,
    hasBankMovement: false,
    paymentMethod: null,
    dueDate: "2026-08-11",
    openAmount: 800,
    isOverdue: false,
    daysOverdue: null,
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  mockUseOrgRole.mockReturnValue({ role: "owner", isWriter: true, isLoading: false })
})

describe("CustomerAccountHistory — Editar vencimiento", () => {
  it("NO aparece para un member (sin rol de escritura), aunque el cargo esté abierto", () => {
    mockUseOrgRole.mockReturnValue({ role: "member", isWriter: false, isLoading: false })
    render(<CustomerAccountHistory movements={[customerMovement({})]} clientId="c1" />)

    expect(screen.queryByTestId("edit-charge-due-date-trigger")).toBeNull()
  })

  it("aparece para owner en un cargo (sale) con saldo abierto", () => {
    render(<CustomerAccountHistory movements={[customerMovement({})]} clientId="c1" />)

    // 2 triggers (mobile + desktop), mismo criterio que delete-operation-trigger.
    expect(screen.getAllByTestId("edit-charge-due-date-trigger").length).toBe(2)
  })

  it("NO aparece en un cobro (payment_received) — no es un cargo", () => {
    const movements = [
      customerMovement({
        id: "cobro", movementType: "payment_received", amount: -400,
        dueDate: null, openAmount: null,
      }),
    ]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    expect(screen.queryByTestId("edit-charge-due-date-trigger")).toBeNull()
  })

  it("NO aparece en un cargo ya saldado (openAmount = 0)", () => {
    const movements = [customerMovement({ openAmount: 0 })]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    expect(screen.queryByTestId("edit-charge-due-date-trigger")).toBeNull()
  })

  it("un ajuste positivo (adjustment, amount>0) con saldo abierto SÍ ofrece la acción", () => {
    const movements = [
      customerMovement({ movementType: "adjustment", amount: 500, openAmount: 500 }),
    ]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    expect(screen.getAllByTestId("edit-charge-due-date-trigger").length).toBe(2)
  })

  it("un ajuste NEGATIVO (no es cargo) NO ofrece la acción aunque tenga openAmount", () => {
    const movements = [
      customerMovement({ movementType: "adjustment", amount: -500, openAmount: null }),
    ]
    render(<CustomerAccountHistory movements={movements} clientId="c1" />)

    expect(screen.queryByTestId("edit-charge-due-date-trigger")).toBeNull()
  })

  it("confirmar con una fecha nueva invoca la mutación con due_date en ISO", async () => {
    mutateAsyncCustomerDueDate.mockResolvedValue({
      movement_id: "m1", due_date: "2026-10-15", previous_due_date: "2026-08-06",
    })
    render(<CustomerAccountHistory movements={[customerMovement({ id: "m1" })]} clientId="c1" />)

    fireEvent.click(screen.getAllByTestId("edit-charge-due-date-trigger")[0])
    const dialog = screen.getByRole("dialog")
    const dateInput = within(dialog).getByLabelText("Vencimiento")
    fireEvent.change(dateInput, { target: { value: "2026-10-15" } })
    fireEvent.click(screen.getByRole("button", { name: /^Guardar$/ }))

    await waitFor(() => expect(mutateAsyncCustomerDueDate).toHaveBeenCalledWith(
      expect.objectContaining({ movementId: "m1", dueDate: "2026-10-15" }),
    ))
  })

  it("vaciar la fecha y confirmar invoca la mutación con dueDate: null", async () => {
    mutateAsyncCustomerDueDate.mockResolvedValue({
      movement_id: "m1", due_date: null, previous_due_date: "2026-08-06",
    })
    render(<CustomerAccountHistory movements={[customerMovement({ id: "m1" })]} clientId="c1" />)

    fireEvent.click(screen.getAllByTestId("edit-charge-due-date-trigger")[0])
    const dialog = screen.getByRole("dialog")
    const dateInput = within(dialog).getByLabelText("Vencimiento")
    fireEvent.change(dateInput, { target: { value: "" } })
    fireEvent.click(screen.getByRole("button", { name: /^Guardar$/ }))

    await waitFor(() => expect(mutateAsyncCustomerDueDate).toHaveBeenCalledWith(
      expect.objectContaining({ movementId: "m1", dueDate: null }),
    ))
  })
})

describe("SupplierAccountHistory — Editar vencimiento", () => {
  it("NO aparece para un member", () => {
    mockUseOrgRole.mockReturnValue({ role: "member", isWriter: false, isLoading: false })
    render(<SupplierAccountHistory movements={[supplierMovement({})]} supplierId="s1" />)

    expect(screen.queryByTestId("edit-charge-due-date-trigger")).toBeNull()
  })

  it("aparece para owner en un cargo (purchase) con saldo abierto", () => {
    render(<SupplierAccountHistory movements={[supplierMovement({})]} supplierId="s1" />)

    expect(screen.getAllByTestId("edit-charge-due-date-trigger").length).toBe(2)
  })

  it("NO aparece en un pago (payment_made)", () => {
    const movements = [
      supplierMovement({
        id: "pago", movementType: "payment_made", amount: -300,
        dueDate: null, openAmount: null,
      }),
    ]
    render(<SupplierAccountHistory movements={movements} supplierId="s1" />)

    expect(screen.queryByTestId("edit-charge-due-date-trigger")).toBeNull()
  })

  it("confirmar invoca la mutación de proveedor con due_date en ISO", async () => {
    mutateAsyncSupplierDueDate.mockResolvedValue({
      movement_id: "m1", due_date: "2026-10-20", previous_due_date: "2026-08-11",
    })
    render(<SupplierAccountHistory movements={[supplierMovement({ id: "m1" })]} supplierId="s1" />)

    fireEvent.click(screen.getAllByTestId("edit-charge-due-date-trigger")[0])
    const dialog = screen.getByRole("dialog")
    const dateInput = within(dialog).getByLabelText("Vencimiento")
    fireEvent.change(dateInput, { target: { value: "2026-10-20" } })
    fireEvent.click(screen.getByRole("button", { name: /^Guardar$/ }))

    await waitFor(() => expect(mutateAsyncSupplierDueDate).toHaveBeenCalledWith(
      expect.objectContaining({ movementId: "m1", dueDate: "2026-10-20" }),
    ))
  })
})
