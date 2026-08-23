/**
 * cuentas-billetera-tipo (tasks 7.1-7.2, 7.4) — /banco ofrece dos entradas de
 * alta diferenciadas por tipo ("+ Banco" / "+ Billetera virtual") tanto en
 * el estado vacío como en el encabezado de la card, sobre un único
 * BankAccountFormDialog parametrizado; el selector de cuenta distingue
 * banco de billetera por ícono.
 *
 * Mocks de los hooks pesados (bank-reconciliation, ledger) siguiendo el
 * precedente de __tests__/pages/caja-page-preselection.test.tsx — sin
 * tab=conciliacion en ningún test, así que ConciliacionTab nunca monta
 * (Radix TabsContent no renderiza children de un tab inactivo).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

const mockUseSearchParams = vi.fn()
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

let bankAccountsFixture: {
  id: string
  accountId: string
  name: string
  bankName: string | null
  cbu: string | null
  alias: string | null
  currency: string
  accountKind: "bank" | "wallet"
  isActive: boolean
}[] = []

const mockCreateBankAccount = vi.fn()
vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({
    data: bankAccountsFixture,
    isLoading: false,
    createBankAccount: mockCreateBankAccount,
    createBankAccountMutation: { isPending: false },
  }),
}))

vi.mock("@/hooks/data/use-bank-reconciliation", () => ({
  useImportStatement: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useOpenSession: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useReconciliationSessions: () => ({ data: [] }),
  useStatementImports: () => ({ data: [] }),
  useRegisterManualMovement: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock("@/hooks/data/use-bank-movements", () => ({
  fetchBankMovementsPage: vi.fn().mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 }),
}))
vi.mock("@/components/bank-reconciliation/ReconciliationBoard", () => ({
  ReconciliationBoard: () => <div data-testid="reconciliation-board" />,
}))
vi.mock("@/components/ledger/LedgerMovementsPanel", () => ({
  LedgerMovementsPanel: () => <div data-testid="ledger-panel" />,
}))
vi.mock("@/components/ledger/LedgerAdjustmentDialog", () => ({
  LedgerAdjustmentDialog: () => <div data-testid="adjustment-dialog" />,
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

async function renderBancoPage() {
  const { default: BancoPage } = await import("@/app/(dashboard)/banco/page")
  return render(<BancoPage />)
}

beforeEach(() => {
  vi.clearAllMocks()
  mockUseSearchParams.mockReturnValue(new URLSearchParams())
  bankAccountsFixture = []
})

describe("/banco — dos entradas de alta por tipo", () => {
  it("estado vacío: ofrece '+ Banco' y '+ Billetera virtual'", async () => {
    await renderBancoPage()

    expect(screen.getByRole("button", { name: /\+ Banco/ })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /\+ Billetera virtual/ })).toBeInTheDocument()
  })

  it("estado vacío: '+ Billetera virtual' abre el diálogo con kind='wallet'", async () => {
    const user = userEvent.setup()
    await renderBancoPage()

    await user.click(screen.getByRole("button", { name: /\+ Billetera virtual/ }))

    expect(screen.getByText("Nueva billetera virtual")).toBeInTheDocument()
  })

  it("estado vacío: '+ Banco' abre el diálogo con kind='bank'", async () => {
    const user = userEvent.setup()
    await renderBancoPage()

    await user.click(screen.getByRole("button", { name: /^\+ Banco$/ }))

    expect(screen.getByText("Nueva cuenta bancaria")).toBeInTheDocument()
  })

  it("con cuentas activas: el encabezado de la card ofrece ambas entradas", async () => {
    bankAccountsFixture = [
      { id: "ba-1", accountId: "acc-1", name: "MP", bankName: null, cbu: null, alias: "luzmin.mp", currency: "ARS", accountKind: "wallet", isActive: true },
    ]

    await renderBancoPage()

    expect(screen.getByRole("button", { name: /\+ Banco/ })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /\+ Billetera virtual/ })).toBeInTheDocument()
  })

  it("el selector de cuenta distingue billetera de banco por ícono", async () => {
    bankAccountsFixture = [
      { id: "ba-1", accountId: "acc-1", name: "MP", bankName: null, cbu: null, alias: "luzmin.mp", currency: "ARS", accountKind: "wallet", isActive: true },
      { id: "ba-2", accountId: "acc-1", name: "Cuenta corriente Galicia", bankName: "Banco Galicia", cbu: null, alias: null, currency: "ARS", accountKind: "bank", isActive: true },
    ]
    const user = userEvent.setup()
    await renderBancoPage()

    await user.click(screen.getByRole("combobox"))

    // Radix SelectContent renderiza en un Portal (document.body) — no dentro
    // del container de render(), por eso se consulta document, no container.
    expect(document.querySelector(".lucide-wallet")).toBeTruthy()
    expect(document.querySelector(".lucide-landmark")).toBeTruthy()
  })
})
