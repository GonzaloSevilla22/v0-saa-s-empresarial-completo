/**
 * PaymentMethodManager — component tests (metodos-pago-operaciones, task 5.1).
 * Espejo del criterio de BranchStockTable.test.tsx: useOrgRole mockeado por
 * caso (member vs owner).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { PaymentMethodManager } from "@/components/payment-methods/PaymentMethodManager"
import { toast } from "sonner"
import type { PaymentMethod } from "@/lib/types"

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}))

const METHODS: PaymentMethod[] = [
  { id: "pm-cash", accountId: "a", name: "Efectivo", kind: "cash", isActive: true, sortOrder: 1, createdAt: "2026-08-19T00:00:00Z", bankAccountId: null },
  { id: "pm-check", accountId: "a", name: "Cheque", kind: "check", isActive: false, sortOrder: 7, createdAt: "2026-08-19T00:00:00Z", bankAccountId: null },
]

const usePaymentMethodsMock = vi.fn()
vi.mock("@/hooks/data/use-payment-methods", () => ({
  usePaymentMethods: (...args: unknown[]) => usePaymentMethodsMock(...args),
}))

// pos-banco-movimientos (D7): PaymentMethodManager ahora también llama a
// useBankAccounts (columna "Cuenta bancaria" + selector del dialog) — sin
// cuentas cargadas por default, espejo del "cero render" de D9 en estos
// tests que no ejercitan el destino bancario.
const useBankAccountsMock = vi.fn()
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => useBankAccountsMock(),
}))

const useOrgRoleMock = vi.fn()
vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => useOrgRoleMock(),
}))

function baseHookReturn(overrides: Partial<ReturnType<typeof defaultHookReturn>> = {}) {
  return { ...defaultHookReturn(), ...overrides }
}

function defaultHookReturn() {
  return {
    paymentMethods: METHODS,
    isLoading: false,
    createPaymentMethod: vi.fn(),
    updatePaymentMethod: vi.fn(),
    deactivatePaymentMethod: vi.fn(),
    reactivatePaymentMethod: vi.fn().mockResolvedValue(undefined),
    createPaymentMethodMutation: { isPending: false },
    updatePaymentMethodMutation: { isPending: false },
    deactivatePaymentMethodMutation: { isPending: false },
    reactivatePaymentMethodMutation: { isPending: false },
  }
}

describe("PaymentMethodManager — gating por rol (D9-espejo)", () => {
  beforeEach(() => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn())
    useBankAccountsMock.mockReturnValue({ data: [], isLoading: false, isError: false, error: null })
  })

  it("member: NO ve el botón 'Nueva' ni las acciones de editar/desactivar", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.queryByText("Nueva")).not.toBeInTheDocument()
    expect(screen.queryByTitle("Editar")).not.toBeInTheDocument()
    expect(screen.queryByTitle("Desactivar")).not.toBeInTheDocument()
  })

  it("member: SÍ puede leer el catálogo (nombres visibles)", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    render(<PaymentMethodManager />)

    // "Efectivo" aparece dos veces: el nombre y la etiqueta de kind (kind
    // "cash" también se traduce como "Efectivo") — se verifica que aparezca
    // al menos una vez, no la unicidad del texto.
    expect(screen.getAllByText("Efectivo").length).toBeGreaterThan(0)
  })

  it("owner: SÍ ve el botón 'Nueva' y las acciones de editar/desactivar", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.getByText("Nueva")).toBeInTheDocument()
    expect(screen.getByTitle("Editar")).toBeInTheDocument()
    expect(screen.getByTitle("Desactivar")).toBeInTheDocument()
  })

  it("admin: también ve las acciones de escritura", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "admin", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.getByText("Nueva")).toBeInTheDocument()
  })

  it("una forma de pago inactiva se muestra con badge 'Inactiva' y sin acciones de escritura visibles para ella", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.getByText("Inactiva")).toBeInTheDocument()
    // Solo la fila activa (Efectivo) tiene botones de acción — 1 Editar, 1 Desactivar.
    expect(screen.getAllByTitle("Editar")).toHaveLength(1)
    expect(screen.getAllByTitle("Desactivar")).toHaveLength(1)
  })

  it("catálogo vacío: mensaje distinto para member (sin invitación a crear) vs owner", () => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn({ paymentMethods: [] }))
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.getByText(/No hay formas de pago definidas\./)).toBeInTheDocument()
    expect(screen.queryByText(/Creá la primera/)).not.toBeInTheDocument()
  })
})

// ── fix/payment-method-reactivate: reactivar una forma de pago inactiva ──

describe("PaymentMethodManager — reactivar (fix/payment-method-reactivate)", () => {
  beforeEach(() => {
    useBankAccountsMock.mockReturnValue({ data: [], isLoading: false, isError: false, error: null })
  })

  it("owner: una fila inactiva muestra el botón 'Reactivar' y NO los de Editar/Desactivar", () => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn())
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.getByRole("button", { name: "Reactivar Cheque" })).toBeInTheDocument()
    // Precondición sin la cual el botón nunca se vería: el gestor pide la
    // lista CON inactivas (el selector operativo pide sólo activas).
    expect(usePaymentMethodsMock).toHaveBeenCalledWith(true)
    // La fila inactiva ("Cheque") no tiene Editar/Desactivar propios: solo
    // existen los de la fila activa ("Efectivo"), 1 de cada uno.
    expect(screen.getAllByTitle("Editar")).toHaveLength(1)
    expect(screen.getAllByTitle("Desactivar")).toHaveLength(1)
  })

  it("owner: click en 'Reactivar' llama a reactivatePaymentMethod con el id y muestra el toast de éxito", async () => {
    const reactivatePaymentMethod = vi.fn().mockResolvedValue(undefined)
    usePaymentMethodsMock.mockReturnValue(baseHookReturn({ reactivatePaymentMethod }))
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    const user = userEvent.setup()
    render(<PaymentMethodManager />)

    await user.click(screen.getByRole("button", { name: "Reactivar Cheque" }))

    expect(reactivatePaymentMethod).toHaveBeenCalledWith("pm-check")
    expect(toast.success).toHaveBeenCalledWith('"Cheque" reactivada')
  })

  it("owner: si reactivar falla, muestra toast de error", async () => {
    const reactivatePaymentMethod = vi.fn().mockRejectedValue(new Error("boom"))
    usePaymentMethodsMock.mockReturnValue(baseHookReturn({ reactivatePaymentMethod }))
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    const user = userEvent.setup()
    render(<PaymentMethodManager />)

    await user.click(screen.getByRole("button", { name: "Reactivar Cheque" }))

    expect(toast.error).toHaveBeenCalledWith("Error al reactivar: boom")
  })

  it("una fila activa NO muestra el botón 'Reactivar'", () => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn())
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.queryByRole("button", { name: "Reactivar Efectivo" })).not.toBeInTheDocument()
  })

  it("member: no ve el botón 'Reactivar' en una fila inactiva", () => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn())
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    render(<PaymentMethodManager />)

    expect(screen.queryByRole("button", { name: "Reactivar Cheque" })).not.toBeInTheDocument()
  })
})

// ── cuentas-billetera-tipo (task 8.1): ícono por tipo de cuenta, no Landmark fijo ─

describe("PaymentMethodManager — cuentas-billetera-tipo (ícono por account_kind)", () => {
  const METHOD_WITH_WALLET_ACCOUNT: PaymentMethod = {
    id: "pm-transfer", accountId: "a", name: "Transferencia", kind: "transfer",
    isActive: true, sortOrder: 2, createdAt: "2026-08-19T00:00:00Z", bankAccountId: "ba-wallet",
  }

  it("una cuenta-default de tipo billetera muestra el ícono de billetera (lucide-wallet), no el Landmark fijo", () => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn({ paymentMethods: [METHOD_WITH_WALLET_ACCOUNT] }))
    useBankAccountsMock.mockReturnValue({
      data: [{ id: "ba-wallet", accountId: "a", name: "Mercado Pago", bankName: null, cbu: null, alias: "luzmin.mp", currency: "ARS", accountKind: "wallet", isActive: true }],
      isLoading: false, isError: false, error: null,
    })
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    const { container } = render(<PaymentMethodManager />)

    expect(container.querySelector(".lucide-wallet")).toBeTruthy()
    expect(container.querySelector(".lucide-landmark")).toBeFalsy()
  })

  it("una cuenta-default de tipo banco muestra el ícono Landmark", () => {
    usePaymentMethodsMock.mockReturnValue(baseHookReturn({ paymentMethods: [METHOD_WITH_WALLET_ACCOUNT] }))
    useBankAccountsMock.mockReturnValue({
      data: [{ id: "ba-wallet", accountId: "a", name: "Galicia", bankName: "Banco Galicia", cbu: null, alias: null, currency: "ARS", accountKind: "bank", isActive: true }],
      isLoading: false, isError: false, error: null,
    })
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    const { container } = render(<PaymentMethodManager />)

    expect(container.querySelector(".lucide-landmark")).toBeTruthy()
    expect(container.querySelector(".lucide-wallet")).toBeFalsy()
  })
})
