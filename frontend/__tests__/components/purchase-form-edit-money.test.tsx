/**
 * PurchaseForm — edición CON DINERO (edicion-operaciones-con-dinero, tanda C, 12.1/13.1). Espejo de sale-form-edit-money.
 *
 * La compra a crédito, en efectivo o por transferencia se puede editar: la edición compensa y registra en la cuenta corriente
 * del proveedor, la caja y el banco según el plan que calcula el servidor. El formulario muestra los bloques con copy de
 * edición, manda las claves tri-estado SÓLO cuando cambian y confirma el plan antes de guardar.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { PurchaseForm } from "@/components/forms/purchase-form"
import type { PurchaseOperation } from "@/lib/group-operations"
import type { EditPreview, MoneyPlan } from "@/lib/money-plan"
import { argentinaToday } from "@/lib/date-range"

const updateMock = vi.fn()
const previewMock = vi.fn()
const toastSuccess = vi.fn()
const toastError = vi.fn()

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let sessionMock: { id: string } | null = null

vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))
vi.mock("@/components/delivery-notes/PendingPurchaseNotesNotice", () => ({ PendingPurchaseNotesNotice: () => null }))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn(), createProductCategoryMutation: { isPending: false } }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-purchases", () => ({
  usePurchases: () => ({
    addPurchaseOperation: vi.fn(),
    updatePurchaseOperation: (...a: unknown[]) => updateMock(...a),
    previewPurchaseOperationEdit: (...a: unknown[]) => previewMock(...a),
  }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: sessionMock, isLoading: false }) }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: ({ value }: { value: string | null }) => <div data-testid="pm-value">{value ?? "none"}</div>,
  BankAccountDestinationSelect: ({
    value,
    onChange,
    paymentMethodKind,
  }: {
    value: string | null
    onChange: (v: string | null) => void
    paymentMethodKind: string | null
  }) =>
    paymentMethodKind === "transfer" ? (
      <div>
        <span data-testid="bank-value">{value ?? "default"}</span>
        <button type="button" onClick={() => onChange("ba-2")}>Cambiar cuenta</button>
      </div>
    ) : null,
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: null }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({
    suppliers: [{ id: "sup-1", name: "Proveedor Test", paymentTermsDays: null }],
    addSupplier: vi.fn(),
    isLoading: false,
    isError: false,
  }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({ useSupplierAccount: () => ({ data: { balance: 1000 } }) }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/shared/scrollable-cart-shell", () => ({
  ScrollableCartShell: ({ children, footerContent }: { children: React.ReactNode; footerContent?: React.ReactNode }) => (
    <>{children}{footerContent}</>
  ),
}))

const PM_CREDIT = { id: "pm-credit", name: "Cuenta corriente", kind: "credit", isActive: true }
const PM_CASH = { id: "pm-cash", name: "Efectivo", kind: "cash", isActive: true }
const PM_TRANSFER = { id: "pm-transfer", name: "Transferencia", kind: "transfer", isActive: true }

const EMPTY_PLAN: MoneyPlan = {
  writes_money: false,
  blocks: [],
  account: { action: "none", party_kind: null, register: null, reverse: [], current_balance: null, projected_balance: null, current_due_date: null },
  cash: { action: "none", register: null, reverse: [] },
  bank: { action: "none", register: null, reverse: [] },
}
const preview = (over: Partial<MoneyPlan> = {}): EditPreview => ({ dry_run: true, plan: { ...EMPTY_PLAN, ...over }, voided_fiscal_document: null })

function makeOperation(over: Partial<PurchaseOperation> = {}): PurchaseOperation {
  return {
    key: "op-1",
    operationId: "op-1",
    date: "2026-11-01",
    items: [
      { id: "purchase-1", date: "2026-11-01", productId: "prod-1", productName: "Producto Test", quantity: 2, unitCost: 500, total: 1000, operationId: "op-1", unitId: "unit-kg" },
    ],
    total: 1000,
    description: "",
    isGrouped: false,
    paymentMethodId: null,
    branchId: "branch-1",
    unitId: null,
    hasAccountCharge: false,
    hasBankMovement: false,
    hasCashMovement: false,
    isDeleteBlocked: false,
    supplierId: "sup-1",
    supplierName: "Proveedor Test",
    costCenterId: null,
    ...over,
  }
}

function submit() {
  fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))
}

beforeEach(() => {
  paymentMethodsMock = [PM_CREDIT, PM_CASH, PM_TRANSFER]
  sessionMock = { id: "ses-0123456789" }
  updateMock.mockResolvedValue({ ok: true, operation_id: "op-1", money: null })
  previewMock.mockResolvedValue(preview())
})

afterEach(() => {
  vi.clearAllMocks()
})

describe("PurchaseForm — edición: bloques de dinero", () => {
  it("compra a crédito: saldo del proveedor y vencimiento VIGENTE precargado", () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "sup-1" })}
      />,
    )
    expect(screen.getByText(/Saldo actual/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/Vencimiento/i)).toHaveValue("2026-12-01")
    // 1000 de saldo ya incluye el cargo de esta compra (1000): no se cuenta dos veces.
    expect(screen.getByText(/Después de guardar/i).textContent).not.toMatch(/2\.000/)
  })

  it("compra en efectivo con movimiento de caja: 'Registrado en caja' TILDADO", () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "checked")
    expect(screen.getByText(/Registrado en caja/i)).toBeInTheDocument()
  })

  it("transferencia: el selector de cuenta bancaria aparece al editar, con la cuenta de la huella", () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_TRANSFER.id, hasBankMovement: true, bankAccountId: "ba-1" })}
      />,
    )
    expect(screen.getByTestId("bank-value")).toHaveTextContent("ba-1")
  })

  it("hay un campo opcional «Motivo del cambio»; en el alta no", () => {
    const { unmount } = render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    expect(screen.getByLabelText(/Motivo del cambio/i)).toBeInTheDocument()
    unmount()
    render(<PurchaseForm onSuccess={vi.fn()} />)
    expect(screen.queryByLabelText(/Motivo del cambio/i)).toBeNull()
  })

  it("pasar a crédito desde otra forma de pago ya no se avisa como imposible", () => {
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id })} />)
    expect(screen.queryByText(/borrala y volvé a cargarla/i)).toBeNull()
  })
})

describe("PurchaseForm — edición: el payload manda las claves de dinero sólo cuando cambian", () => {
  async function saved() {
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    return updateMock.mock.calls[0][0] as { money?: Record<string, unknown> }
  }

  it("sin tocar nada: ninguna clave de dinero viaja", async () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "sup-1" })}
      />,
    )
    submit()
    const call = await saved()
    expect(call.money ?? {}).toEqual({})
  })

  it("cambiar el vencimiento manda dueDate", async () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "sup-1" })}
      />,
    )
    fireEvent.change(screen.getByLabelText(/Vencimiento/i), { target: { value: "2026-12-20" } })
    submit()
    expect((await saved()).money).toEqual({ dueDate: "2026-12-20" })
  })

  it("destildar 'Registrado en caja' manda cashSessionId null explícito", async () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    fireEvent.click(screen.getByRole("checkbox"))
    submit()
    expect((await saved()).money).toEqual({ cashSessionId: null })
  })

  it("efectivo de hoy sin huella: tildar manda la sesión abierta", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, date: argentinaToday() })} />)
    fireEvent.click(screen.getByRole("checkbox"))
    submit()
    expect((await saved()).money).toEqual({ cashSessionId: "ses-0123456789" })
  })

  it("cambiar la cuenta bancaria manda bankAccountId", async () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_TRANSFER.id, hasBankMovement: true, bankAccountId: "ba-1" })}
      />,
    )
    fireEvent.click(screen.getByRole("button", { name: "Cambiar cuenta" }))
    submit()
    expect((await saved()).money).toEqual({ bankAccountId: "ba-2" })
  })

  it("el motivo del cambio se manda recortado", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    fireEvent.change(screen.getByLabelText(/Motivo del cambio/i), { target: { value: " Costo mal cargado " } })
    submit()
    expect((await saved()).money).toEqual({ reason: "Costo mal cargado" })
  })
})

describe("PurchaseForm — edición: el plan del servidor", () => {
  const PURCHASE_CASH_OUT = preview({
    writes_money: true,
    cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: "-350.00", movement_type: "purchase_payment" }, reverse: [] },
  })

  it("sin dinero ni forma de pago: no pide vista previa", async () => {
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    submit()
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    expect(previewMock).not.toHaveBeenCalled()
  })

  it("con dinero registrado pide la vista previa con el MISMO payload que el guardado", async () => {
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: null, chargePartyId: "sup-1" })}
      />,
    )
    submit()
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    expect(previewMock.mock.calls[0][0]).toEqual(updateMock.mock.calls[0][0])
  })

  it("si el plan escribe dinero abre la confirmación (en una compra el efectivo SALE de la caja) y guarda al confirmar", async () => {
    previewMock.mockResolvedValue(PURCHASE_CASH_OUT)
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    submit()
    expect(await screen.findByRole("alertdialog")).toBeInTheDocument()
    expect(screen.getByText(/salen/i)).toBeInTheDocument()
    expect(updateMock).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: /confirmar y guardar/i }))
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
  })

  it("un plan con bloqueo no deja confirmar y muestra el motivo", async () => {
    previewMock.mockResolvedValue(
      preview({
        writes_money: true,
        blocks: [{ book: "account", code: "P0425", token: "reversal_would_go_negative", message: "reversal_would_go_negative: el saldo de la cuenta corriente quedaría en -50.00: ya" }],
      }),
    )
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: null, chargePartyId: "sup-1" })}
      />,
    )
    submit()
    expect((await screen.findByRole("alert")).textContent).toMatch(/anul[aá] primero el pago/i)
    expect(screen.getByRole("button", { name: /confirmar y guardar/i })).toBeDisabled()
  })

  it("el aviso posterior sale de la respuesta del servidor", async () => {
    updateMock.mockResolvedValue({ ok: true, operation_id: "op-1", money: PURCHASE_CASH_OUT.plan })
    render(
      <PurchaseForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: null, chargePartyId: "sup-1" })}
      />,
    )
    submit()
    await waitFor(() => expect(toastSuccess).toHaveBeenCalled())
    expect(String(toastSuccess.mock.calls[0][0])).toMatch(/salen/i)
  })

  it("si el guardado es rechazado por el saldo, el error habla del pago y de edición", async () => {
    updateMock.mockRejectedValue(new Error("reversal_would_go_negative: el saldo de la cuenta corriente quedaría en -50.00: ya"))
    render(<PurchaseForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    submit()
    await waitFor(() => expect(toastError).toHaveBeenCalled())
    const text = String(toastError.mock.calls[0][0])
    expect(text).not.toContain("reversal_would_go_negative")
    expect(text).toMatch(/anul[aá] primero el pago/i)
  })
})
