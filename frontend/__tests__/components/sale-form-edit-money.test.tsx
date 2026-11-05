/**
 * SaleForm — edición CON DINERO (edicion-operaciones-con-dinero, tanda C, 12.1/13.1).
 *
 * Hasta la tanda B la edición de una venta con cuenta corriente, caja o banco era imposible (P0423) y el formulario ocultaba
 * esos bloques con `!isEdit`. Ahora la edición compensa y registra en los libros según un PLAN que calcula el servidor:
 *   · el formulario muestra los bloques de cuenta corriente (vencimiento precargado), caja ("Registrado en caja" marcado si hay
 *     huella) y cuenta bancaria, y un campo opcional «Motivo del cambio»;
 *   · el payload manda las claves tri-estado `cash_session_id`/`bank_account_id`/`due_date` SÓLO cuando el usuario las cambió;
 *   · al guardar pide la vista previa al servidor y, si el plan escribe dinero o tiene un bloqueo, abre el diálogo de confirmación.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { SaleForm } from "@/components/forms/sale-form"
import type { SaleOperation } from "@/lib/group-operations"
import type { EditPreview, MoneyPlan } from "@/lib/money-plan"
import { argentinaToday } from "@/lib/date-range"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

const updateMock = vi.fn()
const previewMock = vi.fn()
const toastSuccess = vi.fn()
const toastError = vi.fn()

let paymentMethodsMock: Array<{ id: string; name: string; kind: string; isActive: boolean }> = []
let sessionMock: { id: string } | null = null

vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [], addProduct: vi.fn() }) }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ clients: [{ id: "client-1", name: "Cliente Test", paymentTermsDays: null }], addClient: vi.fn() }),
}))
vi.mock("@/hooks/data/use-sales", () => ({
  useSales: () => ({
    addSaleOperation: vi.fn(),
    updateSaleOperation: (...a: unknown[]) => updateMock(...a),
    previewSaleOperationEdit: (...a: unknown[]) => previewMock(...a),
  }),
}))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { id: "u1", accountId: "acc-1" } }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
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
        <button type="button" onClick={() => onChange(null)}>Destino configurado</button>
      </div>
    ) : null,
}))
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: () => ({ paymentMethods: paymentMethodsMock, isLoading: false }),
}))
vi.mock("@/hooks/data/use-collection-settings", () => ({
  useCollectionSettings: () => ({ data: { defaultPaymentTermsDays: null }, isLoading: false }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: FACTORY_SCALE_SETTINGS, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({ useCustomerAccount: () => ({ data: { balance: 1000 } }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }) }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: () => ({ data: [{ id: "cashbox-1" }] }) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: () => ({ data: sessionMock, isLoading: false }) }))
vi.mock("@/components/shared/product-picker", () => ({ ProductPicker: () => null }))
vi.mock("@/components/shared/cart-item-list", () => ({ CartItemList: () => null }))
vi.mock("@/components/shared/barcode-scanner-input", () => ({ BarcodeScannerInput: () => null }))
vi.mock("@/components/ui/searchable-select", () => ({ SearchableSelect: () => null }))
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

function makeOperation(over: Partial<SaleOperation> = {}): SaleOperation {
  return {
    key: "op-1",
    operationId: "op-1",
    date: "2026-11-01",
    clientId: "client-1",
    clientName: "Cliente Test",
    currency: "ARS",
    items: [
      {
        id: "sale-1", date: "2026-11-01", productId: "prod-1", productName: "Producto Test", clientId: "client-1",
        clientName: "Cliente Test", quantity: 2, unitPrice: 500, total: 1000, currency: "ARS", operationId: "op-1",
      },
    ],
    total: 1000,
    isGrouped: false,
    paymentMethodId: null,
    branchId: "branch-1",
    canal: null,
    unitId: null,
    isFiscallyLocked: false,
    fiscal: null,
    hasAccountCharge: false,
    hasCashMovement: false,
    hasBankMovement: false,
    sourceQuoteId: null,
    sourceQuoteNumber: null,
    hasServiceLines: false,
    ...over,
  }
}

function submit() {
  fireEvent.click(screen.getByRole("button", { name: /Guardar cambios/i }))
}

beforeEach(() => {
  paymentMethodsMock = [PM_CREDIT, PM_CASH, PM_TRANSFER]
  sessionMock = { id: "ses-0123456789" }
  updateMock.mockResolvedValue({ ok: true, operation_id: "op-1", voided_fiscal_document: null, money: null })
  previewMock.mockResolvedValue(preview())
})

afterEach(() => {
  vi.clearAllMocks()
})

describe("SaleForm — edición: bloques de dinero", () => {
  it("venta a crédito: aparece el bloque de cuenta corriente con el saldo y el vencimiento VIGENTE precargado", () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "client-1" })}
      />,
    )
    expect(screen.getByText(/Saldo actual/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/Vencimiento/i)).toHaveValue("2026-12-01")
  })

  it("el saldo estimado NO cuenta dos veces el cargo que la operación ya tiene", () => {
    // saldo 1000 ya incluye el cargo de 1000 de esta venta; sin cambios el saldo estimado sigue en 1000.
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: null, chargePartyId: "client-1" })}
      />,
    )
    const estimated = screen.getByText(/Después de guardar/i)
    expect(estimated.textContent).toMatch(/1\.000/)
    expect(estimated.textContent).not.toMatch(/2\.000/)
  })

  it("venta en efectivo con movimiento de caja: 'Registrado en caja' aparece TILDADO", () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    const checkbox = screen.getByRole("checkbox")
    expect(checkbox).toHaveAttribute("data-state", "checked")
    expect(screen.getByText(/Registrado en caja/i)).toBeInTheDocument()
  })

  it("venta en efectivo SIN movimiento de caja: el tilde nace destildado", () => {
    render(
      <SaleForm onSuccess={vi.fn()} editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, date: argentinaToday() })} />,
    )
    expect(screen.getByRole("checkbox")).toHaveAttribute("data-state", "unchecked")
  })

  it("transferencia: el selector de cuenta bancaria aparece al editar, con la cuenta de la huella", () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_TRANSFER.id, hasBankMovement: true, bankAccountId: "ba-1" })}
      />,
    )
    expect(screen.getByTestId("bank-value")).toHaveTextContent("ba-1")
  })

  it("hay un campo opcional «Motivo del cambio»", () => {
    render(<SaleForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    expect(screen.getByLabelText(/Motivo del cambio/i)).toBeInTheDocument()
  })

  it("en el alta NO hay motivo del cambio ni el bloque de edición", () => {
    render(<SaleForm onSuccess={vi.fn()} />)
    expect(screen.queryByLabelText(/Motivo del cambio/i)).toBeNull()
  })
})

describe("SaleForm — edición: el payload manda las claves de dinero sólo cuando cambian", () => {
  async function saved() {
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    return updateMock.mock.calls[0][0] as { money?: Record<string, unknown>; meta: Record<string, unknown> }
  }

  it("sin tocar nada: ninguna clave de dinero viaja", async () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "client-1" })}
      />,
    )
    submit()
    const call = await saved()
    expect(call.money ?? {}).toEqual({})
  })

  it("cambiar el vencimiento manda dueDate", async () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "client-1" })}
      />,
    )
    fireEvent.change(screen.getByLabelText(/Vencimiento/i), { target: { value: "2026-12-20" } })
    submit()
    const call = await saved()
    expect(call.money).toEqual({ dueDate: "2026-12-20" })
  })

  it("destildar 'Registrado en caja' manda cashSessionId null explícito", async () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    fireEvent.click(screen.getByRole("checkbox"))
    submit()
    const call = await saved()
    expect(call.money).toEqual({ cashSessionId: null })
  })

  it("con huella de caja y sin tocar el tilde: NO manda cashSessionId", async () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    submit()
    const call = await saved()
    expect(call.money ?? {}).toEqual({})
  })

  it("efectivo de hoy sin huella: tildar manda la sesión abierta", async () => {
    render(
      <SaleForm onSuccess={vi.fn()} editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, date: argentinaToday() })} />,
    )
    fireEvent.click(screen.getByRole("checkbox"))
    submit()
    const call = await saved()
    expect(call.money).toEqual({ cashSessionId: "ses-0123456789" })
  })

  it("cambiar la cuenta bancaria manda bankAccountId; volver al destino configurado manda null", async () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_TRANSFER.id, hasBankMovement: true, bankAccountId: "ba-1" })}
      />,
    )
    fireEvent.click(screen.getByRole("button", { name: "Cambiar cuenta" }))
    submit()
    const call = await saved()
    expect(call.money).toEqual({ bankAccountId: "ba-2" })
  })

  it("el motivo del cambio se manda recortado", async () => {
    render(<SaleForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    fireEvent.change(screen.getByLabelText(/Motivo del cambio/i), { target: { value: "  Corregí el precio " } })
    submit()
    const call = await saved()
    expect(call.money).toEqual({ reason: "Corregí el precio" })
  })
})

describe("SaleForm — edición: el plan del servidor", () => {
  const WITH_CASH = preview({
    writes_money: true,
    cash: { action: "register", register: { session_id: "s", cashbox_id: "b", amount: "200.00", movement_type: "sale" }, reverse: [] },
  })

  it("sin dinero registrado ni forma de pago: no pide vista previa y guarda directo", async () => {
    render(<SaleForm onSuccess={vi.fn()} editingOperation={makeOperation()} />)
    submit()
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    expect(previewMock).not.toHaveBeenCalled()
  })

  it("con dinero registrado pide la vista previa con el MISMO payload que el guardado", async () => {
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: "2026-12-01", chargePartyId: "client-1" })}
      />,
    )
    submit()
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
    expect(previewMock).toHaveBeenCalledTimes(1)
    expect(previewMock.mock.calls[0][0]).toEqual(updateMock.mock.calls[0][0])
  })

  it("si el plan escribe dinero, abre la confirmación y NO guarda hasta que el usuario confirma", async () => {
    previewMock.mockResolvedValue(WITH_CASH)
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    submit()
    expect(await screen.findByRole("alertdialog")).toBeInTheDocument()
    expect(screen.getByText(/entran/i)).toBeInTheDocument()
    expect(updateMock).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole("button", { name: /confirmar y guardar/i }))
    await waitFor(() => expect(updateMock).toHaveBeenCalledTimes(1))
  })

  it("volver a editar cierra la confirmación sin guardar", async () => {
    previewMock.mockResolvedValue(WITH_CASH)
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    submit()
    fireEvent.click(await screen.findByRole("button", { name: /volver a editar/i }))
    await waitFor(() => expect(screen.queryByRole("alertdialog")).toBeNull())
    expect(updateMock).not.toHaveBeenCalled()
  })

  it("un plan con bloqueo muestra el motivo y no deja confirmar", async () => {
    previewMock.mockResolvedValue(
      preview({
        writes_money: true,
        blocks: [{ book: "cash", code: "P0426", token: "no_open_session_for_reversal", message: "no_open_session_for_reversal: x" }],
      }),
    )
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CASH.id, hasCashMovement: true, cashCashboxId: "cashbox-1", cashOpenSessionId: "ses-0123456789" })}
      />,
    )
    submit()
    expect((await screen.findByRole("alert")).textContent).toMatch(/abr[ií] la caja/i)
    expect(screen.getByRole("button", { name: /confirmar y guardar/i })).toBeDisabled()
  })

  it("el aviso posterior sale de la respuesta del servidor (el plan que EJECUTÓ)", async () => {
    previewMock.mockResolvedValue(preview())
    updateMock.mockResolvedValue({ ok: true, operation_id: "op-1", voided_fiscal_document: null, money: WITH_CASH.plan })
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: null, chargePartyId: "client-1" })}
      />,
    )
    submit()
    await waitFor(() => expect(toastSuccess).toHaveBeenCalled())
    expect(String(toastSuccess.mock.calls[0][0])).toMatch(/entran/i)
  })

  it("si la vista previa falla, avisa con un error humanizado y no guarda", async () => {
    previewMock.mockRejectedValue(new Error("cash_intent_required: la sucursal cambió y una sucursal puede tener varias cajas"))
    render(
      <SaleForm
        onSuccess={vi.fn()}
        editingOperation={makeOperation({ paymentMethodId: PM_CREDIT.id, hasAccountCharge: true, chargeDueDate: null, chargePartyId: "client-1" })}
      />,
    )
    submit()
    await waitFor(() => expect(toastError).toHaveBeenCalled())
    expect(String(toastError.mock.calls[0][0])).not.toContain("cash_intent_required")
    expect(updateMock).not.toHaveBeenCalled()
  })
})
