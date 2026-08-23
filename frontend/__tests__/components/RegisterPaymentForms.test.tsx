/**
 * cuentas-billetera-tipo (task 8.3): RegisterPaymentForm (cliente) y
 * RegisterPaymentMadeForm (proveedor) distinguen banco de billetera por
 * ícono en el selector de cuenta bancaria — mismo módulo canónico que
 * PaymentMethodManager/PaymentMethodSelect.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { RegisterPaymentForm } from "@/components/customer-accounts/RegisterPaymentForm"
import { RegisterPaymentMadeForm } from "@/components/supplier-accounts/RegisterPaymentMadeForm"

const bankAccountsFixture = [
  { id: "ba-wallet", accountId: "a", name: "Mercado Pago", bankName: null, cbu: null, alias: "luzmin.mp", currency: "ARS", accountKind: "wallet" as const, isActive: true },
  { id: "ba-bank", accountId: "a", name: "Cuenta corriente Galicia", bankName: "Banco Galicia", cbu: null, alias: null, currency: "ARS", accountKind: "bank" as const, isActive: true },
]

vi.mock("@/hooks/data/use-bank-accounts", () => ({
  useBankAccounts: () => ({ data: bankAccountsFixture, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/data/use-customer-account", () => ({
  useRegisterPayment: () => ({ mutateAsync: vi.fn() }),
}))
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useRegisterPaymentMade: () => ({ mutateAsync: vi.fn() }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn() } }))

async function selectTransferMethod(user: ReturnType<typeof userEvent.setup>) {
  await user.click(screen.getByRole("combobox", { name: /método de pago/i }))
  await user.click(await screen.findByRole("option", { name: "Transferencia" }))
}

describe("RegisterPaymentForm — ícono por account_kind en el selector de cuenta bancaria", () => {
  it("distingue billetera de banco por ícono", async () => {
    const user = userEvent.setup()
    render(<RegisterPaymentForm clientId="client-1" />)

    await selectTransferMethod(user)
    await user.click(screen.getByRole("combobox", { name: /cuenta bancaria/i }))

    expect(document.querySelector(".lucide-wallet")).toBeTruthy()
    expect(document.querySelector(".lucide-landmark")).toBeTruthy()
  })
})

describe("RegisterPaymentMadeForm — ícono por account_kind en el selector de cuenta bancaria", () => {
  it("distingue billetera de banco por ícono", async () => {
    const user = userEvent.setup()
    render(<RegisterPaymentMadeForm supplierId="supplier-1" />)

    await selectTransferMethod(user)
    await user.click(screen.getByRole("combobox", { name: /cuenta bancaria/i }))

    expect(document.querySelector(".lucide-wallet")).toBeTruthy()
    expect(document.querySelector(".lucide-landmark")).toBeTruthy()
  })
})
